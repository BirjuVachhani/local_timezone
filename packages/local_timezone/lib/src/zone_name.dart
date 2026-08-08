import 'package:meta/meta.dart';

/// A plausible IANA zone name: letters, digits, and the punctuation tzdb
/// actually uses, in slash-separated components.
///
/// Verified against every name tzdb ships, so it rejects nothing real. See the
/// test that walks `backwardLinks` in both directions.
final _zoneName = RegExp(r'^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$');

/// Whether [value] is shaped like an IANA zone name.
///
/// This is a shape check, not an existence check. It cannot tell you the zone
/// exists, only that reporting it as one would not be absurd. Deliberately so:
/// validating against a bundled list would mean shipping a list, and it would
/// reject names added to tzdb after this package was published.
///
/// Every provider that reads a name from an untrusted-ish source runs it
/// through this before returning it. A symlink target, a system property and a
/// C string from Foundation are all strings that arrived from outside the
/// package, and a lookup that cannot produce a zone name should say so rather
/// than pass the bytes through and let them surface as a timezone somewhere
/// downstream.
@internal
bool isPlausibleZoneName(String value) => _zoneName.hasMatch(value);
