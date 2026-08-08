#!/usr/bin/env bash
#
# Runs the device suite as a real Flutter Linux app, and moves the system
# timezone underneath it so the listener has something to hear.
#
# Linux is the platform with no timezone change notification at all. There is no
# signal to post and none to subscribe to, so the plugin infers one by watching
# /etc for the moment `timedatectl` replaces the localtime symlink. This script
# is what makes that replacement happen while the app is running.

set -euo pipefail

: "${ZONE:?ZONE must name the timezone to configure}"
: "${ZONE_AFTER:?ZONE_AFTER must name the timezone to move to mid-run}"

# What the suite prints once its listener is registered, which is the harness's
# cue that it is safe to move the zone. Matches `listenerReadySentinel` in
# integration_test/device_test.dart.
SENTINEL=LOCAL_TIMEZONE_LISTENER_READY

# Where the suite's output is mirrored so the mover can watch it.
log=$(mktemp)

set_zone() {
  sudo timedatectl set-timezone "$1"
}

check_zone() {
  actual=$(timedatectl show --property=Timezone --value)
  if [ "$actual" != "$1" ]; then
    echo "::error::wanted $1, timedatectl reports '$actual'"
    exit 1
  fi
}

set_zone "$ZONE"
check_zone "$ZONE"

# `timedatectl` is the right lever here for the same reason `systemsetup` is on
# macOS, though for a different mechanism. It replaces /etc/localtime with an
# atomic create-and-rename, which is exactly the event the plugin's directory
# watch is looking for. Writing the symlink by hand with `ln -sf` would also be
# observed, since inotify does not care who did the rename, but going through
# timedatectl is what a user does and so is what should be tested.

# Timed off a sentinel the suite prints once its listener is registered, rather
# than off the app process appearing. The process exists well before the suite
# runs: `flutter test` still has to attach, and moving the clock through that
# window is a good way to break an attach.
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

  echo "moving the machine from $ZONE to $ZONE_AFTER"
  set_zone "$ZONE_AFTER"
}

move_zone_when_listener_is_ready &
mover=$!
trap 'kill "$mover" 2>/dev/null || true' EXIT

# A Flutter Linux app is a GTK app and needs a display even when nothing will
# look at it. The runner is headless, so without a virtual X server the app dies
# at startup and the suite never runs.
#
# The window is also load bearing on Windows for a different reason, but not
# here: the Linux trigger is an inotify watch, which does not care whether
# anything is on screen.
#
# EXPECTED_RAW is not passed. The Linux provider reports the resolved symlink
# path as `raw`, which is a distribution detail this script does not control.
rc=0
xvfb-run -a flutter test integration_test -d linux \
  --dart-define=EXPECTED_ZONE="$ZONE" \
  --dart-define=ZONE_AFTER="$ZONE_AFTER" 2>&1 | tee "$log" || rc=$?

kill "$mover" 2>/dev/null || true
wait "$mover" 2>/dev/null || true

final=$(timedatectl show --property=Timezone --value)
if [ "$final" = "$ZONE" ]; then
  echo "::error::the machine is still in $ZONE, so the harness never moved it" \
    "to $ZONE_AFTER. Whatever the listener case reported above, it was not" \
    "reporting on a real system timezone change."
  exit 1
elif [ "$final" != "$ZONE_AFTER" ]; then
  echo "::error::the run should have ended in $ZONE_AFTER and the machine is" \
    "in '$final', so it moved for a reason this script did not choose."
  exit 1
fi

exit "$rc"
