#!/bin/sh
#
# Runs the device suite as a real macOS app, and moves the system timezone
# underneath it so the listener has a genuine notification to hear.
#
# The Apple half of the listener cannot be proved any other way. An app cannot
# change the system timezone: there is no supported API for it at all, and the
# admin tool used below needs root. So the mutation has to come from outside the
# process, exactly as it does for Android over adb.

set -eu

: "${ZONE:?ZONE must name the timezone to configure}"
: "${ZONE_AFTER:?ZONE_AFTER must name the timezone to move to mid-run}"

# The process name of the built app, which is what the mover below waits for.
APP=test_host

# Do not be tempted to relink /etc/localtime instead.
#
# `sudo ln -sfh /var/db/timezone/zoneinfo/<zone> /etc/localtime` is what the
# macOS cells in the `test` job use, and it is correct for what they need: it
# moves the zone that Foundation *reads*. It is useless here. It mutates the
# filesystem and nothing else, so nothing posts `com.apple.system.timezone`, no
# NSSystemTimeZoneDidChangeNotification is delivered, and every running process
# keeps the zone it already cached. The listener would never fire and the
# failure would look exactly like a broken plugin.
#
# `systemsetup -settimezone` goes through the privileged admin framework, which
# updates the preference store and the symlink *and* posts the notification.
# That is the whole reason this script exists rather than reusing the one liner
# above.
set_zone() {
  if ! sudo systemsetup -settimezone "$1" >/dev/null 2>&1; then
    echo "::error::systemsetup could not set the zone to $1. It fails this way" \
      "when automatic time zone detection is enabled, and when the name is not" \
      "one it accepts."
    exit 1
  fi
}

# Its accepted spellings are not the whole tz database. Identifiers exist that
# `-gettimezone` will report back but `-listtimezones` does not offer, so a name
# that works everywhere else in this repository can still be rejected here.
# Check both up front rather than discovering it halfway through a run.
accepted=$(sudo systemsetup -listtimezones)
for candidate in "$ZONE" "$ZONE_AFTER"; do
  if ! echo "$accepted" | tr -d ' ' | grep -qx "$candidate"; then
    echo "::error::systemsetup does not accept '$candidate'. Pick one from" \
      "\`sudo systemsetup -listtimezones\`; it is narrower than tzdb."
    exit 1
  fi
done

set_zone "$ZONE"

# Read it back rather than trusting the setter, for the same reason the Android
# script does: a zone that did not take makes every assertion below vacuous.
actual=$(sudo systemsetup -gettimezone | sed 's/^Time Zone: //')
if [ "$actual" != "$ZONE" ]; then
  echo "::error::wanted $ZONE, the machine reports '$actual'"
  exit 1
fi

# Move the zone a second time while the suite is running.
#
# Timed off the app process appearing rather than off a fixed delay, because
# `flutter test` spends most of its wall clock in Xcode and that varies by
# minutes between runs. A fixed sleep either fires before any listener exists or
# burns the job timeout waiting.
move_zone_when_app_starts() {
  attempt=0
  until pgrep -x "$APP" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 600 ]; then
      echo "::warning::$APP never started, so the zone was never moved and the" \
        "listener case will fail on its timeout rather than on a verdict"
      return
    fi
    sleep 1
  done

  # Margin between the process appearing and the Dart suite reaching setUpAll,
  # where the listener is registered. The cases that assert on $ZONE run first
  # and take milliseconds, so this only has to outlast engine startup.
  sleep 15

  echo "moving the machine from $ZONE to $ZONE_AFTER"
  set_zone "$ZONE_AFTER"
}

move_zone_when_app_starts &
mover=$!
trap 'kill "$mover" 2>/dev/null || true' EXIT

# EXPECTED_RAW is deliberately not passed. Foundation reports whichever spelling
# the OS wrote, and macOS is the platform where that genuinely varies: a machine
# set to Asia/Kolkata can report Asia/Calcutta. EXPECTED_ZONE is compared against
# the canonicalized value, which is the same either way, so it is the only one of
# the two that can be asserted here without pinning a spelling this script does
# not control.
rc=0
flutter test integration_test -d macos \
  --dart-define=EXPECTED_ZONE="$ZONE" \
  --dart-define=ZONE_AFTER="$ZONE_AFTER" || rc=$?

kill "$mover" 2>/dev/null || true
wait "$mover" 2>/dev/null || true

final=$(sudo systemsetup -gettimezone | sed 's/^Time Zone: //')
if [ "$final" = "$ZONE" ]; then
  echo "::error::the machine is still in $ZONE, so the harness never moved it" \
    "to $ZONE_AFTER. Whatever the listener case reported above, it was not" \
    "reporting on a real system timezone change."
  exit 1
elif [ "$final" != "$ZONE_AFTER" ]; then
  echo "::error::the run should have ended in $ZONE_AFTER and the machine is" \
    "in '$final', so it moved for a reason this script did not choose and the" \
    "result above says nothing about the plugin."
  exit 1
fi

exit "$rc"
