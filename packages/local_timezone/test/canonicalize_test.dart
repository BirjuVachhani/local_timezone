import 'package:local_timezone/src/backward.g.dart';
import 'package:local_timezone/src/canonicalize.dart';
import 'package:test/test.dart';

void main() {
  group('rewrites the aliases browsers actually emit', () {
    // Chrome, Edge and Node report the deprecated spelling for these, while
    // Firefox, Apple and Linux report the primary one. Without canonicalization
    // the same device gives two different answers depending on the browser.
    const cases = {
      'Asia/Calcutta': 'Asia/Kolkata',
      'Asia/Saigon': 'Asia/Ho_Chi_Minh',
      'Europe/Kiev': 'Europe/Kyiv',
      'Asia/Rangoon': 'Asia/Yangon',
      'America/Godthab': 'America/Nuuk',
      'Pacific/Enderbury': 'Pacific/Kanton',
      'Asia/Katmandu': 'Asia/Kathmandu',
      'America/Buenos_Aires': 'America/Argentina/Buenos_Aires',
      'Europe/Uzhgorod': 'Europe/Kyiv',
    };
    cases.forEach((alias, primary) {
      test('$alias -> $primary', () {
        expect(canonicalizeTimezoneId(alias), primary);
      });
    });
  });

  group('leaves primary names alone', () {
    for (final id in const [
      'Asia/Kolkata',
      'Europe/Kyiv',
      'America/New_York',
      'Australia/Eucla',
      'Pacific/Chatham',
      'Etc/UTC',
      'Etc/GMT',
    ]) {
      test(id, () => expect(canonicalizeTimezoneId(id), id));
    }
  });

  group('Etc/GMT sign trap', () {
    // These look like aliases but are real zones with an inverted sign:
    // Etc/GMT+5 is UTC-05:00. Rewriting one would move a user by twice their
    // offset, so they must pass through untouched.
    for (final id in const [
      'Etc/GMT+1',
      'Etc/GMT+5',
      'Etc/GMT+12',
      'Etc/GMT-1',
      'Etc/GMT-5',
      'Etc/GMT-14',
    ]) {
      test('$id is untouched', () {
        expect(canonicalizeTimezoneId(id), id);
        expect(backwardLinks.containsKey(id), isFalse);
      });
    }
  });

  group('zero-offset family resolves to its tzdb primary', () {
    // Browsers report UTC and Apple reports GMT for the same device. Both are
    // Links in tzdb, so both are rewritten, and package:timezone's default
    // dataset rejects both unrewritten.
    const cases = {
      'UTC': 'Etc/UTC',
      'Zulu': 'Etc/UTC',
      'Universal': 'Etc/UTC',
      'UCT': 'Etc/UTC',
      'Etc/UCT': 'Etc/UTC',
      'Etc/Zulu': 'Etc/UTC',
      'Etc/Universal': 'Etc/UTC',
      'GMT': 'Etc/GMT',
      'GMT0': 'Etc/GMT',
      'GMT+0': 'Etc/GMT',
      'GMT-0': 'Etc/GMT',
      'Greenwich': 'Etc/GMT',
      'Etc/Greenwich': 'Etc/GMT',
      'Etc/GMT+0': 'Etc/GMT',
      'Etc/GMT-0': 'Etc/GMT',
    };
    cases.forEach((alias, primary) {
      test('$alias -> $primary', () {
        expect(canonicalizeTimezoneId(alias), primary);
      });
    });

    test('the primaries are themselves untouched', () {
      expect(canonicalizeTimezoneId('Etc/UTC'), 'Etc/UTC');
      expect(canonicalizeTimezoneId('Etc/GMT'), 'Etc/GMT');
    });
  });

  group('unknown identifiers pass through', () {
    // A stale table must degrade to "no rewrite", never to a wrong answer or
    // an exception, so a zone added after publication still reaches callers.
    for (final id in const [
      'Mars/Olympus_Mons',
      'Not/AZone',
      '',
      'asia/calcutta', // wrong case: IANA ids are case sensitive
      '+05:30',
      'Etc/Unknown',
    ]) {
      test(id.isEmpty ? '<empty>' : id, () {
        expect(canonicalizeTimezoneId(id), id);
      });
    }
  });

  group('table invariants', () {
    test('is non-trivial and matches the generator output', () {
      expect(backwardLinks.length, greaterThan(200));
      expect(backwardTzdbVersion, matches(RegExp(r'^\d{4}[a-z]$')));
    });

    test('has no identity entries', () {
      final identity = backwardLinks.entries.where((e) => e.key == e.value);
      expect(
        identity,
        isEmpty,
        reason: 'an alias mapping to itself is dead weight',
      );
    });

    test('every target is a primary zone name', () {
      // The table holds every Link in tzdb, taken from `backward` and
      // `etcetera`. So a target that is absent from the keys cannot be an
      // alias, which makes it a Zone. That is the property callers depend on:
      // the result set equals what package:timezone accepts by default.
      // It also means one lookup is always enough, with no chain to follow.
      final aliasTargets = backwardLinks.entries
          .where((e) => backwardLinks.containsKey(e.value))
          .map((e) => '${e.key} -> ${e.value}');
      expect(
        aliasTargets,
        isEmpty,
        reason: 'a target that is itself an alias would not be a primary name',
      );
    });

    test('is idempotent', () {
      for (final alias in backwardLinks.keys) {
        final once = canonicalizeTimezoneId(alias);
        expect(canonicalizeTimezoneId(once), once, reason: 'for $alias');
      }
    });

    test('every target looks like a plausible identifier', () {
      for (final target in backwardLinks.values) {
        expect(target, isNotEmpty);
        expect(target.trim(), target);
        expect(target, isNot(startsWith('/')));
      }
    });
  });
}
