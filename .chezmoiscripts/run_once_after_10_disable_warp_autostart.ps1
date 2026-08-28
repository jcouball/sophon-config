# Stop Warp launching itself at sign-in.
#
# Warp's installer registers "Warp" under
# HKCU:\Software\Microsoft\Windows\CurrentVersion\Run, so every sign-in opens a
# terminal window nobody asked for. The obvious fix - delete that value - is
# the fragile one: the Run entry belongs to Warp, which re-registers it on
# update or reinstall, and Warp's own settings live in warp.sqlite where
# nothing in this repo can reach (see "Deliberately not managed" in the
# README).
#
# So do what Task Manager's "Disable" button does instead: leave the Run value
# alone and write the veto next to it, in
# HKCU:\...\Explorer\StartupApproved\Run. Explorer consults that key at
# sign-in and skips any entry whose flag byte is odd, no matter what the Run
# key says. Applications write Run and never touch StartupApproved, so the
# veto survives Warp updates - and Task Manager shows the honest state
# ("Warp - Disabled") rather than the entry silently vanishing.
#
# The value format is 12 bytes: a 4-byte little-endian flag (even = enabled,
# odd = disabled; Task Manager writes 3) followed by a FILETIME recording when
# it was disabled.
#
# WRITTEN UNCONDITIONALLY, even if Warp is not installed: Warp is a by-hand
# install on a rebuilt machine (README, "Warp is a personal preference"), and
# a pre-seeded veto is honoured when the Run entry appears later - the
# hand-install stays quiet at sign-in with no follow-up step to remember.
#
# HONEST LIMIT: this does not close a Warp that is already running, and the
# veto is keyed to the value name "Warp" - if Warp ever registers under a
# different name, this script does not know. Launching Warp by hand is
# unaffected; only the sign-in autostart is vetoed.

$path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
if (-not $key) {
    Write-Warning "Could not open or create HKCU:\$path - Warp autostart left as is."
    return
}

try {
    $existing = $key.GetValue('Warp')
    if ($existing -is [byte[]] -and $existing.Length -ge 4 -and ($existing[0] -band 1)) {
        Write-Host 'Warp autostart already disabled - nothing to do'
        return
    }

    $value = [byte[]]::new(12)
    $value[0] = 3
    [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($value, 4)
    $key.SetValue('Warp', $value, [Microsoft.Win32.RegistryValueKind]::Binary)

    $run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\Microsoft\Windows\CurrentVersion\Run')
    $registered = $run -and ($run.GetValueNames() -contains 'Warp')
    if ($run) { $run.Close() }

    if ($registered) {
        Write-Host 'Warp autostart disabled - takes effect at the next sign-in'
    } else {
        Write-Host ('Warp autostart vetoed in advance - Warp is not registered to ' +
                    'run at sign-in on this machine (not installed yet?), but the ' +
                    'veto will apply when it is.')
    }
} finally {
    $key.Close()
}
