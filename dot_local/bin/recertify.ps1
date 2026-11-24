# Run the re-certification: rebuild the certification VM from its clean
# checkpoint, check the result, and bring the logs back.
#
#   & "$HOME\.local\bin\recertify.ps1"                    # certify main
#   & "$HOME\.local\bin\recertify.ps1" -Branch my-branch  # certify a branch before it merges
#
# Run it on sophon, elevated: at the desktop from an elevated terminal, or
# over ssh, where the session is elevated already. It takes about an hour and
# needs nobody once it has started. See "Re-certify the rebuild" in the README.
#
# WHAT IT DOES
#
#   1. Restores the VM's clean checkpoint and waits for the VM to answer.
#      Prints how long the VM's evaluation licence has left, and warns when
#      it is under 30 days.
#   2. Runs "Rebuild from nothing" from the README inside the VM, each part
#      in a new process, as a person would in a new terminal:
#        install-chezmoi   winget install twpayne.chezmoi --source winget
#        apply             chezmoi init --apply --branch <branch> <repo>  (elevated)
#        terminal          open Windows Terminal once, then chezmoi apply twice
#        checks            recertify-checks.ps1, in a new shell (elevated)
#   3. Copies every log and the check results to ~\cert\<time>-<branch>.
#   4. Prints which steps and checks passed. Exit code 0 only if all did.
#   5. Writes result.json there: the verdict, what was built and the count of
#      checks. record.ps1 reads it to record a CERTIFIED run as a tag.
#
# ONE DEPARTURE FROM THE README. Its command clones stable, the branch that
# holds what has been certified. This clones what is about to be: main, or the
# branch named with -Branch. Once a run is recorded, stable is moved to the
# commit it built, and the README's command then clones the same files.
#
# Only one run at a time: a second for the same VM refuses to start.
#
# The VM is left running as the rebuild left it, to be looked at. The next
# run restores the checkpoint again.
#
# HOW IT REACHES THE VM. PowerShell Direct, which needs no network: the VM's
# firewall blocks ssh. A PowerShell Direct session has no desktop, and parts
# of the rebuild need one: installers that open a window, Windows Terminal
# writing its settings, a font loaded into the session. So the session is used
# only to start each step and to read its log. The step itself runs as a
# scheduled task in the desktop session of the signed-in user. That depends on
# the checkpoint having been taken while signed in, which the README requires
# for another reason.
#
# A STEP THAT STOPS. recertify-step.ps1 says why a step's output goes to a
# file and its input stays the console. A step whose log has not grown for
# -StallMinutes has stopped to ask something, or hung: it is reported as
# stalled, with the last lines of its log, and the run ends there. Nothing is
# answered for it. A rebuild that needs an answer has failed.
#
# THE PASSWORD. PowerShell Direct needs the guest account's password. It is
# taken from -Credential, or as recertify-vm.ps1 says: from a file, or asked
# for. The password is never written to a log.
#
# recertify-vm.ps1, in this folder, holds what this script shares with
# recertify-checkpoint.ps1, which makes the checkpoint this one restores.
#
# It runs under Windows PowerShell 5.1 and pwsh 7.

param(
    # A branch to build from, to certify a change before it merges.
    # Both of these end up on a command line that runs elevated in the VM, so
    # only the characters a branch or a repository address can have are let in.
    [ValidatePattern('^[\w][\w./-]*$')][string]$Branch,
    [ValidatePattern('^[\w][\w.@:/-]*$')][string]$Repo = 'jcouball/windows-dev-config',
    [string]$VMName = 'sophon-cert',
    [string]$Checkpoint = 'clean-windows',
    [string]$User = 'certuser',
    [pscredential]$Credential,
    # Where each run's folder is made.
    [string]$OutRoot = (Join-Path $HOME 'cert'),
    # A step whose log has not grown for this long is taken to have stopped.
    [int]$StallMinutes = 30,
    # No single step may take longer than this.
    [int]$StepMinutes = 120,
    # Use the VM as it is, without restoring the checkpoint. For trying this
    # script. Such a run is never reported as certified, whatever it finds.
    [switch]$NoRestore
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'recertify-vm.ps1')

if (-not (Test-RecertifyElevated)) {
    Write-Warning 'Run this elevated: without that, Hyper-V shows no virtual machines.'
    exit 1
}

if (-not $Credential) { $Credential = Get-RecertifyCredential -User $User -VMName $VMName }

# One run at a time for a VM. A second one would restore the checkpoint under
# the first, and both would report on a machine neither of them built.
$lock = Enter-RecertifyLock -VMName $VMName
if (-not $lock) {
    Write-Warning "Another re-certification of $VMName is running, or its checkpoint is being made. Wait for it to finish: a certification's log is the newest folder under $OutRoot."
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$label = if ($Branch) { $Branch -replace '[^\w.-]', '-' } else { 'main' }
$out = Join-Path $OutRoot "$stamp-$label"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$hostLog = Join-Path $out 'recertify.log'

function Write-Line {
    param([string]$Text)
    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text"
    Write-Host $line
    Add-Content -Path $hostLog -Value $line -Encoding UTF8
}

# Run a script block in the VM. A new connection each time: a rebuild restarts
# services and a long-lived session does not always survive it.
function Invoke-InVM {
    param([scriptblock]$Script, [object[]]$Arguments)
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $Script -ArgumentList $Arguments
}

Write-Line "Re-certifying $Repo, branch $(if ($Branch) { $Branch } else { 'main' }), on $VMName"
Write-Line "Results: $out"

# --- 1. the clean machine ---------------------------------------------------

if ($NoRestore) {
    Write-Line 'NOT restoring the checkpoint (-NoRestore): this run certifies nothing'
} else {
    Write-Line "Restoring the checkpoint $Checkpoint"
    Restore-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false
}
if ((Get-VM -Name $VMName).State -ne 'Running') {
    Write-Line 'Starting the VM'
    Start-VM -Name $VMName
}

Write-Line 'Waiting for the VM to answer'
$problem = Wait-RecertifyVM -VMName $VMName -Credential $Credential
if ($problem -like 'refused:*') {
    Write-Line "The VM refused the sign-in: $($problem -replace '^refused: ', '')"
    exit 1
}
if ($problem) {
    Write-Line "The VM did not answer: $problem"
    exit 1
}

# The steps run in $User's desktop session, so $User has to be signed in.
$signedIn = Wait-RecertifySignIn -VMName $VMName -Credential $Credential -User $User -OnWait {
    Write-Line "$User is not signed in at the VM's desktop. Waiting up to 10 minutes: sign in as $User with vmconnect."
}
if (-not $signedIn) {
    Write-Line "$User is still not signed in. The checkpoint has to be taken while signed in; see 'The certification VM' in the README."
    exit 1
}

$facts = Invoke-InVM {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        Dir   = Join-Path $env:USERPROFILE 'recertify'
        Text  = "$($os.Caption) build $($os.BuildNumber), user $env:USERNAME, computer $env:COMPUTERNAME"
        Stale = [bool](Get-Command chezmoi -ErrorAction SilentlyContinue)
    }
}
$dir = $facts.Dir
Write-Line "The VM: $($facts.Text)"
if ($facts.Stale -and -not $NoRestore) {
    Write-Line 'chezmoi is already installed in the VM, so this is not a clean machine. Stopping.'
    exit 1
}

# What Windows' own servicing is up to. A restored VM whose checkpoint lacks
# the month's updates starts installing them, and an update installed while
# the rebuild runs makes script 11's Add-WindowsCapability fail with
# 0x800f0950. The first run of this script failed that way: two updates went
# in during the apply. So the VM's checkpoint has automatic updates turned
# off (see "The certification VM" in the README), and this says, before the
# rebuild, whether that still holds and what is waiting, and after it, what
# was installed anyway.
function Get-Servicing {
    Invoke-InVM {
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                   (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $waiting = @()
        try {
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            foreach ($update in $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates) {
                # 0 is "never needs a restart": the daily antivirus definitions.
                if ($update.InstallationBehavior.RebootBehavior -ne 0) { $waiting += $update.Title }
            }
        } catch {
            $waiting = @("could not ask Windows Update: $($_.Exception.Message)")
        }
        $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            RestartPending = [bool]$pending
            Waiting        = $waiting
            Installed      = @(Get-HotFix | ForEach-Object { $_.HotFixID })
            AutomaticOff   = ($policy -and $policy.NoAutoUpdate -eq 1)
        }
    }
}

$before = Get-Servicing
if (-not $before.AutomaticOff) {
    Write-Line 'WARNING: automatic updates are ON in the VM. An update installed during the rebuild can make script 11 fail.'
    Write-Line "         See 'The certification VM' in the README for how the checkpoint is meant to be set up."
}
if ($before.Waiting) {
    Write-Line "Windows Update has $(@($before.Waiting).Count) update(s) not installed that may ask for a restart:"
    foreach ($title in $before.Waiting) { Write-Line "    $title" }
}
# Reported, not acted on: the checkpoint has carried a pending restart since
# it was made, and rebuilds have passed with it.
Write-Line "Restart pending in the VM before the rebuild: $($before.RestartPending)"

# The evaluation licence. A restore puts the licence back to what the
# checkpoint holds, so this is the checkpoint's licence, less the days since
# it was made. Once it runs out the VM shuts down every hour, which is about
# as long as a run takes. Reported, and warned about in time to act: this
# script never rearms and never replaces the checkpoint, because the
# checkpoint is what every certification is measured against.
$licence = $null
$licenceRead = $true
try {
    $licence = Get-RecertifyLicence -VMName $VMName -Credential $Credential
} catch {
    $licenceRead = $false
    Write-Line "Could not read the VM's licence: $($_.Exception.Message)"
}
if ($licence) {
    Write-Line "The VM's evaluation licence: $($licence.Days) day(s) left, $($licence.Rearms) rearm(s) left"
    if (-not $licence.Licensed) {
        Write-Line 'WARNING: the licence is not in force. An expired evaluation shuts the VM down every hour.'
    }
    if ($licence.Days -lt 30) {
        if ($licence.Rearms -gt 0) {
            Write-Line 'WARNING: under 30 days. Extend it, in a new checkpoint, when no certification is running:'
            Write-Line '           & "$HOME\.local\bin\recertify-checkpoint.ps1" -Rearm'
        } else {
            Write-Line "WARNING: under 30 days and no rearm is left. The VM has to be rebuilt from the ISO: see 'The certification VM' in the README."
        }
    }
} elseif ($licenceRead) {
    Write-Line 'The VM reports no Windows licence to read.'
}

$session = New-PSSession -VMName $VMName -Credential $Credential
try {
    Invoke-Command -Session $session { param($dir) Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $dir | Out-Null } -ArgumentList $dir
    Copy-Item -ToSession $session -Path (Join-Path $PSScriptRoot 'recertify-step.ps1') -Destination $dir
} finally {
    Remove-PSSession $session
}

# --- 2. the rebuild, one step at a time -------------------------------------

# Start one step in the VM's desktop session and follow its log until it is
# done, has stalled or has run out of time. Returns 'ok', or why not.
function Invoke-Step {
    param([string]$Step, [switch]$Elevated)

    Write-Line "--- $Step$(if ($Elevated) { ' (elevated)' })"
    Invoke-InVM {
        param($dir, $step, $user, $elevated, $repo, $branch)
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$dir\recertify-step.ps1`" -Step $step -Dir `"$dir`" -Repo $repo"
        if ($branch) { $arguments += " -Branch $branch" }
        $task = "recertify-$step"
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        # Interactive: in the session of the user who is signed in, where
        # there is a desktop. Highest is an elevated terminal; Limited is an
        # ordinary one.
        $level = if ($elevated) { 'Highest' } else { 'Limited' }
        $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$user" -LogonType Interactive -RunLevel $level
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $task
    } -Arguments $dir, $Step, $User, [bool]$Elevated, $Repo, $Branch

    $offset = 0
    $started = Get-Date
    $lastGrowth = Get-Date
    $lost = 0
    while ($true) {
        Start-Sleep 15
        try {
            $state = Invoke-InVM {
                param($dir, $step, $offset)
                $log = Join-Path $dir "$step.log"
                $text = ''
                $length = 0
                if (Test-Path $log) {
                    $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
                    try {
                        $length = $stream.Length
                        if ($length -gt $offset) {
                            $stream.Position = $offset
                            $bytes = New-Object byte[] ($length - $offset)
                            [void]$stream.Read($bytes, 0, $bytes.Length)
                            $text = [Text.Encoding]::UTF8.GetString($bytes)
                        }
                    } finally {
                        $stream.Dispose()
                    }
                }
                $doneFile = Join-Path $dir "$step.done"
                $done = if (Test-Path $doneFile) { [IO.File]::ReadAllText($doneFile).Trim() } else { $null }
                [pscustomobject]@{ Length = $length; Text = $text; Done = $done }
            } -Arguments $dir, $Step, $offset
            $lost = 0
        } catch {
            # The VM does not answer for a moment while a rebuild restarts a
            # service. Give up only if it stays that way.
            $lost++
            if ($lost -ge 20) { return "lost contact with the VM: $($_.Exception.Message)" }
            continue
        }

        if ($state.Length -gt $offset) {
            $offset = $state.Length
            $lastGrowth = Get-Date
            # A progress bar redraws one line with carriage returns. Keep what
            # the line ended as.
            foreach ($line in ($state.Text -split "`n")) {
                $line = ($line -split "`r" | Where-Object { $_.Trim() } | Select-Object -Last 1)
                if ($line) { Write-Line "    $line" }
            }
        }
        if ($null -ne $state.Done) {
            if ($state.Done -eq '0') { return 'ok' }
            return "exit $($state.Done)"
        }
        if (((Get-Date) - $lastGrowth).TotalMinutes -ge $StallMinutes) {
            return "stalled: no output for $StallMinutes minutes. It may be waiting for an answer; look at the VM's desktop."
        }
        if (((Get-Date) - $started).TotalMinutes -ge $StepMinutes) {
            return "ran out of time: more than $StepMinutes minutes"
        }
    }
}

$steps = @(
    @{ Name = 'install-chezmoi'; Elevated = $false },
    @{ Name = 'apply'; Elevated = $true },
    @{ Name = 'terminal'; Elevated = $true },
    @{ Name = 'checks'; Elevated = $true }
)
$outcomes = [ordered]@{}
foreach ($step in $steps) {
    $outcome = Invoke-Step -Step $step.Name -Elevated:$step.Elevated
    $outcomes[$step.Name] = $outcome
    Write-Line "--- $($step.Name): $outcome"
    # The checks are what say whether the machine came out right, so a failed
    # apply does not stop them from being run and recorded. A step that never
    # finished does: the next one would run beside it.
    if ($outcome -notmatch '^(ok|exit )') { break }
    if ($step.Name -eq 'install-chezmoi' -and $outcome -ne 'ok') { break }
}

$after = $null
try { $after = Get-Servicing } catch { Write-Line "Could not ask the VM about Windows Update: $($_.Exception.Message)" }

# --- 3. the logs --------------------------------------------------------------

Write-Line 'Copying the logs out of the VM'
try {
    $session = New-PSSession -VMName $VMName -Credential $Credential
    try {
        Copy-Item -FromSession $session -Path (Join-Path $dir '*') -Destination $out -Recurse -Force
    } finally {
        Remove-PSSession $session
    }
} catch {
    Write-Line "Could not copy the logs: $($_.Exception.Message). They are in $dir in the VM."
}

# --- 4. the verdict -----------------------------------------------------------

$failed = $false
Write-Line ''
foreach ($step in $steps) {
    $outcome = if ($outcomes.Contains($step.Name)) { $outcomes[$step.Name] } else { 'not run' }
    if ($outcome -ne 'ok') { $failed = $true }
    Write-Line ("{0,-16} {1}" -f $step.Name, $outcome)
}

$checks = @()
$bad = @()
$checksFile = Join-Path $out 'checks.json'
if (Test-Path $checksFile) {
    # Windows PowerShell hands a JSON array on as one object. Piping it
    # through ForEach-Object makes it a list in both PowerShells.
    $checks = @((Get-Content $checksFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    $bad = @($checks | Where-Object { -not $_.pass })
    Write-Line ''
    Write-Line "$($checks.Count - $bad.Count) of $($checks.Count) checks passed"
    foreach ($check in $bad) {
        $failed = $true
        Write-Line "FAIL  $($check.name)"
        Write-Line "      expected: $($check.expect)"
        Write-Line "      found:    $($check.found)"
    }
} else {
    $failed = $true
    Write-Line 'There are no check results.'
}

if ($after) {
    $new = @($after.Installed | Where-Object { $before.Installed -notcontains $_ })
    Write-Line ''
    if ($new) {
        Write-Line "Windows installed updates during the run: $($new -join ', ')."
        if ($failed) {
            Write-Line 'An update installed during the rebuild makes Add-WindowsCapability fail (0x800f0950), which stops the apply at script 11.'
            Write-Line "If that is what failed, the rebuild was not at fault. See 'The certification VM' in the README, and run this again."
        }
    } else {
        Write-Line 'Windows installed no updates during the run.'
    }
}

# --- 5. the result, for record.ps1 --------------------------------------------

# The commit and the tree the VM built, from the file the terminal step wrote.
$builtCommit = ''
$builtTree = ''
$builtFile = Join-Path $out 'built.txt'
if (Test-Path $builtFile) {
    $builtLines = @(Get-Content $builtFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9a-f]{40}$' })
    if ($builtLines.Count -eq 2) {
        $builtCommit = $builtLines[0]
        $builtTree = $builtLines[1]
    }
}
if (-not $builtCommit) {
    # Passing every check certifies nothing if the commit that passed is not
    # known.
    $failed = $true
    Write-Line ''
    Write-Line 'The commit the VM built could not be read. The apply may have failed before the clone.'
} else {
    Write-Line ''
    Write-Line "Built: commit $builtCommit"
    Write-Line "       tree   $builtTree"
}

$verdict = if ($NoRestore) { 'NOT A CERTIFICATION' } elseif ($failed) { 'NOT CERTIFIED' } else { 'CERTIFIED' }
$resultObject = [ordered]@{
    verdict      = $verdict
    repo         = $Repo
    branch       = $(if ($Branch) { $Branch } else { 'main' })
    commit       = $builtCommit
    tree         = $builtTree
    # What the clean machine was, for the tag. A tag made from this run must
    # not read as more than it was.
    machine      = "VM $VMName from checkpoint $Checkpoint, $($facts.Text)"
    checksPassed = $(if ($checks) { $checks.Count - $bad.Count } else { 0 })
    checksTotal  = $(if ($checks) { $checks.Count } else { 0 })
    started      = $stamp
}
[IO.File]::WriteAllText((Join-Path $out 'result.json'), ($resultObject | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

Write-Line ''
if ($NoRestore) {
    # Whatever passed, it passed on a machine that was not rebuilt from the
    # clean checkpoint.
    $summary = if ($failed) { 'It also failed.' } else { 'Its steps and checks passed.' }
    Write-Line "NOT A CERTIFICATION: the checkpoint was not restored (-NoRestore). $summary The logs are in $out"
    exit 2
}
if ($failed) {
    Write-Line "NOT CERTIFIED. The logs are in $out"
    exit 1
}
Write-Line "CERTIFIED. The logs are in $out"
Write-Line ''
if ($Branch) {
    Write-Line "To record this certification: merge $Branch, run 'chezmoi update' on sophon, then"
} else {
    Write-Line "To record this certification: run 'chezmoi update' on sophon if its source is not at $builtCommit, then"
}
Write-Line "  & `"`$HOME\.local\bin\record.ps1`" -Log '$out'"
exit 0
