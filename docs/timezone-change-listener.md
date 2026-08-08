# Watching for local timezone changes, per platform

Feasibility research for a listener API (`addListener` / `removeListener`) that
fires when the device's local timezone changes, whether the user changed it in
Settings or the OS changed it automatically after the device crossed a border.

This document is about **how each platform tells us something moved**. The public
API is Phase 1, and the requirements and architecture that come out of this are
Phase 3. Nothing here is a commitment to a design.

## The shape this takes

Three decisions are already made and this document is written around them.

1. **`local_timezone` stays pure Dart** and keeps doing exactly what it does
   today: resolve the current zone, synchronously, with no plugin and nothing to
   bundle. It gains no listener, no isolate and no timer.
2. **`flutter_local_timezone` becomes a real plugin** and owns the listener
   feature end to end. It is allowed native code, platform channels and the
   federated plugin system.
3. **No polling.** Every platform must use a real system trigger, or it does not
   get push detection at all.

That splits cleanly, and the split has a name worth using throughout:

> **The native side is a doorbell, not a data source.**

Each platform's native code does one thing: notice the system trigger and send an
empty event to Dart. It carries no timezone value, does no parsing, knows nothing
about IANA names, CLDR or canonicalization. On receiving the ping, the Dart side
calls `LocalTimezone.getTimeZone()` from the existing pure Dart package and
compares against the last known value.

This is worth being deliberate about, because the obvious alternative is worse.
If the native side reported the new zone, we would have five platforms reporting
five different string formats (a Java ID on Android, a Foundation name on Apple,
a Windows registry key, a symlink path on Linux) and we would need the entire
canonicalization layer again, on the other side of a channel, in five languages.
Sending nothing means the five native implementations stay a few dozen lines
each, and the one well-tested Dart implementation remains the only thing that
turns a platform value into an answer.

| | Native side | Dart side |
| --- | --- | --- |
| Knows about | one system API | zone names, offsets, CLDR, tzdb aliases |
| Sends | an empty event | the resolved change to listeners |
| Size | tens of lines per platform | the existing package, unchanged |
| Tested by | device tests | the existing unit tests |

## Summary

| Platform | Standard system trigger | Flutter hook | Push |
| --- | --- | --- | --- |
| Android | `ACTION_TIMEZONE_CHANGED` broadcast | `BroadcastReceiver`, registered on subscribe | **yes, implemented and verified on device** |
| iOS | `NSSystemTimeZoneDidChangeNotification` | `NotificationCenter` observer | yes |
| macOS | `NSSystemTimeZoneDidChangeNotification` | `NotificationCenter` observer | yes |
| Windows | `WM_TIMECHANGE` / `WM_SETTINGCHANGE` | `RegisterTopLevelWindowProcDelegate` | yes, needs verifying |
| Linux | `/etc/localtime` replacement | `GFileMonitor` on `/etc` | yes |
| Web | none exists | `visibilitychange`, `focus`, `pageshow`, `resume` | no, see the gap below |

Plus one cross-platform layer, which you have already decided is always on:
**app lifecycle**. `AppLifecycleListener` gives a re-check every time the app
returns to the foreground, on every platform including web. On the four native
platforms it is a backstop for anything missed while the process was backgrounded
or frozen. On the web it is the only mechanism there is.

## What we are actually detecting

Worth pinning down, because it decides what the listener can honestly promise.

Three different things get called "the timezone changed":

1. **Zone identity changed.** `Asia/Kolkata` became `Europe/London`. This is the
   travel case and the Settings case, and it is what the listener is for.
2. **Offset changed with no identity change.** A DST transition. The zone name is
   untouched.
3. **The zone database changed underneath a stable identifier.** A country
   redefines its DST rules and the OS ships new tzdata. Rare, and no platform
   below signals it distinctly.

Every trigger in this document is a *hint* that something moved, not a
description of what moved. Several fire when nothing relevant changed at all.

Diffing `ResolvedLocalTimezone` gives case 1 and nothing else, for free, without
a special case anywhere: a DST transition does not alter any field of a
`NamedLocalTimezone`, so an equality check simply does not fire. That falls out
of the existing type rather than being designed in, and it means the default
behaviour is the one most callers want. Case 2 would need the offset to be
compared separately, which is a Phase 1 decision rather than a mechanism problem.

---

## Android

### The trigger

`Intent.ACTION_TIMEZONE_CHANGED`, a protected system broadcast. It is sent by
`AlarmManagerService` alongside the write to `persist.sys.timezone`, so it covers
every path that changes the device zone: the Settings UI, telephony-based
automatic detection, and the Android 12+ location time zone detector.

This is the first-class documented API for exactly this question, and it is the
one thing in the whole feature that pure Dart could not reach, since receiving a
broadcast needs a `BroadcastReceiver` and therefore Java or Kotlin.

### The hook

Register at runtime in `onAttachedToEngine`, unregister in
`onDetachedFromEngine`. Forward each `onReceive` to Dart over an `EventChannel`
with no payload.

Manifest registration is also legal here, which is not true of most implicit
broadcasts. Android 8 (API 26) stopped apps from declaring manifest receivers for
implicit broadcasts, but `ACTION_TIMEZONE_CHANGED` is on the documented exemption
list, explicitly because clock apps need it. It is still the wrong choice for
this plugin: a manifest receiver exists to wake an app that is not running, and a
listener API whose callbacks live in a Dart isolate has nothing to wake. Runtime
registration also keeps the plugin from contributing anything to the host app's
manifest.

### Requirements

| | |
| --- | --- |
| Minimum API | none beyond Flutter's own floor of 24 |
| Permissions | none |
| Manifest entries | none, with runtime registration |
| `registerReceiver` export flag | **not required, and should be omitted** |

That last row is a real trap. Android 13 (API 33) requires
`RECEIVER_EXPORTED` or `RECEIVER_NOT_EXPORTED` on `registerReceiver`, and Android
14 makes it a hard failure. The requirement applies only when the receiver is
*not* registered exclusively for system broadcasts, and our filter contains one
protected system broadcast and nothing else, so no flag is needed. Passing one
anyway is actively harmful: the AndroidX Media team reverted exactly this change
with the note that protected system broadcasts should not specify the export
flag, because marking them `NOT_EXPORTED` breaks sticky broadcasts in some cases.

### Edge cases

* **Backgrounded or frozen process.** A runtime-registered receiver lives only as
  long as the process. A zone change while the app is cached or killed is not
  delivered, which is correct: there are no listeners to call. The lifecycle
  re-check on resume covers it, and covers it better than a manifest receiver
  would, because it produces one event at the moment the app can act on it.
* **Extras are ignored.** The intent may carry the new zone. We do not read it,
  by the doorbell rule.
* **Multiple engines.** Flutter allows several engines per app, each with its own
  plugin instance. Registration and state must live on the instance, not in
  statics.

---

## iOS and macOS

### The trigger

`NSSystemTimeZoneDidChangeNotification`, on the default `NotificationCenter`,
posted on the main queue. Identical on both platforms, so one Swift file can
serve both targets.

iOS has a second, broader notification worth considering:
`UIApplication.significantTimeChangeNotification`, which fires on a zone change,
on a carrier-driven time change, and at midnight. The midnight case makes it
noisier than we need, but the diff absorbs that, and it catches time changes that
the zone notification does not. Whether to observe both is a Phase 3 call.

### The hook

Add an observer in the plugin's `register(with:)`, remove it on detach, and send
an empty event over the `EventChannel`. Delivery is already on the main queue, so
the channel send needs no dispatch hop.

### The Foundation cache, and why this hook is better than the pure Dart one

The `AppleProvider` doc comment already records that Foundation memoizes the
system zone and drops that cache when it receives this notification. That is fine
in a Flutter app, whose main queue is drained, and a documented weakness in a
plain Dart CLI, which runs no CFRunLoop and can keep reporting the zone it first
resolved.

The plugin can close that hole rather than work around it. `+[NSTimeZone
resetSystemTimeZone]` is public API that clears the cached information, and the
native handler runs on the main thread, so it can call it before pinging Dart.
The Dart side then re-resolves through the existing FFI path and reads a fresh
value by construction.

Whether it is *necessary* is unknown: the ordering between Foundation's own cache
invalidation and the delivery of the notification to our observer is not
documented, so our handler may run before or after Foundation drops its cache.
Calling `resetSystemTimeZone` unconditionally makes the ordering irrelevant and
costs one message send per zone change, which is a handful per year. Do it, and
note in Phase 3 that the reason is defensive rather than proven.

### Requirements

| | |
| --- | --- |
| Minimum OS | none beyond Flutter's own floors |
| Entitlements | none |
| `Info.plist` keys | none |
| App Sandbox (macOS) | unaffected; the default center is in-process |
| Private API | none; both the notification and `resetSystemTimeZone` are public |

### Edge cases

* **Suspension on iOS.** Notifications posted while the app is suspended are
  coalesced, so a resumed app gets one delivery rather than a backlog. One is all
  we need, and the lifecycle re-check would have caught it regardless.
* **In-process default changes.** The notification covers the *system* zone. An
  app that reassigns its own `NSTimeZone.default` does not trigger it, which is
  correct for us since `+localTimeZone` deliberately tracks the system zone.

---

## Windows

### The trigger, and the honest uncertainty

This is the least settled platform in the document.

`WM_TIMECHANGE` is broadcast by the system to all top-level windows, and since
Windows 2000 the system sends it rather than requiring the app that caused the
change to do so. The documentation describes it as covering "a change in the
system time", and it is what `SystemEvents.TimeChanged` wraps in .NET.

`WM_SETTINGCHANGE` is what Microsoft's own `SetTimeZoneInformation` guidance
points at: "To inform Explorer that the time zone has changed, send the
`WM_SETTINGCHANGE` message." That phrasing puts the burden on the *caller* of the
API, which means it is sent by whoever changed the zone rather than by the
system, and the Settings app is presumably that caller.

**Neither is documented as "the system broadcasts this when the time zone
changes."** Community reports claim `WM_TIMECHANGE` covers zone changes as well
as clock changes, but the one detailed account also found the message hard to
observe and hard to test. Handling both messages and diffing is the pragmatic
answer, but it is a guess until someone changes the zone on a real Windows
machine and watches what arrives.

If it turns out neither message fires for a Settings-driven zone change, the
fallback is `RegNotifyChangeKeyValue` on
`HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation`, which is documented,
unambiguous, and easy in native code because the plugin can own a real thread
rather than a Dart isolate. Details of that API are in the appendix, since it was
researched for the pure Dart design.

### The hook

`flutter::PluginRegistrarWindows::RegisterTopLevelWindowProcDelegate` gives a
plugin a delegate over the runner's top-level window procedure. The delegate
receives `(HWND, UINT message, WPARAM, LPARAM)` and returns
`std::optional<LRESULT>`.

Two details matter:

1. **Return `std::nullopt` for everything.** Returning a value consumes the
   message and stops it reaching other delegates and Flutter's own window
   procedure. We are observing, not handling, so we must always pass through even
   for the messages we care about.
2. **Keep the returned delegate id** and pass it to
   `UnregisterTopLevelWindowProcDelegate` on teardown. Registration is per
   registrar and the ids are handed out by an incrementing counter.

### Requirements

| | |
| --- | --- |
| Minimum Windows | Windows 10, Flutter's own floor |
| Privileges | none; observing messages needs nothing, and the registry fallback needs only `KEY_NOTIFY`, which standard users have |
| Window | provided by the runner; no message-only window to create |

### Edge cases

* **Duplicates.** Both messages can arrive for one user action, and an
  application that sends `WM_TIMECHANGE` itself produces another. The diff
  absorbs them.
* **DST transitions.** If the registry fallback is used, note that
  `ActiveTimeBias` under the same key is rewritten at DST transitions, so the
  watch fires without an identity change.
* **Headless.** A Windows Flutter app with no window has no delegate to register.
  Not a case this package needs to serve, but worth not crashing on.

---

## Linux

### The trigger

The zone lives in `/etc/localtime`, and `timedatectl set-timezone` replaces it
rather than editing it. systemd's `write_data_timezone()` calls
`symlink_atomic()`, which creates a randomly named temporary symlink and renames
it over the target:

```
symlink("../usr/share/zoneinfo/Canada/Mountain", "/etc/.localtimef0f051fb5138d8e2")
rename("/etc/.localtimef0f051fb5138d8e2", "/etc/localtime")
```

The original inode is never touched, so **a monitor on `/etc/localtime` itself
will never fire.** The watch has to be on `/etc`, filtered to the `localtime`
child. This is the single most common way to get Linux timezone watching wrong.

### The hook

`flutter_linux` plugins are GObject C with GLib available, so
`g_file_monitor_directory` on `/etc` with `G_FILE_MONITOR_WATCH_MOVES` is the
natural fit, connecting to the `changed` signal and matching the child name.

GIO is a better tool here than raw inotify. The move-related event types
(`RENAMED`, `MOVED_IN`, `MOVED_OUT`) only exist on a *directory* monitor with
`WATCH_MOVES`, which is exactly our shape, and GIO gives the old and new names on
the event so the temporary file is trivially filtered out.

Handle both shapes of change, because `/etc/localtime` is not always a symlink:

| Shape | Events | Where it happens |
| --- | --- | --- |
| Symlink replaced | `RENAMED` or `MOVED_IN`, plus `CREATED` for the temporary | systemd, `dpkg-reconfigure tzdata` |
| Regular file rewritten | `CHANGED`, `CHANGES_DONE_HINT` | WSL, some Arch installs, images that copy rather than link |
| Removed | `DELETED` | unsetting the zone |

`/etc/timezone` is worth watching in the same monitor, since the Linux provider
falls back to it and Debian tooling writes it.

### Rejected alternative: D-Bus

`org.freedesktop.timedate1` exposes a `Timezone` property and would emit
`PropertiesChanged`. Two reasons not to: it adds a D-Bus dependency and a service
that may not be running, and timedated is documented as not noticing out-of-band
edits to the symlink, so it is strictly less reliable than watching the file that
is the actual source of truth.

### Requirements

| | |
| --- | --- |
| Dependencies | GLib and GIO, already linked by `flutter_linux` |
| Privileges | none; `/etc` is world readable |
| systemd | not required; the watch is on the filesystem, not on timedated |

### Edge cases

* **Main context.** The `changed` signal is emitted in the thread-default main
  context of the thread that created the monitor. Create it on the platform
  thread, where Flutter's main loop runs.
* **Containers and read-only `/etc`.** An overlay or read-only mount may deliver
  no events at all. A minimal image frequently has no `/etc/localtime` either,
  which is already the documented unavailable case for the provider.
* **`TZ` is unobservable.** The environment is per-process and immutable from
  outside, and `Platform.environment` is cached anyway. A process launched with
  `TZ` set keeps that zone for its lifetime, correctly.
* **Layered symlinks.** Ubuntu Core points `/etc/localtime` at
  `/etc/writable/localtime`, itself a symlink. Since we re-resolve through the
  existing provider rather than reading the event payload, the indirection
  resolves itself.

---

## Web

### There is no trigger, and no polling means a real gap

No DOM event fires when the host timezone changes. There is no `timezonechange`
event and nothing on `Intl` to subscribe to. That is not a gap in this research;
it is a gap in the platform.

With polling ruled out, the web gets detection only at moments the browser
already tells us about:

| Event | Catches |
| --- | --- |
| `visibilitychange` to visible | tab foregrounded after the user changed settings |
| `focus` on `window` | same, on desktop |
| `pageshow` | restore from the back/forward cache |
| `resume` (Page Lifecycle) | mobile thaw after freeze |

**The blind spot, stated plainly:** a tab that stays open, visible and focused
while the OS changes the zone underneath it will never notice. The realistic
version of this is a laptop with the lid open and the browser focused, crossing a
timezone boundary with automatic time enabled. Nothing short of a timer detects
that, and a timer is polling.

This is worth accepting rather than working around. Changing a timezone by hand
requires leaving the browser, which produces a `focus` or `visibilitychange` on
return, so the manual case is fully covered. Only silent automatic change during
continuous foreground use is missed.

### The hook

Flutter web plugin implementations are Dart, declared with `pluginClass` and
`fileName` rather than `dartPluginClass`. In practice we may not need
`package:web` at all: Flutter's own `AppLifecycleListener` already derives its
states from page visibility and focus on web, so the lifecycle layer that is
switched on everywhere may be the entire web implementation.

That is worth confirming in Phase 3 rather than assuming, because the mapping
between DOM events and Flutter lifecycle states on web is an engine detail. If it
turns out to be too coarse, the fallback is listening to the four DOM events
directly through `package:web`.

### Requirements

| | |
| --- | --- |
| Dependencies | none, or `package:web`, which `local_timezone` already has |
| Browser support | `visibilitychange` and `focus` are universal |
| Workers | no `document`, so a worker gets nothing |

---

## What `local_timezone` does not get, and who notices

The core package keeps no listener at all. Four situations get nothing:

1. **Plain Dart CLI or server.** No Flutter, no plugin. `getTimeZone()` still
   works, and a caller who needs change detection can write their own timer,
   which is their choice to make rather than ours to impose.
2. **Non-Flutter web.** Same.
3. **A Flutter app that depends only on `local_timezone`.** This is the sharp
   edge. The current README calls `local_timezone` "the implementation" and
   `flutter_local_timezone` "a thin Flutter-facing package that re-exports the
   whole API", which actively steers a Flutter developer to the package that has
   no listener. That framing has to change: after this feature,
   `flutter_local_timezone` is not thin and not a re-export, and it is the one a
   Flutter app should depend on.
4. **Background isolates.** Platform channels do not work off the root isolate
   without `BackgroundIsolateBinaryMessenger.ensureInitialized`, and plugin
   registration sets per-isolate state. The package already documents a version
   of this for `setMock`. A background isolate can still resolve; it cannot
   listen.

---

## Open questions for Phase 3

1. **Windows: which message actually fires.** The largest single unknown. Test
   before writing the implementation, because the answer decides between the
   window procedure and the registry watch.
2. **Web: is `AppLifecycleListener` enough**, or do we need the DOM events
   directly.
3. **iOS: observe `significantTimeChangeNotification` as well?** Broader
   coverage, more noise.
4. **Apple: is `resetSystemTimeZone` load-bearing** or merely defensive.
5. **Debounce window.** Windows and Linux both burst. The diff handles
   correctness; a short debounce would only reduce redundant lookups, each of
   which costs a few hundred nanoseconds. Probably not worth it, but measure
   rather than assume.
6. **Error path.** `getTimeZone()` throws rather than falling back, and a device
   can move to an unresolvable zone. Phase 1 chose a sealed event covering both
   outcomes; Phase 3 needs to decide whether a *repeated* failure re-fires.

---

## Appendix: the pure Dart alternative, and why it is no longer the plan

The first version of this research assumed no plugin was allowed, and found that
push detection is achievable on all four native platforms in pure Dart via FFI.
That is retained here because it remains the only option for `local_timezone`
should the core package ever want a listener, and because one part of it was
verified rather than merely read.

| Platform | Pure Dart mechanism | Floor |
| --- | --- | --- |
| Android | `__system_property_wait` on `persist.sys.timezone`, a futex | API 26; `__system_property_serial` below that |
| Apple | `notify_register_file_descriptor` on `com.apple.system.timezone`, then blocking `read(2)` | none |
| Windows | `RegNotifyChangeKeyValue` on the TimeZoneInformation key | Windows 8 for `REG_NOTIFY_THREAD_AGNOSTIC` |
| Linux | inotify via `Directory('/etc').watch()` in `dart:io` | none |
| Web | no mechanism | n/a |

**The Apple path was verified working**, on macOS 15 (Darwin 25.5.0) with Dart
3.12.2, in a plain `dart run` process with no runloop, no dispatch drain and no
Objective-C:

```
register_check           -> 0 token=16
register_file_descriptor -> 0 fd=8 token=18
  [fd isolate] blocking in read(2) on fd 8
notify_post              -> 0
check after post         -> 1
  [fd isolate] WOKE UP: 4 bytes
check again              -> 0
```

The polling transport, `notify_register_check` plus `notify_check`, measured
**36 ns per call**, because it is a shared-memory read rather than a syscall.

> Method note, because it will trip up anyone repeating this. Posting to
> `com.apple.system.timezone` from an unprivileged process is silently dropped
> and `notify_post` still returns `NOTIFY_STATUS_OK`, so two earlier attempts
> looked like transport failures and were not. The working spike posts to a
> private `com.example.*` key and allows time for `notifyd` to process the post,
> since `notify_post` is asynchronous.

### Why the plugin wins anyway

| | Pure Dart FFI | Plugin |
| --- | --- | --- |
| APIs used | the layer beneath the documented one | the documented one |
| Waiting thread | a Dart helper isolate per platform, which we own | the OS, which already has one |
| Cancellation | a per-platform problem, and unsolved on Android except by timeout | unregister and return |
| Android floor | API 26 for push, or a second code path | none |
| Apple cache | cannot call `resetSystemTimeZone` before re-reading | can |
| Serves a Dart CLI | yes | no |

The cancellation row is the decisive one. `__system_property_wait` takes a
relative timeout and offers no other interrupt, so tearing down an Android
watcher means either a timeout loop that wakes periodically forever or leaving an
isolate parked. Every plugin mechanism in this document unregisters in one call.

### Windows registry fallback details

Kept here because it is the Windows contingency if neither window message fires.

`RegNotifyChangeKeyValue(hKey, FALSE, REG_NOTIFY_CHANGE_LAST_SET, hEvent, TRUE)`
against `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation`, opened with
`KEY_NOTIFY`. Three documented behaviours shape the loop:

1. **One-shot.** "This function detects a single change. After the caller
   receives a notification event, it should call the function again."
2. **Tied to the registering thread.** "If the thread that called
   `RegNotifyChangeKeyValue` exits, the event is signaled." Harmless in native
   code with an owned thread; it was the reason the Dart version needed
   `REG_NOTIFY_THREAD_AGNOSTIC`, since isolates migrate between OS threads.
3. **Repeated registration leaks.** "Each time a process calls
   `RegNotifyChangeKeyValue` with the same set of parameters, it establishes
   another wait operation, creating a resource leak." One outstanding
   registration at a time, strictly.

---

## Sources

* [Implicit broadcast exceptions](https://developer.android.com/develop/background-work/background-tasks/broadcasts/broadcast-exceptions), for `ACTION_TIMEZONE_CHANGED` being exempt from the API 26 manifest restriction
* [Broadcasts overview](https://developer.android.com/develop/background-work/background-tasks/broadcasts), for runtime registration and the Android 13 export flags
* [Android time overview](https://source.android.com/docs/core/connect/time) and [location time zone detection](https://source.android.com/docs/core/connect/time/location-tz-detection), for the paths that change the device zone
* [`PluginRegistrarWindows`](https://api.flutter.dev/windows-embedder/classflutter_1_1_plugin_registrar_windows.html) and [`plugin_registrar_windows.h`](https://api.flutter.dev/windows-embedder/plugin__registrar__windows_8h_source.html), for `RegisterTopLevelWindowProcDelegate`
* [`WM_TIMECHANGE`](https://learn.microsoft.com/en-us/windows/win32/sysinfo/wm-timechange) and [`SetTimeZoneInformation`](https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/nf-timezoneapi-settimezoneinformation), for the two candidate messages
* [`RegNotifyChangeKeyValue`](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regnotifychangekeyvalue), for the registry fallback
* [`Gio.FileMonitorFlags`](https://docs.gtk.org/gio/flags.FileMonitorFlags.html) and [`Gio.FileMonitor::changed`](https://docs.gtk.org/gio/signal.FileMonitor.changed.html), for `WATCH_MOVES` being directory-only
* [systemd `timedated.c`](https://github.com/systemd/systemd/blob/main/src/timedate/timedated.c) and [systemd issue 13197](https://github.com/systemd/systemd/issues/13197), for `symlink_atomic` and for timedated not watching the link
* [`localtime(5)`](https://man7.org/linux/man-pages/man5/localtime.5.html) and [`inotify(7)`](https://man7.org/linux/man-pages/man7/inotify.7.html)
* [`Intl.DateTimeFormat.prototype.resolvedOptions()`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DateTimeFormat/resolvedOptions), for the construction-time snapshot
* [Developing packages and plugins](https://docs.flutter.dev/packages-and-plugins/developing-packages), for `dartPluginClass`, `pluginClass` and the multiple-engines caveat
* [Darwin Notify](https://developer.apple.com/documentation/DarwinNotify) and [Darwin Notification Concepts](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/MacOSXNotifcationOv/DarwinNotificationConcepts/DarwinNotificationConcepts.html), for the appendix
* [bionic `sys/system_properties.h`](https://github.com/aosp-mirror/platform_bionic/blob/master/libc/include/sys/system_properties.h), for the appendix

## Verification log

Run on macOS 15 (Darwin 25.5.0), Dart 3.12.2, Flutter 3.44.9.

| Claim | How | Result |
| --- | --- | --- |
| **`ACTION_TIMEZONE_CHANGED` reaches a runtime-registered receiver on a real zone change** | `android_device_test.sh` against an API 36 emulator, zone moved mid-suite with `cmd alarm set-timezone` | **passes**, twice, from `Asia/Kolkata` and from `America/Denver` |
| **The new zone is readable by the time the broadcast arrives** | the same case asserts the resolved value, not merely that an event fired | **passes**: `LocalTimezoneChanged(NamedLocalTimezone(Australia/Sydney))` |
| The Kotlin plugin builds and registers | `flutter build apk --debug` on `test_host` | `GeneratedPluginRegistrant` lists `FlutterLocalTimezonePlugin` |
| `com.apple.system.timezone` is a live notify key | `notifyutil -g` | `com.apple.system.timezone 0` |
| `notify_register_file_descriptor` is callable from Dart FFI | spike | status 0, fd 8, token 18 |
| A blocking `read(2)` on the notify fd wakes a Dart isolate with no runloop | spike, self-posted | woke with 4 bytes |
| `notify_register_check` plus `notify_check` detects a post | spike, self-posted | 1 after the post, 0 after |
| `notify_check` is cheap enough to poll | 100,000 iterations | 36 ns per call |
| Unprivileged processes cannot post `com.apple.system.*` | spike | `notify_post` returns 0, nothing delivered |
| Flutter's default `minSdkVersion` | `FlutterExtension.kt` in the installed SDK | `val minSdkVersion: Int = 24` |
| `dartPluginClass` composes with a native `pluginClass` | Flutter tooling source and docs | hybrid registration is documented and supported |

Not yet verified, and needing a device or root. Every one of these is a
platform's primary trigger, so the list is the Phase 3 test plan rather than a
footnote:

| Claim | Needs |
| --- | --- |
| `NSSystemTimeZoneDidChangeNotification` fires on a real zone change | an iOS device, and root on macOS |
| `resetSystemTimeZone` is required before re-reading | the same |
| `WM_TIMECHANGE` or `WM_SETTINGCHANGE` reaches a Flutter window on a Settings-driven change | a Windows machine |
| `GFileMonitor` on `/etc` fires for `timedatectl set-timezone` | a Linux machine |
| Flutter web maps `visibilitychange` and `focus` to lifecycle states finely enough | a browser |

The pure Dart spikes are at `/tmp/tz_spike/` and are not part of the repository.
