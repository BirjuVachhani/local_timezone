/// @docImport '../local_timezone_exception.dart';
library;

import 'package:meta/meta.dart';

import '../canonicalize.dart';
import '../resolved_local_timezone.dart';

/// A base class for platform-specific timezone lookup. Each platform implementation
/// must implement [resolve] to return the local timezone or throw
/// a [LocalTimezoneUnavailableException] if the platform has no resolvable timezone.
abstract class Provider {
  /// Constructs a [Provider].
  const Provider();

  /// Resolves the local timezone for the current platform.
  ///
  /// An implementation returning a [NamedLocalTimezone] must fill in all three
  /// layers: `raw` exactly as the platform reported it, `name` parsed into an
  /// identifier, and `canonicalized` put through [canonicalizeName]. On most
  /// platforms `raw` and `name` are the same string; on Windows and Linux they
  /// are not, because the platform reports a registry key or a filesystem path
  /// rather than an identifier.
  ///
  /// Throws a [LocalTimezoneUnavailableException] if the platform has no
  /// resolvable timezone.
  ResolvedLocalTimezone resolve();

  /// Rewrites a timezone name to its current primary IANA identifier.
  @protected
  String canonicalizeName(String identifier) =>
      canonicalizeTimezoneId(identifier);
}
