// Parser tests only. `parseJavaCustomId` is pure, so it runs anywhere, and
// importing the library is safe off-Android because the FFI bindings are lazy
// top-level finals that nothing here touches.
//
// The FFI path itself is exercised on a real emulator, which is the only place
// `persist.sys.timezone` exists.
import 'package:local_timezone/src/platform/android.dart';
import 'package:test/test.dart';

void main() {
  group('parses the java.util.TimeZone custom ID grammar', () {
    const cases = {
      // Every form libcore's regex accepts.
      'GMT+5': Duration(hours: 5),
      'GMT+05': Duration(hours: 5),
      'GMT+0530': Duration(hours: 5, minutes: 30),
      'GMT+05:30': Duration(hours: 5, minutes: 30),
      'GMT+05:30:30': Duration(hours: 5, minutes: 30, seconds: 30),
      'GMT-8': Duration(hours: -8),
      'GMT-08': Duration(hours: -8),
      'GMT-0800': Duration(hours: -8),
      'GMT-08:00': Duration(hours: -8),
      'GMT-05:45': Duration(hours: -5, minutes: -45),
      'GMT+0': Duration.zero,
      'GMT-0': Duration.zero,
      'GMT+23:59': Duration(hours: 23, minutes: 59),
      // The Javadoc's own example.
      'GMT+10': Duration(hours: 10),
      'GMT+0010': Duration(hours: 0, minutes: 10),
    };
    cases.forEach((id, expected) {
      test('$id -> $expected', () {
        expect(parseJavaCustomId(id), expected);
      });
    });
  });

  group('the sign is Java, not POSIX', () {
    // The single most dangerous thing in this file. POSIX reads GMT+5 as five
    // hours *behind* UTC; Java reads it as five hours *ahead*, and this
    // property is the Java one. Getting it backwards puts a caller out by
    // twice their offset. bionic flips the sign for its own C consumers, and
    // a Dart caller reading the property directly must not repeat that flip.
    test('GMT+5 is ahead of UTC, not behind', () {
      expect(parseJavaCustomId('GMT+5'), const Duration(hours: 5));
      expect(parseJavaCustomId('GMT+5')!.isNegative, isFalse);
    });

    test('GMT-5 is behind UTC, not ahead', () {
      expect(parseJavaCustomId('GMT-5'), const Duration(hours: -5));
      expect(parseJavaCustomId('GMT-5')!.isNegative, isTrue);
    });

    test('the two are exact opposites', () {
      expect(parseJavaCustomId('GMT+05:30'), -parseJavaCustomId('GMT-05:30')!);
    });
  });

  group('rejects out-of-range components', () {
    // libcore documents hours 0 to 23 and minutes and seconds 00 to 59.
    for (final id in const [
      'GMT+24',
      'GMT+24:00',
      'GMT+05:60',
      'GMT+05:30:60',
      'GMT+99',
    ]) {
      test(id, () => expect(parseJavaCustomId(id), isNull));
    }
  });

  group('rejects anything that is not a custom ID', () {
    for (final id in const [
      'Asia/Kolkata',
      'Etc/GMT+5', // a real zone, and the sign means the opposite
      'GMT', // plain GMT is a zone name, not an offset
      'UTC',
      'UTC+05:30', // Java requires the literal GMT prefix
      '+05:30', // the web shape, not Android's
      'GMT+', // truncated
      'GMT+5:3', // minutes must be two digits
      'GMT +5', // no space is permitted
      'gmt+5', // case sensitive
      'GMT+05:30:30:30',
      '',
    ]) {
      test(id.isEmpty ? '<empty>' : id, () {
        expect(parseJavaCustomId(id), isNull);
      });
    }
  });

  test('never rewrites Etc/GMT zones into offsets', () {
    // Etc/GMT+5 is UTC-05:00 by IANA design. Treating it as an offset would
    // both invert it and lose the zone.
    expect(parseJavaCustomId('Etc/GMT+5'), isNull);
    expect(parseJavaCustomId('Etc/GMT-5'), isNull);
  });
}
