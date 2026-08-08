/// @docImport 'resolved_local_timezone.dart';
/// @docImport 'local_timezone_exception.dart';
library;

import 'package:meta/meta.dart';

/// The longest rendering [describe] will produce before truncating.
///
/// The longest tzdb name is 30 characters and the longest Windows zone key is
/// 31, so anything approaching this is already not a zone name.
const _maxLength = 120;

/// Renders [value] for an exception message or a `toString()`.
///
/// Every string this package reports came from outside it: an environment
/// variable, a system property, a symlink target, a registry key. Those are
/// low-privilege sources rather than hostile ones, but they all end up in
/// [LocalTimezoneException.message], and a message goes to a log.
///
/// A value containing a newline can therefore forge a log entry, and one
/// containing a terminal escape can rewrite what an operator reading that log
/// sees. Neither is a memory-safety problem and neither changes what this
/// package resolves; both are worth removing anyway, because the whole purpose
/// of these strings is to be read by a human diagnosing something.
///
/// So control characters are escaped and the result is bounded. The underlying
/// fields are left exactly as the platform reported them, since
/// [ResolvedLocalTimezone.raw] documents itself as verbatim and callers may be
/// comparing it. This is a rendering concern only.
@internal
String describe(String value) {
  // Truncate by rune rather than by code unit. `substring` counts UTF-16 code
  // units, so cutting at a fixed index can land between the two halves of a
  // surrogate pair and leave an unpaired surrogate, which is not a character
  // and which some encoders downstream will reject outright.
  final runes = value.runes;
  final kept = runes.length > _maxLength ? runes.take(_maxLength) : runes;
  final elided = runes.length > _maxLength;

  final buffer = StringBuffer();
  for (final rune in kept) {
    buffer.write(switch (rune) {
      0x0a => r'\n',
      0x0d => r'\r',
      0x09 => r'\t',
      0x22 => r'\"',
      0x5c => r'\\',
      // C0 controls, DEL and C1 controls. NUL lives here, and so does the
      // ANSI escape that would let a value repaint the terminal of whoever is
      // reading the log.
      < 0x20 ||
      0x7f ||
      >= 0x80 && <= 0x9f => '\\x${rune.toRadixString(16).padLeft(2, '0')}',
      // Bidirectional formatting. Not control characters, so they survive the
      // range above, but they reorder the glyphs around them: a value carrying
      // one can make a log line read as something other than what it says.
      // LRM and RLM, the embeddings and overrides, and the isolates.
      // Unicode's own line and paragraph separators. Not C0 or C1, so they
      // survive the range above, and a log consumer that splits on Unicode
      // line boundaries rather than on `\n` will break a line on them.
      0x2028 ||
      0x2029 ||
      0x200e ||
      0x200f ||
      >= 0x202a && <= 0x202e ||
      >= 0x2066 && <= 0x2069 => '\\u{${rune.toRadixString(16)}}',
      _ => String.fromCharCode(rune),
    });
  }
  if (elided) buffer.write('...');
  return buffer.toString();
}
