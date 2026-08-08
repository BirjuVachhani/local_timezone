import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Must match `channelName` in every native implementation:
/// `FlutterLocalTimezonePlugin.kt` and `FlutterLocalTimezonePlugin.swift`.
///
/// Not private, so tests can use the same name rather than repeating the
/// literal and silently testing a channel nothing listens on. That matters more
/// than it looks: a mismatch here does not throw anywhere a test can see, it
/// just means no event ever arrives. See the device test that probes for a
/// native handler.
const timezoneSignalChannelName =
    'com.birjuvachhani.flutter_local_timezone/changes';

const _channel = EventChannel(timezoneSignalChannelName);

/// The platforms with a native doorbell.
///
/// Grow this as each platform lands, alongside the implementation itself. It is
/// the one place that answers "which platforms have push detection", and
/// leaving it stale is the failure mode: a platform missing from here silently
/// degrades to lifecycle-only detection with no error anywhere.
///
/// The guard is not cosmetic. [EventChannel.receiveBroadcastStream] does not
/// deliver a failed `listen` as a stream error; it hands it to
/// [FlutterError.reportError] instead. So subscribing on a platform with no
/// native implementation does not produce something catchable, it produces a
/// logged framework error in every app on that platform. Not subscribing at all
/// is the only quiet way to be unimplemented.
bool get _hasNativeSignal =>
    // `defaultTargetPlatform` reports the *host* on web, so a browser on an
    // Android phone claims to be Android. Check this first or the web build
    // subscribes to a channel that cannot exist.
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

Stream<void>? _signals;

/// Fires once per platform signal, carrying nothing.
///
/// An empty stream on platforms with no native implementation, which is a
/// working state rather than an error: the watcher's lifecycle leg still
/// detects changes when the app returns to the foreground.
///
/// Cached, because [EventChannel.receiveBroadcastStream] builds a fresh
/// controller per call and each one sends its own `listen` to the platform.
/// Calling it twice would make the native side cancel the first subscription to
/// serve the second.
Stream<void> get timezoneSignals {
  if (!_hasNativeSignal) return const Stream<void>.empty();
  return _signals ??= _channel.receiveBroadcastStream().map<void>((_) {});
}

/// Drops the cached stream so the next read re-subscribes.
///
/// Not annotated `@visibleForTesting` even though testing is the only reason it
/// exists, because `LocalTimezoneWatcher.debugReset` is what calls it and that
/// is library code. The annotation there is the one that matters.
void resetTimezoneSignals() => _signals = null;
