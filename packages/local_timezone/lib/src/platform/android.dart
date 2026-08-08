import 'dart:convert';
import 'dart:ffi';

import 'package:meta/meta.dart';

import '../local_timezone_exception.dart';
import '../provider/provider_base.dart';
import '../resolved_local_timezone.dart';

/// The property Android stores the device timezone in, and the one bionic's
/// own `tzset` reads. Present since API 4.
const _property = 'persist.sys.timezone';

/// bionic's `PROP_VALUE_MAX`. `__system_property_get` will not write more.
const _propValueMax = 92;

/// The `java.util.TimeZone` custom ID grammar, as implemented by libcore:
/// `^GMT[-+](\d{1,2})((\d\d)|:((\d\d)(:(\d\d))?))?`
///
/// So `GMT+5`, `GMT+05`, `GMT+0530`, `GMT+05:30` and `GMT+05:30:30` are all
/// legal, and the sign means east of UTC.
final _javaCustomId = RegExp(
  r'^GMT([+-])(\d{1,2})(?:(\d{2})|:(\d{2})(?::(\d{2}))?)?$',
);

/// Values that are plainly not zone names, so passing them through as one
/// would be dishonest. Anything matching this that is not a legal custom ID
/// is reported as unavailable rather than returned.
final _offsetish = RegExp(r'^(GMT|UTC)?[+-]');

/// A [Provider] that reads the local timezone from Android's system property
/// store.
///
/// Reads `persist.sys.timezone` through bionic's `__system_property_get`,
/// which is a shared-memory read rather than a syscall and costs a few hundred
/// nanoseconds. It is in libc's base ABI and has been since API 1, so there is
/// no version floor to speak of.
///
/// The property normally holds an IANA identifier. It can hold a
/// `java.util.TimeZone` custom ID such as `GMT+05:30` instead, which bionic
/// documents as happening on set-top boxes that take the zone from the TV
/// network and write it straight to the property.
class AndroidProvider extends Provider {
  const AndroidProvider._();

  /// Constructs an [AndroidProvider].
  const factory AndroidProvider() = AndroidProvider._;

  /// The device's timezone, from `persist.sys.timezone`.
  ///
  /// Throws [LocalTimezoneUnavailableException] when the property is unset,
  /// which happens on a device that has never had a zone configured, or when
  /// it holds an offset this cannot parse.
  @override
  ResolvedLocalTimezone resolve() {
    final reported = _readProperty();
    if (reported.isEmpty) {
      _unavailable('$_property is empty');
    }

    final offset = parseJavaCustomId(reported);
    if (offset != null) {
      return OffsetLocalTimezone(offset: offset, raw: reported, prefix: 'GMT');
    }

    if (_offsetish.hasMatch(reported)) {
      _unavailable(
        '$_property holds "$reported", which is not a zone name '
        'and not a legal GMT offset',
      );
    }

    return NamedLocalTimezone(
      name: reported,
      canonicalized: canonicalizeName(reported),
      raw: reported,
    );
  }

  Never _unavailable(String reason) => throw LocalTimezoneUnavailableException(
    platform: 'android',
    reason: reason,
  );
}

/// Parses a `java.util.TimeZone` custom ID such as `GMT+05:30` into an offset
/// east of UTC, or returns null if [value] is not one.
///
/// **The sign is not inverted.** POSIX and Java disagree here, and this
/// property is the Java one. bionic says so in as many words: "For POSIX,
/// `GMT+3` means 3 hours west/behind, but for Java it means 3 hours
/// east/ahead. Since (a) Java is the one that matches human expectations and
/// (b) this system property is used directly by Java, we flip the sign here to
/// translate from Java to POSIX." That flip is bionic's, for bionic's own C
/// consumers. A caller reading the property directly, as this does, must not
/// repeat it.
///
/// For the same reason the offset is parsed rather than read from
/// `DateTime.now().timeZoneOffset`. bionic's flip is guarded by
/// `strcmp(buf, "GMT")`, which is only true when the value is exactly `GMT`,
/// so for `GMT+05:30` the flip never runs and bionic's own `localtime` reads
/// the string as POSIX. On such a device the VM clock and the Java clock
/// disagree by twice the offset, and the Java reading is the one the rest of
/// the system shows the user.
@visibleForTesting
Duration? parseJavaCustomId(String value) {
  final match = _javaCustomId.firstMatch(value);
  if (match == null) return null;

  final hours = int.parse(match.group(2)!);
  // Either `GMT+0530` (group 3) or `GMT+05:30` (group 4).
  final minutes = int.parse(match.group(3) ?? match.group(4) ?? '0');
  final seconds = int.parse(match.group(5) ?? '0');

  // libcore documents hours 0 to 23 and minutes and seconds 00 to 59.
  if (hours > 23 || minutes > 59 || seconds > 59) return null;

  final magnitude = Duration(hours: hours, minutes: minutes, seconds: seconds);
  return match.group(1) == '-' ? -magnitude : magnitude;
}

// ---------------------------------------------------------------- bindings

/// Opened by name rather than resolved through [DynamicLibrary.process].
/// `process()` is reported to miss symbols on some Android images, and libc is
/// always loadable by name, so the explicit form costs nothing and is not
/// subject to that.
final DynamicLibrary _libc = DynamicLibrary.open('libc.so');

typedef _PropertyGetNative =
    Int32 Function(Pointer<Uint8> name, Pointer<Uint8> value);
typedef _PropertyGetDart =
    int Function(Pointer<Uint8> name, Pointer<Uint8> value);

final _PropertyGetDart _propertyGet = _libc
    .lookupFunction<_PropertyGetNative, _PropertyGetDart>(
      '__system_property_get',
    );

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

final _MallocDart _malloc = _libc.lookupFunction<_MallocNative, _MallocDart>(
  'malloc',
);
final _FreeDart _free = _libc.lookupFunction<_FreeNative, _FreeDart>('free');

/// The property name as a C string, encoded once.
final Pointer<Uint8> _propertyName = () {
  final bytes = utf8.encode(_property);
  final pointer = _malloc(bytes.length + 1);
  pointer.asTypedList(bytes.length + 1)
    ..setRange(0, bytes.length, bytes)
    ..[bytes.length] = 0;
  return pointer;
}();

/// The output buffer, allocated once.
///
/// Safe to reuse across calls: Dart statics are per-isolate and an isolate is
/// single-threaded, so two reads can never be in this buffer at the same time.
/// [AndroidProvider.resolve] is synchronous and never yields, which is what
/// keeps that true.
final Pointer<Uint8> _valueBuffer = _malloc(_propValueMax);

String _readProperty() {
  final length = _propertyGet(_propertyName, _valueBuffer);
  if (length <= 0) return '';
  return utf8.decode(_valueBuffer.asTypedList(length));
}

/// Releases the process-lifetime buffers. Only for tests that want a clean
/// heap; the buffers are two small allocations that normally live as long as
/// the isolate.
@visibleForTesting
void releaseAndroidBuffers() {
  _free(_propertyName);
  _free(_valueBuffer);
}
