#!/bin/sh

set -eu

: "${ZONE:?ZONE must name the timezone to configure}"
: "${ANDROID_SERIAL:?android-emulator-runner must select the emulator}"

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

# `EXPECTED_RAW` is the same string as `EXPECTED_ZONE` because the Android
# provider returns the property verbatim as `raw`. The matrix entries are
# primary IANA names, so canonicalization is a no-op for all three.
flutter test integration_test -d "$ANDROID_SERIAL" \
  --dart-define=EXPECTED_ZONE="$ZONE" \
  --dart-define=EXPECTED_RAW="$ZONE"
