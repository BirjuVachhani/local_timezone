// Fixture, not a test. Run as a subprocess so the parent can control `TZ`,
// which is read once at process start.
//
// Prints one pipe-delimited record so the parent can assert on every layer:
//
// * `named|<canonicalized>|<name>|<raw>`
// * `offset|<iso8601>|<raw>|<prefix>`
//
// `getTimeZoneName` would do for the canonical name alone, but it throws on an
// offset result, and both the offset result and the raw-versus-name distinction
// are worth testing.
import 'package:local_timezone/local_timezone.dart';

void main() {
  print(switch (LocalTimezone.getTimeZone()) {
    NamedLocalTimezone(:final canonicalized, :final name, :final raw) =>
      'named|$canonicalized|$name|$raw',
    OffsetLocalTimezone(:final iso8601, :final raw, :final prefix) =>
      'offset|$iso8601|$raw|$prefix',
  });
}
