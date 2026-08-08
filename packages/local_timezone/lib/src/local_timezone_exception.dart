import 'resolved_local_timezone.dart';

/// The base type for every failure this package reports.
///
/// It is sealed, so callers can switch over failures exhaustively in the same
/// way they switch over [ResolvedLocalTimezone]:
///
/// ```dart
/// try {
///   print(LocalTimezone.getTimeZoneName());
/// } on LocalTimezoneException catch (e) {
///   switch (e) {
///     case LocalTimezoneUnavailableException():
///       // Nothing usable came back from the platform.
///     case LocalTimezoneNotNamedException(:final resolved):
///       // A fixed offset came back instead of a zone name.
///       print(resolved.iso8601);
///   }
/// }
/// ```
sealed class LocalTimezoneException implements Exception {
  /// Creates a local timezone exception.
  const LocalTimezoneException();

  /// A human readable description of the failure.
  ///
  /// Intended for logs and bug reports, not for display to end users.
  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The platform could not supply a usable timezone at all.
///
/// This is not a bug in the calling code. It means the device itself has no
/// resolvable zone, which does happen:
///
/// * **Android**, when `persist.sys.timezone` is unset. Android falls back to
///   GMT internally in this situation, which this package deliberately does
///   not do, because a silent UTC is indistinguishable from a correct answer.
/// * **Linux**, when there is no `/etc/localtime` and no `TZ`, which is common
///   in minimal container images.
/// * **Web**, when `Intl` is unavailable or reports `Etc/Unknown`.
/// * **Windows**, when the reported zone key has no IANA mapping.
///
/// Callers that would rather have a fallback than an exception should catch
/// this and choose their own, rather than have one chosen for them.
final class LocalTimezoneUnavailableException extends LocalTimezoneException {
  /// Creates an exception describing why no timezone could be resolved.
  const LocalTimezoneUnavailableException({
    required this.platform,
    required this.reason,
    this.raw,
  });

  /// The platform the lookup ran on, such as `android` or `windows`.
  final String platform;

  /// Why the lookup failed, such as
  /// `persist.sys.timezone is empty`.
  final String reason;

  /// Whatever the platform did report, when it reported something unusable.
  ///
  /// Null when the platform returned nothing at all. Present, for example,
  /// when the web reported the literal string `Etc/Unknown`.
  final String? raw;

  @override
  String get message =>
      'No IANA timezone could be resolved on $platform: $reason'
      '${raw == null ? '' : ' (platform reported "$raw")'}';
}

/// The platform reported a fixed offset where a zone name was requested.
///
/// Only thrown by the name-returning entry points. The offset-tolerant entry
/// points return an [OffsetLocalTimezone] instead of throwing.
///
/// The [resolved] result is attached so recovering does not need a second
/// platform lookup:
///
/// ```dart
/// try {
///   useZone(LocalTimezone.getTimeZoneName());
/// } on LocalTimezoneNotNamedException catch (e) {
///   useOffset(e.resolved.offset);
/// }
/// ```
final class LocalTimezoneNotNamedException extends LocalTimezoneException {
  /// Creates an exception carrying the offset that was resolved instead.
  const LocalTimezoneNotNamedException(this.resolved);

  /// The offset the platform reported.
  final OffsetLocalTimezone resolved;

  @override
  String get message =>
      'The platform reported the fixed offset ${resolved.iso8601} '
      '("${resolved.raw}") rather than an IANA timezone name';
}
