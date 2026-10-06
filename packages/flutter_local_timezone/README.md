# flutter_local_timezone

Read the device's IANA timezone identifier, such as `Asia/Kolkata`,
**synchronously**, and be told when it changes. Android, iOS, macOS, Windows,
Linux and the web.

```dart
// Reading is synchronous on every platform. No await, no channel.
final zone = LocalTimezone.getTimeZoneName(); // Asia/Kolkata

// And a listener for when the user, or the OS, moves the device.
LocalTimezoneWatcher.addListener((event) {
  if (event case LocalTimezoneChanged(:final timezone)) {
    applyZone(timezone);
  }
});
```

Reading is pure Dart, so it needs no platform channel and can be called from
`build()`. Only change notification needs native code, and it costs nothing
until the first listener is added: no channel is opened, no broadcast receiver
is registered and no lifecycle observer is installed until then, and all three
are released when the last listener goes.

## Which package do I want

| You are writing | Depend on |
| --- | --- |
| A Flutter app | **`flutter_local_timezone`**, this package |
| A Dart CLI, server, script, or non-Flutter web app | [`local_timezone`](https://pub.dev/packages/local_timezone) |

This package re-exports the whole `local_timezone` API, so `LocalTimezone`,
`ResolvedLocalTimezone` and `LocalTimezoneException` all arrive from one import.
A Flutter app never needs to depend on both.

Change notification is the only thing that lives here rather than in the pure
Dart package, because it needs each platform's own notification API, which needs
native code, which needs a plugin. Reading the zone behaves identically from
either package.

## Install

```sh
flutter pub add flutter_local_timezone
```

```dart
import 'package:flutter_local_timezone/flutter_local_timezone.dart';
```

**There is nothing to set up.** No permissions, no manifest entries, no
entitlements, no `Info.plist` keys, no Podfile changes, and no
`registerWith` call. On Apple platforms both CocoaPods and Swift Package Manager
are supported, and the bundled `PrivacyInfo.xcprivacy` declares no tracking, no
collected data and no required-reason APIs, so it needs no addition to your own
privacy manifest.

## Reading the zone

The whole reading API comes from `local_timezone` and is documented in
[its README](https://pub.dev/packages/local_timezone), which covers the
per-platform lookups, the alias canonicalization and the version floors. The
short version:

```dart
// The common case.
final zone = LocalTimezone.getTimeZoneName(); // Asia/Kolkata

// A device can report a fixed UTC offset instead of a zone. The result is
// sealed, so both cases are handled without an exception.
switch (LocalTimezone.getTimeZone()) {
  case NamedLocalTimezone(:final canonicalized): useZone(canonicalized);
  case OffsetLocalTimezone(:final offset):       useOffset(offset);
}
```

Failures are exceptions, never a silent fallback to UTC, and
`LocalTimezoneException` is sealed so they can be handled exhaustively.

## Watching for changes

Register once, when the app starts, and keep the listener for the life of the
process:

```dart
void main() {
  LocalTimezoneWatcher.addListener((event) {
    switch (event) {
      case LocalTimezoneChanged(:final timezone):
        applyZone(timezone);
      case LocalTimezoneUnavailable(:final exception):
        log(exception.message);
    }
  });
  runApp(const MyApp());
}
```

`addListener` may be called before `runApp`. It initializes the binding itself
if nothing else has.

Starting the watcher does not call the listener. The first resolve establishes
the baseline to compare against, and reporting the zone the device was already
in as a change would be a lie. Ask `LocalTimezone.getTimeZone()` for the current
value instead, which is synchronous.

`removeListener` removes one registration, so a listener added twice needs
removing twice. When the last listener goes, every platform resource the watcher
took is released.

### Rebuilding a widget on it

`LocalTimezoneWatcher.listenable` is the same information as a
`ValueListenable`, for the case where a widget should rebuild rather than a
callback fire:

```dart
ListenableBuilder(
  listenable: LocalTimezoneWatcher.listenable,
  builder: (context, _) => Text('${LocalTimezoneWatcher.listenable.value}'),
)
```

Attaching to it starts the watcher exactly as `addListener` does, and detaching
the last listener stops it, so a widget tree that only uses this never touches
`addListener` at all.

It is deliberately not a `ValueNotifier` handed out to callers: you can listen
and read, but you cannot set the device's timezone by assigning to it. `null`
means either that no timezone could be resolved or that nothing is watching yet,
which are told apart by whether anything is listening. A `ListenableBuilder`
never sees the idle `null`, because `initState` subscribes before the first
`build`.

### What counts as a change

The resolved value differing from the last one. Nothing else.

That matters because **every platform signals spuriously**, and each of those is
absorbed before a listener hears about it. Android bumps its property serial on
a same-value write, Windows rewrites its registry key at every DST transition,
and one `timedatectl set-timezone` produces two filesystem events on Linux. A
spurious signal costs one lookup of a few hundred nanoseconds and produces no
event.

**A daylight saving transition is not a change.** It alters the offset in effect
but no field of a `NamedLocalTimezone`, so the comparison finds nothing
different. Code that cares about the offset rather than the zone should watch
the clock, not this.

A `LocalTimezoneUnavailable` event means a re-resolve that used to succeed now
throws, which a device can genuinely reach: `/etc/localtime` removed rather than
replaced on Linux, `persist.sys.timezone` cleared on Android, or a Windows zone
key with no entry in the bundled CLDR table. It is sent only on the transition
into that state, for the same reason two identical zones in a row produce
nothing.

### How a change is detected

Two legs feed one funnel, and the native side is a doorbell rather than a data
source. It reports that something moved and carries no value; the Dart side
re-reads the zone with `LocalTimezone.getTimeZone` and compares. So there is one
well-tested implementation turning a platform value into an answer, not five.

The **native leg** is the platform's own change notification:

| Platform | Native trigger | Hook |
| --- | --- | --- |
| Android | `ACTION_TIMEZONE_CHANGED` | a `BroadcastReceiver`, registered on subscribe |
| iOS, macOS | `NSSystemTimeZoneDidChangeNotification` | a `NotificationCenter` observer |
| Windows | `WM_TIMECHANGE` | a top-level window proc delegate |
| Linux | `/etc/localtime` being replaced | a `GFileMonitor` on `/etc` |
| Web | none exists | none |

The **lifecycle leg** re-checks whenever the app returns to the foreground, on
every platform. It is the backstop for a zone that changed while the process was
backgrounded, frozen or killed, which no native trigger can report because
nothing was running to report it to.

On the web the lifecycle leg is the only one, because browsers expose no
timezone change event at all. That detects the common case, where the user
changes the zone and then comes back to the tab, and misses a change that
happens while the tab is in continuous use.

Linux watches the directory rather than the file on purpose:
`timedatectl set-timezone` does not edit `/etc/localtime`, it creates a
temporary symlink and renames it over the target, so a monitor on the file
itself would never fire.

## Using it with `package:timezone`

`getTimeZoneName()` returns the zone's current primary IANA spelling, which is
what `package:timezone` accepts. Passing the platform's own spelling instead
would throw for every Indian user on Chrome, since `data/latest.dart` rejects
`Asia/Calcutta`:

```dart
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  tzdata.initializeTimeZones();

  void apply(String zone) => tz.setLocalLocation(tz.getLocation(zone));

  apply(LocalTimezone.getTimeZoneName());

  LocalTimezoneWatcher.addListener((event) {
    if (event case LocalTimezoneChanged(
      timezone: NamedLocalTimezone(:final canonicalized),
    )) {
      apply(canonicalized);
    }
  });

  runApp(const MyApp());
}
```

Verified against `timezone` 0.11.1. See the
[`local_timezone` README](https://pub.dev/packages/local_timezone) for why this
composes without a lookup that can throw.

## Platform support

| Platform | Reading | Native change signal | Minimum version |
| --- | --- | --- | --- |
| Android | yes | yes | API 24, Flutter's own floor |
| iOS | yes | yes | iOS 13.0, Flutter's own floor |
| macOS | yes | yes | macOS 10.15, Flutter's own floor |
| Windows | yes | yes | Windows 10, Flutter's own floor |
| Linux | yes | yes | GTK, GLib and GIO, already linked by `flutter_linux` |
| Web | yes | no, lifecycle only | see the `local_timezone` README |

Every version floor here is Flutter's, not this package's. `local_timezone`
itself reaches considerably further back, which matters for a Dart CLI or server
and never for a Flutter app.

**pub.dev's platform chips omit Web, and the table above is the accurate one.**
Those chips are derived from the plugin's declared platforms, which list only the
five with native code, because a plugin platform entry exists to name a class the
tooling should register and there is nothing to register for the web. Reading the
zone is pure Dart and works there, and the lifecycle leg gives it change
detection whenever the tab returns to the foreground.

Two situations resolve but cannot listen. A **background isolate** has no
platform channel unless `BackgroundIsolateBinaryMessenger.ensureInitialized` has
been called, and plugin registration is per-isolate. A **Flutter web worker**
has no `document` to observe. Both can still call `LocalTimezone.getTimeZone()`.

## Testing

For a fixed zone, use `local_timezone`'s own mock, which this package
re-exports:

```dart
LocalTimezone.setMockValue(
  const NamedLocalTimezone(
    name: 'Asia/Kolkata',
    canonicalized: 'Asia/Kolkata',
    raw: 'Asia/Kolkata',
  ),
);
addTearDown(LocalTimezone.clearMock);
```

The watcher adds two testing hooks of its own:

* `LocalTimezoneWatcher.debugReset()` releases every resource and forgets the
  last known zone, which a `tearDown` wants because the watcher is static.
* `LocalTimezoneWatcher.debugResolveOverride` replaces the lookup with any
  function, including one that throws. `setMockValue` cannot express a failure,
  so the `LocalTimezoneUnavailable` path is unreachable without it.

To drive the native leg in a widget test, mock the event channel and pin the
target platform. `LocalTimezoneWatcher` only subscribes on the platforms that
have an implementation, so a test left on the default platform exercises the
lifecycle leg alone. See
[`test/local_timezone_watcher_test.dart`](https://github.com/BirjuVachhani/local_timezone/blob/main/packages/flutter_local_timezone/test/local_timezone_watcher_test.dart).

## Example

[`example/`](example/) is a small app that shows the current zone, all three
identifier layers, and a live log of change events. Change the timezone in the
device's settings while it runs to see the listener fire.

## Additional information

Issues and pull requests are welcome at
[github.com/BirjuVachhani/local_timezone](https://github.com/BirjuVachhani/local_timezone/issues).

Licensed under [BSD 3-Clause](LICENSE).
