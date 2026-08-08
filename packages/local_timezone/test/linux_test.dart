// Resolution logic only. These functions are pure, so they run anywhere, and
// importing the library off Linux is safe because nothing here touches the
// filesystem.
//
// The syscall wiring is exercised by CI on a real Linux runner; the parsing,
// which is where the bugs live, is covered here against fixtures taken from
// real distributions.
import 'package:local_timezone/src/platform/linux.dart';
import 'package:test/test.dart';

void main() {
  group('zoneFromTz', () {
    const named = {
      // glibc accepts all of these, and all of them turn up in the wild.
      'Asia/Kolkata': 'Asia/Kolkata',
      ':Asia/Kolkata': 'Asia/Kolkata',
      '/usr/share/zoneinfo/Asia/Kolkata': 'Asia/Kolkata',
      ':/usr/share/zoneinfo/Asia/Kolkata': 'Asia/Kolkata',
      // Docker images commonly set the bare name.
      'UTC': 'UTC',
      'GMT': 'GMT',
      'Etc/UTC': 'Etc/UTC',
      // A digit after a sign, which the POSIX-rule guard must not catch.
      'Etc/GMT+5': 'Etc/GMT+5',
      'Etc/GMT-14': 'Etc/GMT-14',
      // Three components.
      'America/Argentina/Buenos_Aires': 'America/Argentina/Buenos_Aires',
      // Slashless real zones.
      'EST': 'EST',
      'Japan': 'Japan',
      'Zulu': 'Zulu',
    };
    named.forEach((input, expected) {
      test('$input -> $expected', () => expect(zoneFromTz(input), expected));
    });

    const unnamed = [
      // POSIX rules. These describe offsets and transitions, not a zone, so
      // there is no identifier to report and the caller gets an offset.
      'EST5EDT,M3.2.0,M11.1.0',
      'EST5EDT',
      'IST-5:30',
      'GMT+5',
      'GMT0BST,M3.5.0/1,M10.5.0',
      'CET-1CEST,M3.5.0,M10.5.0/3',
      // Degenerate.
      '',
      ':',
      // A path with no database component in it.
      '/etc/localtime',
      ':/some/other/file',
    ];
    for (final input in unnamed) {
      test('${input.isEmpty ? '<empty>' : input} -> null', () {
        expect(zoneFromTz(input), isNull);
      });
    }
  });

  group('zoneFromPath', () {
    const cases = {
      '/usr/share/zoneinfo/Asia/Kolkata': 'Asia/Kolkata',
      // Rocky and Fedora write a relative target.
      '../usr/share/zoneinfo/Europe/Paris': 'Europe/Paris',
      '/usr/share/zoneinfo/America/Argentina/Buenos_Aires':
          'America/Argentina/Buenos_Aires',
      // Recent macOS. Checked before the plain marker, since `zoneinfo/` is a
      // prefix of `zoneinfo.default/` and would otherwise match first and
      // leave a stray `default/` on the front.
      '/var/db/timezone/zoneinfo.default/Asia/Tokyo': 'Asia/Tokyo',
      '/var/db/timezone/tz/2026b.1.0/zoneinfo/Asia/Kolkata': 'Asia/Kolkata',
    };
    cases.forEach((input, expected) {
      test('$input -> $expected', () => expect(zoneFromPath(input), expected));
    });

    for (final input in const [
      '/etc/localtime',
      '/usr/share/zoneinfo/', // nothing after the marker
      '',
      'Asia/Kolkata', // already a name, not a path
    ]) {
      test('${input.isEmpty ? '<empty>' : input} -> null', () {
        expect(zoneFromPath(input), isNull);
      });
    }

    // Most distributions ship these subtrees alongside the top-level names,
    // `right` being the leap-second build. A link into either names the same
    // zone one directory deeper, and returning the tail verbatim would hand
    // back `right/Asia/Kolkata`, which resolves nowhere.
    test('the posix and right subtrees are stripped', () {
      expect(
        zoneFromPath('/usr/share/zoneinfo/posix/Asia/Kolkata'),
        'Asia/Kolkata',
      );
      expect(
        zoneFromPath('/usr/share/zoneinfo/right/Europe/Paris'),
        'Europe/Paris',
      );
      expect(
        zoneFromPath('../usr/share/zoneinfo/posix/America/New_York'),
        'America/New_York',
      );
    });

    test('a zone whose own name starts with those words is untouched', () {
      // Nothing in tzdb begins `posix/` or `right/`, but the strip must be
      // anchored at the component boundary rather than matching anywhere.
      expect(
        zoneFromPath('/usr/share/zoneinfo/Australia/Brisbane'),
        'Australia/Brisbane',
      );
    });
  });

  group('zoneFromTimezoneFile', () {
    // Debian and derivatives write the name plus a newline.
    test('trailing newline is trimmed', () {
      expect(zoneFromTimezoneFile('Europe/Berlin\n'), 'Europe/Berlin');
    });

    test('surrounding whitespace is trimmed', () {
      expect(zoneFromTimezoneFile('  Asia/Tokyo  \r\n'), 'Asia/Tokyo');
    });

    for (final input in const ['', '\n', '   ', 'not a zone name!']) {
      test('${input.trim().isEmpty ? '<blank>' : input} -> null', () {
        expect(zoneFromTimezoneFile(input), isNull);
      });
    }
  });

  group('the POSIX-rule guard', () {
    // The single most dangerous discrimination in this file. Getting it wrong
    // in one direction reports a rule string as though it were a zone name;
    // in the other it throws away a legitimate zone whose name contains
    // digits.
    test('Etc/GMT+N is a zone, not a rule', () {
      for (var i = 1; i <= 12; i++) {
        expect(zoneFromTz('Etc/GMT+$i'), 'Etc/GMT+$i');
        expect(zoneFromTz('Etc/GMT-$i'), 'Etc/GMT-$i');
      }
    });

    test('an abbreviation followed by an offset is a rule, not a zone', () {
      for (final rule in const ['EST5', 'CET-1', 'AEST-10', 'IST-5:30']) {
        expect(zoneFromTz(rule), isNull, reason: rule);
      }
    });
  });
}
