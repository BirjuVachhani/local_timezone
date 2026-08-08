import 'dart:convert';
import 'dart:ffi';

import '../local_timezone_exception.dart';
import '../provider/provider_base.dart';
import '../resolved_local_timezone.dart';
import '../zone_name.dart';

/// The name CoreFoundation gives a zone it built from a bare offset.
///
/// Much narrower than Android's custom-ID grammar: the sign is always present,
/// the digits are always four, and there is never a colon. `TZ=GMT+5` and
/// `TZ=GMT+5:30` become `GMT+0500` and `GMT+0530`. Finer than a minute is not
/// truncated but rejected, so `TZ=GMT+5:30:30` is ignored entirely and
/// Foundation falls back to the symlink zone.
///
/// Bare `GMT` is deliberately outside this. A zero offset is named `GMT` rather
/// than `GMT+0000`, and that is a real zone name which canonicalization already
/// maps to `Etc/GMT`.
final _fixedOffsetName = RegExp(r'^GMT[+-]\d{4}$');

/// Values that are plainly not zone names, so passing one off as an identifier
/// would be dishonest. Anything matching this but not [_fixedOffsetName] is
/// reported as unavailable. Mirrors the same guard in the Android provider.
final _offsetish = RegExp(r'^(GMT|UTC)?[+-]');

/// A [Provider] that reads the local timezone from Apple platforms.
///
/// iOS and macOS timezone lookup through the Objective-C runtime.
///
/// Calls `[[NSTimeZone localTimeZone] name]` by hand, using only `dart:ffi`
/// and `dart:convert`. Nothing is bundled, signed, or notarized: `libobjc` and
/// `Foundation` are already mapped into every iOS and macOS process, so
/// [DynamicLibrary.process] resolves them with no `dlopen`. That matters on
/// iOS, which refuses to load any Mach-O that is not part of the OS or
/// embedded and signed inside the app bundle.
///
/// All symbols and selectors are resolved once into lazy top-level finals.
/// Resolving them per call is about 50 times slower, because each
/// `lookupFunction` is a symbol-table search and each
/// `sel_registerName` interns a string in the runtime.
///
/// ## Foundation does not canonicalize
///
/// The name is whatever the OS wrote, with no alias resolution. Foundation
/// resolves the zone from `TZFILE`, then `TZ`, then by reading the
/// `TZDEFAULT` symlink and taking everything after `zoneinfo/`, and that path
/// component is returned verbatim. `Asia/Calcutta` in the symlink means
/// `Asia/Calcutta` out of this provider, so canonicalization is load-bearing here
/// rather than the no-op it looks like on a machine that happens to be
/// configured with a primary name.
///
/// Do not validate against `+[NSTimeZone knownTimeZoneNames]`. That list comes
/// from ICU, whose stable-ID policy keeps the deprecated spelling canonical, so
/// it contains `Asia/Calcutta` and not `Asia/Kolkata`. It would reject values
/// this very API returns.
///
/// ## Staleness in a process with no runloop
///
/// Foundation memoizes the system zone and invalidates that cache on
/// `NSSystemTimeZoneDidChangeNotification`, which Apple documents as being
/// posted on the main queue. A Flutter app services that queue, so a zone
/// change mid-session is picked up. A plain Dart CLI or server does not run a
/// CFRunLoop at all, so the cache may never be invalidated and a long-lived
/// process can keep reporting the zone it saw first. Re-sending the message,
/// which this does on every call, cannot fix that on its own. This is read from
/// Apple's documentation rather than reproduced: forcing a real system timezone
/// change needs root.
class AppleProvider extends Provider {
  const AppleProvider._();

  /// Constructs an [AppleProvider].
  const factory AppleProvider() = AppleProvider._;

  /// The device's timezone, from `[[NSTimeZone localTimeZone] name]`.
  ///
  /// `+localTimeZone` is the Objective-C counterpart of Swift's
  /// `TimeZone.autoupdatingCurrent`: Foundation bridges it through
  /// `_autoupdating()`, and `-name` is the same string Swift calls
  /// `.identifier`. So this returns exactly what a native Swift app reading
  /// `TimeZone.autoupdatingCurrent.identifier` would get.
  ///
  /// The proxy is not what keeps the value fresh, though. `+localTimeZone` and
  /// `+systemTimeZone` read the same memoized cache slot, so re-sending the
  /// message on every call, which is what this does, is what picks up a change.
  /// The auto-updating distinction only matters to a caller that holds the
  /// object. What `+localTimeZone` does buy is independence from
  /// `+setDefaultTimeZone:`: since iOS 11 and macOS 10.13 it tracks the system
  /// zone, so a host app changing its own default cannot move this answer.
  ///
  /// Usually a [NamedLocalTimezone]. Foundation falls back to a fixed-offset
  /// zone named `GMT+0530` when `TZ` holds a POSIX-style string it cannot
  /// resolve to a zone file, and that is an [OffsetLocalTimezone].
  ///
  /// Throws [LocalTimezoneUnavailableException] if any step of the message chain
  /// returns nil, or if the name looks like an offset but is not one.
  @override
  ResolvedLocalTimezone resolve() {
    // -[NSTimeZone name] returns a freshly auto-released string on every call.
    // Without a pool on this thread the runtime installs a page and appends to
    // it forever: about 56 bytes per call, leaked silently with no warning.
    // Push and pop must stay strictly LIFO, and the token must be handed back
    // exactly as received, because the first push on a pool-less thread returns
    // a placeholder value rather than a page pointer.
    //
    // Nothing inside this scope may await. Dart isolates can migrate between OS
    // threads at an await point, and popping a pool on a different thread than
    // pushed it corrupts memory rather than failing cleanly.
    final pool = _poolPush();
    try {
      final timezone = _objcMsgSend(_classNSTimeZone, _selLocalTimeZone);
      if (timezone == nullptr) {
        _unavailable('+[NSTimeZone localTimeZone] returned nil');
      }

      final name = _objcMsgSend(timezone, _selName);
      if (name == nullptr) {
        _unavailable('-[NSTimeZone name] returned nil');
      }

      final utf8String = _objcMsgSend(name, _selUTF8String);
      if (utf8String == nullptr) {
        _unavailable('-[NSString UTF8String] returned nil');
      }

      // Copy before the pool pops and the backing string is released.
      final identifier = _fromCString(utf8String.cast<Uint8>());
      if (identifier.isEmpty) {
        _unavailable('-[NSTimeZone name] returned an empty string');
      }

      if (_fixedOffsetName.hasMatch(identifier)) {
        // Take the offset the runtime applies, not the one Foundation names.
        // The two disagree, and asking the zone object would report the wrong
        // one. Given TZ=GMT+5, Foundation builds a zone named GMT+0500 whose
        // secondsFromGMT is +05:00, while libc resolves UTC-05:00; given
        // TZ=GMT+0530 Foundation says +05:30 while the process is in UTC.
        //
        // A caller feeding our result back through a timezone database has to
        // land on the same wall clock as a plain DateTime(), and DateTime
        // follows libc. Reporting Foundation's answer would leave every
        // DateTime in the same program disagreeing with us.
        //
        // This matches the web provider, which ignores V8's POSIX-signed
        // string for the same reason. Android is the deliberate exception:
        // there the property belongs to Java and bionic's own libc misparses
        // it, so the string is authoritative and DateTime is not.
        //
        // Only a POSIX-style TZ reaches this branch. System Settings offers
        // cities, not offsets, so a configured phone or Mac never gets here.
        return OffsetLocalTimezone(
          offset: DateTime.now().timeZoneOffset,
          raw: identifier,
          prefix: 'GMT',
        );
      }

      if (_offsetish.hasMatch(identifier)) {
        _unavailable(
          '-[NSTimeZone name] returned "$identifier", which is not a zone '
          'name and not a fixed offset',
        );
      }

      // The C string is decoded leniently, so bytes that are not valid UTF-8
      // arrive here as replacement characters rather than throwing. Neither
      // those nor anything else unnameable should become a timezone.
      if (!isPlausibleZoneName(identifier)) {
        _unavailable(
          '-[NSTimeZone name] returned "$identifier", which is not shaped '
          'like a zone name',
        );
      }

      return NamedLocalTimezone(
        name: identifier,
        canonicalized: canonicalizeName(identifier),
        raw: identifier,
      );
    } finally {
      _poolPop(pool);
    }
  }

  Never _unavailable(String reason) => throw LocalTimezoneUnavailableException(
    platform: 'apple',
    reason: reason,
  );
}

// ---------------------------------------------------------------- bindings

final DynamicLibrary _process = DynamicLibrary.process();

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

final _MallocDart _malloc = _process.lookupFunction<_MallocNative, _MallocDart>(
  'malloc',
);
final _FreeDart _free = _process.lookupFunction<_FreeNative, _FreeDart>('free');

/// `id objc_getClass(const char *)` and `SEL sel_registerName(const char *)`
/// share a shape, so one typedef pair covers both.
typedef _LookupNative = Pointer<Void> Function(Pointer<Uint8>);
typedef _LookupDart = Pointer<Void> Function(Pointer<Uint8>);

final _LookupDart _objcGetClass = _process
    .lookupFunction<_LookupNative, _LookupDart>('objc_getClass');
final _LookupDart _selRegisterName = _process
    .lookupFunction<_LookupNative, _LookupDart>('sel_registerName');

/// Every message sent here has the shape `id (*)(id, SEL)`.
///
/// This is how the Objective-C runtime is meant to be called from a non-ObjC
/// language: `objc_msgSend` has no single true prototype, and the modern SDK
/// declares it as `void objc_msgSend(void)` precisely to force a cast at each
/// use. `package:objective_c` resolves it once and casts per signature for the
/// same reason.
///
/// If a second signature is ever needed, add another typedef pair and look the
/// same symbol up again. Do not declare it variadic: on arm64 variadic
/// arguments go on the stack while fixed ones stay in registers, so a variadic
/// prototype produces garbage. There is no `objc_msgSend_stret` case to worry
/// about either, since that variant does not exist on arm64.
typedef _MsgSendNative = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _MsgSendDart = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);

final _MsgSendDart _objcMsgSend = _process
    .lookupFunction<_MsgSendNative, _MsgSendDart>('objc_msgSend');

typedef _PoolPushNative = Pointer<Void> Function();
typedef _PoolPushDart = Pointer<Void> Function();
typedef _PoolPopNative = Void Function(Pointer<Void>);
typedef _PoolPopDart = void Function(Pointer<Void>);

/// Not declared in any public C header, but exported from the public SDK's
/// `libobjc.A.tbd` on both iOS and macOS, and emitted by clang for every
/// `@autoreleasepool`. Every ARC binary on the App Store already imports them.
/// They are not private API in the sense App Review cares about.
///
/// The SDK's Swift interface declares `_objc_autoreleasePoolPush`, an
/// underscore-prefixed CoreFoundation-compat alias, rather than these. Both are
/// exported; these are the ones the compiler reaches for.
final _PoolPushDart _poolPush = _process
    .lookupFunction<_PoolPushNative, _PoolPushDart>('objc_autoreleasePoolPush');
final _PoolPopDart _poolPop = _process
    .lookupFunction<_PoolPopNative, _PoolPopDart>('objc_autoreleasePoolPop');

// ---------------------------------------------------------------- strings

/// Copies [value] into a NUL-terminated C string on the native heap.
Pointer<Uint8> _toCString(String value) {
  final bytes = utf8.encode(value);
  final pointer = _malloc(bytes.length + 1);
  if (pointer == nullptr) {
    throw LocalTimezoneUnavailableException(
      platform: 'apple',
      reason: 'malloc(${bytes.length + 1}) failed',
    );
  }
  pointer.asTypedList(bytes.length + 1)
    ..setRange(0, bytes.length, bytes)
    ..[bytes.length] = 0;
  return pointer;
}

/// The longest C string [_fromCString] will scan for a terminator.
///
/// Only zone names come back this way, and the longest tzdb name is 30 bytes,
/// so this is three orders of magnitude of headroom.
///
/// Worth being precise about what this does and does not buy. It is a scan
/// bound, not a bounds check: nothing here can establish how large the
/// allocation behind the pointer actually is, so a pointer to an unterminated
/// two-byte buffer would still be read past its end before the cap stops it.
/// What the cap removes is the unbounded case, where a missing terminator
/// walks the scan through the whole address space until it faults.
///
/// The real guarantee is Foundation's: `-[NSString UTF8String]` is documented
/// to return a NUL-terminated representation, and the value it describes is a
/// zone name. Eliminating the assumption rather than bounding it would mean
/// switching to `-getCString:maxLength:encoding:`, which writes into a buffer
/// this package owns and whose length it therefore knows. That is a better
/// shape and worth doing if this code is ever revisited; it is not done here
/// because it changes a message signature and a well-tested path to close a
/// gap that Foundation's own contract already closes.
const _maxCStringLength = 4096;

/// Copies a NUL-terminated C string into a Dart string.
///
/// The copy is what makes this safe: the pointer returned by `-[NSString
/// UTF8String]` is an interior pointer owned by the string, valid only while
/// the string is, and must never be freed by us.
String _fromCString(Pointer<Uint8> pointer) {
  var length = 0;
  while (length < _maxCStringLength && pointer[length] != 0) {
    length++;
  }
  if (length == _maxCStringLength) {
    throw const LocalTimezoneUnavailableException(
      platform: 'apple',
      reason:
          'the zone name was not NUL-terminated within $_maxCStringLength '
          'bytes',
    );
  }
  return utf8.decode(pointer.asTypedList(length), allowMalformed: true);
}

/// Runs [action] with [value] as a temporary C string, then frees it.
///
/// Safe for `objc_getClass` and `sel_registerName` because both intern the
/// name, so the runtime does not retain our buffer.
Pointer<Void> _withCString(String value, _LookupDart action) {
  final pointer = _toCString(value);
  try {
    return action(pointer);
  } finally {
    _free(pointer);
  }
}

// ------------------------------------------------------ classes, selectors

final Pointer<Void> _classNSTimeZone = _withCString(
  'NSTimeZone',
  _objcGetClass,
);
final Pointer<Void> _selLocalTimeZone = _withCString(
  'localTimeZone',
  _selRegisterName,
);
final Pointer<Void> _selName = _withCString('name', _selRegisterName);
final Pointer<Void> _selUTF8String = _withCString(
  'UTF8String',
  _selRegisterName,
);
