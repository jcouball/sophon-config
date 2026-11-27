# Keep Tailscale running with nobody signed in to Windows.
#
# Tailscale puts sophon on the tailnet, which is how another machine reaches
# it from outside the LAN. The winget manifest installs it. Installed and left
# alone, it connects only while someone is signed in at the desktop, so after
# a restart sophon would be out of reach until someone signed in. Unattended
# mode keeps the connection up without a desktop session. This script turns it
# on, and makes sure the service starts with Windows.
#
# SIGNING IN IS NOT DONE HERE. It needs a person and a browser:
# `tailscale up --unattended`. The script says so while sophon is signed out,
# and says when Tailscale is disconnected or in some other state. It exits 0
# for all of those: running it again would not sign anyone in.
#
# EXIT 1 WHEN THE WORK IS NOT DONE. chezmoi records a run_onchange script as
# done when it exits 0, and does not run it again until its text changes. So
# Tailscale missing, no elevation, or a setting that did not take, all exit 1,
# and the next apply runs the script again. "Did not take" is judged by
# reading the setting back, not by what the command that set it returned.
#
# THE `after_` ATTRIBUTE IS REQUIRED, as it is for script 11: without it the
# script would run before chezmoi writes the files. The number puts it after
# script 01, which installs Tailscale. On a rebuild Tailscale arrives in this
# same apply, and chezmoi's own PATH is from before it, so the program is
# named by its full path.

$ErrorActionPreference = 'Stop'

$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

# Runs tailscale and returns what it printed, standard error included. Continue,
# not Stop, because Windows PowerShell 5.1 turns anything a native command
# writes to a redirected stderr into a terminating error under Stop.
function Invoke-Tailscale([string[]]$tailscaleArgs) {
    $ErrorActionPreference = 'Continue'
    (& $tailscale @tailscaleArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
}

$service = Get-Service Tailscale -ErrorAction SilentlyContinue
if (-not $service -or -not (Test-Path -LiteralPath $tailscale)) {
    Write-Warning ('Tailscale is not installed - is Tailscale.Tailscale in the winget manifest, ' +
                   'and did script 01 install it? Unattended mode not set; the next apply tries again.')
    exit 1
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning ('Script 16 needs an elevated terminal: it changes the Tailscale service ' +
                   'and its settings. Run `chezmoi apply` again from an elevated terminal.')
    exit 1
}

if ($service.StartType -ne 'Automatic') {
    Write-Host "Setting the Tailscale service to start with Windows (it was $($service.StartType))"
    Set-Service -Name Tailscale -StartupType Automatic
}
if ($service.Status -ne 'Running') {
    Write-Host 'Starting the Tailscale service'
    Start-Service Tailscale
}

# The service takes a moment to answer after it starts. `tailscale set` is
# tried until it does. Setting a value that is already set changes nothing.
$set = ''
$done = $false
foreach ($try in 1..10) {
    $set = Invoke-Tailscale @('set', '--unattended=true')
    if ($LASTEXITCODE -eq 0) { $done = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $done) {
    # The first line only: on a bad flag tailscale prints its whole usage.
    Write-Warning ("tailscale set --unattended=true failed - unattended mode not set. It said: " +
                   "$(@($set -split "`n")[0])")
    exit 1
}

# What `tailscale set` returned is not the outcome. A system policy can hold a
# setting at another value, and the command still succeeds. So the setting is
# read back. Tailscale calls it ForceDaemon, and `debug prefs` is the one
# command that prints it, which is also what the certification check reads.
$prefs = Invoke-Tailscale @('debug', 'prefs')
if ($prefs -notmatch '"ForceDaemon"\s*:\s*true') {
    Write-Warning ('tailscale set --unattended=true succeeded and unattended mode is not on: ' +
                   '`tailscale debug prefs` does not show "ForceDaemon": true. A system policy ' +
                   'may be holding it off. The next apply tries again.')
    exit 1
}

$service = Get-Service Tailscale
if ($service.Status -ne 'Running' -or $service.StartType -ne 'Automatic') {
    Write-Warning "The Tailscale service is $($service.Status), $($service.StartType), not Running, Automatic."
    exit 1
}

# The state is read from the JSON, not from the exit code: `tailscale status`
# exits 1 on a machine that is signed out.
$state = ''
if ((Invoke-Tailscale @('status', '--json')) -match '"BackendState"\s*:\s*"([^"]*)"') { $state = $Matches[1] }
#
# Only NeedsLogin means nobody is signed in. Stopped is a machine that was
# disconnected, with `tailscale down`, and connects again with no browser.
# Anything else, such as Starting, is said as it is, with no advice.
if ($state -eq 'NeedsLogin') {
    Write-Warning ('Tailscale is not signed in on this machine. Sign in, and approve the address ' +
                   'it prints in a browser: tailscale up --unattended. Then turn off key expiry ' +
                   'for this machine in the admin console.')
} elseif ($state -eq 'Stopped') {
    Write-Warning ('Tailscale is disconnected on this machine, so it is off the tailnet. ' +
                   'Connect it: tailscale up --unattended')
} elseif ($state -ne 'Running') {
    Write-Warning ("Tailscale is in state '$state', not Running. If it stays there, look at: " +
                   'tailscale status')
}
exit 0
