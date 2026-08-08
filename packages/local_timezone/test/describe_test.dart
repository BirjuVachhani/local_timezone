import 'package:local_timezone/local_timezone.dart';
import 'package:local_timezone/src/describe.dart';
import 'package:test/test.dart';

void main() {
  group('describe', () {
    test('leaves every real zone name untouched', () {
      for (final name in [
        'Asia/Kolkata',
        'America/Argentina/Buenos_Aires',
        'Etc/GMT+5',
        'UTC',
        'America/Port-au-Prince',
        'GMT',
      ]) {
        expect(describe(name), name, reason: '$name must survive verbatim');
      }
    });

    test('leaves a Windows zone key untouched', () {
      // Spaces, periods and parentheses are all legitimate here.
      expect(
        describe('Central Standard Time (Mexico)'),
        'Central Standard Time (Mexico)',
      );
      expect(describe('E. Africa Standard Time'), 'E. Africa Standard Time');
    });

    test('escapes the line breaks that would forge a log entry', () {
      expect(
        describe('Etc/UTC\nWARN root logged in'),
        r'Etc/UTC\nWARN root logged in',
      );
      expect(describe('a\r\nb'), r'a\r\nb');
      expect(describe('a\tb'), r'a\tb');
    });

    test('escapes the ANSI escape that would repaint a terminal', () {
      expect(describe('Etc/UTC\x1b[2J'), r'Etc/UTC\x1b[2J');
    });

    test('escapes NUL, DEL and C1 controls', () {
      expect(describe('a\x00b'), r'a\x00b');
      expect(describe('a\x7fb'), r'a\x7fb');
      expect(describe('a\x9bb'), r'a\x9bb');
    });

    test('escapes bidirectional formatting, which is not a control char', () {
      // U+202E reverses everything after it, so an unescaped one can make a
      // log line read backwards. It is above U+009F, so the control-character
      // range does not catch it.
      expect(describe('Etc/\u202eUTC'), r'Etc/\u{202e}UTC');
      expect(describe('a\u2066b'), r'a\u{2066}b');
      expect(describe('a\u200eb'), r'a\u{200e}b');
    });

    test('escapes the quote and backslash that would break the quoting', () {
      // Messages wrap these values in double quotes, so an unescaped quote
      // lets a value close the quoted section and append its own commentary.
      expect(describe('Etc/UTC" and fine'), r'Etc/UTC\" and fine');
      expect(describe(r'a\b'), r'a\\b');
    });

    test('escapes the Unicode line and paragraph separators', () {
      // Not C0 or C1, so the control-character range does not catch them, but
      // a log consumer splitting on Unicode line boundaries breaks on them.
      expect(describe('Etc/UTC\u2028FORGED'), r'Etc/UTC\u{2028}FORGED');
      expect(describe('Etc/UTC\u2029FORGED'), r'Etc/UTC\u{2029}FORGED');
    });

    test('truncation never splits a surrogate pair', () {
      // 119 ASCII plus one astral character is 121 UTF-16 code units but 120
      // runes, so a code-unit truncation at 120 would keep the high surrogate
      // and drop the low one, leaving an unpaired surrogate in the output.
      final out = describe('${'A' * 119}\u{1F600}');
      expect(out, '${'A' * 119}\u{1F600}');
      expect(out.runes.every((r) => r < 0xd800 || r > 0xdfff), isTrue);

      final cut = describe('${'A' * 130}\u{1F600}');
      expect(cut.runes.every((r) => r < 0xd800 || r > 0xdfff), isTrue);
      expect(cut, endsWith('...'));
    });

    test('the exception message sanitizes reason and platform too', () {
      // These are built by the providers, but they are built by interpolating
      // whatever the platform said, so they are exactly as untrusted as raw.
      final message = const LocalTimezoneUnavailableException(
        platform: 'linux\nFORGED',
        reason: 'no TZ\u2028FORGED',
      ).message;
      expect(message, isNot(contains('\n')));
      expect(message, isNot(contains('\u2028')));
      expect(message, contains(r'linux\nFORGED'));
      expect(message, contains(r'no TZ\u{2028}FORGED'));
    });

    test('bounds the output', () {
      final out = describe('Z' * 400);
      expect(out.length, lessThan(130));
      expect(out, endsWith('...'));
    });

    test('bounds the output even when every character expands', () {
      // 400 newlines become 400 two-character escapes if truncation happens
      // after escaping instead of before.
      expect(describe('\n' * 400).length, lessThan(260));
    });

    test('is a rendering concern only, so fields stay verbatim', () {
      const hostile = 'Etc/UTC\nWARN forged';
      const resolved = NamedLocalTimezone(
        name: hostile,
        canonicalized: 'Etc/UTC',
        raw: hostile,
      );
      expect(resolved.raw, hostile, reason: 'raw is documented as verbatim');
      expect(resolved.name, hostile);
      expect(resolved.toString(), isNot(contains('\n')));
    });
  });

  group('rendered through the public types', () {
    test('NamedLocalTimezone.toString cannot inject a line', () {
      expect(
        const NamedLocalTimezone(
          name: 'Etc/UTC\nWARN forged',
          canonicalized: 'Etc/UTC',
          raw: 'Etc/UTC\nWARN forged',
        ).toString(),
        r'NamedLocalTimezone(Etc/UTC, name: Etc/UTC\nWARN forged)',
      );
    });

    test('OffsetLocalTimezone.toString cannot inject a line', () {
      expect(
        const OffsetLocalTimezone(
          offset: Duration.zero,
          raw: '+00:00\nWARN forged',
          prefix: 'GMT\n',
        ).toString(),
        r'OffsetLocalTimezone(offset: +00:00, prefix: GMT\n, '
        r'raw: +00:00\nWARN forged)',
      );
    });

    test('exception messages cannot inject a line', () {
      expect(
        const LocalTimezoneUnavailableException(
          platform: 'web',
          reason: 'Intl reported an unusable value',
          raw: 'Etc/Unknown\nWARN forged',
        ).message,
        contains(r'`Etc/Unknown\nWARN forged`'),
      );
      expect(
        const LocalTimezoneNotNamedException(
          OffsetLocalTimezone(
            offset: Duration.zero,
            raw: '+00:00\nWARN forged',
          ),
        ).message,
        isNot(contains('\n')),
      );
    });
  });
}
