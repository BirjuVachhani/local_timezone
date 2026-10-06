# Changelog

Changes to the repository as a whole: the workspace, CI, tooling, and anything
spanning both packages.

Each package keeps its own changelog, which is what pub.dev renders and what
release notes are cut from:

- [`packages/local_timezone/CHANGELOG.md`](packages/local_timezone/CHANGELOG.md)
- [`packages/flutter_local_timezone/CHANGELOG.md`](packages/flutter_local_timezone/CHANGELOG.md)

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
both packages follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Packages are versioned independently, so this file carries no version numbers of
its own.

## Initial release

Everything below ships as `local_timezone` 0.1.0 and `flutter_local_timezone`
0.1.0, the first published version of each.

### Added

- `local_timezone`: synchronous IANA timezone lookup in pure Dart, with a
  provider for each of Android, iOS, macOS, Linux, Windows and the web. No
  plugin, no platform channel, and no native code shipped.
- `local_timezone`: a sealed `ResolvedLocalTimezone` result, so a device
  reporting a fixed UTC offset rather than a zone is a case to handle instead of
  a failure, and a sealed `LocalTimezoneException`, so failures are exhaustive
  and never a silent fallback to UTC.
- `local_timezone`: canonicalization of deprecated IANA aliases to their current
  primary names, generated from tzdb `backward` and `etcetera` (currently 2026c,
  257 entries). This is what makes `tz.getLocation()` work against
  `package:timezone`'s default dataset, which rejects aliases.
- `local_timezone`: a bundled CLDR Windows-to-IANA table with territory
  refinement via `GetUserDefaultGeoName`, so the 66 registry keys that cover more
  than one zone do not relocate people to the `001` fallback.
- `local_timezone`: `setMock` / `setMockValue` / `clearMock` for tests, and
  `getTimeZoneAsync` / `getTimeZoneNameAsync` for callers with an async-shaped
  API to satisfy.
- `local_timezone`: `tool/generate_backward.dart` and
  `tool/generate_windows_zones.dart`, which regenerate the two `.g.dart` tables
  from IANA and CLDR upstream.
- `flutter_local_timezone`: a Flutter-facing package re-exporting the whole
  `local_timezone` API and adding `LocalTimezoneWatcher`, which reports a change
  to the device's timezone from each platform's own notification API, with an
  app-lifecycle re-check as the backstop everywhere and the only leg on the web.
- `flutter_local_timezone`: an example app under `example/`, the device tests
  covering all five native platforms, and the `test_host` app they are installed
  into.
- CI covering Linux, macOS and Windows on x64 and arm64, Chrome on `dart2js` and
  `dart2wasm`, Node, an Android emulator and an iOS simulator, each crossed with
  several system timezones, along with a job pinned to the minimum SDK the
  pubspec promises.
- Repository README, this changelog, and a BSD 3-Clause license carried by the
  repository root and by both packages, since pub archives each one on its own.
