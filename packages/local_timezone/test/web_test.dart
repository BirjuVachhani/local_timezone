@TestOn('browser || node')
library;

import 'package:local_timezone/local_timezone.dart';
import 'package:local_timezone/src/backward.g.dart';
import 'package:test/test.dart';

/// Assertions that must hold whatever timezone the host is configured with,
/// so the same file is meaningful under every `TZ` the CI matrix sweeps.
void main() {
  test('resolves without throwing on a configured host', () {
    expect(LocalTimezone.getTimeZone, returnsNormally);
  });

  test('a named result is canonicalized', () {
    final resolved = LocalTimezone.getTimeZone();
    if (resolved is! NamedLocalTimezone) return;

    expect(resolved.name, isNotEmpty);
    expect(
      backwardLinks.containsKey(resolved.name),
      isFalse,
      reason:
          '${resolved.name} is a deprecated alias and should have been '
          'rewritten to ${backwardLinks[resolved.name]}',
    );
  });

  test('raw preserves what the engine reported', () {
    final resolved = LocalTimezone.getTimeZone();
    expect(resolved.raw, isNotEmpty);

    // Guarded with `if` rather than `expect(skip:)`, because skip suppresses
    // the assertion but not the evaluation of its arguments, and
    // getTimeZoneName throws by design when the host has only an offset.
    if (resolved is NamedLocalTimezone) {
      // The engine reports an identifier, so raw and name coincide on web.
      expect(resolved.name, resolved.raw);
    } else {
      expect(
        () => LocalTimezone.getTimeZoneName(),
        throwsA(isA<LocalTimezoneNotNamedException>()),
      );
    }
  });

  test('canonicalizing is idempotent through the public API', () {
    final once = LocalTimezone.getTimeZone();
    final twice = LocalTimezone.getTimeZone();
    expect(once, twice);
  });

  test('an offset result carries the engine offset, not the parsed string', () {
    final resolved = LocalTimezone.getTimeZone();
    if (resolved is! OffsetLocalTimezone) return;

    // V8 misreports the sign for a POSIX TZ such as GMT+5, reporting the
    // identifier +05:00 while applying UTC-05:00. The offset must come from
    // the engine, so it must agree with DateTime rather than with raw.
    expect(resolved.offset, DateTime.now().timeZoneOffset);
    expect(resolved.iso8601, matches(RegExp(r'^[+-]\d{2}:\d{2}$')));
  });

  test('async mirrors sync', () async {
    expect(await LocalTimezone.getTimeZoneAsync(), LocalTimezone.getTimeZone());
  });

  test('Etc/GMT zones are never mistaken for offsets', () {
    // Etc/GMT+5 is a real zone meaning UTC-05:00. It starts with a designator
    // but is not an offset shape, and must round-trip as a name.
    expect(backwardLinks.containsKey('Etc/GMT+5'), isFalse);
    expect(backwardLinks.containsKey('Etc/GMT-5'), isFalse);
  });
}
