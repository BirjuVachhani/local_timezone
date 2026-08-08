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
//     flutter test ../integration_test -d <device>
//
// Two of the cases below compare against a zone the harness configured, which
// this process cannot discover for itself. CI passes it in:
//
//     --dart-define=EXPECTED_ZONE=Asia/Kolkata
//     --dart-define=EXPECTED_RAW=Asia/Calcutta
//
// Both are optional. Left unset, those two cases skip and the rest still run,
// so a bare `flutter test ../integration_test -d <device>` on a workstation is
// a useful smoke test rather than a failure.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_timezone/flutter_local_timezone.dart';
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

String _wall(DateTime d) =>
    '${d.year}-${d.month}-${d.day} ${d.hour}:${d.minute}:${d.second}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(tzdata.initializeTimeZones);

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
}
