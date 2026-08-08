import 'dart:js_interop';

import '../local_timezone_exception.dart';
import '../provider/provider_base.dart';
import '../resolved_local_timezone.dart';

/// Matches the offset forms an engine can report, with or without a
/// designator: `+05:30` and `-08:00` from V8, `GMT+05:00` from
/// JavaScriptCore.
final _offsetShape = RegExp(r'^(GMT|UTC)?[+-]');

/// ICU's sentinel for "the host has no resolvable zone". Not an identifier.
const _unknown = 'Etc/Unknown';

/// A [Provider] that reads the local timezone from the JavaScript `Intl` API.
///
/// Web timezone lookup, for both `dart2js` and `dart2wasm`.
///
/// Reads `Intl.DateTimeFormat().resolvedOptions().timeZone`, which is
/// synchronous on both web compilers. The same call underlies plugin-based
/// packages; the `Future` they return comes from the platform channel wrapping
/// it, not from the lookup itself.
///
/// Needs only `dart:js_interop`. `package:web` covers DOM APIs and `Intl` is
/// not one, so nothing here touches the DOM and this works in a worker.
class WebProvider extends Provider {
  const WebProvider._();

  /// Constructs a [WebProvider].
  const factory WebProvider() = WebProvider._;

  /// The device's timezone, from `Intl.DateTimeFormat()`.
  ///
  /// Returns a [NamedLocalTimezone] for an identifier, or an
  /// [OffsetLocalTimezone] when the host has only a fixed offset configured.
  ///
  /// Throws [LocalTimezoneUnavailableException] when `Intl` is unavailable,
  /// reports nothing, or reports the `Etc/Unknown` sentinel.
  @override
  ResolvedLocalTimezone resolve() {
    final String? reported;
    try {
      reported = _DateTimeFormat().resolvedOptions().timeZone;
    } catch (_) {
      // This must stay a bare catch. Under dart2wasm every JavaScript
      // exception arrives boxed as a JSValue, which implements neither Error
      // nor Exception, so `on Error` would not fire and the throw would
      // escape. Even on dart2js a JS-thrown `new Error(...)` surfaces as a
      // JSObject rather than a Dart Error. Bare catch is the only form that
      // works on both.
      _unavailable('Intl.DateTimeFormat() threw');
    }

    // undefined and null both arrive as Dart null, but an empty string does
    // not, so it needs its own check.
    if (reported == null || reported.isEmpty) {
      _unavailable(
        reported == null
            ? 'Intl reported no timezone'
            : 'Intl reported an empty timezone',
      );
    }

    if (reported == _unknown) {
      _unavailable('Intl reported the $_unknown sentinel');
    }

    final offset = _offsetShape.firstMatch(reported);
    if (offset != null) {
      // Deliberately not parsed. V8 misreports the sign when the host `TZ`
      // holds a POSIX string: `TZ=GMT+5` yields the identifier `+05:00` while
      // correctly applying UTC-05:00. `DateTime.now().timeZoneOffset` is the
      // offset the engine actually applies, so it is the honest source.
      return OffsetLocalTimezone(
        offset: DateTime.now().timeZoneOffset,
        raw: reported,
        prefix: offset.group(1),
      );
    }

    return NamedLocalTimezone(
      name: reported,
      canonicalized: canonicalizeName(reported),
      raw: reported,
    );
  }

  Never _unavailable(String reason) =>
      throw LocalTimezoneUnavailableException(platform: 'web', reason: reason);
}

// ---------------------------------------------------------------- bindings

@JS('Intl.DateTimeFormat')
extension type _DateTimeFormat._(JSObject _) implements JSObject {
  external _DateTimeFormat();
  external _ResolvedOptions resolvedOptions();
}

extension type _ResolvedOptions._(JSObject _) implements JSObject {
  /// Nullable on purpose: an engine that cannot resolve the host zone returns
  /// `undefined` here, which arrives as Dart null. Declaring it non-nullable
  /// would instead throw a different exception type on each web compiler.
  external String? get timeZone;
}
