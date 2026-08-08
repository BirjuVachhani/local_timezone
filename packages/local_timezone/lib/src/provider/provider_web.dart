import '../platform/web.dart';
import 'provider_base.dart';

/// Selects the platform lookup at compile time.
Provider get platformProvider => const WebProvider();
