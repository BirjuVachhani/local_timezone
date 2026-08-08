# Runs the device suite as a real Flutter Windows app, and moves the system
# timezone underneath it so the listener has something to hear.
#
# PowerShell rather than sh, for the same reason the `test` job uses it: Git
# Bash rewrites `tzutil`'s `/s` flag into a path and the call silently does the
# wrong thing.
#
# The Windows trigger is WM_TIMECHANGE, which the system broadcasts to top level
# windows. `tzutil /s` reaches it through SetDynamicTimeZoneInformation, which
# is the same path the Settings app takes, so this exercises the real signal
# rather than a synthetic one.

$ErrorActionPreference = 'Stop'

# Native commands must not throw, only cmdlets.
#
# PowerShell 7.4, which is what `shell: pwsh` runs, defaults
# $PSNativeCommandUseErrorActionPreference to true, so a nonzero exit from
# `flutter test` would abort this script on the spot. That would skip the
# post-run zone check below, and that check is what separates "the plugin is
# broken" from "the harness never moved the zone, so the run proved nothing".
# This script reads exit codes itself; let it.
#
# Assigning this on Windows PowerShell 5.1, where the variable does not exist,
# simply creates an unused one.
$PSNativeCommandUseErrorActionPreference = $false

foreach ($name in 'WINDOWS_ZONE', 'WINDOWS_ZONE_AFTER', 'ZONE', 'ZONE_AFTER') {
    if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) {
        Write-Output "::error::$name is not set, the job should have defined it"
        exit 1
    }
}

# The process name of the built app, which is what the mover below waits for.
$app = 'test_host'

function Set-Zone($windowsZone) {
    tzutil /s "$windowsZone"
    $actual = (tzutil /g).Trim()
    if ($actual -ne $windowsZone) {
        Write-Output "::error::wanted $windowsZone, tzutil reports $actual"
        exit 1
    }
}

Set-Zone $env:WINDOWS_ZONE

# Move the zone a second time while the suite is running.
#
# Timed off the app process appearing rather than off a fixed delay, because
# `flutter test` spends most of its wall clock in the C++ build and that varies
# by minutes between runs.
$mover = Start-Job -ArgumentList $app, $env:WINDOWS_ZONE_AFTER -ScriptBlock {
    param($app, $zoneAfter)

    $attempt = 0
    while (-not (Get-Process -Name $app -ErrorAction SilentlyContinue)) {
        $attempt++
        if ($attempt -ge 600) {
            Write-Output "::warning::$app never started, so the zone was never moved"
            return
        }
        Start-Sleep -Seconds 1
    }

    # Margin between the process appearing and the Dart suite reaching
    # setUpAll, where the listener is registered.
    Start-Sleep -Seconds 15

    Write-Output "moving the machine to $zoneAfter"
    tzutil /s "$zoneAfter"
}

# EXPECTED_RAW is the Windows registry key rather than an IANA name, because
# that is what the provider reports as `raw` on this platform. It is the one
# platform where the two genuinely differ by construction, so it is worth
# pinning: a regression that canonicalized correctly from the wrong key would
# pass EXPECTED_ZONE alone.
$rc = 0
flutter test integration_test -d windows `
    --dart-define=EXPECTED_ZONE="$env:ZONE" `
    --dart-define=EXPECTED_RAW="$env:WINDOWS_ZONE" `
    --dart-define=ZONE_AFTER="$env:ZONE_AFTER"
if ($LASTEXITCODE -ne 0) { $rc = $LASTEXITCODE }

Receive-Job $mover
Remove-Job $mover -Force

$final = (tzutil /g).Trim()
if ($final -eq $env:WINDOWS_ZONE) {
    Write-Output ("::error::the machine is still in $env:WINDOWS_ZONE, so the " +
        "harness never moved it to $env:WINDOWS_ZONE_AFTER. Whatever the listener " +
        "case reported above, it was not reporting on a real timezone change.")
    exit 1
}
elseif ($final -ne $env:WINDOWS_ZONE_AFTER) {
    Write-Output ("::error::the run should have ended in " +
        "$env:WINDOWS_ZONE_AFTER and the machine is in '$final', so it moved " +
        "for a reason this script did not choose.")
    exit 1
}

exit $rc
