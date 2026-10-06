# flutter_local_timezone example

An app that shows the device's timezone and logs every change to it.

[`lib/main.dart`](lib/main.dart) covers, in one screen:

* reading the zone during `build`, with no `await`, no `FutureBuilder` and no
  loading state, because the lookup is synchronous on every platform;
* all three identifier layers, `raw`, `name` and `canonicalized`, and why they
  differ;
* the fixed-offset case and the failure cases, each handled through an
  exhaustive switch over a sealed type;
* `LocalTimezoneWatcher.addListener` and its matching `removeListener` in
  `dispose`;
* `LocalTimezoneWatcher.listenable`, for a widget that should rebuild rather
  than a callback that should fire.

## Running it

Run it from a clone of
[the repository](https://github.com/BirjuVachhani/local_timezone), not from the
copy inside the published archive. This project resolves through the
repository's pub workspace, which is what puts the package next door on its
package config rather than a version from pub.dev.

Platform folders are not committed either, so generate them first:

```sh
git clone https://github.com/BirjuVachhani/local_timezone.git
cd local_timezone/packages/flutter_local_timezone/example
flutter create .
flutter run
```

`flutter create` in an existing project only adds the missing scaffolding. It
leaves `lib/`, `pubspec.yaml` and this file alone.

## Seeing the listener fire

Change the timezone in the device's own settings while the app is running. The
app cannot do it for you: no platform lets an app set the system zone, which is
also why the device tests drive it from the host over `adb` and `simctl`.

| Platform | Where |
| --- | --- |
| Android | Settings, System, Date & time. Or `adb shell su 0 setprop persist.sys.timezone Australia/Sydney` on an emulator. |
| iOS | Settings, General, Date & Time. Or `xcrun simctl` on a simulator. |
| macOS | System Settings, General, Date & Time. Or `sudo systemsetup -settimezone Australia/Sydney`. |
| Windows | Settings, Time & language. Or `tzutil /s "AUS Eastern Standard Time"`. |
| Linux | `sudo timedatectl set-timezone Australia/Sydney`. |
| Web | No browser exposes a timezone change event, so a change is picked up when the tab is brought back to the foreground. |

Backgrounding the app and returning to it re-checks on every platform, which is
the backstop for a zone that changed while the process was frozen or killed.
Both routes end at the same funnel, so either one produces the event.
