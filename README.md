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
| [`local_timezone`](packages/local_timezone/) | [![pub package](https://img.shields.io/pub/v/local_timezone.svg)](https://pub.dev/packages/local_timezone) | The implementation. Pure Dart, no Flutter dependency, usable from a CLI or server. |
| [`flutter_local_timezone`](packages/flutter_local_timezone/) | [![pub package](https://img.shields.io/pub/v/flutter_local_timezone.svg)](https://pub.dev/packages/flutter_local_timezone) | The Flutter-facing package. Re-exports the whole `local_timezone` API and adds `LocalTimezoneWatcher`, which notifies when the device's timezone changes. Also hosts the on-device tests. |

**Flutter apps should depend on `flutter_local_timezone`.** Change notification
needs each platform's own notification API, which needs native code, which needs
a plugin, so it lives there rather than in the pure Dart package. Reading the
zone works identically from either, and there is no reason to depend on both.

```sh
flutter pub add flutter_local_timezone   # Flutter apps
dart pub add local_timezone              # CLI, server, script, non-Flutter web
```

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
    example/                runnable, one function per case
  flutter_local_timezone/   the Flutter-facing package and change listener
    lib/src/                the listener funnel and its platform signal
    android/                the BroadcastReceiver that feeds it
    darwin/                 one Swift observer serving both iOS and macOS
    windows/                a WM_TIMECHANGE window procedure delegate
    linux/                  a GFileMonitor watching /etc
    test/                   host tests for the funnel
    integration_test/       the device tests, run on all five platforms
    test_host/              the app those tests are installed into
    example/                the example app, platform folders not committed
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

Both of those run `dart pub get` first, which refuses this workspace because
`flutter_local_timezone` and the two projects nested under it need the Flutter
SDK. CI works around it by removing that directory and its workspace entries
before installing Dart alone, and locally the same thing works in a scratch copy.

A `pubspec_overrides.yaml` holding `resolution: local` looks like the tidier
answer and is not one: the member stops declaring workspace resolution, so the
root then rejects it as a member that should not be listed.

Host tests for the listener funnel, from `packages/flutter_local_timezone`, plus
the example's smoke test:

```sh
flutter test
cd example && flutter test
```

Device tests, from `packages/flutter_local_timezone/test_host`. The cases live
one directory up, in the package that owns them, and `integration_test/` here
holds a single file that delegates to them:

```sh
flutter test integration_test -d <device>
```

Use that path rather than `../integration_test`. `flutter test` treats a file as
a device test only when its path starts with `<cwd>/integration_test`, and a path
that fails the check does not error: it silently falls back to `flutter_tester`
on the host, ignoring `-d`, building no app, and never loading the platform code
the suite exists to cover.

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

## Releasing

The two packages are versioned independently and published separately, and the
order matters: `flutter_local_timezone` depends on `local_timezone` by version
constraint, and pub rejects an archive whose dependency it cannot resolve from
pub.dev.

1. Bump the version and write the entry in that package's own `CHANGELOG.md`.
   Three other places carry a version: `flutter_local_timezone`'s constraint on
   `local_timezone`, the `s.version` line in
   `darwin/flutter_local_timezone.podspec`, and the table at the top of this
   file.
2. Run `flutter pub get`, `dart format .`, `flutter analyze` and the tests above.
   For an Apple-side change, `pod lib lint darwin/flutter_local_timezone.podspec`
   as well.
3. Publish the pure Dart package first, then the Flutter one:

   ```sh
   cd packages/local_timezone         && flutter pub publish
   cd packages/flutter_local_timezone && flutter pub publish
   ```

`flutter pub publish` rather than `dart pub publish` in both, for the same reason
`flutter pub get` is needed at the root: the workspace contains a Flutter
package, and `dart pub` refuses to resolve one.

What ends up in each archive is governed by that package's `.pubignore`, which
pub uses *instead of* `.gitignore` when it exists, and which never sees the
`.gitignore` files above the package root. Every publish-time exclusion has to be
written there, not just the publish-only extras. `--dry-run` prints the file list
to check it against.

One consequence of publishing from a workspace is worth knowing rather than
fixing: `resolution: workspace` is uploaded verbatim, because pub does not strip
it. Consumers are unaffected, since the resolver reads the hosted metadata rather
than the archived pubspec, and pub.dev analyses such packages normally. Only
someone running `pub get` inside an extracted copy of the archive hits "found no
workspace root", which is why the example says to run it from a clone.

## Contributing

Issues and pull requests are welcome at
[github.com/BirjuVachhani/local_timezone](https://github.com/BirjuVachhani/local_timezone/issues).

Please keep `dart format` clean and `flutter analyze` quiet, and add a test
alongside any provider change. The providers are written as pure functions over
their inputs precisely so they can be tested off the platform they target.

## License

[BSD 3-Clause](LICENSE). Copyright (c) 2026, Birju Vachhani.
