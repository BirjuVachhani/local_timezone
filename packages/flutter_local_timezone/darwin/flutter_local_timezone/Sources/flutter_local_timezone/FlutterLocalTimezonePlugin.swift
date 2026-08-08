#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

import Foundation

/// Tells Dart that the device timezone changed, and nothing else.
///
/// This is a doorbell, not a data source. The event carries no payload: it does
/// not report the new zone and knows nothing about IANA names, aliases or
/// canonicalization. Dart resolves the zone itself through
/// `package:local_timezone`, which already does that work and produces the
/// identical answer on every platform.
///
/// One file for both iOS and macOS, via `sharedDarwinSource` in the pubspec.
/// `NSSystemTimeZoneDidChangeNotification` is the same notification on both, so
/// the only differences are the framework name and the shape of the registrar's
/// messenger accessor.
public class FlutterLocalTimezonePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  /// Must match `timezoneSignalChannelName` in `lib/src/timezone_signal.dart`.
  private static let channelName = "com.birjuvachhani.flutter_local_timezone/changes"

  private var sink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    // The one place the two platforms genuinely differ. iOS declares
    // `messenger()` as a method and macOS declares `messenger` as a property,
    // so this cannot be written once.
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif

    let instance = FlutterLocalTimezonePlugin()
    let channel = FlutterEventChannel(name: channelName, binaryMessenger: messenger)
    channel.setStreamHandler(instance)

    // The channel's message handler closure already retains the stream handler,
    // but publishing ties the instance's lifetime to the registrar, which is
    // what makes `deinit` run when the engine goes away rather than whenever
    // the channel happens to be released.
    registrar.publish(instance)
  }

  /// Starts observing when Dart starts listening.
  ///
  /// Deliberately bound to the subscription rather than to `register`, so that
  /// an app which never adds a listener never installs an observer. That maps
  /// one to one onto `addListener` and `removeListener` on the Dart side.
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(systemTimeZoneDidChange),
      name: .NSSystemTimeZoneDidChange,
      object: nil)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(
      self, name: .NSSystemTimeZoneDidChange, object: nil)
    sink = nil
    return nil
  }

  @objc private func systemTimeZoneDidChange() {
    onMainThread {
      // Foundation memoizes the system zone. It does drop that cache when this
      // notification is delivered, but nothing documents whether that happens
      // before or after our observer runs, and if it runs after then Dart
      // re-reads `+[NSTimeZone localTimeZone]` and gets the zone the device
      // just left. Resetting here makes the ordering irrelevant.
      //
      // The cost is one message send per timezone change, which is a handful
      // per year. Do not remove this as an optimisation: the failure it
      // prevents is silent, because a stale read diffs to "no change" and the
      // listener simply never fires.
      NSTimeZone.resetSystemTimeZone()
      self.sink?(nil)
    }
  }

  /// Runs `work` on the main thread, inline when already there.
  ///
  /// Apple documents this notification as posted on the main queue, so the
  /// inline branch is the one that runs. The hop exists because a FlutterEventSink
  /// may only be touched from the platform thread, and "documented as" is a
  /// weaker guarantee than the crash we would get for being wrong.
  private func onMainThread(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
