# local_timezone

Read the device's IANA timezone identifier, such as `Asia/Kolkata`, **synchronously**,
in pure Dart, on Android, iOS, macOS, Windows, Linux and the web.

```dart
final zone = LocalTimezone.getTimeZoneName(); // Asia/Kolkata
```

No plugin, no platform channel, no native code. Because it is
synchronous, it can be called from `build()` without an `await`.

> **Status: all six platforms are implemented.** Android, iOS, macOS, Linux, Windows
> and web. Linux and Windows are the newest and cannot be exercised from a macOS
> development machine, so their resolution logic is written as pure functions and
> tested exhaustively against fixtures taken from real distributions; only the syscall
> itself waits on CI.

### Android

Reads `persist.sys.timezone` through bionic's `__system_property_get`, which is a
shared-memory read rather than a syscall. It is in libc's base ABI and has been since
API 1, and the property since API 4, so there is effectively no version floor.

The property normally holds an IANA identifier, though not necessarily a current one:
an emulator set to `Asia/Calcutta` stores exactly that, and `canonicalized` reports
`Asia/Kolkata`. It can also hold a `java.util.TimeZone` custom ID such as `GMT+05:30`,
which bionic documents as happening on set-top boxes that take the zone from the TV
network and write it straight to the property. Those are returned as an
`OffsetLocalTimezone`.

**The sign is not inverted.** POSIX reads `GMT+5` as five hours *behind* UTC and Java
reads it as five hours *ahead*, and this property is the Java one. bionic says so
directly: "Since (a) Java is the one that matches human expectations and (b) this
system property is used directly by Java, we flip the sign here to translate from Java
to POSIX." That flip belongs to bionic's own C consumers, and a caller reading the
property must not repeat it.

For the same reason the offset is parsed rather than taken from
`DateTime.now().timeZoneOffset`, which is the opposite of what the web path does.
bionic's flip is guarded by `strcmp(buf, "GMT")`, true only when the value is exactly
`GMT`, so for `GMT+05:30` it never runs and bionic's own `localtime` reads the string as
POSIX. On such a device the VM clock and the Java clock disagree by twice the offset,
and the Java reading is what the rest of the system shows the user.

### Apple

Sends `[[NSTimeZone localTimeZone] name]` through `objc_msgSend`. That is the exact
counterpart of `TimeZone.autoupdatingCurrent.identifier` in a native Swift app:
Foundation bridges `+localTimeZone` through `_autoupdating()`, and `-name` is the same
string Swift calls `.identifier`. Both resolve from `TZFILE`, then `TZ`, then the
`TZDEFAULT` symlink, which is `/etc/localtime` on macOS and the simulator and
`/var/db/timezone/localtime` on a device.

Re-sending the message on every call is what keeps the value current, not the
auto-updating proxy: `+localTimeZone` and `+systemTimeZone` read the same memoized
cache slot, and the proxy only matters to a caller holding the object. What
`+localTimeZone` does buy is that a host app calling `+setDefaultTimeZone:` cannot move
the answer.

| Foundation reports | Result |
| --- | --- |
| `Asia/Calcutta` (a deprecated alias) | `NamedLocalTimezone('Asia/Kolkata')` |
| `GMT` (Foundation's name for UTC) | `NamedLocalTimezone('Etc/GMT')` |
| `GMT+0530`, from a POSIX `TZ` | `OffsetLocalTimezone` |
| nil anywhere in the message chain | `LocalTimezoneUnavailableException` |

**Foundation canonicalizes nothing**, so canonicalization is load-bearing here rather than
the no-op it looks like on a Mac already set to a primary name. See
[Canonicalization](#canonicalization).

**The offset comes from the runtime, not from Foundation's name.** The two disagree on
a POSIX `TZ`: given `TZ=GMT+5`, Foundation builds a zone it calls `GMT+0500` while libc
runs the process at UTC-05:00, and given `TZ=GMT+0530` Foundation says `+05:30` while the
process is in UTC. Dart's `DateTime` follows libc, so reporting Foundation's number would
leave the package disagreeing with every `DateTime` in the same program. `raw` keeps
Foundation's spelling, `offset` is what the runtime applies, and the mismatch between
them is deliberate.

A configured device never reaches this branch. System Settings offers cities, not
offsets, so it always yields a real IANA zone, and for those Foundation and libc agree.
It is a CLI, container and server case. Note also that Foundation honours `TZ` rather
than falling back to the system zone, so a process with `TZ=Europe/Paris` reports Paris
on a Mac set to Kolkata, exactly as `DateTime` does.

**A long-lived process with no runloop can go stale.** Foundation drops its cached zone
on `NSSystemTimeZoneDidChangeNotification`, which Apple posts on the main queue. Flutter
services that queue; a plain Dart CLI or server does not, so a change may never be
observed. Short-lived processes are unaffected.

### Linux

Reads `TZ`, then the `/etc/localtime` symlink, then `/etc/timezone`. The first two are
what glibc itself consults, in that order. The third is not: it is a Debian convention
no libc reads, checked last only because it is the remaining place a zone *name* can be
recovered from. No FFI is involved, just `dart:io`.

| Source | Result |
| --- | --- |
| `TZ=Asia/Kolkata`, `:Asia/Kolkata`, or a path into the database | `NamedLocalTimezone` |
| `TZ=EST5EDT,M3.2.0,M11.1.0`, a POSIX rule naming no zone | `OffsetLocalTimezone` |
| `/etc/localtime` symlinked into the database | `NamedLocalTimezone` |
| `/etc/localtime` copied rather than linked, no `/etc/timezone` | `OffsetLocalTimezone` |
| none of the above | `LocalTimezoneUnavailableException` |

There is no kernel or libc version floor. The requirement is a distribution providing
one of those sources, which every mainstream one does. Minimal images often do not: a
stock `ubuntu` image ships no zoneinfo at all and `distroless` ships a dangling symlink,
so both need `TZ` set.

Two details that are easy to get wrong and are covered by tests. Links into the
`posix/` and `right/` subtrees, which most distributions ship, must have that component
stripped or the result is `right/Asia/Kolkata`, which resolves nowhere. And `Etc/GMT+5`
is a zone while `EST5EDT` is a rule, despite both containing a digit, so the
discrimination is anchored on an abbreviation immediately followed by an offset.

### Windows

Calls `GetDynamicTimeZoneInformation` and maps the registry key it reports through
CLDR. Only `kernel32.dll` is opened, which is the point: the obvious alternative,
ICU's `ucal_getTimeZoneIDForWindowsID`, would impose a Windows 10 version 1903 floor,
because that is when the combined `icu.dll` first shipped. This works back to Vista.

The older `GetTimeZoneInformation` is not used because it reports a localized display
name that cannot be looked up, and is less accurate besides: in Singapore it says
"Malay Peninsula Standard Time" where the registry key is "Singapore Standard Time".

**The mapping is not one-to-one, and treating it as one relocates people.** Of 139
Windows keys, 66 cover more than one IANA zone. "Romance Standard Time" is
`Europe/Paris` in France and `Europe/Madrid` in Spain; CLDR marks the tie-break with
territory `001`. Consulting only that fallback, which is what most implementations do,
puts every Spanish user in Paris. So `GetUserDefaultGeoName` supplies the region and a
territory table refines the answer. That function arrived in Windows 10 version 1709 and
is resolved at runtime, so older Windows loses the refinement rather than failing to
start.

**Canonicalization is load-bearing here too.** CLDR freezes its canonical IDs for
stability, so 115 of the 361 zones it names are deprecated spellings: "India Standard
Time" maps to `Asia/Calcutta`, not `Asia/Kolkata`. Returning those unrewritten would
fail downstream for roughly a third of Windows configurations.

### Web

Both `dart2js` and `dart2wasm` are supported and tested. The lookup is
`Intl.DateTimeFormat().resolvedOptions().timeZone`, which is synchronous on both, so
the web path needs no `await` either. Only `dart:js_interop` is used, and `Intl` is not
a DOM API, so this also runs in a worker.

Browsers report more shapes than an identifier, and each is handled:

| The engine reports | Result |
| --- | --- |
| `Asia/Calcutta` (a deprecated alias) | `NamedLocalTimezone('Asia/Kolkata')` |
| `+05:30`, or `GMT+05:00` on Safari | `OffsetLocalTimezone` |
| `Etc/Unknown` | `LocalTimezoneUnavailableException` |
| `undefined` or an empty string | `LocalTimezoneUnavailableException` |

**The offset is taken from the engine, never parsed from the string.** V8 misreports the
sign when the host `TZ` holds a POSIX value: `TZ=GMT+5` yields the identifier `+05:00`
while correctly applying UTC-05:00. Parsing that string would put a caller ten hours out,
so `OffsetLocalTimezone.offset` comes from the offset the engine actually applies, with
the reported string kept in `raw`.

`Etc/GMT+5` is an identifier rather than an offset, despite how it looks, and is treated
as a name.

## Canonicalization

Platforms disagree about which spelling to report for the same zone. Chrome and Node
say `Asia/Calcutta` where Firefox and Linux say `Asia/Kolkata`, and the same split
exists for Kyiv, Ho Chi Minh City, Yangon, Nuuk, Kanton, Kathmandu and Buenos Aires.
By default the identifier is rewritten to the current primary name, so one device
yields one answer whatever it is running:

```dart
LocalTimezone.getTimeZoneName();  // Asia/Kolkata, the canonical spelling

switch (LocalTimezone.getTimeZone()) {
  case NamedLocalTimezone(:final raw, :final name, :final canonicalized):
    raw;           // India Standard Time   <- what the platform said
    name;          // Asia/Calcutta         <- parsed, not corrected
    canonicalized; // Asia/Kolkata          <- the primary spelling
  case OffsetLocalTimezone():
    // no identifier to canonicalize
}
```

All three layers are always present; there is nothing to opt into. On Apple,
Android and the web `raw` and `name` are the same string, because those platforms
already report an identifier. Windows and Linux are where they differ, reporting a
registry key and a filesystem path respectively.

This also matters downstream. `package:timezone`'s default dataset,
`data/latest.dart`, is generated from the `Zone` entries of tzdb's `rearguard.zi`, so
it holds primary names only and rejects every alias. `tz.getLocation('Asia/Calcutta')`
throws, which means the obvious
`tz.getLocation(LocalTimezone.getTimeZoneName())` fails for every Indian user on
Chrome unless the canonical spelling is used.

**Every result is a primary zone name.** The table is taken verbatim from the two tzdb
files that declare `Link` entries, and a Link always points at a `Zone`. So the set of
values this can return is exactly the set `package:timezone` accepts by default. A test
asserts that rather than assuming it.

**Apple is not on the primary-name side of that split, despite appearances.** Foundation
does no canonicalization whatsoever: the identifier is the tail of the `TZDEFAULT`
symlink, returned verbatim, so an iOS or macOS device reports whichever spelling the OS
wrote. `Asia/Saigon` and `Europe/Kiev` both turn up in the wild. Apple's own
`knownTimeZoneNames` cannot arbitrate either, since ICU's stable-ID policy keeps
`Asia/Calcutta` canonical and omits `Asia/Kolkata` altogether: validating against that
list would reject values the same API returns.

### Compatibility with `package:timezone`

Verified against **`timezone` 0.11.1**. The 257 aliases resolve to 111 distinct
identifiers, and **all 111 are accepted by all three of its datasets**:

| Dataset | Accepted |
| --- | --- |
| `data/latest.dart` (the default) | 111 / 111 |
| `data/latest_all.dart` | 111 / 111 |
| `data/latest_10y.dart` | 111 / 111 |

So this composes directly, with no lookup that can throw on an alias:

```dart
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

tzdata.initializeTimeZones();
tz.setLocalLocation(tz.getLocation(LocalTimezone.getTimeZoneName()));
```

Using `name` rather than `canonicalized` there would throw on `data/latest.dart` for anyone whose platform
reports an alias, which includes every Chrome user in India, Ukraine, Vietnam, Myanmar,
Greenland, Nepal and Argentina, plus every machine set to UTC on any platform.

This is structural rather than a lucky spot check. `data/latest.dart` is generated from
the `Zone` entries of tzdb's `rearguard.zi`, and every value this package can return is
one of those `Zone` entries by construction.

The one way it could drift is a tzdb release that adds a zone: regenerating this table
against a newer release than `timezone` ships could name a zone its dataset lacks.
Nothing like that is outstanding today, and `data/latest_all.dart` is immune either way.

The table is generated by
[`tool/generate_backward.dart`](tool/generate_backward.dart), currently tzdb **2026c**,
257 entries, about 10 KB. Nothing is validated: an identifier this package has not
heard of passes straight through, so a stale table degrades to "no rewrite" rather
than to a wrong answer.

> **Sources.** Aliases come from
> [`backward`](https://data.iana.org/time-zones/tzdb/backward) and
> [`etcetera`](https://data.iana.org/time-zones/tzdb/etcetera), which between them hold
> every `Link` in the database; the seven regional files declare none. The release is
> read from [`version`](https://data.iana.org/time-zones/tzdb/version). All are fetched
> at generation time only. Nothing is downloaded at runtime and the package has no
> network dependency. Regenerate with `dart run tool/generate_backward.dart` after a
> new tzdb release.

One thing is deliberately never rewritten. **`Etc/GMT+5` and friends are left alone.**
They look like aliases but are real zones with an inverted sign, so `Etc/GMT+5` is
UTC-05:00 by the database's own design. They are `Zone` entries rather than `Link`
entries and so never enter the table. Rewriting one would move a user by twice their
offset.

The zero-offset family needs no special case. `UTC`, `Zulu`, `Universal` and `UCT`
resolve to `Etc/UTC`; `GMT`, `GMT0` and `Greenwich` resolve to `Etc/GMT`. Browsers
report `UTC` and Apple reports `GMT`, so both get rewritten, and both would otherwise
be rejected downstream.

## Why

`DateTime.now().timeZoneName` returns an abbreviation, not an identifier. It gives
you `IST`, which is India, Ireland, and Israel, and it gives you different *kinds*
of value depending on where you run it:

| | Native | Web |
| --- | --- | --- |
| `DateTime.now().timeZoneName` | `IST` | `India Standard Time` |
| `LocalTimezone.getTimeZoneName()` | `Asia/Kolkata` | `Asia/Kolkata` |

Existing packages solve this with a platform channel, which forces the answer to be
asynchronous even though every underlying OS call is synchronous.

## Usage

```dart
import 'package:local_timezone/local_timezone.dart';

// The common case.
final zone = LocalTimezone.getTimeZoneName();

// A device can report a fixed UTC offset instead of a zone.
switch (LocalTimezone.getTimeZone()) {
  case NamedLocalTimezone(:final name):    useZone(name);
  case OffsetLocalTimezone(:final offset): useOffset(offset);
}
```

Failures are exceptions, never a silent fallback to UTC. `LocalTimezoneException` is
sealed, so they can be handled exhaustively. See [`example/`](example/) for the full
set of cases.

## Requirements

The Dart SDK constraint is `^3.12.2`.

Two different floors matter. The first column is what this package's own code needs.
The second is what Flutter imposes on any app regardless, and for Flutter users it is
the one that binds. In a plain Dart CLI or server app, only the first column applies.

| Platform | This package needs | Flutter 3.44 needs |
| --- | --- | --- |
| Android | API 1 | API 24 |
| iOS | iOS 11.0 | iOS 13.0 |
| macOS | macOS 10.13 | macOS 10.15 |
| Windows | Windows Vista / Server 2008 | Windows 10 |
| Linux | no version floor | Debian 10+, Ubuntu 20.04+ |
| Web, `dart2js` | Chrome 45, Edge 14, Firefox 53, Safari 10 | Safari 15.6+, latest 2 of the rest |
| Web, `dart2wasm` | Chrome 119, Edge 119, Firefox 120, Safari 18.2 | Chromium only, see below |

### Notes on the numbers

**iOS 11 and macOS 10.13 are a correctness floor, not an availability floor.** Every
Objective-C symbol used here has existed since macOS 10.0 and iOS 2.0. The constraint
comes from Apple's own documentation of `NSTimeZone.local`: "In macOS High Sierra and
later, iOS 11 and later, tvOS 11 and later, and watchOS 4 and later, the local class
property reflects the current system time zone, whereas previously it reflected the
default time zone." Below those versions the API still works, but can report the app's
default zone rather than the device's.

**Android's floor is effectively zero.** `__system_property_get` has been in bionic's
base ABI since API 1, and `persist.sys.timezone` since API 4. The package ships no
`.so` of its own, so the 16 KB page size requirement introduced for API 35 does not
apply to it.

**Windows needs no ICU.** `GetDynamicTimeZoneInformation` has been in `kernel32.dll`
since Vista, and the Windows-to-IANA mapping is a bundled CLDR table. Packages that
call `ucal_getTimeZoneIDForWindowsID` instead inherit a Windows 10 version 1903 floor,
because that is when the combined `icu.dll` first shipped. This package does not.

**Linux has no version floor, but it does have a configuration requirement.** The
lookup reads `TZ`, then resolves the `/etc/localtime` symlink. Mainstream distributions
provide that symlink. Minimal container images frequently do not: a stock `ubuntu` base
image ships no zoneinfo at all, and `distroless` ships a dangling link. On those, set
`TZ` or expect `LocalTimezoneUnavailableException`.

**The `dart2js` browser floor comes from the compiler, not from this package.** The
`Intl` API it calls has been Baseline Widely available since September 2017, but
`dart2js` emits arrow functions in its own output, which is what puts Chrome at 45.

**Flutter does not ship the Wasm build to every browser that supports it.** Flutter's
loader gates Wasm on an engine allowlist that is Chromium-only, so Firefox and Safari
receive the JavaScript build by default even though both support WasmGC. Flutter
compiled to Wasm also cannot run in any iOS browser, since all of them are required to
use WebKit. The `dart2wasm` row above is the floor for the *compiler output*; whether a
given Flutter app reaches it is a separate question.

## How it works

| Platform | Source |
| --- | --- |
| Android | `__system_property_get("persist.sys.timezone")` via `dart:ffi` |
| iOS, macOS | `[[NSTimeZone localTimeZone] name]` via the Objective-C runtime |
| Linux | `TZ`, then the `/etc/localtime` symlink |
| Windows | `GetDynamicTimeZoneInformation`, mapped through CLDR |
| Web | `Intl.DateTimeFormat().resolvedOptions().timeZone` |

On Apple platforms the call goes through `objc_msgSend` against `libobjc`, which is
already loaded in every process, so nothing is bundled, signed, or notarized. Web
covers both `dart2js` and `dart2wasm`.

## Additional information

Issues and pull requests are welcome at
[github.com/BirjuVachhani/local_timezone](https://github.com/BirjuVachhani/local_timezone/issues).
