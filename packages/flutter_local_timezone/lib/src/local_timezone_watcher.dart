import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:local_timezone/local_timezone.dart';

import 'local_timezone_event.dart';
import 'timezone_signal.dart';

/// Called when the device's local timezone changes.
typedef LocalTimezoneListener = void Function(LocalTimezoneEvent event);

/// Notifies when the device's local timezone changes.
///
/// Register once, when the app starts, and keep the listener for the life of
/// the process:
///
/// ```dart
/// void main() {
///   LocalTimezoneWatcher.addListener((event) {
///     if (event case LocalTimezoneChanged(:final timezone)) {
///       applyZone(timezone);
///     }
///   });
///   runApp(const MyApp());
/// }
/// ```
///
/// ## What it costs
///
/// Nothing until the first listener is added. No channel is opened, no
/// broadcast receiver is registered and no lifecycle observer is installed
/// until then, and all three are torn down when the last listener is removed.
///
/// ## How a change is detected
///
/// Two legs feed one funnel.
///
/// The **native leg** is the platform's own change notification, forwarded from
/// the plugin as an empty signal. It carries no value: on each signal this
/// re-reads the zone with [LocalTimezone.getTimeZone] and compares. That is why
/// a platform signalling spuriously, which all of them do, costs one lookup of
/// a few hundred nanoseconds and produces no event.
///
/// | Platform | Native trigger |
/// | --- | --- |
/// | Android | `ACTION_TIMEZONE_CHANGED` |
/// | iOS, macOS | `NSSystemTimeZoneDidChangeNotification` |
/// | Windows, Linux | not yet implemented |
/// | Web | none exists |
///
/// The **lifecycle leg** re-checks whenever the app returns to the foreground,
/// on every platform. It is the backstop for a zone that changed while the
/// process was backgrounded, frozen or killed, which no native trigger can
/// report because there was nothing running to report it to. On platforms with
/// no native implementation it is the only leg, which detects the common case
/// (the user changes the zone, then comes back to the app) and misses a change
/// that happens while the app is in continuous use.
///
/// ## What counts as a change
///
/// The resolved value differing from the last one. A daylight saving transition
/// is not a change, because it alters no field of a [NamedLocalTimezone]. See
/// [LocalTimezoneEvent].
final class LocalTimezoneWatcher {
  LocalTimezoneWatcher._();

  static final List<LocalTimezoneListener> _listeners = [];
  static final _TimezoneNotifier _notifier = _TimezoneNotifier();

  static StreamSubscription<void>? _subscription;
  static AppLifecycleListener? _lifecycle;
  static bool _watching = false;

  /// The device's current timezone, as something a widget can rebuild on.
  ///
  /// ```dart
  /// ListenableBuilder(
  ///   listenable: LocalTimezoneWatcher.listenable,
  ///   builder: (context, _) => Text('${LocalTimezoneWatcher.listenable.value}'),
  /// )
  /// ```
  ///
  /// Attaching to this starts the watcher exactly as [addListener] does, and
  /// detaching the last one stops it, so a widget tree that only ever uses this
  /// never needs to touch [addListener] at all.
  ///
  /// Null means one of two things, which are distinguished by whether anything
  /// is listening: no timezone could be resolved, or nothing is watching yet.
  /// Reading `value` on an idle watcher gives null rather than a stale answer.
  /// It is populated synchronously when the first listener attaches, so a
  /// [ListenableBuilder] never sees the idle null: `initState` subscribes
  /// before the first `build` runs.
  ///
  /// Deliberately not a `ValueNotifier` this package hands out. Callers can
  /// listen and read, but cannot set the device's timezone by assigning to it.
  static ValueListenable<ResolvedLocalTimezone?> get listenable => _notifier;

  /// Registers [listener] to be called when the device's timezone changes.
  ///
  /// Adding the same listener twice calls it twice. Starting the watcher does
  /// not call it: the first resolve establishes the baseline to compare
  /// against, and reporting the zone the device was already in as a change
  /// would be a lie. Callers who want the current value should ask
  /// [LocalTimezone.getTimeZone] for it, which is synchronous.
  static void addListener(LocalTimezoneListener listener) {
    _listeners.add(listener);
    _start();
  }

  /// Stops [listener] being called.
  ///
  /// Removes one registration, so a listener added twice needs removing twice.
  /// Removing something that was never added does nothing. When the last
  /// listener goes, and nothing is attached to [listenable], every platform
  /// resource this took is released.
  static void removeListener(LocalTimezoneListener listener) {
    _listeners.remove(listener);
    _stopIfIdle();
  }

  /// Releases everything and forgets the last known zone.
  @visibleForTesting
  static void debugReset() {
    _listeners.clear();
    _stop();
    resetTimezoneSignals();
    debugResolveOverride = null;
  }

  /// Replaces the platform lookup, for tests.
  ///
  /// `LocalTimezone`'s own mock returns a fixed value and has no way to throw,
  /// so without this the [LocalTimezoneUnavailable] path is unreachable off a
  /// real device: it needs a resolve that fails, and every mock succeeds.
  ///
  /// Prefer `LocalTimezone.setMockValue` for the cases it can express. This
  /// exists for the ones it cannot.
  @visibleForTesting
  static ResolvedLocalTimezone Function()? debugResolveOverride;

  static void _start() {
    if (_watching) return;

    // `addListener` is documented as callable from `main` before `runApp`, and
    // both legs need a binding: the channel needs a messenger and the lifecycle
    // listener needs an observer registry. Idempotent, and returns an existing
    // custom binding rather than replacing it.
    WidgetsFlutterBinding.ensureInitialized();

    // The baseline. Seeded rather than published, so no event is dispatched for
    // the zone the device was already in.
    //
    // Before `_watching` is set, deliberately. `_read` swallows a
    // `LocalTimezoneException` but not, say, the `UnimplementedError` an
    // unsupported operating system produces. Flipping the flag first would let
    // that escape having marked the watcher started, leaving it permanently
    // wedged with no legs attached and no way to retry.
    _notifier.seed(_zoneOf(_read()));

    _watching = true;
    _lifecycle = AppLifecycleListener(onResume: _check);
    _subscription = timezoneSignals.listen((_) => _check());
  }

  static void _stopIfIdle() {
    if (_listeners.isNotEmpty || _notifier.hasAnyListener) return;
    _stop();
  }

  static void _stop() {
    _watching = false;
    _subscription?.cancel();
    _subscription = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    // Not a value anyone should read while idle, and holding it would make a
    // later restart compare against an arbitrarily old answer.
    _notifier.seed(null);
  }

  /// Re-reads the platform and dispatches if the answer moved.
  static void _check() {
    final event = _read();
    final zone = _zoneOf(event);

    // The entire spurious-wakeup defence, in one comparison. Two identical
    // zones in a row, or two failures in a row, both land here and stop.
    if (zone == _notifier.value) return;

    _notifier.publish(zone);
    _dispatch(event);
  }

  static LocalTimezoneEvent _read() {
    try {
      final resolve = debugResolveOverride ?? LocalTimezone.getTimeZone;
      return LocalTimezoneChanged(resolve());
    } on LocalTimezoneException catch (error) {
      return LocalTimezoneUnavailable(error);
    }
  }

  static ResolvedLocalTimezone? _zoneOf(LocalTimezoneEvent event) =>
      switch (event) {
        LocalTimezoneChanged(:final timezone) => timezone,
        LocalTimezoneUnavailable() => null,
      };

  static void _dispatch(LocalTimezoneEvent event) {
    // Iterate a copy. A listener is allowed to remove itself, or to add
    // another, from inside the callback, and mutating the list being walked
    // would throw a ConcurrentModificationError out of an unrelated stack.
    for (final listener in List.of(_listeners)) {
      try {
        listener(event);
      } catch (error, stack) {
        // One listener throwing must not stop the others being told. Reported
        // rather than swallowed, so it still surfaces in the console and in
        // whatever crash reporter the app has installed on FlutterError.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'flutter_local_timezone',
            context: ErrorDescription(
              'while notifying a local timezone listener of $event',
            ),
          ),
        );
      }
    }
  }
}

/// The backing store for [LocalTimezoneWatcher.listenable].
///
/// A hand-rolled [ChangeNotifier] rather than a [ValueNotifier] because seeding
/// the baseline has to set the value *without* notifying, and `ValueNotifier`
/// offers no way to do that.
final class _TimezoneNotifier extends ChangeNotifier
    implements ValueListenable<ResolvedLocalTimezone?> {
  ResolvedLocalTimezone? _value;

  @override
  ResolvedLocalTimezone? get value => _value;

  /// [ChangeNotifier.hasListeners] is protected, and the watcher needs it to
  /// decide whether it is idle.
  bool get hasAnyListener => hasListeners;

  /// Sets the value with no notification, for establishing the baseline.
  void seed(ResolvedLocalTimezone? value) => _value = value;

  /// Sets the value and notifies.
  void publish(ResolvedLocalTimezone? value) {
    if (_value == value) return;
    _value = value;
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    LocalTimezoneWatcher._start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    LocalTimezoneWatcher._stopIfIdle();
  }
}
