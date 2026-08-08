import 'dart:ffi';

import 'package:meta/meta.dart';

import '../local_timezone_exception.dart';
import '../provider/provider_base.dart';
import '../resolved_local_timezone.dart';
import '../windows_zones.g.dart';

/// `GetDynamicTimeZoneInformation` returns this when it fails.
const _timeZoneIdInvalid = 0xFFFFFFFF;

/// `HEAP_ZERO_MEMORY`. Worth the flag: the decode below trusts that the buffer
/// past the terminator is zeroed, and an uninitialised heap block would let
/// stale bytes through.
const _heapZeroMemory = 0x00000008;

/// A [Provider] that reads the local timezone from the Win32 timezone API.
///
/// Calls `GetDynamicTimeZoneInformation` and maps the registry key it reports
/// through CLDR. Only `kernel32.dll` is opened, which matters: the obvious
/// alternative, ICU's `ucal_getTimeZoneIDForWindowsID`, would impose a Windows
/// 10 version 1903 floor, because that is when the combined `icu.dll` first
/// shipped. `GetDynamicTimeZoneInformation` has been present since Vista and
/// Server 2008, so this has effectively no floor.
///
/// `GetDynamicTimeZoneInformation` is used rather than the older
/// `GetTimeZoneInformation` because the latter reports a localized display name
/// that cannot be looked up. Its `TimeZoneKeyName` is the stable registry key,
/// and it is also more accurate: in Singapore the older call reports "Malay
/// Peninsula Standard Time" where the registry key is "Singapore Standard
/// Time".
class WindowsProvider extends Provider {
  const WindowsProvider._();

  /// Constructs a [WindowsProvider].
  const factory WindowsProvider() = WindowsProvider._;

  /// The device's timezone.
  ///
  /// Always a [NamedLocalTimezone]. Windows has no notion of a bare offset
  /// zone: every configuration names a registry key.
  ///
  /// Throws [LocalTimezoneUnavailableException] when the call fails, when the
  /// key is empty, or when CLDR has no mapping for it, which happens if
  /// Windows ships a zone newer than the bundled table.
  @override
  ResolvedLocalTimezone resolve() {
    final key = _readTimeZoneKeyName();
    if (key.isEmpty) {
      _unavailable('GetDynamicTimeZoneInformation reported an empty key name');
    }

    final iana = windowsZoneToIana(key, region: _readRegion());
    if (iana == null) {
      _unavailable(
        'no CLDR mapping for the Windows zone key `$key` (bundled CLDR '
        '$windowsZonesCldrVersion)',
      );
    }

    return NamedLocalTimezone(
      name: iana,
      canonicalized: canonicalizeName(iana),
      raw: key,
    );
  }

  Never _unavailable(String reason) => throw LocalTimezoneUnavailableException(
    platform: 'windows',
    reason: reason,
  );
}

/// Maps a Windows zone key to an IANA identifier, preferring [region].
///
/// Of 139 Windows keys, 66 cover more than one IANA zone. "Romance Standard
/// Time" is `Europe/Paris` in France and `Europe/Madrid` in Spain, and CLDR
/// marks the tie-break with territory `001`. Consulting only that fallback,
/// which is what most implementations do, silently puts every Spanish user in
/// Paris.
///
/// Returns null when the key is unknown, rather than guessing.
@visibleForTesting
String? windowsZoneToIana(String key, {String? region}) {
  if (region != null && region.isNotEmpty) {
    final specific = windowsZonesByTerritory['$key|$region'];
    if (specific != null) return specific;
  }
  return windowsZones[key];
}

/// Decodes a NUL-terminated UTF-16 buffer of at most [capacity] code units,
/// reading them one at a time through [unitAt].
///
/// Takes an accessor rather than the `Array<Uint16>` itself so the decode can
/// be tested off Windows, where no such array can be constructed.
///
/// Stops at the first NUL rather than skipping over them. Skipping looks
/// equivalent and is not: it concatenates whatever follows the terminator into
/// the key, which then fails to map. That is a real bug in at least one
/// published package, and it only shows up on a buffer that is not zeroed.
@visibleForTesting
String decodeUtf16(int Function(int index) unitAt, int capacity) {
  final units = <int>[];
  for (var i = 0; i < capacity; i++) {
    final unit = unitAt(i);
    if (unit == 0) break;
    units.add(unit);
  }
  // Dart strings are UTF-16 internally, so surrogate pairs pass through.
  return String.fromCharCodes(units);
}

String _readTimeZoneKeyName() {
  final heap = _getProcessHeap();
  final buffer = _heapAlloc(
    heap,
    _heapZeroMemory,
    sizeOf<_DynamicTimeZoneInformation>(),
  ).cast<_DynamicTimeZoneInformation>();
  if (buffer == nullptr) {
    // HeapAlloc returns null under memory pressure. Handing that to Win32
    // would be a null write inside the kernel call, not a Dart exception.
    throw const LocalTimezoneUnavailableException(
      platform: 'windows',
      reason: 'HeapAlloc could not allocate DYNAMIC_TIME_ZONE_INFORMATION',
    );
  }
  try {
    // The return value is not a status code in the usual sense: 0, 1 and 2 all
    // mean success and describe whether daylight time is in effect. Only
    // TIME_ZONE_ID_INVALID signals failure, and ignoring it would leave the
    // caller reading a zeroed buffer as though it were a real answer.
    if (_getDynamicTimeZoneInformation(buffer) == _timeZoneIdInvalid) {
      throw const LocalTimezoneUnavailableException(
        platform: 'windows',
        reason: 'GetDynamicTimeZoneInformation returned TIME_ZONE_ID_INVALID',
      );
    }
    final key = buffer.ref.timeZoneKeyName;
    return decodeUtf16((i) => key[i], 128);
  } finally {
    _heapFree(heap, 0, buffer.cast());
  }
}

/// The user's region as a two-letter code, or null when unavailable.
///
/// `GetUserDefaultGeoName` arrived in Windows 10 version 1709. It is resolved
/// at runtime rather than linked, so older Windows loses the territory
/// refinement and falls back to CLDR's default instead of failing to start.
String? _readRegion() {
  final function = _getUserDefaultGeoName;
  if (function == null) return null;

  const capacity = 16;
  final heap = _getProcessHeap();
  final buffer = _heapAlloc(heap, _heapZeroMemory, capacity * 2).cast<Uint16>();
  // The region is an optional refinement, so an allocation failure here
  // degrades to CLDR's territory-independent fallback rather than throwing.
  if (buffer == nullptr) return null;
  try {
    final written = function(buffer, capacity);
    if (written <= 0) return null;
    return decodeUtf16((i) => buffer[i], capacity);
  } on Object {
    return null;
  } finally {
    _heapFree(heap, 0, buffer.cast());
  }
}

// ---------------------------------------------------------------- bindings

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();

final _GetProcessHeapDart _getProcessHeap = _kernel32
    .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
      'GetProcessHeap',
    );

typedef _HeapAllocNative =
    Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr);
typedef _HeapAllocDart = Pointer<Void> Function(Pointer<Void>, int, int);

final _HeapAllocDart _heapAlloc = _kernel32
    .lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');

typedef _HeapFreeNative = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(Pointer<Void>, int, Pointer<Void>);

final _HeapFreeDart _heapFree = _kernel32
    .lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');

/// Returns `DWORD`, which is 32 bits. Declaring it wider would leave the high
/// half undefined and could turn TIME_ZONE_ID_INVALID into a value that reads
/// as success.
typedef _GetTimeZoneNative =
    Uint32 Function(Pointer<_DynamicTimeZoneInformation>);
typedef _GetTimeZoneDart = int Function(Pointer<_DynamicTimeZoneInformation>);

final _GetTimeZoneDart _getDynamicTimeZoneInformation = _kernel32
    .lookupFunction<_GetTimeZoneNative, _GetTimeZoneDart>(
      'GetDynamicTimeZoneInformation',
    );

typedef _GetGeoNameNative = Int32 Function(Pointer<Uint16>, Int32);
typedef _GetGeoNameDart = int Function(Pointer<Uint16>, int);

/// Absent before Windows 10 version 1709, so this is resolved defensively.
final _GetGeoNameDart? _getUserDefaultGeoName = () {
  try {
    return _kernel32.lookupFunction<_GetGeoNameNative, _GetGeoNameDart>(
      'GetUserDefaultGeoName',
    );
  } on ArgumentError {
    return null;
  }
}();

/// `SYSTEMTIME`, eight `WORD` fields. Present only so the enclosing struct has
/// the right size and field offsets; none of it is read.
final class _SystemTime extends Struct {
  @Uint16()
  external int year;
  @Uint16()
  external int month;
  @Uint16()
  external int dayOfWeek;
  @Uint16()
  external int day;
  @Uint16()
  external int hour;
  @Uint16()
  external int minute;
  @Uint16()
  external int second;
  @Uint16()
  external int milliseconds;
}

/// `DYNAMIC_TIME_ZONE_INFORMATION`, 432 bytes.
///
/// The API takes no size argument, so it writes the full structure regardless
/// of what the caller believes. Every field has to be declared even though only
/// [timeZoneKeyName] is read, or the allocation would be short and the call
/// would write past it.
///
/// The trailing field is `BOOLEAN`, one byte, not the four-byte `BOOL`.
final class _DynamicTimeZoneInformation extends Struct {
  @Int32()
  external int bias;

  @Array(32)
  external Array<Uint16> standardName;

  external _SystemTime standardDate;

  @Int32()
  external int standardBias;

  @Array(32)
  external Array<Uint16> daylightName;

  external _SystemTime daylightDate;

  @Int32()
  external int daylightBias;

  /// The stable registry key, such as `India Standard Time`. This is the only
  /// field worth reading: the two display names above are localized.
  @Array(128)
  external Array<Uint16> timeZoneKeyName;

  @Uint8()
  external int dynamicDaylightTimeDisabled;
}
