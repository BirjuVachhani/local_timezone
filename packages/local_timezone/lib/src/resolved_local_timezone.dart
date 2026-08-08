/// @docImport 'local_timezone_exception.dart';
library;

import 'describe.dart';

/// The outcome of a successful local timezone lookup.
///
/// Every platform reports its timezone in one of two shapes, so this type is
/// sealed over exactly those two cases:
///
/// * [NamedLocalTimezone] carries an IANA identifier such as `Asia/Kolkata`.
///   This is what every platform returns when it is configured correctly.
/// * [OffsetLocalTimezone] carries a fixed UTC offset, because the platform
///   reported an offset instead of a zone. Android, Apple and the web can all
///   produce this; it always means the device has no real zone configured.
///
/// Switch over it to handle both:
///
/// ```dart
/// switch (LocalTimezone.getTimeZone()) {
///   case NamedLocalTimezone(:final canonicalized):
///     print('zone: \$canonicalized');
///   case OffsetLocalTimezone(:final offset):
///     print('fixed offset: \$offset');
/// }
/// ```
///
/// A failed lookup is not represented here. It throws a
/// [LocalTimezoneException] instead.
sealed class ResolvedLocalTimezone {
  /// Creates a resolved timezone that the platform reported as [raw].
  const ResolvedLocalTimezone({required this.raw});

  const factory ResolvedLocalTimezone.named({
    required String name,
    required String canonicalized,
    required String raw,
  }) = NamedLocalTimezone;

  const factory ResolvedLocalTimezone.offset({
    required Duration offset,
    required String raw,
  }) = OffsetLocalTimezone;

  /// Exactly what the platform reported, before any parsing or rewriting.
  ///
  /// Useful for diagnostics and bug reports, because the value a platform
  /// hands back is not always the value this package returns. Examples of
  /// what shows up here in practice:
  ///
  /// | Platform | `raw` |
  /// | --- | --- |
  /// | Chrome, Edge, Node | `Asia/Calcutta` (a deprecated IANA alias) |
  /// | Firefox, Linux | `Asia/Kolkata` |
  /// | Apple | either one, whichever the OS wrote |
  /// | Windows | `India Standard Time` (a Windows zone key) |
  /// | Android, misconfigured | `GMT+05:30` |
  ///
  /// Prefer [NamedLocalTimezone.canonicalized] for anything user facing or
  /// anything passed to a timezone database. [NamedLocalTimezone.name] sits
  /// between the two: the platform's own answer, parsed but not corrected.
  final String raw;
}

/// A local timezone the platform identified by IANA name.
///
/// This is the common case on every supported platform.
final class NamedLocalTimezone extends ResolvedLocalTimezone {
  /// Creates a named local timezone.
  const NamedLocalTimezone({
    required this.name,
    required this.canonicalized,
    required super.raw,
  });

  /// The IANA identifier the platform named, exactly as it spells it.
  ///
  /// This is the platform's own answer, parsed into an identifier but not
  /// corrected. It is the same string as [raw] on Apple, Android and the web,
  /// where the platform already reports an identifier. It differs on the two
  /// platforms that do not:
  ///
  /// | Platform | `raw` | `name` |
  /// | --- | --- | --- |
  /// | Windows | `India Standard Time` | `Asia/Calcutta` |
  /// | Linux | `/usr/share/zoneinfo/Asia/Calcutta` | `Asia/Calcutta` |
  ///
  /// Reach for this when you want what the system said. Reach for
  /// [canonicalized] for anything you intend to look up.
  final String name;

  /// [name] rewritten to the zone's current primary IANA identifier.
  ///
  /// Platforms disagree about which spelling to report for one zone: Chrome
  /// says `Asia/Calcutta` where Firefox says `Asia/Kolkata`, CLDR keeps the
  /// deprecated spelling canonical on Windows, and Apple returns whatever the
  /// OS happened to write. Canonicalizing means one device yields one
  /// identifier whatever it is running.
  ///
  /// It also matters downstream: timezone databases do not reliably accept the
  /// deprecated spellings, so this is the field to pass to one.
  ///
  /// Equal to [name] when the platform already reported the primary name,
  /// which is the common case.
  final String canonicalized;

  @override
  String toString() =>
      'NamedLocalTimezone(${describe(canonicalized)}'
      '${name == canonicalized ? '' : ', name: ${describe(name)}'}'
      '${raw == name ? '' : ', raw: ${describe(raw)}'})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NamedLocalTimezone &&
          other.name == name &&
          other.canonicalized == canonicalized &&
          other.raw == raw;

  @override
  int get hashCode => Object.hash(name, canonicalized, raw);
}

/// A local timezone the platform described only as a fixed offset from UTC.
///
/// This means the device has no IANA zone configured, so there are no daylight
/// saving rules to apply and no historical transitions available. Treat it as
/// a degraded result: correct right now, but not safe for arithmetic across a
/// DST boundary.
///
/// It arises on three platforms:
///
/// * **Android**, when `persist.sys.timezone` holds a Java style value such as
///   `GMT+05:30` instead of an IANA identifier. Android's own documentation
///   notes this happens on some set-top boxes that take the zone from the TV
///   network.
/// * **Apple**, when `TZ` holds a POSIX style string that Foundation cannot
///   resolve to a zone file. Foundation builds a fixed-offset zone and names it
///   `GMT+0530`. A device with a configured zone never reaches this, so in
///   practice it is a CLI and server case rather than an app one.
/// * **Web**, when `Intl.DateTimeFormat().resolvedOptions().timeZone` returns
///   an offset shape such as `+05:00`.
///
/// All three mean the same thing by a `+` sign: ahead of, or east of, UTC.
/// Android follows the `java.util.TimeZone` custom-ID contract, the web follows
/// ECMA-262's offset time zone identifiers, and Foundation follows ISO. None of
/// them uses the POSIX convention, where the sign is inverted.
///
/// That last point is worth stating plainly, because the platforms sitting
/// underneath do invert it. Given `TZ=GMT+5`, libc resolves UTC-05:00 while
/// Foundation resolves UTC+05:00, and V8 misreports the sign outright: it
/// correctly applies UTC-05:00 while reporting the identifier `+05:00`. Each
/// provider therefore takes [offset] from the source that owns the name it also
/// reports. Reading [offset] is always safe; parsing [raw] yourself is not.
final class OffsetLocalTimezone extends ResolvedLocalTimezone {
  /// Creates an offset-only local timezone.
  const OffsetLocalTimezone({
    required this.offset,
    required super.raw,
    this.prefix,
  });

  /// The offset east of UTC, with the platform's sign convention already
  /// resolved.
  ///
  /// UTC+05:30 is `Duration(hours: 5, minutes: 30)`, and UTC-08:00 is
  /// `Duration(hours: -8)`.
  final Duration offset;

  /// The designator the platform wrote in front of the offset, if any.
  ///
  /// `GMT` for an Android property such as `GMT+05:30` or an Apple zone name
  /// such as `GMT+0530`, and null on the web, which always reports a bare
  /// offset like `+05:00`.
  ///
  /// The web can never produce a prefix. ECMA-262's `UTCOffset` grammar has no
  /// production for one, so `GMT+05:00` is not a valid offset time zone
  /// identifier and passing it to `Intl` throws a `RangeError`. A null here
  /// means the platform wrote no designator, not that the offset is not GMT.
  ///
  /// This is a lexical record of what the platform wrote, kept for diagnostics
  /// and round-tripping. It carries no meaning of its own: GMT and UTC denote
  /// the same zero point for the purpose of expressing a wall-clock offset, so
  /// `GMT+05:30` and `+05:30` describe the same timezone. Use [offset] for
  /// meaning and [iso8601] for display.
  final String? prefix;

  /// [offset] in ISO 8601 form, such as `+05:30` or `-08:00`.
  ///
  /// Always signed, always zero padded to `±HH:MM`.
  ///
  /// Deliberately lossy: the web resolves offsets to minute precision, but
  /// Android's `java.util.TimeZone` custom-ID grammar admits seconds, as in
  /// `GMT+05:30:30`. [offset] keeps the full precision; only this rendering
  /// drops it.
  String get iso8601 {
    final totalMinutes = offset.inMinutes;
    final sign = totalMinutes < 0 ? '-' : '+';
    final absolute = totalMinutes.abs();
    final hours = (absolute ~/ 60).toString().padLeft(2, '0');
    final minutes = (absolute % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }

  @override
  String toString() =>
      'OffsetLocalTimezone(offset: $iso8601'
      '${prefix == null ? '' : ', prefix: ${describe(prefix!)}'}'
      ', raw: ${describe(raw)})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OffsetLocalTimezone &&
          other.offset == offset &&
          other.prefix == prefix &&
          other.raw == raw;

  @override
  int get hashCode => Object.hash(offset, prefix, raw);
}
