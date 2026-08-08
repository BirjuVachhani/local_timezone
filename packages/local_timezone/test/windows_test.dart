// Mapping and decoding only. Both are pure, so they run anywhere, and
// importing the library off Windows is safe because the kernel32 bindings are
// lazy top-level finals that nothing here touches.
//
// The GetDynamicTimeZoneInformation call itself is exercised by CI on a real
// Windows runner.
import 'package:local_timezone/src/canonicalize.dart';
import 'package:local_timezone/src/platform/windows.dart';
import 'package:local_timezone/src/windows_zones.g.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Reads a Dart list as though it were the WCHAR buffer Windows fills in.
int Function(int) buffer(List<int> units) =>
    (i) => i < units.length ? units[i] : 0;

List<int> utf16(String value) => value.codeUnits;

void main() {
  group('windowsZoneToIana', () {
    test('maps a key through the territory-independent fallback', () {
      // Note the spelling. CLDR's canonical ID for India is the *deprecated*
      // one, so this layer returns Asia/Calcutta and canonicalization is what
      // turns it into Asia/Kolkata. Asserting Asia/Kolkata here would be
      // testing the wrong layer.
      expect(windowsZoneToIana('India Standard Time'), 'Asia/Calcutta');
      expect(
        canonicalizeTimezoneId(windowsZoneToIana('India Standard Time')!),
        'Asia/Kolkata',
      );
      expect(windowsZoneToIana('Singapore Standard Time'), 'Asia/Singapore');
    });

    test('an unknown key returns null rather than guessing', () {
      expect(windowsZoneToIana('Narnia Standard Time'), isNull);
      expect(windowsZoneToIana(''), isNull);
    });

    // The reason the territory table exists. 66 of 139 keys cover more than
    // one zone, and using only CLDR's fallback silently relocates users.
    test('the region disambiguates a shared key', () {
      expect(windowsZoneToIana('Romance Standard Time'), 'Europe/Paris');
      expect(
        windowsZoneToIana('Romance Standard Time', region: 'ES'),
        'Europe/Madrid',
      );
      expect(
        windowsZoneToIana('Romance Standard Time', region: 'BE'),
        'Europe/Brussels',
      );

      expect(
        windowsZoneToIana('Central Europe Standard Time'),
        'Europe/Budapest',
      );
      expect(
        windowsZoneToIana('Central Europe Standard Time', region: 'CZ'),
        'Europe/Prague',
      );
    });

    test('an unknown or empty region falls back rather than failing', () {
      expect(
        windowsZoneToIana('Romance Standard Time', region: 'ZZ'),
        'Europe/Paris',
      );
      expect(
        windowsZoneToIana('Romance Standard Time', region: ''),
        'Europe/Paris',
      );
      expect(windowsZoneToIana('Romance Standard Time'), 'Europe/Paris');
    });
  });

  group('decodeUtf16', () {
    test('reads up to the terminator', () {
      final units = [...utf16('India Standard Time'), 0];
      expect(decodeUtf16(buffer(units), 128), 'India Standard Time');
    });

    // The bug this exists to prevent. Windows writes a 128-unit field and only
    // the prefix is meaningful; a decoder that skips NULs instead of stopping
    // at one concatenates the residue and produces a key that maps to nothing.
    test('stops at the terminator, ignoring anything after it', () {
      final units = [
        ...utf16('India Standard Time'),
        0,
        ...utf16('GARBAGE'),
        0,
      ];
      expect(decodeUtf16(buffer(units), 128), 'India Standard Time');
    });

    test('an immediately terminated buffer is empty', () {
      expect(decodeUtf16(buffer([0]), 128), isEmpty);
    });

    test('honours capacity when there is no terminator', () {
      final units = utf16('AAAA');
      expect(decodeUtf16(buffer(units), 2), 'AA');
    });

    test('non-ASCII survives, since Dart strings are UTF-16', () {
      final units = [...utf16('Ekaterinburg Стандарт'), 0];
      expect(decodeUtf16(buffer(units), 128), 'Ekaterinburg Стандарт');
    });
  });

  group('table invariants', () {
    test('is non-trivial and records its CLDR release', () {
      expect(windowsZones, hasLength(greaterThan(100)));
      expect(windowsZonesByTerritory, isNotEmpty);
      expect(windowsZonesCldrVersion, isNotEmpty);
    });

    test('every territory override has a fallback to fall back to', () {
      final orphans = windowsZonesByTerritory.keys
          .map((composite) => composite.split('|').first)
          .where((key) => !windowsZones.containsKey(key))
          .toSet();
      expect(orphans, isEmpty);
    });

    test('no override merely repeats the fallback', () {
      final redundant = windowsZonesByTerritory.entries.where((entry) {
        final key = entry.key.split('|').first;
        return windowsZones[key] == entry.value;
      });
      expect(redundant, isEmpty, reason: 'dead weight in every Windows build');
    });

    test('canonicalization is load-bearing here, not decorative', () {
      // CLDR's canonical IDs are frozen for stability, so a large share of the
      // table is deprecated spellings. Returning them uncanonicalized would fail
      // downstream for roughly a third of Windows configurations.
      final aliases = {
        ...windowsZones.values,
        ...windowsZonesByTerritory.values,
      }.where((zone) => canonicalizeTimezoneId(zone) != zone);
      expect(
        aliases,
        hasLength(greaterThan(50)),
        reason:
            'sanity: CLDR really '
            'does hand back deprecated names, and the provider must rewrite them',
      );
    });

    test('every value is a single identifier, not a CLDR zone list', () {
      // CLDR stores several zones per territory, space separated. Emitting one
      // of those lists verbatim would produce a name nothing can resolve.
      for (final value in [
        ...windowsZones.values,
        ...windowsZonesByTerritory.values,
      ]) {
        expect(value, isNot(contains(' ')), reason: value);
        expect(value, isNotEmpty);
      }
    });
  });

  group('downstream', () {
    setUpAll(tzdata.initializeTimeZones);

    // The same bar the rest of the package is held to: whatever Windows
    // resolves to has to be a name a timezone database actually accepts, after
    // canonicalization. A CLDR entry naming a zone that package:timezone's default
    // dataset lacks would be a silent failure on that Windows machine only.
    test('every mapping resolves after canonicalization', () {
      final unresolvable = <String>[];
      for (final value in {
        ...windowsZones.values,
        ...windowsZonesByTerritory.values,
      }) {
        final canonical = canonicalizeTimezoneId(value);
        try {
          tz.getLocation(canonical);
        } on Object {
          unresolvable.add('\$value -> \$canonical');
        }
      }
      expect(unresolvable, isEmpty);
    });
  });
}
