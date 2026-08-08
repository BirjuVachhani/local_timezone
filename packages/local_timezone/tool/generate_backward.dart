// Regenerates lib/src/backward.g.dart from the IANA time zone database.
//
//   dart run tool/generate_backward.dart
//
// Emits a map from every deprecated or alternative zone identifier to the
// primary name it links to, taken verbatim from the database.
//
// Two source files are read. `backward` holds the renamed and deprecated
// names, which is nearly all of them. `etcetera` holds exactly one more,
// `GMT`, which matters because Apple platforms report it. Together they are
// every Link in tzdb: the eight regional files contain none.
//
// The targets are therefore exactly tzdb's primary zone names, which is the
// same set `package:timezone` exposes in its default `data/latest.dart`, since
// that is generated from the `Zone` entries of `rearguard.zi`.
//
// This is a development tool. It is not shipped in lib/ and adds no dependency
// to the package.
import 'dart:convert';
import 'dart:io';

const _repository = 'https://data.iana.org/time-zones/tzdb';

/// Every tzdb file that declares a `Link`. Verified against the full database:
/// africa, antarctica, asia, australasia, europe, northamerica and
/// southamerica declare none.
const _sourceFiles = ['backward', 'etcetera'];

const _output = 'lib/src/backward.g.dart';

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

/// Parses `Link <target> <alias>` lines, ignoring comments and blanks.
Map<String, String> parseLinks(String source) {
  final links = <String, String>{};
  for (final line in const LineSplitter().convert(source)) {
    if (!line.startsWith('Link')) continue;
    final fields = line.split('#').first.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    links[fields[2]] = fields[1];
  }
  return links;
}

Future<void> main() async {
  final version = (await _fetch('$_repository/version')).trim();

  final links = <String, String>{};
  for (final file in _sourceFiles) {
    links.addAll(parseLinks(await _fetch('$_repository/$file')));
  }

  // An alias pointing at itself would cost a lookup and mean nothing.
  links.removeWhere((alias, target) => alias == target);

  // A target that is itself an alias would need transitive resolution. tzdb
  // does not currently produce those, so fail loudly rather than silently
  // emitting a table that resolves only one hop.
  final chained = links.entries.where((e) => links.containsKey(e.value));
  if (chained.isNotEmpty) {
    stderr.writeln(
      'Chained links found, which this generator does not resolve: '
      '${chained.map((e) => '${e.key} -> ${e.value}').join(', ')}',
    );
    exitCode = 1;
    return;
  }

  final sorted = links.keys.toList()..sort();
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln('//')
    ..writeln('// Regenerate with: dart run tool/generate_backward.dart')
    ..writeln('// Source: $_repository/{${_sourceFiles.join(',')}}')
    ..writeln()
    ..writeln('/// The tzdb release [backwardLinks] was generated from.')
    ..writeln("const String backwardTzdbVersion = '$version';")
    ..writeln()
    ..writeln(
      '/// Deprecated IANA identifiers mapped to current primary names.',
    )
    ..writeln('///')
    ..writeln('/// Taken verbatim from the database, so every target is a')
    ..writeln('/// primary zone name.')
    ..writeln('const Map<String, String> backwardLinks = {');
  for (final alias in sorted) {
    buffer.writeln("  '$alias': '${links[alias]}',");
  }
  buffer.writeln('};');

  File(_output).writeAsStringSync(buffer.toString());
  stdout.writeln('Wrote $_output: ${links.length} links from tzdb $version.');
}
