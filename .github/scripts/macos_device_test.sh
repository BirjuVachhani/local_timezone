#!/usr/bin/env bash
#
# Runs the device suite as a real macOS app, and moves the system timezone
# underneath it so the listener has a genuine notification to hear.
#
# The Apple half of the listener cannot be proved any other way. An app cannot
# change the system timezone: there is no supported API for it at all, so the
# mutation has to come from outside the process, exactly as it does for Android
# over adb.

set -euo pipefail

: "${ZONE:?ZONE must name the timezone to configure}"
: "${ZONE_AFTER:?ZONE_AFTER must name the timezone to move to mid-run}"

# What the suite prints once its listener is registered, which is the harness's
# cue that it is safe to move the zone. Matches `listenerReadySentinel` in
# integration_test/device_test.dart.
SENTINEL=LOCAL_TIMEZONE_LISTENER_READY

# Where the suite's output is mirrored so the mover can watch it.
log=$(mktemp)

# Foundation's zoneinfo root, not /usr/share/zoneinfo, which is itself a
# symlink. Foundation recovers the IANA name by stripping this prefix from the
# raw /etc/localtime target and otherwise falls back to GMT even though libc can
# read the same tzfile.
ZONEINFO=/var/db/timezone/zoneinfo

# Why not `systemsetup -settimezone`, which is the documented way to do this and
# the only one that posts a notification by itself:
#
# It validates its argument against `-listtimezones`, and that needs Full Disk
# Access, which a CI shell does not have. On a runner it therefore rejects every
# zone in the database, including ones `-gettimezone` will happily report back.
# The `test` job's macOS step already carries this warning; this script learned
# it the hard way on 2026-08-08, when every macos_app run failed on
# "systemsetup does not accept 'Asia/Kolkata'".
#
# So the change is made in two halves that `systemsetup` would have done
# together. Relinking moves the zone Foundation reads. Posting the darwin key
# is what tells every running process to stop trusting its cache, which is the
# half a plain `ln -sf` silently omits and the half this whole job exists to
# exercise.
set_zone() {
  local zone=$1
  if [ ! -f "$ZONEINFO/$zone" ]; then
    echo "::error::no zone file for $zone in this tzdata"
    exit 1
  fi
  sudo ln -sfh "$ZONEINFO/$zone" /etc/localtime
  sudo notifyutil -p com.apple.system.timezone
}

check_zone() {
  local wanted=$1
  local actual
  actual=$(swift -e 'import Foundation; print(NSTimeZone.local.identifier)')
  if [ "$actual" != "$wanted" ]; then
    echo "::error::wanted $wanted, Foundation reports '$actual'"
    exit 1
  fi
}

# Can this runner post the key at all?
#
# Unprivileged processes cannot: notifyd drops posts to com.apple.system.* and
# `notify_post` still returns success, so a silent no-op is the failure mode to
# rule out rather than discover. Root is expected to be allowed, but "expected"
# is not "checked", and if it is wrong then the listener case below would fail
# for a reason that has nothing to do with the plugin.
#
# So establish it first, with the same tools, and let the answer decide whether
# the listener case runs at all. This is a precondition, not a softened
# assertion: when it holds, the case is a real test that can really fail.
can_post_darwin_key() {
  local watcher_out
  watcher_out=$(mktemp)
  notifyutil -w com.apple.system.timezone >"$watcher_out" 2>&1 &
  local watcher_pid=$!

  sleep 2
  sudo notifyutil -p com.apple.system.timezone
  sleep 2

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  grep -q "com.apple.system.timezone" "$watcher_out"
}

set_zone "$ZONE"
check_zone "$ZONE"

if can_post_darwin_key; then
  echo "root can post com.apple.system.timezone, so the listener case will run"
  zone_after_define=(--dart-define=ZONE_AFTER="$ZONE_AFTER")
else
  echo "::warning::root cannot post com.apple.system.timezone on this runner," \
    "so there is no way to deliver a system timezone change to the app and the" \
    "listener case will skip. Everything else in the suite still runs, including" \
    "the probe that the plugin is registered on the channel."
  zone_after_define=()
fi

# Timed off the sentinel rather than off the process appearing, because the
# process exists well before the suite does: `flutter test` still has to attach,
# and moving the clock through that window is a good way to break an attach.
move_zone_when_listener_is_ready() {
  local attempt=0
  until grep -q "$SENTINEL" "$log" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 900 ]; then
      echo "::warning::the suite never reported its listener ready, so the zone" \
        "was never moved"
      return
    fi
    sleep 1
  done

  echo "moving the machine from $ZONE to $ZONE_AFTER"
  set_zone "$ZONE_AFTER"
}

if [ ${#zone_after_define[@]} -gt 0 ]; then
  move_zone_when_listener_is_ready &
  mover=$!
  trap 'kill "$mover" 2>/dev/null || true' EXIT
fi

# EXPECTED_RAW is deliberately not passed. Foundation reports whichever spelling
# the OS wrote, and macOS is the platform where that genuinely varies: a machine
# set to Asia/Kolkata can report Asia/Calcutta. EXPECTED_ZONE is compared against
# the canonicalized value, which is the same either way.
rc=0
flutter test integration_test -d macos \
  --dart-define=EXPECTED_ZONE="$ZONE" \
  "${zone_after_define[@]}" 2>&1 | tee "$log" || rc=$?

if [ ${#zone_after_define[@]} -gt 0 ]; then
  kill "$mover" 2>/dev/null || true
  wait "$mover" 2>/dev/null || true

  final=$(swift -e 'import Foundation; print(NSTimeZone.local.identifier)')
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
fi

exit "$rc"
