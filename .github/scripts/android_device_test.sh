#!/usr/bin/env bash

set -euo pipefail

: "${ZONE:?ZONE must name the timezone to configure}"
: "${ZONE_AFTER:?ZONE_AFTER must name the timezone to move to mid-run}"
: "${ANDROID_SERIAL:?android-emulator-runner must select the emulator}"

# What the suite prints once its listener is registered, which is the harness's
# cue that it is safe to move the zone. Matches `listenerReadySentinel` in
# integration_test/device_test.dart.
SENTINEL=LOCAL_TIMEZONE_LISTENER_READY

# Where the suite's output is mirrored so the mover can watch it.
log=$(mktemp)

# The action already waits for sys.boot_completed, but keep the readiness check
# beside the device mutation it protects. `adb wait-for-device` only proves that
# the transport is listed. It does not prove that Android can run a shell command.
attempt=0
while :; do
  booted=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') || booted=
  if [ "$booted" = 1 ] && adb shell true >/dev/null 2>&1; then
    break
  fi

  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "::error::device $ANDROID_SERIAL was not ready after 60 seconds"
    exit 1
  fi
  sleep 1
done

# What the device came up in, before anything here touches it. An emulator
# reports the host's zone to the guest as a NITZ telephony signal, and the time
# zone detector applies it, so an untouched runner emulator sits in the runner's
# zone rather than in some neutral default. `-timezone` in the job's emulator
# options is what aims that signal at the zone this cell wants. When it lands
# this already reads $ZONE and everything below is belt and braces; when it does
# not, the detector is holding a different answer and the rest of this script is
# load bearing again. Worth one line either way, because the difference is
# invisible in every other part of the log.
initial=$(adb shell getprop persist.sys.timezone | tr -d '\r')
if [ "$initial" = "$ZONE" ]; then
  echo "device booted into $ZONE already, so -timezone reached the guest"
else
  echo "::warning::device booted into '$initial' rather than $ZONE, so" \
    "-timezone did not reach the guest and automatic detection is still" \
    "holding '$initial' as its answer"
fi

# Otherwise the framework is free to resync the zone from the network partway
# through and undo the value below.
adb shell settings put global auto_time_zone 0

# Ask Android's system service to change the zone instead of writing the
# property as the shell user. The service has SET_TIME_ZONE permission, updates
# `persist.sys.timezone`, resets Android's timezone state, and broadcasts the
# change. This works without restarting adbd and without a root-capable image.
adb shell cmd alarm set-timezone "$ZONE"

# The provider reads exactly this property, and so does bionic when `TZ` is
# unset, so changing it moves the provider and `DateTime` together. That keeps
# the round trip assertion meaningful instead of tautological.
actual=$(adb shell getprop persist.sys.timezone | tr -d '\r')
if [ "$actual" != "$ZONE" ]; then
  echo "::error::wanted $ZONE, the device reports '$actual'"
  exit 1
fi

# The guard above is one reading taken seconds after boot, and the app does not
# start for another seven minutes. The detector is awake for all of it, still
# holding whatever the emulator suggested, and if it reasserts that the device
# moves with nothing in this log to say so. Sample the two values that would
# explain it, for as long as the run lasts, so a recurrence reports itself
# instead of arriving as a mystery about the provider.
started=$(date +%s)
(
  seen_zone=$ZONE
  seen_auto=0
  while :; do
    sleep 5
    state=$(adb shell 'getprop persist.sys.timezone; settings get global auto_time_zone' 2>/dev/null | tr -d '\r') || continue
    zone_now=$(echo "$state" | sed -n 1p)
    auto_now=$(echo "$state" | sed -n 2p)
    if [ -n "$zone_now" ] && [ "$zone_now" != "$seen_zone" ]; then
      if [ "$seen_zone" = "$ZONE" ] && [ "$zone_now" = "$ZONE_AFTER" ]; then
        # The one transition this run asks for. Logged, not warned about, so
        # the annotation still means "something moved that should not have".
        echo "$(( $(date +%s) - started ))s in, the harness moved the device" \
          "from '$seen_zone' to '$zone_now'"
      else
        echo "::warning::$(( $(date +%s) - started ))s in, the device zone went" \
          "from '$seen_zone' to '$zone_now'"
      fi
      seen_zone=$zone_now
    fi
    if [ -n "$auto_now" ] && [ "$auto_now" != "$seen_auto" ]; then
      echo "::warning::$(( $(date +%s) - started ))s in, auto_time_zone went" \
        "from '$seen_auto' to '$auto_now'"
      seen_auto=$auto_now
    fi
  done
) &
watcher=$!

# Move the zone a second time while the suite is running, so the listener has
# something real to hear. This has to come from the host: an app cannot change
# the device zone, because SET_TIME_ZONE is privileged, so there is no way to
# trigger a genuine ACTION_TIMEZONE_CHANGED from inside the test.
#
# Timed off a sentinel the suite prints once its listener is registered, not off
# the app process appearing. The process exists well before the suite runs:
# `flutter test` still has to read the VM service URL out of logcat and attach,
# and moving the system clock through that window is a good way to break an
# attach that upstream already stalls on. On 2026-08-08 this cell went silent
# exactly there and burned the job's whole 45 minute budget.
move_zone_when_listener_is_ready() {
  attempt=0
  until grep -q "$SENTINEL" "$log" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 900 ]; then
      echo "::warning::the suite never reported its listener ready, so the zone" \
        "was never moved and the listener case will fail on its timeout rather" \
        "than on a verdict"
      return
    fi
    sleep 1
  done

  echo "moving the device from $ZONE to $ZONE_AFTER"
  adb shell cmd alarm set-timezone "$ZONE_AFTER"
}

move_zone_when_listener_is_ready &
mover=$!
# Otherwise a failure before the mover finishes leaves it running against a
# teardown emulator, and the step hangs waiting on a background child.
trap 'kill "$mover" 2>/dev/null || true' EXIT

# `EXPECTED_RAW` is the same string as `EXPECTED_ZONE` because the Android
# provider returns the property verbatim as `raw`. The matrix entries are
# primary IANA names, so canonicalization is a no-op for all three.
#
# Tee rather than redirect. The mover needs to read this stream as it arrives,
# and a stalled run gets killed by the job timeout, which would take an
# unflushed log file with it and leave nothing to diagnose.
rc=0
flutter test integration_test -d "$ANDROID_SERIAL" \
  --dart-define=EXPECTED_ZONE="$ZONE" \
  --dart-define=EXPECTED_RAW="$ZONE" \
  --dart-define=ZONE_AFTER="$ZONE_AFTER" 2>&1 | tee "$log" || rc=$?

kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
kill "$mover" 2>/dev/null || true
wait "$mover" 2>/dev/null || true

# Read it back rather than inferring it from whether the suite was happy. A
# device that moved for a reason this script did not choose invalidates every
# assertion in the run, and telling that apart from a real regression is the
# difference between a broken harness and a broken package. Checked even when
# the suite passed, because the Etc/UTC cell expects the value the device would
# revert to and so cannot fail on this by itself.
#
# The expected end state is ZONE_AFTER, not ZONE: this run moves the device on
# purpose, once, to give the listener a real broadcast to hear.
final=$(adb shell getprop persist.sys.timezone | tr -d '\r')
if [ "$final" = "$ZONE" ]; then
  echo "::error::the device is still in $ZONE, so the harness never moved it" \
    "to $ZONE_AFTER. Whatever the listener case reported above, it was not" \
    "reporting on a real system timezone change."
  exit 1
elif [ "$final" != "$ZONE_AFTER" ]; then
  echo "::error::the run should have ended in $ZONE_AFTER and the device is in" \
    "'$final', so it moved for a reason this script did not choose and the" \
    "result above says nothing about the provider. The warnings above give the" \
    "time it moved."
  exit 1
fi

exit "$rc"
