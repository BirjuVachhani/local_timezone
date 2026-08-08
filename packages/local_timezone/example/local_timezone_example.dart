import 'package:local_timezone/local_timezone.dart';

void main() async {
  simplest();
  handlingFixedOffsets();
  handlingFailure();
  seeingWhatThePlatformSaid();
  await asynchronously();
  memoizingWhenItMatters();
}

/// The common case: one call, no await, an IANA identifier.
void simplest() {
  print(LocalTimezone.getTimeZoneName()); // Asia/Kolkata
}

/// A device can report a fixed UTC offset instead of a zone, which happens on
/// misconfigured Android devices and on the web. Switch over the sealed result
/// to handle both without an exception.
void handlingFixedOffsets() {
  switch (LocalTimezone.getTimeZone()) {
    case NamedLocalTimezone(:final name):
      print('zone: $name'); // zone: Asia/Kolkata
    case OffsetLocalTimezone(:final offset, :final iso8601):
      // No daylight saving rules are available in this case, so avoid
      // arithmetic that crosses a DST boundary.
      print('fixed offset: $iso8601 ($offset)'); // fixed offset: +05:30
  }
}

/// Nothing falls back to UTC silently. Failures are exceptions, and the
/// exception type is sealed so they can be handled exhaustively.
void handlingFailure() {
  try {
    print(LocalTimezone.getTimeZoneName());
  } on LocalTimezoneException catch (e) {
    switch (e) {
      case LocalTimezoneUnavailableException(:final platform, :final reason):
        print('no timezone on $platform: $reason');
      case LocalTimezoneNotNamedException(:final resolved):
        // getTimeZoneName() wanted a name but the device only has an offset.
        // The result is attached, so no second lookup is needed.
        print('only an offset available: ${resolved.iso8601}');
    }
  }
}

/// By default, deprecated IANA aliases are rewritten to their current primary
/// names, so the same device reports the same identifier on every platform.
/// Chrome reports `Asia/Calcutta` where Firefox reports `Asia/Kolkata`, and
/// timezone databases do not reliably accept the deprecated spelling.
void seeingWhatThePlatformSaid() {
  final resolved = LocalTimezone.getTimeZone();
  print('raw: ${resolved.raw}'); // raw: Asia/Calcutta   (on Chrome)

  if (resolved case NamedLocalTimezone(:final name, :final canonicalized)) {
    // Three layers, always all present. `raw` is what the system said, `name`
    // is that parsed into an identifier, and `canonicalized` is the current
    // primary spelling.
    print('name:         $name'); // name:         Asia/Calcutta
    print('canonicalized: $canonicalized'); // canonicalized: Asia/Kolkata
  }
}

/// Every platform resolves synchronously, so the async entry points complete
/// immediately. They exist for callers already inside async code.
Future<void> asynchronously() async {
  print(await LocalTimezone.getTimeZoneNameAsync());
}

/// Nothing is cached, so every call reflects the device's current timezone
/// even if the user changes it mid-session. Apple and Android cost a few
/// hundred nanoseconds per call; Linux and the web cost about 40 microseconds.
///
/// When that matters, memoize at the call site, which is also the only place
/// that knows when the value should be discarded.
void memoizingWhenItMatters() {
  final zone = LocalTimezone.getTimeZoneName(); // read the platform once
  for (final event in ['standup', 'review', 'retro']) {
    print('$event is in $zone');
  }
}
