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
String roundTripWithTz(String zone) => _roundTrip({'TZ': zone}, 'TZ=$zone');

/// The same fixture with the environment left alone, so the zone under test is
/// whatever the machine is configured with.
String roundTripWithHostZone() => _roundTrip(null, 'the host zone');

String _roundTrip(Map<String, String>? environment, String label) {
  final result = Process.runSync(Platform.resolvedExecutable, [
    'run',
    'test/fixture/round_trip.dart',
  ], environment: environment);
  if (result.exitCode != 0) {
    fail('fixture failed for $label: ${result.stderr}');
  }
  return (result.stdout as String).trim().split('\n').last;
}

void main() {
  // The same bar, against whatever zone the machine is really configured with
  // rather than one forced through `TZ`.
  //
  // This is the only round trip that runs on Windows, and there it is the one
  // that matters: CI sets the system zone, so this checks the CLDR mapping end
  // to end against the clock the runtime keeps.
  test('the host zone round trips', () {
    expect(roundTripWithHostZone(), endsWith('|MATCH'));
  }, timeout: const Timeout(Duration(minutes: 2)));

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
        test('TZ=$zone (fixed offset)', () {
          expect(roundTripWithTz(zone), 'offset|MATCH');
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    // `TZ` moves one side of this comparison on Windows and not the other, so
    // every row here would mismatch by construction.
    //
    // The provider reads `GetDynamicTimeZoneInformation`, which never consults
    // the environment, so `TZ` cannot move it off the system zone. Dart's
    // `DateTime` goes through the MSVC CRT instead, and that *does* read `TZ`,
    // but only in the POSIX `IST-5:30` spelling. An IANA name fails to parse
    // and the CRT falls back to UTC. So on a runner set to Asia/Kolkata this
    // reports `named|Asia/Kolkata|MISMATCH 10:28 vs 4:58`: the name is right,
    // and the clock it is being compared against has been dragged to UTC.
    //
    // The host zone test above is the Windows equivalent, and is the stronger
    // check anyway, since nothing has to be faked to get there.
    skip: Platform.isWindows
        ? 'TZ drives DateTime but not the provider on Windows'
        : null,
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
