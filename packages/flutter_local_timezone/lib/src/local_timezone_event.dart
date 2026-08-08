/// @docImport 'local_timezone_watcher.dart';
library;

import 'package:local_timezone/local_timezone.dart';

/// What a listener is handed when the device's local timezone changes.
///
/// Sealed over the two outcomes a re-resolve can have, so callers switch over
/// it exhaustively in the same way they already switch over
/// [ResolvedLocalTimezone] and [LocalTimezoneException]:
///
/// ```dart
/// LocalTimezoneWatcher.addListener((event) {
///   switch (event) {
///     case LocalTimezoneChanged(:final timezone):
///       applyZone(timezone);
///     case LocalTimezoneUnavailable(:final exception):
///       log(exception.message);
///   }
/// });
/// ```
///
/// An event means the *resolved value* changed, not that the platform signalled
/// something. Platforms signal spuriously: Android bumps its property serial on
/// a same-value write, Windows rewrites its registry key at every DST
/// transition, and Linux produces two filesystem events for one
/// `timedatectl set-timezone`. Every one of those is absorbed before it reaches
/// here.
///
/// One consequence worth stating, because it is a design decision rather than
/// an oversight: a daylight saving transition is **not** an event. It changes
/// the offset in effect but no field of a [NamedLocalTimezone], so the
/// comparison finds nothing different. Callers who care about the offset rather
/// than the zone should watch the clock, not this.
sealed class LocalTimezoneEvent {
  /// Creates a local timezone event.
  const LocalTimezoneEvent();
}

/// The device moved to a different timezone.
///
/// The common case, and the one the listener exists for: the user picked a new
/// zone in Settings, or the OS detected one after the device crossed a border.
final class LocalTimezoneChanged extends LocalTimezoneEvent {
  /// Creates an event reporting that the device is now in [timezone].
  const LocalTimezoneChanged(this.timezone);

  /// The zone the device is in now.
  ///
  /// The same value [LocalTimezone.getTimeZone] would return if called at this
  /// moment, so it carries all three layers: [ResolvedLocalTimezone.raw],
  /// [NamedLocalTimezone.name] and [NamedLocalTimezone.canonicalized].
  ///
  /// The previous value is deliberately not carried. A listener that needs it
  /// held it already, since it was handed the same way.
  final ResolvedLocalTimezone timezone;

  @override
  String toString() => 'LocalTimezoneChanged($timezone)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalTimezoneChanged && other.timezone == timezone;

  @override
  int get hashCode => timezone.hashCode;
}

/// The device had a resolvable timezone and no longer does.
///
/// Rare, and not a bug in the calling code. It means a re-resolve that used to
/// succeed now throws, which a device can genuinely arrive at:
///
/// * **Windows**, when the zone key has no mapping in the bundled CLDR table,
///   which happens if Windows ships a zone newer than the table.
/// * **Linux**, when `/etc/localtime` is removed rather than replaced.
/// * **Android**, when `persist.sys.timezone` is cleared.
///
/// Only sent on the *transition* into that state. A platform that keeps
/// signalling while the zone stays unresolvable produces one of these and then
/// silence, for the same reason two identical zones in a row produce nothing:
/// the resolved value did not change.
final class LocalTimezoneUnavailable extends LocalTimezoneEvent {
  /// Creates an event reporting that no timezone can be resolved.
  const LocalTimezoneUnavailable(this.exception);

  /// Why the lookup failed.
  ///
  /// Always a [LocalTimezoneUnavailableException] today, since the watcher
  /// calls [LocalTimezone.getTimeZone] rather than the name-returning form and
  /// that is the only failure it can produce. Typed as the sealed base so the
  /// switch stays exhaustive if that ever stops being true.
  final LocalTimezoneException exception;

  @override
  String toString() => 'LocalTimezoneUnavailable($exception)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalTimezoneUnavailable && other.exception == exception;

  @override
  int get hashCode => exception.hashCode;
}
