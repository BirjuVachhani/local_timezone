import 'dart:io';

import '../platform/android.dart';
import '../platform/apple.dart';
import '../platform/linux.dart';
import '../platform/windows.dart';
import 'provider_base.dart';

/// The native platform provider, chosen at runtime.
///
/// Other platforms are tree-shaken away by the `Platform.isX` checks.
Provider get platformProvider {
  if (Platform.isMacOS || Platform.isIOS) return const AppleProvider();

  if (Platform.isAndroid) return const AndroidProvider();

  if (Platform.isWindows) return const WindowsProvider();

  if (Platform.isLinux) return const LinuxProvider();

  throw UnimplementedError(
    'local_timezone does not support ${Platform.operatingSystem}. '
    'Android, iOS, macOS, Linux, Windows and web are supported.',
  );
}
