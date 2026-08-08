/// Synchronous access to the device's IANA timezone identifier, in pure Dart,
/// on Android, iOS, macOS, Windows, Linux and the web.
///
/// ```dart
/// import 'package:local_timezone/local_timezone.dart';
///
/// void main() {
///   print(LocalTimezone.getTimeZoneName()); // Asia/Kolkata
/// }
/// ```
///
/// See [LocalTimezone] for the entry points, [ResolvedLocalTimezone] for the
/// shape of a successful lookup, and [LocalTimezoneException] for failures.
///
/// @docImport 'src/local_timezone.dart';
/// @docImport 'src/local_timezone_exception.dart';
/// @docImport 'src/resolved_local_timezone.dart';
library;

export 'src/local_timezone.dart';
export 'src/local_timezone_exception.dart';
export 'src/resolved_local_timezone.dart';
