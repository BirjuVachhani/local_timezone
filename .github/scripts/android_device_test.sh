#!/bin/sh

set -eu

: "${ZONE:?ZONE must name the timezone to configure}"
: "${ZONE_AFTER:?ZONE_AFTER must name the timezone to move to mid-run}"
: "${ANDROID_SERIAL:?android-emulator-runner must select the emulator}"

# The application id of test_host, which is what the mover below waits for.
APP_ID=com.birjuvachhani.test_host

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

# `EXPECTED_RAW` is the same string as `EXPECTED_ZONE` because the Android
# provider returns the property verbatim as `raw`. The matrix entries are
# primary IANA names, so canonicalization is a no-op for all three.
rc=0
# Move the zone a second time while the suite is running, so the listener has
# something real to hear. This has to come from the host: an app cannot change
# the device zone, because SET_TIME_ZONE is privileged, so there is no way to
# trigger a genuine ACTION_TIMEZONE_CHANGED from inside the test.
#
# Timed off the app process appearing rather than off a fixed delay from here.
# `flutter test` spends most of its wall clock building and installing, and that
# varies by minutes between runs, so a fixed sleep either fires before any
# listener exists or burns the job timeout waiting.
move_zone_when_app_starts() {
  attempt=0
  until adb shell pidof "$APP_ID" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 600 ]; then
      echo "::warning::$APP_ID never started, so the zone was never moved and" \
        "the listener case will fail on its timeout rather than on a verdict"
      return
    fi
    sleep 1
  done

  # Margin between the process appearing and the Dart suite reaching setUpAll,
  # where the listener is registered. The cases that assert on $ZONE run first
  # and take milliseconds, so this only has to outlast engine startup.
  sleep 15

  echo "moving the device from $ZONE to $ZONE_AFTER"
  adb shell cmd alarm set-timezone "$ZONE_AFTER"
}

move_zone_when_app_starts &
mover=$!
# Otherwise a failure before the mover finishes leaves it running against a
# teardown emulator, and the step hangs waiting on a background child.
trap 'kill "$mover" 2>/dev/null || true' EXIT

flutter test integration_test -d "$ANDROID_SERIAL" \
  --dart-define=EXPECTED_ZONE="$ZONE" \
  --dart-define=EXPECTED_RAW="$ZONE" \
  --dart-define=ZONE_AFTER="$ZONE_AFTER" || rc=$?

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
