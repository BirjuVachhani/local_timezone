// Device tests. These run on a real Android device or emulator and a real iOS
// device or simulator, which is the only place the Android and Apple providers
// can be exercised at all: one reads `__system_property_get`, the other calls
// into Foundation, and neither exists on a desktop host.
//
// They live here, in the package that owns the code, rather than in the app
// that hosts them. `flutter test -d <device>` needs a runner project to build
// an installable app from, so `../test_host` exists to be that project and
// nothing else. It does not need to own the tests:
//
//     cd packages/flutter_local_timezone/test_host
//     flutter test integration_test -d <device>
//
// The command targets the delegating entrypoint under `test_host`, which calls
// this file's [main], so the cases themselves still live with the package that
// owns them. The indirection is not cosmetic. `flutter test` decides a file is
// a device test by checking that its path starts with `<cwd>/integration_test`,
// so passing `../integration_test` from `test_host` fails that check, and the
// run silently downgrades to `flutter_tester` on the host: `-d` is ignored, no
// app is built, and the provider under test is never reached. It reports a
// green suite while proving nothing about the device, so keep the path
// relative to the runner project.
//
// Some cases below compare against zones the harness controls, which this
// process cannot discover for itself. CI passes them in:
//
//     --dart-define=EXPECTED_ZONE=Asia/Kolkata
//     --dart-define=EXPECTED_RAW=Asia/Calcutta
//     --dart-define=ZONE_AFTER=Australia/Sydney
//
// All three are optional. Left unset, those cases skip and the rest still run,
// so a bare `flutter test integration_test -d <device>` on a workstation is a
// useful smoke test rather than a failure.
//
// The first two describe the zone the device is in when the suite starts. The
// third is different in kind: it is the zone the harness moves the device to
// *while the suite runs*, which is the only way to exercise the listener. An
// app cannot change its own timezone, so that mutation has to come from the
// host over adb, and the case that asserts on it therefore has to be last.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_timezone/flutter_local_timezone.dart';
import 'package:flutter_local_timezone/src/timezone_signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The zone the harness put the device into, canonicalized.
///
/// This is compared against [NamedLocalTimezone.canonicalized], so it has to be
/// the primary spelling. `Asia/Kolkata`, not `Asia/Calcutta`.
const expectedZone = String.fromEnvironment('EXPECTED_ZONE');

/// What the platform is expected to report before canonicalization.
///
/// Separate from [expectedZone] because the two genuinely differ. Android
/// stores whatever was written to `persist.sys.timezone`, and Foundation
/// reports whatever spelling the OS wrote, so a device set to `Asia/Kolkata`
/// can report `Asia/Calcutta`. Only set this where the harness knows which one
/// to expect.
const expectedRaw = String.fromEnvironment('EXPECTED_RAW');

/// The zone the harness moves the device to *while this suite is running*.
///
/// Unset outside CI, which skips the listener case. Proving that a platform
/// really delivers a change notification needs the zone to actually change
/// mid-run, and nothing inside the app can do that: an app cannot hold
/// `SET_TIME_ZONE`, so the mutation has to come from the host over adb. See
/// `.github/scripts/android_device_test.sh`.
const zoneAfter = String.fromEnvironment('ZONE_AFTER');

/// Printed once the listener is registered, so the harness knows when it is
/// safe to move the device zone.
///
/// Deliberately a shape nothing else emits, because the harness greps
/// `flutter test`'s combined output for it and that stream also carries the
/// tool's own chatter and anything the app logs.
const listenerReadySentinel = 'LOCAL_TIMEZONE_LISTENER_READY';

/// How long to wait for the harness to move the zone.
///
/// Generous on purpose. The host schedules the change a fixed delay after the
/// app process appears, and CI emulators are slow enough that pinning this
/// tighter would buy flakiness rather than speed.
const _listenerTimeout = Duration(seconds: 90);

/// Everything the watcher reported, from process start.
///
/// Collected from `setUpAll` rather than inside the case that asserts on it,
/// because the harness fires its change against the wall clock and cannot know
/// which case is running. Registering early means the event is captured
/// whenever it lands.
final _observed = <LocalTimezoneEvent>[];

String _wall(DateTime d) =>
    '${d.year}-${d.month}-${d.day} ${d.hour}:${d.minute}:${d.second}';

Future<void> _awaitEvent() async {
  final deadline = DateTime.now().add(_listenerTimeout);
  while (_observed.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    tzdata.initializeTimeZones();
    LocalTimezoneWatcher.addListener(_observed.add);

    // The harness waits for this line before moving the device zone.
    //
    // It used to key off the app process existing plus a fixed sleep, which
    // races `flutter test`'s own startup: after the process appears the tool is
    // still reading logcat for the VM service URL and attaching, and moving the
    // system clock through that window is a good way to make an already flaky
    // attach fail. On 2026-08-08 one Android cell went silent right there and
    // burned the job's whole 45 minute budget.
    //
    // Printing from `setUpAll` removes the guesswork entirely: by the time this
    // reaches the harness, the tool has attached, the suite is running, and the
    // listener above is registered.
    debugPrint(listenerReadySentinel);
  });

  testWidgets('resolves to a named zone', (_) async {
    final resolved = LocalTimezone.getTimeZone();

    // Logged, not asserted. Which zone the device is in is the harness's
    // business, but having it in the log is what makes a failure on a runner
    // diagnosable without a rerun, and it is the only way to see what a
    // simulator picked up when nothing was injected.
    debugPrint('device reports $resolved');

    // Not just `isA<NamedLocalTimezone>()`. An offset result is a real outcome
    // of the API rather than a bug in it, so if a device produces one the
    // failure should say which device and what it said, not just report the
    // wrong subtype.
    expect(
      resolved,
      isA<NamedLocalTimezone>(),
      reason:
          'the device reported no IANA zone, only $resolved. '
          'A device with a zone configured should never reach this.',
    );
  });

  testWidgets('agrees with the zone the harness configured', (_) async {
    expect(LocalTimezone.getTimeZoneName(), expectedZone);
  }, skip: expectedZone.isEmpty);

  testWidgets('reports the raw value the harness expects', (_) async {
    // The layer under canonicalization. Worth pinning separately, because a
    // regression that canonicalized correctly from the wrong input would pass
    // the test above.
    expect(LocalTimezone.getTimeZone().raw, expectedRaw);
  }, skip: expectedRaw.isEmpty);

  testWidgets('round trips through package:timezone', (_) async {
    // The acceptance bar, and the one case here that needs nothing injected:
    // whatever zone the device is in, resolving it through a timezone database
    // and rebuilding the moment has to land on the same wall clock as a plain
    // `DateTime`. A zone that is merely well formed but wrong fails this.
    final resolved = LocalTimezone.getTimeZone();

    // One instant for both sides, so the comparison is exact rather than
    // racing the clock over a second boundary.
    final now = DateTime.now();

    switch (resolved) {
      case NamedLocalTimezone(:final canonicalized):
        // Deliberately `canonicalized`: that is what `getTimeZoneName` hands
        // back, so it is the string a caller actually looks up.
        final location = tz.getLocation(canonicalized);
        expect(
          _wall(tz.TZDateTime.from(now, location)),
          _wall(now),
          reason: '$canonicalized does not agree with the device clock',
        );

      case OffsetLocalTimezone(:final offset):
        // An offset cannot be fed to `getLocation`, so the equivalent bar is
        // that it matches the offset the runtime actually applies.
        expect(offset, now.timeZoneOffset);
    }
  });

  testWidgets('is stable across repeated calls', (_) async {
    // Nothing is cached, so every call re-reads the platform. Reading the same
    // unchanged device twice has to give the same answer.
    expect(
      List.generate(5, (_) => LocalTimezone.getTimeZone()),
      everyElement(equals(LocalTimezone.getTimeZone())),
    );
  });

  testWidgets('async mirrors sync', (_) async {
    expect(await LocalTimezone.getTimeZoneAsync(), LocalTimezone.getTimeZone());
    expect(
      await LocalTimezone.getTimeZoneNameAsync(),
      LocalTimezone.getTimeZoneName(),
    );
  });

  // Deliberately last. It waits for the harness to move the device zone, and
  // every case above asserts on the zone the harness configured *before* the
  // run, so they have to be finished before that happens.
  testWidgets('reports a zone change made by the system', (_) async {
    await _awaitEvent();

    expect(
      _observed,
      isNotEmpty,
      reason:
          'the device zone was moved to $zoneAfter and no listener fired '
          'within $_listenerTimeout. Either the platform notification never '
          'arrived, or the harness never changed the zone.',
    );

    final event = _observed.first;
    debugPrint('watcher reported $event');

    // Not just `isA<LocalTimezoneChanged>()`. The whole design rests on the
    // platform having already written the new zone by the time it tells us: if
    // the notification went out first, this would re-resolve, read the old
    // value, diff to "no change", and report nothing at all. Asserting the
    // value is what tests that ordering. Asserting only that *an* event arrived
    // would pass on a build where the value was stale.
    expect(
      event,
      isA<LocalTimezoneChanged>().having(
        (e) => switch (e.timezone) {
          NamedLocalTimezone(:final canonicalized) => canonicalized,
          final OffsetLocalTimezone offset => offset.iso8601,
        },
        'timezone',
        zoneAfter,
      ),
    );

    // The same value, through the other half of the public API.
    expect(
      LocalTimezoneWatcher.listenable.value,
      (event as LocalTimezoneChanged).timezone,
    );

    // And the plain synchronous read agrees, which is what a caller reaching
    // for `getTimeZoneName()` inside the callback would see.
    expect(LocalTimezone.getTimeZoneName(), zoneAfter);
  }, skip: zoneAfter.isEmpty);

  // Deliberately last, because it deliberately breaks the native subscription
  // that everything above depends on.
  //
  // This exists because a green run proves less than it looks like it does.
  // When Dart subscribes to an EventChannel with no native handler, the failure
  // is handed to `FlutterError.reportError` rather than delivered as a stream
  // error, and that does *not* fail an integration test: pointing the channel
  // name at a deliberate typo and rerunning this suite on macOS still reported
  // "All tests passed". Without a positive check, "the suite is green on an
  // Apple device" and "the plugin was never registered" are the same
  // observation.
  //
  // So probe the wire protocol directly. An EventChannel is a MethodChannel of
  // the same name carrying `listen` and `cancel`, so invoking `listen` by hand
  // reaches the same native stream handler. No handler means
  // MissingPluginException.
  testWidgets(
    'the platform channel has a native handler',
    (_) async {
      const probe = MethodChannel(timezoneSignalChannelName);
      try {
        await probe.invokeMethod<void>('listen');
      } on MissingPluginException {
        fail(
          'nothing is registered on "$timezoneSignalChannelName", so this '
          'platform has no native doorbell however green the rest of this '
          'suite looks. Check that the plugin is declared for this platform in '
          'pubspec.yaml, that the host app depends on flutter_local_timezone, '
          'and that the channel name matches on both sides.',
        );
      } finally {
        // Undo it, for tidiness rather than correctness: this is the last case.
        try {
          await probe.invokeMethod<void>('cancel');
        } on PlatformException {
          // Nothing after this depends on the subscription.
        }
      }
    },
    skip: kIsWeb || !_platformsWithADoorbell.contains(defaultTargetPlatform),
  );
}

/// Kept beside the probe rather than imported, so that adding a platform to
/// the package's own gate without adding it here shows up as a skipped case
/// rather than as silence.
const _platformsWithADoorbell = {
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
};
