import 'backward.g.dart';

/// Returns the current primary IANA name for [identifier], rewriting
/// deprecated identifiers.
///
/// Platforms disagree about which spelling to report for the same zone. Chrome
/// and Node say `Asia/Calcutta` where Firefox and Linux say `Asia/Kolkata`; the
/// same split exists for Kyiv, Ho Chi Minh City, Yangon, Nuuk, Kanton,
/// Kathmandu and Buenos Aires. Apple reports `GMT` where Chrome reports `UTC`.
/// Canonicalizing means one device yields one identifier no matter what it is
/// running.
///
/// Apple sits on neither side of that split. Foundation returns the tail of the
/// `TZDEFAULT` symlink with no alias resolution at all, so an iOS or macOS
/// device reports whichever spelling the OS happened to write, and `Asia/Saigon`
/// and `Europe/Kiev` are both seen in the wild. Apple's own
/// `knownTimeZoneNames` cannot be used to settle it either: ICU's stable-ID
/// policy keeps `Asia/Calcutta` canonical and omits `Asia/Kolkata` entirely.
///
/// It also matters downstream. `package:timezone`'s default dataset,
/// `data/latest.dart`, is generated from the `Zone` entries of tzdb's
/// `rearguard.zi`, so it contains primary names only and rejects every alias.
/// `tz.getLocation('Asia/Calcutta')` throws, which means the obvious
/// `tz.getLocation(LocalTimezone.getTimeZoneName())` fails for every Indian
/// user on Chrome unless the canonical spelling is used.
///
/// Returns [identifier] unchanged when it is already primary, or when the name
/// is not one this package knows about. **Nothing is validated.** An
/// identifier added to the database after this package was published passes
/// straight through rather than being rejected, so a stale table degrades to
/// "no rewrite" instead of "wrong answer".
///
/// ```dart
/// canonicalizeTimezoneId('Asia/Calcutta'); // Asia/Kolkata
/// canonicalizeTimezoneId('Asia/Kolkata');  // Asia/Kolkata
/// canonicalizeTimezoneId('GMT');           // Etc/GMT
/// canonicalizeTimezoneId('Mars/Olympus');  // Mars/Olympus
/// ```
///
/// ## Every result is a primary zone name
///
/// The table is taken verbatim from tzdb's `backward` and `etcetera` files,
/// which between them hold every `Link` in the database. Because a Link always
/// points at a `Zone`, every value here is a primary name, and the set of
/// possible results is exactly the set `package:timezone` accepts by default.
/// That property is asserted by the tests rather than assumed.
///
/// The zero-offset family follows the same rule with no special casing. `UTC`,
/// `Zulu`, `Universal`, `UCT` and `Etc/UCT` resolve to `Etc/UTC`; `GMT`,
/// `GMT0`, `Greenwich` and `Etc/GMT+0` resolve to `Etc/GMT`. Browsers report
/// `UTC` and Apple reports `GMT`, so both are rewritten, and both would
/// otherwise be rejected downstream.
///
/// ## What is deliberately not rewritten
///
/// `Etc/GMT+5` and friends are left alone. They look like aliases but are real
/// zones with an inverted sign: `Etc/GMT+5` is UTC-05:00, by the database's own
/// design. They are `Zone` entries rather than `Link` entries and so are absent
/// here. Rewriting one would move a user by twice their offset.
String canonicalizeTimezoneId(String identifier) =>
    backwardLinks[identifier] ?? identifier;
