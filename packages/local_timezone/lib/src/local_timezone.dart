import 'package:meta/meta.dart';

import 'local_timezone_exception.dart';
import 'provider/provider.dart';
import 'resolved_local_timezone.dart';

/// Reads the device's local timezone, synchronously, on every platform.
///
/// ```dart
/// final zone = LocalTimezone.getTimeZoneName(); // 'Asia/Kolkata'
/// ```
///
/// Unlike `DateTime.now().timeZoneName`, which returns an ambiguous
/// abbreviation such as `IST` that maps to more than one zone, this returns an
/// IANA identifier. Unlike plugin-based alternatives, it needs no platform
/// channel, so it can be called from `build()` without an await.
///
/// ## Platforms
///
/// | Platform | Source |
/// | --- | --- |
/// | Android | `__system_property_get("persist.sys.timezone")` |
/// | iOS, macOS | `[[NSTimeZone localTimeZone] name]` |
/// | Linux | `TZ`, then the `/etc/localtime` symlink |
/// | Windows | `GetDynamicTimeZoneInformation`, mapped through CLDR |
/// | Web | `Intl.DateTimeFormat().resolvedOptions().timeZone` |
///
/// Web covers both `dart2js` and `dart2wasm`. The package is pure Dart, so it
/// ships no native code and needs no plugin registration.
///
/// ## Failure is loud
///
/// Nothing here falls back to UTC. A device with no resolvable zone throws
/// [LocalTimezoneUnavailableException], because a silently wrong timezone is
/// harder to notice than a crash and tends to surface as corrupted timestamps
/// much later. Callers who want a fallback should catch and pick their own.
///
/// ## Nothing is cached
///
/// Every call reads the platform, so the answer reflects the device's current
/// timezone even if the user changes it mid-session. Measured cost per call,
/// with symbol lookups resolved once at load:
///
/// | Platform | Per call | Calls per 16.7ms frame |
/// | --- | --- | --- |
/// | Android, iOS, macOS | ~250 to 350 ns | ~50,000 |
/// | Linux, web | ~40 us | ~400 |
///
/// Apple and Android are a single FFI call. Linux makes two filesystem
/// syscalls, and the web constructs an `Intl.DateTimeFormat`, so both cost
/// more, though still several hundred calls per frame.
///
/// If you need more than that, memoize at the call site, where you also know
/// when the value should be discarded:
///
/// ```dart
/// late final zone = LocalTimezone.getTimeZoneName();
/// ```
///
/// Nothing is cached *here*, which is not the same as nothing being cached at
/// all. Apple's Foundation memoizes the system zone and drops that cache when
/// it receives `NSSystemTimeZoneDidChangeNotification`, which Apple documents
/// as being posted on the main queue. A Flutter app services that queue and so
/// picks up a change. A plain Dart CLI or server runs no CFRunLoop, so a
/// long-lived process on iOS or macOS can keep reporting the zone it resolved
/// first, and re-reading cannot help. Short-lived processes are unaffected,
/// since each one resolves from scratch.
final class LocalTimezone {
  const LocalTimezone._();

  static LocalTimezone _instance = const LocalTimezone._();

  /// The singleton instance, which reads the platform.
  static LocalTimezone get instance => _instance;

  /// Overrides the singleton with a [LocalTimezone] that returns [value].
  @visibleForTesting
  static void setMock(LocalTimezone value) => _instance = value;

  /// Overrides the singleton with a [LocalTimezone] that returns [value].
  @visibleForTesting
  static void setMockValue(ResolvedLocalTimezone value) =>
      _instance = MockedLocalTimezone(value: value);

  /// Resets the singleton to the default, which reads the platform.
  @visibleForTesting
  static void clearMock() => _instance = const LocalTimezone._();

  ResolvedLocalTimezone _resolve() => platformProvider.resolve();

  // Deliberately not Isolate.run. dart:isolate compiles for web but throws
  // "Unsupported operation: new RawReceivePort" at runtime on both dart2js and
  // dart2wasm, so offloading here would silently break the async API on the
  // web. It would also cost more than it saves: the lookup is a few hundred
  // nanoseconds, while a spawned isolate gets its own copies of the lazy FFI
  // statics and has to resolve every symbol again.
  Future<ResolvedLocalTimezone> _resolveAsync() async => _resolve();

  /// The device's local timezone, as either a name or a fixed offset.
  ///
  /// Prefer this over [getTimeZoneName] when the caller can do something
  /// sensible with a fixed offset. Switch over the sealed result:
  ///
  /// ```dart
  /// switch (LocalTimezone.getTimeZone()) {
  ///   case NamedLocalTimezone(:final name):
  ///     useZone(name);
  ///   case OffsetLocalTimezone(:final offset):
  ///     useOffset(offset);
  /// }
  /// ```
  ///
  /// A named result carries all three layers at once, so nothing has to be
  /// asked for: [ResolvedLocalTimezone.raw] is what the platform said,
  /// [NamedLocalTimezone.name] is that parsed into an identifier, and
  /// [NamedLocalTimezone.canonicalized] is the zone's current primary
  /// spelling. The last is the one to hand to a timezone database.
  ///
  /// Throws [LocalTimezoneUnavailableException] if the platform has no
  /// resolvable timezone.
  static ResolvedLocalTimezone getTimeZone() => _instance._resolve();

  /// The device's local IANA timezone identifier, such as `Asia/Kolkata`.
  ///
  /// A convenience over [getTimeZone] for the common case where only a zone
  /// name is useful. Returns [NamedLocalTimezone.canonicalized], the current
  /// primary spelling, which is what a timezone database will accept.
  ///
  /// Throws [LocalTimezoneUnavailableException] if the platform has no
  /// resolvable timezone, and [LocalTimezoneNotNamedException] if it reported
  /// a fixed offset rather than a name. The latter carries the offset, so
  /// recovering from it needs no second lookup.
  static String getTimeZoneName() => switch (getTimeZone()) {
    NamedLocalTimezone(:final canonicalized) => canonicalized,
    final OffsetLocalTimezone offset => throw LocalTimezoneNotNamedException(
      offset,
    ),
  };

  /// The asynchronous mirror of [getTimeZone].
  ///
  /// Every supported platform resolves synchronously, so today this completes
  /// immediately with the same value [getTimeZone] returns. It exists so
  /// callers already inside async code do not have to mix styles, and to give
  /// code migrating from channel-based packages a signature to move onto.
  ///
  /// Reach for [getTimeZone] unless you specifically need a [Future].
  static Future<ResolvedLocalTimezone> getTimeZoneAsync() =>
      _instance._resolveAsync();

  /// The asynchronous mirror of [getTimeZoneName].
  ///
  /// See [getTimeZoneAsync] for why this is asynchronous at all.
  static Future<String> getTimeZoneNameAsync() async =>
      switch (await getTimeZoneAsync()) {
        NamedLocalTimezone(:final canonicalized) => canonicalized,
        final OffsetLocalTimezone offset =>
          throw LocalTimezoneNotNamedException(offset),
      };
}

/// A [LocalTimezone] that returns a fixed value, for testing.
///
/// For a background isolate, call [LocalTimezone.setMock] in the isolate's
/// entrypoint before using [LocalTimezone].
@visibleForTesting
final class MockedLocalTimezone extends LocalTimezone {
  ResolvedLocalTimezone _value;

  /// The value that [getTimeZone] and [getTimeZoneName] return.
  ResolvedLocalTimezone get value => _value;

  /// Creates a [LocalTimezone] that returns [value] for every call.
  MockedLocalTimezone({required this._value}) : super._();

  /// Changes the value that [getTimeZone] and [getTimeZoneName] return.
  void setValue(ResolvedLocalTimezone value) => _value = value;

  @override
  ResolvedLocalTimezone _resolve() => _value;

  @override
  Future<ResolvedLocalTimezone> _resolveAsync() => Future.value(_value);
}
