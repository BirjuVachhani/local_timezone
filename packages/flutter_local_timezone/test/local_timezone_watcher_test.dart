// Host tests for the listener funnel. Everything here runs on `flutter_tester`
// with the platform channel mocked, so what is covered is the Dart half: the
// diffing, the dispatch, the lifecycle leg, and the resource teardown. That the
// Android broadcast actually arrives is a device claim and lives in
// `integration_test/device_test.dart`.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_timezone/flutter_local_timezone.dart';
import 'package:flutter_local_timezone/src/timezone_signal.dart';
import 'package:flutter_test/flutter_test.dart';

const _kolkata = NamedLocalTimezone(
  name: 'Asia/Kolkata',
  canonicalized: 'Asia/Kolkata',
  raw: 'Asia/Kolkata',
);

const _london = NamedLocalTimezone(
  name: 'Europe/London',
  canonicalized: 'Europe/London',
  raw: 'Europe/London',
);

const _unavailable = LocalTimezoneUnavailableException(
  platform: 'test',
  reason: 'the harness said so',
);

void main() {
  const channel = EventChannel(timezoneSignalChannelName);

  // The signal is gated on the target platform, because subscribing to a
  // channel with no implementation logs a framework error rather than throwing
  // something catchable. Without pinning the platform the whole native leg is
  // skipped and most of this file passes for the wrong reason.
  //
  // A variant rather than `debugDefaultTargetPlatformOverride` in `setUp`.
  // flutter_test asserts that every foundation debug variable is unset at the
  // end of the *test body*, which is before `tearDown` runs, so setting one
  // that way fails every test in the group. A variant sets and restores it
  // inside the body, where the invariant check sees it undone.
  final onAndroid = TargetPlatformVariant.only(TargetPlatform.android);

  /// Every platform with a native doorbell, so the gating test proves each one
  /// individually rather than proving Android five times.
  final onImplemented = TargetPlatformVariant(const {
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  });

  /// A platform with no plugin.
  ///
  /// Fuchsia, because every platform this package targets now has one. The
  /// other unimplemented case is the web, and that one cannot be reached from
  /// here: the gate tests `kIsWeb` first, and no VM test can make that true.
  final onUnimplemented = TargetPlatformVariant.only(TargetPlatform.fuchsia);

  /// The native side of the channel, captured when Dart subscribes.
  MockStreamHandlerEventSink? sink;

  /// Stands in for the plugin.
  ///
  /// Must be called from inside the test body, not from `setUp`.
  /// `setMockStreamHandler` builds a `StreamController` in the calling zone,
  /// and `setUp` runs outside the `FakeAsync` zone the body runs in. A
  /// controller built out there delivers on the real event loop, which
  /// `tester.pump` does not advance: events would silently never arrive, and
  /// `tester.idle` would wait for them forever.
  void connectPlugin() {
    sink = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          channel,
          // Block bodies, not arrows. An arrow body returns the assigned value,
          // and the mock encodes whatever `onListen` returns as the reply to
          // the `listen` call, so `=> sink = events` tries to send a
          // MockStreamHandlerEventSink over the channel and the subscription
          // fails with a PlatformException.
          MockStreamHandler.inline(
            onListen: (_, events) {
              sink = events;
            },
            onCancel: (_) {
              sink = null;
            },
          ),
        );
  }

  tearDown(() {
    LocalTimezoneWatcher.debugReset();
    LocalTimezone.clearMock();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, null);
  });

  /// A [testWidgets] with the plugin connected and a platform pinned.
  void watcherTest(
    String description,
    Future<void> Function(WidgetTester tester) body, {
    TargetPlatformVariant? variant,
  }) {
    testWidgets(description, (tester) async {
      connectPlugin();
      await body(tester);
    }, variant: variant ?? onAndroid);
  }

  /// Rings the doorbell, as the plugin does. Carries nothing, on purpose.
  Future<void> signal(WidgetTester tester) async {
    expect(
      sink,
      isNotNull,
      reason: 'the watcher never subscribed to the platform channel',
    );
    sink!.success(null);
    await tester.pump();
  }

  group('addListener', () {
    watcherTest('does not fire for the zone the device was already in', (
      tester,
    ) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      // The first resolve is the baseline, not a change. Reporting it would
      // make every app see a spurious "you moved" on launch.
      expect(events, isEmpty);
    });

    watcherTest('fires when a signal finds a different zone', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezone.setMockValue(_london);
      await signal(tester);

      expect(events, [const LocalTimezoneChanged(_london)]);
    });

    watcherTest('stays silent when a signal finds the same zone', (
      tester,
    ) async {
      // The spurious-wakeup case, which every platform produces: Android bumps
      // the property serial on a same-value write, Windows rewrites its key at
      // DST, Linux fires twice per `set-timezone`.
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      await signal(tester);
      await signal(tester);

      expect(events, isEmpty);
    });

    watcherTest('reports one event for a burst of signals', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezone.setMockValue(_london);
      await signal(tester);
      await signal(tester);
      await signal(tester);

      expect(events, hasLength(1));
    });

    watcherTest('calls a listener registered twice, twice', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      var calls = 0;
      void listener(LocalTimezoneEvent _) => calls++;

      LocalTimezoneWatcher.addListener(listener);
      LocalTimezoneWatcher.addListener(listener);
      await tester.pump();

      LocalTimezone.setMockValue(_london);
      await signal(tester);

      expect(calls, 2);
    });
  });

  group('removeListener', () {
    watcherTest('stops delivery', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezoneWatcher.removeListener(events.add);
      LocalTimezone.setMockValue(_london);

      // Removing the last listener tears the subscription down, so there is no
      // sink left to ring. That is the assertion.
      expect(sink, isNull);
      expect(events, isEmpty);
    });

    watcherTest('removes one registration of a listener added twice', (
      tester,
    ) async {
      LocalTimezone.setMockValue(_kolkata);

      var calls = 0;
      void listener(LocalTimezoneEvent _) => calls++;

      LocalTimezoneWatcher.addListener(listener);
      LocalTimezoneWatcher.addListener(listener);
      LocalTimezoneWatcher.removeListener(listener);
      await tester.pump();

      LocalTimezone.setMockValue(_london);
      await signal(tester);

      expect(calls, 1);
    });

    watcherTest('ignores a listener that was never added', (tester) async {
      LocalTimezone.setMockValue(_kolkata);
      expect(
        () => LocalTimezoneWatcher.removeListener((_) {}),
        returnsNormally,
      );
    });
  });

  group('failure', () {
    watcherTest('reports a zone becoming unresolvable', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezoneWatcher.debugResolveOverride = () => throw _unavailable;
      await signal(tester);

      expect(events, [const LocalTimezoneUnavailable(_unavailable)]);
    });

    watcherTest('reports a repeated failure once', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezoneWatcher.debugResolveOverride = () => throw _unavailable;
      await signal(tester);
      await signal(tester);

      // Same reasoning as two identical zones in a row: the resolved value did
      // not change, so there is nothing to report.
      expect(events, hasLength(1));
    });

    watcherTest('reports recovery from unresolvable', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezoneWatcher.debugResolveOverride = () => throw _unavailable;
      await signal(tester);

      LocalTimezoneWatcher.debugResolveOverride = null;
      LocalTimezone.setMockValue(_london);
      await signal(tester);

      expect(events, [
        const LocalTimezoneUnavailable(_unavailable),
        const LocalTimezoneChanged(_london),
      ]);
    });

    watcherTest('keeps notifying after one listener throws', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener((_) => throw StateError('boom'));
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      LocalTimezone.setMockValue(_london);
      await signal(tester);

      expect(events, [const LocalTimezoneChanged(_london)]);
      expect(tester.takeException(), isStateError);
    });
  });

  group('lifecycle', () {
    watcherTest('re-checks when the app resumes', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      final events = <LocalTimezoneEvent>[];
      LocalTimezoneWatcher.addListener(events.add);
      await tester.pump();

      // The zone moved while the app was away, which no native trigger can
      // report because nothing was running to receive it.
      LocalTimezone.setMockValue(_london);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(events, [const LocalTimezoneChanged(_london)]);
    });
  });

  group('listenable', () {
    watcherTest('is null while nothing is watching', (tester) async {
      LocalTimezone.setMockValue(_kolkata);
      expect(LocalTimezoneWatcher.listenable.value, isNull);
    });

    watcherTest('is populated as soon as a listener attaches', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      LocalTimezoneWatcher.addListener((_) {});
      // Synchronous on purpose: a ListenableBuilder subscribes in initState and
      // reads in build, with no frame in between.
      expect(LocalTimezoneWatcher.listenable.value, _kolkata);
    });

    watcherTest('starts the watcher on its own', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      void noop() {}
      LocalTimezoneWatcher.listenable.addListener(noop);
      await tester.pump();

      // Nothing called addListener, so if the native leg is running it is
      // because attaching to the listenable started it.
      expect(sink, isNotNull);
      expect(LocalTimezoneWatcher.listenable.value, _kolkata);

      LocalTimezoneWatcher.listenable.removeListener(noop);
    });

    watcherTest('notifies and updates on a change', (tester) async {
      LocalTimezone.setMockValue(_kolkata);

      var notifications = 0;
      void onChange() => notifications++;

      LocalTimezoneWatcher.listenable.addListener(onChange);
      await tester.pump();

      LocalTimezone.setMockValue(_london);
      await signal(tester);

      expect(notifications, 1);
      expect(LocalTimezoneWatcher.listenable.value, _london);

      LocalTimezoneWatcher.listenable.removeListener(onChange);
    });

    watcherTest('goes null rather than stale when the last listener leaves', (
      tester,
    ) async {
      LocalTimezone.setMockValue(_kolkata);

      void listener(LocalTimezoneEvent _) {}
      LocalTimezoneWatcher.addListener(listener);
      await tester.pump();
      expect(LocalTimezoneWatcher.listenable.value, _kolkata);

      LocalTimezoneWatcher.removeListener(listener);
      expect(LocalTimezoneWatcher.listenable.value, isNull);
    });

    watcherTest('keeps the watcher alive while only it is attached', (
      tester,
    ) async {
      LocalTimezone.setMockValue(_kolkata);

      void noop() {}
      LocalTimezoneWatcher.listenable.addListener(noop);
      void listener(LocalTimezoneEvent _) {}
      LocalTimezoneWatcher.addListener(listener);
      await tester.pump();

      LocalTimezoneWatcher.removeListener(listener);

      // The listenable still has a subscriber, so tearing down here would stop
      // feeding a widget that is still on screen.
      expect(sink, isNotNull);
      expect(LocalTimezoneWatcher.listenable.value, _kolkata);

      LocalTimezoneWatcher.listenable.removeListener(noop);
      expect(sink, isNull);
    });
  });

  group('platform gating', () {
    watcherTest('opens a channel on every implemented platform', (
      tester,
    ) async {
      LocalTimezone.setMockValue(_kolkata);

      LocalTimezoneWatcher.addListener((_) {});
      await tester.pump();

      expect(
        sink,
        isNotNull,
        reason:
            'this platform has a native implementation, so the watcher should '
            'have subscribed to its channel',
      );

      LocalTimezone.setMockValue(_london);
      await signal(tester);
      expect(LocalTimezoneWatcher.listenable.value, _london);
    }, variant: onImplemented);

    watcherTest(
      'does not open a channel where there is no implementation',
      (tester) async {
        LocalTimezone.setMockValue(_kolkata);

        final events = <LocalTimezoneEvent>[];
        LocalTimezoneWatcher.addListener(events.add);
        await tester.pump();

        expect(
          sink,
          isNull,
          reason:
              'subscribing on a platform with no plugin logs a framework error '
              'rather than failing catchably, so it must not be attempted',
        );

        // The lifecycle leg still works, which is the whole point of gating
        // rather than throwing.
        LocalTimezone.setMockValue(_london);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(events, [const LocalTimezoneChanged(_london)]);
      },
      variant: onUnimplemented,
    );
  });
}
