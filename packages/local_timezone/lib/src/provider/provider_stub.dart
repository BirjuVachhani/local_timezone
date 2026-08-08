import 'provider_base.dart';

/// Stub provider that throws an error when used,
/// because the platform could not be determined.
Provider get platformProvider => throw UnsupportedError(
  'local_timezone found neither dart:io nor dart:js_interop on this '
  'compile target, so it cannot read the platform timezone.',
);
