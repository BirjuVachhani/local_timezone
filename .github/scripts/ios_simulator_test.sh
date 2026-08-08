#!/usr/bin/env bash
#
# Runs the device suite on an already booted simulator, and puts a bound on the
# one wait that has none of its own.
#
# `flutter test -d <simulator>` learns that the app is up from a single line,
# "Dart VM Service is listening on ...", which it reads off a
# `simctl spawn <udid> log stream` child. The await on that line bottoms out in
# `ProtocolDiscovery.uri`, which is `await uris.first` with no timeout at any
# layer, and the only message before it is a `printTrace`. So when the line
# never arrives the run does not fail and does not say anything: it goes quiet
# and stays quiet until something else kills it. That is a known intermittent
# upstream defect (flutter/flutter#112174, #115985), and on 2026-08-08 one
# occurrence ate this job's entire 45 minute budget and left no evidence behind
# beyond an orphaned `simctl`. Not #153433, which reads like the same report:
# its fix landed as `eagerError: true` in flutter_platform.dart and is already
# in the SDK this job runs, and that path prints on its way down regardless.
#
# So a stall is treated here as its own outcome, distinct from a test failure.
# It is bounded, it is announced, it takes the evidence with it, and it is
# retried once, because upstream is flaky rather than broken. A suite that
# actually ran and failed is never retried: that is a real result and it stands.
set -uo pipefail

: "${SIM_UDID:?SIM_UDID is not set, the boot step should have exported it}"
: "${ZONE:?ZONE is not set, the job should have defined it}"

# A healthy run is roughly three minutes on a CI runner: half a minute of pub
# get, two minutes of Xcode, then the attach. Ten leaves room for a cold build
# without letting a stall run away.
STALL_SECONDS=${STALL_SECONDS:-600}
ATTEMPTS=${ATTEMPTS:-2}

# Note the bare `log` rather than `/usr/bin/log`, in this and every `simctl
# spawn` below. The absolute path names the host binary, which then cannot
# resolve identities inside the guest and bails out with "Must be admin to run
# 'stream' command"; the bare name resolves inside the runtime and works. The
# two are easy to confuse because only one of them is obviously wrong, and it
# is not the one that fails. Flutter itself spawns the bare form, so matching it
# is also what makes this probe a probe of flutter's own channel.
log_stream_delivers() {
  local out
  out=$(mktemp)
  xcrun simctl spawn "$SIM_UDID" log stream --style json \
    --predicate 'eventType = logEvent' >"$out" 2>&1 &
  local probe_pid=$!

  # Stops at the first sign of life rather than at the deadline. The deadline is
  # what a silent device costs, and only a silent device should have to pay it:
  # a healthy one answers in a fraction of a second, and there is no reason to
  # keep buying its output after that. An unfiltered stream is a firehose, and
  # the first version of this probe sat through all eight seconds of it and
  # wrote half a million lines to disk to learn what five would have said.
  local ticks=0
  while [ "$ticks" -lt 32 ]; do
    if [ "$(wc -c <"$out")" -gt 65536 ]; then
      break
    fi
    sleep 0.25
    ticks=$((ticks + 1))
  done

  kill "$probe_pid" 2>/dev/null
  wait "$probe_pid" 2>/dev/null

  local lines
  lines=$(wc -l <"$out" | tr -d '[:space:]')
  if [ "$lines" -lt 5 ]; then
    echo "log stream delivered $lines lines in $((ticks / 4))s:"
    sed 's/^/    /' "$out" | head -5
    rm -f "$out"
    return 1
  fi
  echo "log stream delivered $lines lines"
  rm -f "$out"
  return 0
}

# Printed at the moment the run is given up on, because none of it survives the
# step otherwise. Two of the calls `startApp` makes between the Xcode build and
# the first test are unbounded and print nothing, and from the outside they look
# identical: `installApp`, and the await on the VM Service URL. The orphaned
# `simctl` the runner reports does not separate them either, because the log
# stream that would be the second one is only started between them. What does
# separate them is below. Nothing installed means install never returned;
# installed and running, with the engine's own line sitting in the device log
# that flutter was reading, means the wait is the one at fault.
dump_diagnostics() {
  echo "--- did the app get installed ---"
  xcrun simctl listapps "$SIM_UDID" 2>/dev/null \
    | grep -i "CFBundleIdentifier" | grep -vi "com\.apple\." \
    || echo "nothing but Apple's own bundles, so install never completed"
  echo "--- did the app ever start ---"
  pgrep -fl "Runner.app/Runner" || echo "no Runner process on the host"
  echo "--- did the engine ever log the line the run was waiting for ---"
  xcrun simctl spawn "$SIM_UDID" log show --last 15m --style compact \
    --predicate 'eventMessage CONTAINS "Dart VM Service"' 2>&1 | tail -10
  echo "--- is the log stream delivering at all ---"
  log_stream_delivers || true
}

# Leaves nothing of the previous attempt behind. The log stream is started with
# `start` rather than `run`, so it outlives its parent and would otherwise still
# be attached to the device on the retry.
kill_strays() {
  pkill -f "simctl spawn $SIM_UDID log" 2>/dev/null
  pkill -f "flutter_tools.snapshot test integration_test" 2>/dev/null
  return 0
}

reboot_device() {
  kill_strays
  xcrun simctl shutdown "$SIM_UDID"
  xcrun simctl boot "$SIM_UDID"
  xcrun simctl bootstatus "$SIM_UDID" -b || true
}

# A silent stream is worth one reboot before it is worth failing over. Probes
# are not free of their own flakiness, and this one runs eight seconds after a
# boot, so treating the first reading as final would trade a rare hang for a
# more common false red. Two readings that agree is a real answer: the run that
# would follow does not fail, it hangs, and that is the whole point of this
# script.
ensure_log_stream() {
  if log_stream_delivers; then
    return 0
  fi
  echo "::warning::$SIM_UDID has a silent log stream, rebooting it once"
  reboot_device
  if log_stream_delivers; then
    return 0
  fi
  echo "::error::$SIM_UDID still has a silent log stream after a reboot, and" \
    "that is the only channel flutter reads the VM Service URL from"
  return 1
}

# Returns 124 for a stall and the suite's own status for anything else, so the
# caller can tell "never ran" from "ran and failed" without parsing output.
run_attempt() {
  local attempt=$1
  local marker
  marker=$(mktemp)
  rm -f "$marker"

  # `integration_test`, never `../integration_test`. `flutter test` selects its
  # device backend only for paths starting with `<cwd>/integration_test`, and a
  # path that fails that check is not an error: the run silently falls back to
  # `flutter_tester` on the host, ignores `-d`, builds no app, and never loads
  # `apple.dart` at all. It then passes. That green is the one failure mode this
  # job cannot detect on its own, so the path matters more here than anywhere
  # else. The directory holds a single file that delegates to the suite in the
  # package above it.
  #
  # Asserting the zone is sound despite `simctl` having no timezone command. A
  # simulator does not copy the host's zone, it reads the host's file:
  # `/etc/localtime` inside the device and on the host are the same inode, so
  # the symlink the workflow writes before booting is what Foundation resolves
  # inside the app. `EXPECTED_RAW` matches `EXPECTED_ZONE` because Foundation
  # reports the tail of that symlink verbatim, and the zone the job picks is
  # already the primary spelling, so canonicalization is a no-op.
  # `-r expanded` rather than the default. On GitHub Actions `package:test`
  # selects its `github` reporter, and that reporter prints nothing as tests
  # start: `_onTestStarted` only registers listeners, and everything it has to
  # say waits for completion. A run that stalls before the suite is even loaded
  # and a run that stalls between two tests therefore produce byte-identical
  # output, namely none, which is most of why the failure this script exists for
  # left so little behind. Expanded prints a line per update, so the next one
  # says how far it got. Flutter's own help recommends it for CI.
  flutter test integration_test -d "$SIM_UDID" -r expanded \
    --dart-define=EXPECTED_ZONE="$ZONE" \
    --dart-define=EXPECTED_RAW="$ZONE" &
  local test_pid=$!

  (
    sleep "$STALL_SECONDS"
    kill -0 "$test_pid" 2>/dev/null || exit 0
    : >"$marker"
    echo "::warning::attempt $attempt has not finished after ${STALL_SECONDS}s," \
      "which is long enough past a healthy run to call it the stall"
    dump_diagnostics
    kill -9 "$test_pid" 2>/dev/null
  ) &
  local watchdog_pid=$!

  local rc=0
  wait "$test_pid" || rc=$?
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null

  if [ -f "$marker" ]; then
    rm -f "$marker"
    return 124
  fi
  rm -f "$marker"
  return "$rc"
}

ensure_log_stream || exit 1

attempt=1
while :; do
  rc=0
  run_attempt "$attempt" || rc=$?

  if [ "$rc" -eq 0 ]; then
    exit 0
  fi

  # The suite ran and something in it failed. That is a real answer about the
  # code under test and retrying it would only hide it.
  if [ "$rc" -ne 124 ]; then
    exit "$rc"
  fi

  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    # The kill above lands on the `flutter` wrapper, and the dart process doing
    # the work is its child rather than itself, so it outlives the signal.
    kill_strays
    echo "::error::flutter test did not finish on $SIM_UDID in $ATTEMPTS attempts" \
      "of ${STALL_SECONDS}s. The diagnostics above say which half of startApp it" \
      "stopped in: no bundle installed means install never returned, an installed" \
      "bundle means it was the wait on the VM Service URL."
    exit 1
  fi

  attempt=$((attempt + 1))
  echo "retrying on a fresh boot"
  reboot_device
  ensure_log_stream || exit 1
done
