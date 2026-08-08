@TestOn('vm')
library;

import 'dart:io';

import 'package:local_timezone/src/backward.g.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The acceptance bar for this package, as a test.
///
/// Whatever we return has to survive the trip a real caller makes with it:
///
/// ```dart
/// tz.setLocalLocation(tz.getLocation(LocalTimezone.getTimeZoneName()));
/// tz.TZDateTime.now(tz.local)   ==   DateTime.now()
/// ```
///
/// `timezone` is a dev dependency only, so consumers are unaffected. It is here
/// so the compatibility claim in the README is enforced rather than asserted.
String roundTripWithTz(String zone) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', 'test/fixture/round_trip.dart'],
    environment: {'TZ': zone},
  );
  if (result.exitCode != 0) {
    fail('fixture failed for TZ=$zone: ${result.stderr}');
  }
  return (result.stdout as String).trim().split('\n').last;
}

void main() {
  group(
    'round trips through package:timezone',
    () {
      // Every shape the Apple provider can produce, plus the aliases that make
      // canonicalization load-bearing. A failure on a *named* row means the name we
      // hand back does not describe the zone the process is running in, which is
      // the bug this whole suite exists to prevent.
      for (final zone in const [
        'Asia/Kolkata', // a current primary name
        'Asia/Calcutta', // a deprecated alias, canonicalized on the way out
        'Europe/Kiev', // another, renamed more recently
        'America/Denver', // northern DST
        'Australia/Eucla', // a 45-minute offset
        'Pacific/Chatham', // another, with DST
        'UTC', // Foundation reports GMT, we canonicalize to Etc/GMT
        'Zulu', // canonicalized to Etc/UTC
        'Etc/GMT+5', // a real zone whose sign is inverted by design
      ]) {
        test('TZ=$zone', () {
          expect(roundTripWithTz(zone), endsWith('|MATCH'));
        });
      }

      // Foundation falls back to a fixed-offset zone for these, so the bar is
      // that the offset matches what the runtime applies.
      for (final zone in const ['GMT+5', 'GMT-8', 'GMT+0530', 'GMT+5:30']) {
        test(
          'TZ=$zone (fixed offset)',
          () {
            expect(roundTripWithTz(zone), 'offset|MATCH');
          },
          // Windows has no `TZ`. Both the provider and Dart's own `DateTime`
          // go to `GetDynamicTimeZoneInformation`, which reads the system zone
          // and never the environment, so the subprocess resolves the runner's
          // zone by name and there is no offset result to assert on. The named
          // rows above survive that for free, because what they check is that
          // whatever we resolved round trips onto the same wall clock, and
          // that stays a real assertion when the zone is the host's own.
          skip: Platform.isWindows
              ? 'TZ is inert on Windows, so no fixed-offset zone is reachable'
              : null,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  group('canonicalization preserves the zone', () {
    // The other way the bar can break, and the reason this is not assumed:
    // tzdb links are not all pure renames. Europe/Uzhgorod and Europe/Kyiv were
    // genuinely distinct zones before they were merged. If any rewrite changed
    // the offset, canonicalizing would silently move a caller's clock.
    //
    // latest_all is used deliberately: it is the only dataset that carries both
    // spellings, so the two can be compared at all.
    setUpAll(tzdata.initializeTimeZones);

    test('every alias and its target agree on the current offset', () {
      final now = DateTime.now();
      final divergent = <String>[];

      for (final entry in backwardLinks.entries) {
        final tz.Location alias;
        final tz.Location target;
        try {
          alias = tz.getLocation(entry.key);
          target = tz.getLocation(entry.value);
        } on Object {
          // A name this dataset does not carry cannot be compared here. The
          // dedicated coverage test already asserts every target is present.
          continue;
        }
        final a = alias.timeZone(now.millisecondsSinceEpoch).offset;
        final b = target.timeZone(now.millisecondsSinceEpoch).offset;
        if (a != b) {
          divergent.add('${entry.key} ($a) -> ${entry.value} ($b)');
        }
      }

      expect(
        divergent,
        isEmpty,
        reason:
            'canonicalizing these would move the caller off the wall clock '
            'their own DateTime reports',
      );
    });
  });
}
