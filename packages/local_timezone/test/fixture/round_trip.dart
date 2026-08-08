// Fixture, not a test. Run as a subprocess so the parent can control `TZ`,
// which is read once at process start.
//
// Checks the acceptance bar: resolving what this package returns through
// `package:timezone` and rebuilding the moment must land on the same wall
// clock as a plain `DateTime`.
//
// Prints one of:
//
// * `named|<canonicalized>|MATCH`
// * `named|<canonicalized>|MISMATCH <tz wall clock> vs <dart wall clock>`
// * `offset|MATCH`
// * `offset|MISMATCH <ours> vs <dart>`
// * `threw|<type>`
import 'package:local_timezone/local_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

String _wall(DateTime d) =>
    '${d.year}-${d.month}-${d.day} ${d.hour}:${d.minute}:${d.second}';

void main() {
  tzdata.initializeTimeZones();

  // One instant, used for both sides, so the comparison is exact rather than
  // racing the clock.
  final now = DateTime.now();

  final ResolvedLocalTimezone resolved;
  try {
    resolved = LocalTimezone.getTimeZone();
  } on Object catch (e) {
    print('threw|${e.runtimeType}');
    return;
  }

  switch (resolved) {
    case NamedLocalTimezone(:final canonicalized):
      // Deliberately the canonicalized field: that is what getTimeZoneName
      // hands back, so it is the string a caller actually looks up.
      final tz.Location location;
      try {
        location = tz.getLocation(canonicalized);
      } on Object catch (e) {
        print(
          'named|$canonicalized|MISMATCH getLocation threw ${e.runtimeType}',
        );
        return;
      }
      final there = tz.TZDateTime.from(now, location);
      final matches = _wall(there) == _wall(now);
      print(
        'named|$canonicalized|'
        '${matches ? 'MATCH' : 'MISMATCH ${_wall(there)} vs ${_wall(now)}'}',
      );

    case OffsetLocalTimezone(:final offset):
      // An offset cannot be fed to getLocation, so the equivalent bar is that
      // it matches the offset the runtime actually applies.
      final matches = offset == now.timeZoneOffset;
      print(
        'offset|'
        '${matches ? 'MATCH' : 'MISMATCH $offset vs ${now.timeZoneOffset}'}',
      );
  }
}
