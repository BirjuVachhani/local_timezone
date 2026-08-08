import 'package:meta/meta.dart';

/// The characters IANA permits inside one component of a zone name.
///
/// IANA's own rule is "ASCII letters, `.`, `-` and `_`", and it excludes digits
/// to avoid ambiguity with POSIX proleptic `TZ` strings. Digits are admitted
/// here anyway, because the rule postdates names that use them and those names
/// are still shipped: `Etc/GMT+5`, `EST5EDT`, `Australia/LHI`. `+` is admitted
/// for the same reason.
final _component = RegExp(r'^[A-Za-z0-9_+.-]+$');

/// Every zone tzdb ships begins with a letter, and the `AREA/LOCATION` form
/// makes that structural rather than incidental.
final _startsWithLetter = RegExp(r'^[A-Za-z]');

/// Whether [value] is shaped like an IANA zone name.
///
/// A shape check, not an existence check. It cannot tell you the zone exists,
/// only that reporting it as one would not be absurd. Deliberately so:
/// validating against a bundled list would mean shipping a list, and it would
/// reject names added to tzdb after this package was published.
///
/// Every provider runs the value it is about to return through this. The point
/// is not defence against a hostile platform, which on four of the five sources
/// would already outrank the process. It is that `LocalTimezoneException` is
/// sealed so callers can handle failure exhaustively, and returning a string
/// that is not a name does not remove a failure, it relocates it. The caller
/// gets a `LocationNotFoundException` out of whichever timezone database they
/// passed it to, from a package they never agreed to catch, at a point with
/// less context than here.
///
/// The rules are IANA's, from the "Timezone identifiers" section of
/// `theory.html`, minus the ones that would reject names tzdb itself still
/// ships:
///
/// * No empty component, which also rules out a doubled slash and a leading or
///   trailing one.
/// * Neither `.` nor `..` as a whole component. IANA forbids both. It matters
///   here beyond conformance: the Linux provider takes the tail of a resolved
///   symlink, so admitting `.` inside a component without excluding these would
///   accept `../../etc/shadow` as a zone name.
/// * No component starting with `-`.
/// * The name begins with a letter.
///
/// Two IANA rules are deliberately not enforced. The 14-character component
/// limit is omitted because it only constrains what tzdb may add, not what is
/// valid to receive, and enforcing it could only ever reject something real.
/// The exclusion of digits is omitted for the reason given on [_component].
@internal
bool isPlausibleZoneName(String value) {
  if (value.isEmpty) return false;
  if (!_startsWithLetter.hasMatch(value)) return false;

  for (final component in value.split('/')) {
    if (component.isEmpty) return false;
    if (component == '.' || component == '..') return false;
    if (component.startsWith('-')) return false;
    if (!_component.hasMatch(component)) return false;
  }
  return true;
}
