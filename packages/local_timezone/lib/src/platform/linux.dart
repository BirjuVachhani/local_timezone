import 'dart:io';

import 'package:meta/meta.dart';

import '../local_timezone_exception.dart';
import '../provider/provider_base.dart';
import '../resolved_local_timezone.dart';

/// Where the symlink lands, and the marker that separates the database root
/// from the zone name inside it.
///
/// `zoneinfo.default/` is checked first because recent macOS uses it and the
/// plain form is a prefix of it, so testing `zoneinfo/` first would match the
/// wrong boundary. Linux only ever uses the plain form, but the ordering costs
/// nothing and the two providers share these fixtures in tests.
const _zoneinfoMarkers = ['zoneinfo.default/', 'zoneinfo/'];

/// A POSIX rule rather than a zone name: an abbreviation immediately followed
/// by an offset, as in `EST5EDT` or `IST-5:30`.
///
/// Anchored deliberately. `Etc/GMT+5` is a real zone whose name contains a
/// digit after a sign, and must not be caught.
final _posixRule = RegExp(r'^[A-Za-z]{3,}[+-]?\d');

/// A plausible zone name: letters, digits, and the punctuation tzdb actually
/// uses, in slash-separated components.
final _zoneName = RegExp(r'^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$');

/// Subtrees that sit between the database root and the zone name.
///
/// Many distributions ship `zoneinfo/posix/...` and `zoneinfo/right/...`
/// alongside the top-level names, the second built with leap seconds. A symlink
/// into either yields a path whose tail is `posix/Asia/Kolkata`, which is not
/// an identifier anything will accept.
const _zoneinfoSubtrees = ['posix/', 'right/'];

/// A [Provider] that reads the local timezone from the filesystem.
///
/// Resolution is `TZ`, then `/etc/localtime`, then `/etc/timezone`. The first
/// two are what glibc itself consults, in that order. The third is not: it is a
/// Debian convention that no libc reads, and it is checked last only because it
/// is the one remaining place a zone *name* can be recovered from. Nothing here
/// uses FFI; `dart:io` is enough, and all of it is synchronous.
///
/// There is no kernel or libc version floor. The requirement is a distribution
/// that provides one of those three, which every mainstream one does. Minimal
/// container images frequently do not: a stock `ubuntu` image ships no zoneinfo
/// at all and `distroless` ships a dangling symlink, so those need `TZ` set.
class LinuxProvider extends Provider {
  const LinuxProvider._();

  /// Constructs a [LinuxProvider].
  const factory LinuxProvider() = LinuxProvider._;

  /// The device's timezone.
  ///
  /// Usually a [NamedLocalTimezone]. `TZ` can also hold a POSIX rule such as
  /// `EST5EDT,M3.2.0,M11.1.0`, which names no zone at all; that is an
  /// [OffsetLocalTimezone] carrying the offset the runtime applies.
  ///
  /// Throws [LocalTimezoneUnavailableException] when none of the three sources
  /// yields anything, which is the container case.
  @override
  ResolvedLocalTimezone resolve() {
    final tz = Platform.environment['TZ'];
    if (tz != null && tz.isNotEmpty) {
      final name = zoneFromTz(tz);
      if (name != null) return _named(name, tz);

      // TZ is set and authoritative, but describes rules rather than a zone,
      // so there is no identifier to report. The offset is still knowable.
      return OffsetLocalTimezone(
        offset: DateTime.now().timeZoneOffset,
        raw: tz,
      );
    }

    final link = _readLink();
    if (link != null) {
      final name = zoneFromPath(link);
      if (name != null) return _named(name, link);
      _unavailable(
        '/etc/localtime resolves to "$link", which contains no zoneinfo '
        'directory to take a zone name from',
      );
    }

    final file = _readTimezoneFile();
    if (file != null) {
      final name = zoneFromTimezoneFile(file);
      if (name != null) return _named(name, file);
    }

    // Some images copy the zone file rather than linking it, which leaves the
    // process with a perfectly good timezone and no name for it anywhere on
    // disk. Reporting the offset beats claiming there is no timezone at all.
    if (_localtimeIsRegularFile()) {
      return OffsetLocalTimezone(
        offset: DateTime.now().timeZoneOffset,
        raw: '/etc/localtime',
      );
    }

    _unavailable(
      'no TZ, no /etc/localtime symlink and no usable /etc/timezone',
    );
  }

  bool _localtimeIsRegularFile() =>
      FileSystemEntity.typeSync('/etc/localtime', followLinks: false) ==
      FileSystemEntityType.file;

  NamedLocalTimezone _named(String name, String raw) => NamedLocalTimezone(
    name: name,
    canonicalized: canonicalizeName(name),
    raw: raw,
  );

  Never _unavailable(String reason) => throw LocalTimezoneUnavailableException(
    platform: 'linux',
    reason: reason,
  );

  String? _readLink() {
    final file = Link('/etc/localtime');
    try {
      if (!file.existsSync()) return null;
      return file.resolveSymbolicLinksSync();
    } on FileSystemException {
      // A dangling link, a permission failure or a loop. Distroless images ship
      // exactly the first of those.
      return null;
    }
  }

  String? _readTimezoneFile() {
    try {
      final file = File('/etc/timezone');
      return file.existsSync() ? file.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }
}

/// Extracts a zone name from a `TZ` value, or null if it names no zone.
///
/// glibc accepts several spellings, all of which turn up in the wild:
///
/// ```dart
/// zoneFromTz('Asia/Kolkata');                        // Asia/Kolkata
/// zoneFromTz(':Asia/Kolkata');                       // Asia/Kolkata
/// zoneFromTz('/usr/share/zoneinfo/Asia/Kolkata');    // Asia/Kolkata
/// zoneFromTz(':/usr/share/zoneinfo/Asia/Kolkata');   // Asia/Kolkata
/// zoneFromTz('UTC');                                 // UTC
/// zoneFromTz('EST5EDT,M3.2.0,M11.1.0');              // null, a POSIX rule
/// ```
///
/// The leading colon is glibc's "this is a path or a zone name, not a rule"
/// marker. Without it the value is a POSIX rule, except that glibc falls back
/// to treating it as a name when the rule fails to parse, which is why bare
/// `Asia/Kolkata` works everywhere and is accepted here.
@visibleForTesting
String? zoneFromTz(String tz) {
  final value = tz.startsWith(':') ? tz.substring(1) : tz;
  if (value.isEmpty) return null;

  // An absolute or relative path into the database.
  if (value.contains('/')) {
    final fromPath = zoneFromPath(value);
    if (fromPath != null) return fromPath;
    // A leading slash with no zoneinfo component names a file we cannot
    // interpret, so there is no zone name in it.
    if (value.startsWith('/')) return null;
  }

  if (_posixRule.hasMatch(value)) return null;
  return _zoneName.hasMatch(value) ? value : null;
}

/// Where [marker] begins in [path], but only where it starts a whole path
/// component, or -1.
///
/// A plain substring search would match `zoneinfo/` inside `myzoneinfo/` and
/// take the tail of an unrelated directory for a zone name.
int _componentIndex(String path, String marker) {
  if (path.startsWith(marker)) return 0;
  final index = path.indexOf('/$marker');
  return index == -1 ? -1 : index + 1;
}

/// Extracts a zone name from a resolved path such as
/// `/usr/share/zoneinfo/Asia/Kolkata`, or null if there is no database
/// component in it.
///
/// Handles relative link targets, which are mainstream: Rocky and Fedora write
/// `../usr/share/zoneinfo/Asia/Kolkata` rather than an absolute path.
@visibleForTesting
String? zoneFromPath(String path) {
  for (final marker in _zoneinfoMarkers) {
    final index = _componentIndex(path, marker);
    if (index == -1) continue;
    var name = path.substring(index + marker.length);
    // A link into the posix/ or right/ subtree names the same zone, one
    // directory deeper. Returning the tail verbatim would hand back
    // `right/Asia/Kolkata`, which resolves nowhere.
    for (final subtree in _zoneinfoSubtrees) {
      if (name.startsWith(subtree)) {
        name = name.substring(subtree.length);
        break;
      }
    }
    return name.isEmpty ? null : name;
  }
  return null;
}

/// Extracts a zone name from the contents of `/etc/timezone`.
///
/// Debian and derivatives write the name plus a trailing newline. Anything that
/// does not look like a zone name is rejected rather than passed through, since
/// this file has no other legal content.
@visibleForTesting
String? zoneFromTimezoneFile(String contents) {
  final value = contents.trim();
  if (value.isEmpty) return null;
  return _zoneName.hasMatch(value) ? value : null;
}
