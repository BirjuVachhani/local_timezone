# local_timezone

Read the device's IANA timezone identifier, such as `Asia/Kolkata`,
**synchronously**, in pure Dart, on Android, iOS, macOS, Windows, Linux and the
web.

```dart
final zone = LocalTimezone.getTimeZoneName(); // Asia/Kolkata
```

No plugin, no platform channel, no native code, and nothing to bundle. Because
the lookup is synchronous on every platform, it can be called from `build()`
without an `await`.

This repository is a [pub workspace](https://dart.dev/tools/pub/workspaces)
holding two packages.

| Package | Version | Description |
| --- | --- | --- |
| [`local_timezone`](packages/local_timezone/) | 0.1.0 | The implementation. Pure Dart, no Flutter dependency, usable from a CLI or server. |
| [`flutter_local_timezone`](packages/flutter_local_timezone/) | 0.1.0 | The Flutter-facing package. Re-exports the whole `local_timezone` API and adds `LocalTimezoneWatcher`, which notifies when the device's timezone changes. Also hosts the on-device tests. |

**Flutter apps should depend on `flutter_local_timezone`.** Change notification
needs each platform's own notification API, which needs native code, which needs
a plugin, so it lives there rather than in the pure Dart package. Reading the
zone works identically from either.

> **Neither package is on pub.dev yet.** Until the first release, depend on them
> by git:
>
> ```yaml
> dependencies:
>   local_timezone:
>     git:
>       url: https://github.com/BirjuVachhani/local_timezone.git
>       path: packages/local_timezone
> ```

## Why

`DateTime.now().timeZoneName` returns an abbreviation, not an identifier. It
gives you `IST`, which is India, Ireland, and Israel, and it gives you different
*kinds* of value depending on where you run it:

| | Native | Web |
| --- | --- | --- |
| `DateTime.now().timeZoneName` | `IST` | `India Standard Time` |
| `LocalTimezone.getTimeZoneName()` | `Asia/Kolkata` | `Asia/Kolkata` |

Existing packages solve this with a platform channel, which forces the answer to
be asynchronous even though every underlying OS call is synchronous.

## How it works

| Platform | Source |
| --- | --- |
| Android | `__system_property_get("persist.sys.timezone")` via `dart:ffi` |
| iOS, macOS | `[[NSTimeZone localTimeZone] name]` via the Objective-C runtime |
| Linux | `TZ`, then the `/etc/localtime` symlink, then `/etc/timezone` |
| Windows | `GetDynamicTimeZoneInformation`, mapped through CLDR |
| Web | `Intl.DateTimeFormat().resolvedOptions().timeZone` |

Every result is then rewritten to its current primary IANA name, so a device
reports the same identifier whatever it is running. Chrome says `Asia/Calcutta`
where Firefox says `Asia/Kolkata`, and `package:timezone`'s default dataset
rejects the former.

Failures are exceptions, never a silent fallback to UTC, and the exception type
is sealed so they can be handled exhaustively.

[**Read the package README**](packages/local_timezone/README.md) for the
per-platform behaviour, the canonicalization table, the version floors, and the
notes on `package:timezone` compatibility.

## Layout

```
packages/
  local_timezone/           the pure Dart package
    lib/src/platform/       one provider per platform
    lib/src/*.g.dart        generated tzdb and CLDR tables
    test/                   unit tests, one file per provider
    tool/                   the generators for those tables
    example/
  flutter_local_timezone/   the Flutter-facing package and change listener
    lib/src/                the listener funnel and its platform signal
    android/                the BroadcastReceiver that feeds it
    test/                   host tests for the funnel
    integration_test/       the Android and iOS device tests
    test_host/              the app those tests are installed into
docs/                       design and platform research
research/                   background notes written while building this
.github/workflows/ci.yml
```

## Development

The workspace contains a Flutter package, and `dart pub get` refuses to resolve
a workspace that does. Use Flutter's version at the root, which resolves every
member including the pure Dart ones:

```sh
flutter pub get
```

Format and analyze the whole workspace:

```sh
dart format .
flutter analyze
```

### Tests

Unit tests, from `packages/local_timezone`:

```sh
dart test
```

The web providers, on both compilers and both runtimes:

```sh
dart test -p chrome -c dart2js -c dart2wasm
dart test -p node
```

Device tests, from `packages/flutter_local_timezone/test_host`. They live one
directory up, in `integration_test/`, because the host app does not own them:

```sh
flutter test ../integration_test -d <device>
```

Android is the only place `android.dart` runs at all (it reads a bionic symbol,
so no desktop host reaches a line of it), and the iOS job exists to prove
`DynamicLibrary.process()` resolves Foundation from inside an app bundle. See
[`test_host/README.md`](packages/flutter_local_timezone/test_host/README.md).

### Regenerating the tables

Two files under `lib/src/` are generated and should never be hand-edited. Both
fetch at generation time only, so the package itself has no network dependency.

```sh
cd packages/local_timezone
dart run tool/generate_backward.dart       # IANA aliases -> backward.g.dart
dart run tool/generate_windows_zones.dart  # CLDR mapping -> windows_zones.g.dart
```

Rerun the first after a new tzdb release.

## Continuous integration

[`ci.yml`](.github/workflows/ci.yml) runs on every push and pull request, plus
weekly. `pubspec.lock` is deliberately not committed, so the scheduled run is
what catches a dependency release that breaks the suite with nobody having
pushed anything.

| Job | What it covers |
| --- | --- |
| `analyze` | `dart format` and `flutter analyze` across the workspace |
| `test` | Linux, macOS and Windows, x64 and arm64, crossed with three system timezones |
| `web` | Chrome on `dart2js` and `dart2wasm`, plus Node, across the same three zones |
| `android` | A real emulator, with `persist.sys.timezone` written per zone |
| `ios` | A booted simulator |
| `min-sdk` | The exact SDK floor the pubspec promises, rather than whatever `stable` is |

The timezone axis is the point of the matrix rather than a bonus. GitHub runners
are all UTC, and under UTC the Windows and Linux providers barely do any work: a
provider that always answered "UTC" would pass.

## Contributing

Issues and pull requests are welcome at
[github.com/BirjuVachhani/local_timezone](https://github.com/BirjuVachhani/local_timezone/issues).

Please keep `dart format` clean and `flutter analyze` quiet, and add a test
alongside any provider change. The providers are written as pure functions over
their inputs precisely so they can be tested off the platform they target.

## License

[BSD 3-Clause](LICENSE). Copyright (c) 2026, Birju Vachhani.
