// Regenerates lib/src/windows_zones.g.dart from CLDR.
//
//   dart run tool/generate_windows_zones.dart
//
// Windows names its zones with its own registry keys ("India Standard Time"),
// not IANA identifiers, so a mapping is unavoidable. CLDR maintains it.
//
// The mapping is not one-to-one. Of 139 Windows keys, 66 map to different IANA
// zones depending on territory: "Romance Standard Time" is Europe/Paris in
// France but Europe/Madrid in Spain. CLDR marks the fallback with territory
// "001". Emitting only that fallback, which is what most implementations do,
// silently puts every Spanish user in Paris.
//
// So two tables are emitted: the "001" defaults, and the territory-specific
// entries that actually differ from them. The provider consults the second when
// Windows can tell it the user's region.
//
// This is a development tool. It is not shipped in lib/ and adds no dependency.
import 'dart:convert';
import 'dart:io';

const _source =
    'https://raw.githubusercontent.com/unicode-org/cldr-json/main/'
    'cldr-json/cldr-core/supplemental/windowsZones.json';

const _output = 'lib/src/windows_zones.g.dart';

Future<String> _fetch(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GET $url returned ${response.statusCode}');
    }
    return response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

/// Characters that would end, escape or interpolate out of the Dart string
/// literal these values are emitted into.
///
/// The generated file is compiled into the package, so an upstream value
/// containing a quote would not merely corrupt the table: it would inject
/// arbitrary top-level Dart. Both sources are trusted and no current entry
/// comes close to this, which is exactly why it has to be checked rather than
/// assumed.
final _unsafeInLiteral = RegExp(r"['\\$]|[\x00-\x1f\x7f]");

/// Fails loudly rather than emitting something that could inject code.
void _rejectUnsafe(Iterable<String> values, String what) {
  final unsafe = values.where(_unsafeInLiteral.hasMatch).toList();
  if (unsafe.isEmpty) return;
  throw StateError(
    'Refusing to generate: $what contains characters that would break out of '
    'a Dart string literal: ${unsafe.map((v) => v.codeUnits).join(', ')}',
  );
}

Future<void> main() async {
  final json = jsonDecode(await _fetch(_source)) as Map<String, dynamic>;
  final supplemental = json['supplemental'] as Map<String, dynamic>;
  final windowsZones = supplemental['windowsZones'] as Map<String, dynamic>;
  final entries = windowsZones['mapTimezones'] as List<dynamic>;
  final version =
      (supplemental['version'] as Map<String, dynamic>?)?['_cldrVersion']
          as String? ??
      'unknown';

  final defaults = <String, String>{};
  final byTerritory = <String, String>{};

  for (final entry in entries) {
    final zone =
        (entry as Map<String, dynamic>)['mapZone']! as Map<String, dynamic>;
    final key = zone['_other']! as String;
    final territory = zone['_territory']! as String;

    // A territory can list several zones, most specific first. Windows knows
    // only the region, so the leading one is the best available answer.
    final iana = (zone['_type']! as String).split(' ').first;

    if (territory == '001') {
      defaults[key] = iana;
    } else {
      byTerritory['$key|$territory'] = iana;
    }
  }

  // Keep only the territory rows that disagree with the fallback. The rest
  // would be dead weight in every Windows binary.
  byTerritory.removeWhere((composite, iana) {
    final key = composite.split('|').first;
    return defaults[key] == iana;
  });

  final missing = byTerritory.keys
      .map((k) => k.split('|').first)
      .where((k) => !defaults.containsKey(k))
      .toSet();
  if (missing.isNotEmpty) {
    stderr.writeln('Territory rows with no "001" fallback: $missing');
    exitCode = 1;
    return;
  }

  _rejectUnsafe([version], 'the CLDR version');
  _rejectUnsafe(defaults.keys, 'a Windows zone key');
  _rejectUnsafe(defaults.values, 'an IANA zone name');
  _rejectUnsafe(byTerritory.keys, 'a Windows zone key and region');
  _rejectUnsafe(byTerritory.values, 'an IANA zone name');

  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln('//')
    ..writeln('// Regenerate with: dart run tool/generate_windows_zones.dart')
    ..writeln('// Source: $_source')
    ..writeln()
    ..writeln('/// The CLDR release [windowsZones] was generated from.')
    ..writeln("const String windowsZonesCldrVersion = '$version';")
    ..writeln()
    ..writeln('/// Windows zone key to IANA identifier, CLDR\'s territory-')
    ..writeln('/// independent fallback.')
    ..writeln('const Map<String, String> windowsZones = {');
  for (final key in defaults.keys.toList()..sort()) {
    buffer.writeln("  '$key': '${defaults[key]}',");
  }
  buffer
    ..writeln('};')
    ..writeln()
    ..writeln('/// Windows zone key and region to IANA identifier, for the')
    ..writeln('/// combinations that differ from [windowsZones].')
    ..writeln('///')
    ..writeln('/// Keyed `"<zone key>|<region>"`, where the region is what')
    ..writeln('/// `GetUserDefaultGeoName` returns.')
    ..writeln('const Map<String, String> windowsZonesByTerritory = {');
  for (final key in byTerritory.keys.toList()..sort()) {
    buffer.writeln("  '$key': '${byTerritory[key]}',");
  }
  buffer.writeln('};');

  File(_output).writeAsStringSync(buffer.toString());
  stdout.writeln(
    'Wrote $_output: ${defaults.length} defaults, '
    '${byTerritory.length} territory overrides, CLDR $version.',
  );
}
