// `vm` as well as `mac-os`, because the node platform reports the host OS and
// would otherwise select this file, where `dart:io` does not compile.
@TestOn('vm && mac-os')
library;

import 'dart:io';

import 'package:local_timezone/local_timezone.dart';
import 'package:test/test.dart';

/// The device's zone derived independently of the package, by resolving the
/// `/etc/localtime` symlink. Gives the assertions something to compare against
/// that does not come from the code under test.
///
/// `/etc/localtime` is the right path for macOS and the simulator only. The
/// SDK's `tzfile.h` defines `TZDEFAULT` as `/var/db/timezone/localtime` on a
/// real iOS device, so this helper does not transfer to a device test. Apple
/// guarantees only that the final component of the prefix is `zoneinfo`, which
/// is why the split is on that rather than on a fixed prefix.
String? zoneFromLocaltimeSymlink() {
  final file = File('/etc/localtime');
  if (!file.existsSync()) return null;
  final resolved = file.resolveSymbolicLinksSync();
  for (final marker in const ['zoneinfo.default/', 'zoneinfo/']) {
    final index = resolved.indexOf(marker);
    if (index != -1) return resolved.substring(index + marker.length);
  }
  return null;
}

/// Resolves the timezone in a subprocess with `TZ` set to [zone], and returns
/// the fixture's one-line record.
///
/// `TZ` is read once at process start, so changing it in-process would not
/// take effect. See `test/fixture/print_zone.dart` for the record format.
String resolveWithTz(String zone) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', 'test/fixture/print_zone.dart'],
    environment: {'TZ': zone},
  );
  expect(
    result.exitCode,
    0,
    reason: 'fixture failed for TZ=$zone: ${result.stderr}',
  );
  return (result.stdout as String).trim();
}

void main() {
  group('LocalTimezone.getTimeZoneName', () {
    test('returns a non-empty identifier', () {
      final zone = LocalTimezone.getTimeZoneName();
      expect(zone, isNotEmpty);
      expect(zone.trim(), zone, reason: 'must not be padded');
    });

    test('agrees with the /etc/localtime symlink', () {
      final expected = zoneFromLocaltimeSymlink();
      if (expected == null) {
        markTestSkipped('no /etc/localtime symlink on this machine');
        return;
      }
      expect(LocalTimezone.getTimeZoneName(), expected);
    });

    test('is stable across repeated calls', () {
      final first = LocalTimezone.getTimeZoneName();
      for (var i = 0; i < 1000; i++) {
        expect(LocalTimezone.getTimeZoneName(), first);
      }
    });

    test(
      'tracks the TZ environment variable',
      () {
        // Proves the value is read from the platform rather than being a
        // constant. These are all current primary names, so canonicalizing
        // leaves them alone and all three layers coincide.
        for (final zone in const [
          'Europe/Paris',
          'America/Denver',
          'Pacific/Chatham',
        ]) {
          expect(resolveWithTz(zone), 'named|$zone|$zone|$zone');
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('canonicalization', () {
    test(
      'rewrites the deprecated names Foundation reports verbatim',
      () {
        // Foundation does no canonicalization: the identifier is the tail of
        // the TZDEFAULT symlink, returned as-is. So Apple can and does report
        // any of the IANA backward names, and canonicalizing is load-bearing here
        // rather than the no-op it looks like on a Mac that happens to be
        // configured with a primary name.
        //
        // Note the direction. Apple's own knownTimeZoneNames comes from ICU,
        // whose stable-ID policy keeps `Asia/Calcutta` canonical and omits
        // `Asia/Kolkata` entirely, so it must never be used to validate these.
        expect(
          resolveWithTz('Asia/Calcutta'),
          'named|Asia/Kolkata|Asia/Calcutta|Asia/Calcutta',
        );
        expect(
          resolveWithTz('Europe/Kiev'),
          'named|Europe/Kyiv|Europe/Kiev|Europe/Kiev',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'maps the bare GMT that Apple reports for UTC',
      () {
        // Foundation names the zero-offset zone `GMT` where browsers say
        // `UTC`. Bare `GMT` is a real zone name rather than an offset, so it
        // stays named and canonicalizes to `Etc/GMT`.
        expect(resolveWithTz('UTC'), 'named|Etc/GMT|GMT|GMT');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('fixed offsets', () {
    test(
      'reports a POSIX TZ string as an offset, not as a zone name',
      () {
        // Foundation falls back to a fixed-offset zone when TZ holds something
        // it cannot resolve to a zone file, and names it `GMT+0530`. That is
        // not an identifier any timezone database accepts, so returning it as
        // one would be dishonest.
        //
        // The sign is the part worth pinning down, and `raw` deliberately
        // disagrees with `offset` here. Foundation names the zone in the ISO
        // convention, so it calls TZ=GMT+5 "GMT+0500". libc reads the same
        // string as POSIX and runs the process at -05:00, and Dart's DateTime
        // follows libc. Since a caller has to land on the same wall clock as
        // DateTime, the offset is the runtime's and the name is Foundation's.
        //
        // Every expectation below was measured, then cross-checked against
        // `TZ=$z date +%z`. Do not hand-edit them; re-measure.
        expect(resolveWithTz('GMT+5'), 'offset|-05:00|GMT+0500|GMT');
        expect(resolveWithTz('UTC+05:30'), 'offset|-05:30|GMT+0530|GMT');
        expect(resolveWithTz('GMT-8'), 'offset|+08:00|GMT-0800|GMT');

        // The sharpest divergence: Foundation names it GMT+0530 while the
        // process is actually running in UTC, because libc rejects the
        // four-digit form and falls back.
        expect(resolveWithTz('GMT+0530'), 'offset|+00:00|GMT+0530|GMT');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('LocalTimezone.getTimeZone', () {
    test('returns a NamedLocalTimezone on a configured machine', () {
      // Apple reports an identifier whenever the device has a zone configured,
      // which is always true of a normally set up Mac. The offset case needs a
      // POSIX TZ to reach, so it lives in the subprocess group above.
      expect(LocalTimezone.getTimeZone(), isA<NamedLocalTimezone>());
    });

    test('getTimeZoneName returns the canonicalized field', () {
      final resolved = LocalTimezone.getTimeZone() as NamedLocalTimezone;
      expect(resolved.canonicalized, LocalTimezone.getTimeZoneName());
    });

    test('raw and name are the same on Apple', () {
      // Foundation already reports an identifier, so there is nothing to parse
      // and these two layers coincide. Windows and Linux are where they differ.
      // Whether canonicalizing changes anything depends on how this machine is
      // configured, so that is asserted in the canonicalization group instead,
      // where TZ makes it deterministic.
      final resolved = LocalTimezone.getTimeZone() as NamedLocalTimezone;
      expect(resolved.name, resolved.raw);
    });
  });

  group('async mirrors', () {
    test('getTimeZoneNameAsync matches the sync result', () async {
      expect(
        await LocalTimezone.getTimeZoneNameAsync(),
        LocalTimezone.getTimeZoneName(),
      );
    });

    test('getTimeZoneAsync matches the sync result', () async {
      expect(
        await LocalTimezone.getTimeZoneAsync(),
        LocalTimezone.getTimeZone(),
      );
    });
  });

  test('does not leak native memory', () {
    // -[NSTimeZone name] returns an autoreleased string on every call. Without
    // the autorelease pool this leaks about 56 bytes per call, silently, with
    // no warning: 500k calls would grow RSS by roughly 28 MB. This is the only
    // observable symptom, so it is the only way to test for it.
    const iterations = 500000;
    LocalTimezone.getTimeZoneName(); // warm up lazy statics
    final before = ProcessInfo.currentRss;
    for (var i = 0; i < iterations; i++) {
      LocalTimezone.getTimeZoneName();
    }
    final growthMb = (ProcessInfo.currentRss - before) / (1024 * 1024);

    expect(
      growthMb,
      lessThan(8),
      reason:
          'RSS grew ${growthMb.toStringAsFixed(1)} MB over $iterations calls, '
          'which suggests the autorelease pool is missing or mismatched',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
