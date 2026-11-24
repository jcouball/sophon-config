# Make a new clean checkpoint of the certification VM from an existing one.
#
#   & "$HOME\.local\bin\recertify-checkpoint.ps1"           # a new clean-windows from the current one
#   & "$HOME\.local\bin\recertify-checkpoint.ps1" -Rearm    # the same, with the evaluation licence extended first
#
# Run it on sophon, elevated: at the desktop from an elevated terminal, or
# over ssh, where the session is elevated already. Not while a certification
# is running: the two share the VM, and this refuses to start beside one. See
# "The certification VM" in the README.
#
# WHAT A CHECKPOINT HAS TO BE. recertify.ps1 restores the checkpoint named
# clean-windows and rebuilds the machine from there. So the checkpoint is:
#
#   - a Standard checkpoint, taken while certuser is signed in. It captures
#     memory, so a restore lands on a live desktop, and recertify.ps1 runs
#     each step as a task in that session. One taken at the sign-in screen is
#     useless.
#   - clean: nothing the rebuild installs.
#   - set not to update itself. An update installed during a rebuild makes
#     script 11 fail with 0x800f0950.
#   - taken while Windows' own servicing is idle. A checkpoint taken while it
#     is busy resumes in the middle of that work on every restore.
#
# WHAT IT DOES
#
#   1. Stops if a checkpoint name it will use is held by more than one
#      checkpoint. Hyper-V allows that, and a restore by name is then a guess.
#   2. Restores the source checkpoint and says which it was and when it was
#      made.
#   3. Waits for the VM to answer and for the desktop.
#      With -Rearm: extends the licence here. See below.
#   4. Sets the update policy, and tells the two update services to stop, so
#      that a scan the restore set off does not carry on. They start again
#      when asked.
#   5. Checks the state. It takes no checkpoint unless all of this holds:
#        - the guest account is signed in at the desktop
#        - chezmoi is not installed, and its source folder does not exist
#        - the OpenSSH server capability is not present
#        - the update policy reads back as set
#        - automatic sign-in is off, and no password is stored for it
#   6. Waits for servicing to go quiet: no TiWorker process for a full
#      -QuietMinutes, within -QuietLimitMinutes. This comes after the checks
#      because asking Windows about a capability starts servicing itself.
#      Then looks again at whether the account is signed in.
#   7. Takes the new checkpoint under a temporary name. Only then renames the
#      checkpoint that had the new name to <name>-<the date it was made>, and
#      renames the new one. If taking the checkpoint fails, the old one still
#      has its name and recertify.ps1 still works. If the new one cannot be
#      given its name, the old one is given its name back.
#   8. Prints what it checked, the checkpoints that now exist with each one's
#      parent, and the size of the VM's folder.
#
# The checks in step 5 do not prove the VM is clean. They look for three
# things out of everything a rebuild installs. The new checkpoint is clean
# because its source was, which is why step 2 names the source. The checks
# catch some wrong sources, not all.
#
# IT NEVER DELETES A CHECKPOINT. Each one kept holds a memory image of the VM
# and a differencing disk. Step 8 prints the folder's size; removing old
# checkpoints is a decision for a person.
#
# -Rearm: THE EVALUATION LICENCE. The image is Windows Enterprise Evaluation.
# It runs 90 days, and `slmgr /rearm` starts another 90 a limited number of
# times. A restore puts the licence back with everything else, so a rearm
# lasts only if a checkpoint captures it. That is what -Rearm is for.
#
# A rearm needs a restart, and a restart ends the signed-in session the
# checkpoint depends on. Automatic sign-in is the only way back to a
# signed-in desktop without a person, so -Rearm turns it on for the one
# restart and off again:
#
#   a. Reads the licence. Stops if no rearm is left. Stops if more than 30
#      days remain, unless -Force is given: a rearm starts 90 days from the
#      day it runs, so an early one throws the remaining days away.
#   b. Turns on automatic sign-in for the guest account.
#   c. Runs `slmgr /rearm`.
#   d. Shuts the VM down and starts it, and waits for the desktop.
#   e. Reads the licence again. Stops unless the days went up and the rearms
#      went down by one.
#   f. Turns automatic sign-in off and removes the stored password.
#
# Automatic sign-in is turned off so that the checkpoint matches a new
# machine, which has none. Keeping the password secret is not the reason: it
# opens nothing but this VM and is already in a plain file on the host. A
# checkpoint captures memory, so removing the registry value does not prove
# the password is absent from the checkpoint. That is accepted.
#
# The restart changes more than the licence: it finishes whatever restart was
# pending in the source. The script prints whether one was pending before and
# after.
#
# If -Rearm stops partway, the VM is left as it is, possibly with automatic
# sign-in on. No checkpoint has been taken, so nothing lasts: the next
# restore of any checkpoint puts the VM back.
#
# It runs under Windows PowerShell 5.1 and pwsh 7.

param(
    # The checkpoint to start from.
    [string]$SourceCheckpoint = 'clean-windows',
    # The name the new checkpoint ends up with. A checkpoint that has it
    # already is kept, renamed to <name>-<the date it was made>.
    [ValidatePattern('^[\w][\w .-]*$')][string]$NewName = 'clean-windows',
    [string]$VMName = 'sophon-cert',
    # The guest account: the one signed in at the VM's desktop, whose profile
    # is checked and which -Rearm signs in again.
    [string]$User = 'certuser',
    # That account's password, to give in place of the password file. It has
    # to be for -User: the checks run as this account and look at its profile.
    [pscredential]$Credential,
    # Extend the evaluation licence before the checkpoint is taken.
    [switch]$Rearm,
    # With -Rearm: rearm although more than 30 days remain.
    [switch]$Force,
    # Use the VM as it is, without restoring the source. For trying the
    # refusals on a VM that is not clean. Refused when the new name is
    # clean-windows: the real checkpoint is only ever made from a restore.
    [switch]$NoRestore,
    # Servicing counts as quiet after this long with no TiWorker process.
    [ValidateRange(1, 1440)][int]$QuietMinutes = 1,
    # How long to wait for that before giving up.
    [ValidateRange(1, 1440)][int]$QuietLimitMinutes = 20,
    # Where the log is written.
    [string]$OutRoot = (Join-Path $HOME 'cert')
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'recertify-vm.ps1')

if (-not (Test-RecertifyElevated)) {
    Write-Warning 'Run this elevated: without that, Hyper-V shows no virtual machines.'
    exit 1
}
if ($NoRestore -and $NewName -eq 'clean-windows') {
    Write-Warning '-NoRestore is for trying this script. It will not make clean-windows from a VM it did not restore: give -NewName.'
    exit 1
}
if ($Force -and -not $Rearm) {
    Write-Warning '-Force only means something with -Rearm.'
    exit 1
}

if (-not $Credential) { $Credential = Get-RecertifyCredential -User $User -VMName $VMName }
# A credential for another account would have the checks look at that
# account's profile, and -Rearm set automatic sign-in for $User with that
# account's password. The name may come with a machine in front of it.
$credentialUser = $Credential.UserName -replace '^.*\\', ''
if ($credentialUser -ne $User) {
    Write-Warning "The credential is for '$($Credential.UserName)' and -User is '$User'. They have to be the same account."
    exit 1
}

$lock = Enter-RecertifyLock -VMName $VMName
if (-not $lock) {
    Write-Warning "A certification of $VMName is running, or another checkpoint is being made. Wait for it to finish."
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
$hostLog = Join-Path $OutRoot "checkpoint-$stamp.log"

function Write-Line {
    param([string]$Text)
    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text"
    Write-Host $line
    Add-Content -Path $hostLog -Value $line -Encoding UTF8
}

# Say why, and stop. Nothing that lasts has been changed unless the message
# says so: until step 7 the only checkpoint touched is the one restored from.
function Stop-Checkpoint {
    param([string]$Why)
    Write-Line "STOPPED: $Why"
    Write-Line 'No checkpoint was taken.'
    exit 1
}

function Invoke-InVM {
    param([scriptblock]$Script, [object[]]$Arguments)
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $Script -ArgumentList $Arguments
}

function Get-RestartPending {
    Invoke-InVM {
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
}

function Format-Licence {
    param($Licence)
    "$($Licence.Days) day(s) left ($($Licence.Minutes) minutes), $($Licence.Rearms) rearm(s) left, " +
        $(if ($Licence.Licensed) { 'in force' } else { 'NOT in force' })
}

Write-Line "Making the checkpoint '$NewName' of $VMName from '$SourceCheckpoint'$(if ($Rearm) { ', with a rearm' })"
Write-Line "Log: $hostLog"

# --- 1. the names -------------------------------------------------------------

$vm = Get-VM -Name $VMName
# A Production checkpoint holds no memory, so a restore of one lands on a
# machine that is starting up, with nobody signed in.
if ("$($vm.CheckpointType)" -ne 'Standard') {
    Stop-Checkpoint "$VMName makes $($vm.CheckpointType) checkpoints, and this needs Standard ones, which hold memory. Set-VM -Name $VMName -CheckpointType Standard"
}

$all = @(Get-VMCheckpoint -VMName $VMName)
$sources = @($all | Where-Object { $_.Name -eq $SourceCheckpoint })
$olds = @($all | Where-Object { $_.Name -eq $NewName })
if (-not $NoRestore) {
    if ($sources.Count -eq 0) { Stop-Checkpoint "There is no checkpoint named '$SourceCheckpoint'. The checkpoints are: $(($all | ForEach-Object { $_.Name }) -join ', ')" }
    if ($sources.Count -gt 1) { Stop-Checkpoint "$($sources.Count) checkpoints are named '$SourceCheckpoint', so a restore by that name is a guess. Rename all but one." }
}
if ($olds.Count -gt 1) { Stop-Checkpoint "$($olds.Count) checkpoints are named '$NewName' already. Rename all but one." }

# What the checkpoint that has the new name will be called once it is
# replaced: its name and the day it was made, with the time added when that
# is taken, as it is when a checkpoint is replaced twice in a day.
$old = $null
$keptName = ''
if ($olds.Count -eq 1) {
    $old = $olds[0]
    $keptName = "$NewName-$($old.CreationTime.ToString('yyyy-MM-dd'))"
    if ($all | Where-Object { $_.Name -eq $keptName }) {
        $keptName = "$keptName-$($old.CreationTime.ToString('HHmm'))"
    }
    if ($all | Where-Object { $_.Name -eq $keptName }) {
        Stop-Checkpoint "The checkpoint '$NewName' would be kept as '$keptName', and that name is taken too. Rename one of them."
    }
}
$tempName = "$NewName-being-made-$stamp"
if ($old) {
    Write-Line "The checkpoint named '$NewName' now, made $($old.CreationTime.ToString('yyyy-MM-dd HH:mm')), will be kept as '$keptName'"
}

# --- 2. the source ------------------------------------------------------------

if ($NoRestore) {
    Write-Line 'NOT restoring a checkpoint (-NoRestore): the VM is used as it is'
} else {
    $source = $sources[0]
    Write-Line "Restoring '$($source.Name)', made $($source.CreationTime.ToString('yyyy-MM-dd HH:mm'))"
    Restore-VMCheckpoint -VMName $VMName -Name $SourceCheckpoint -Confirm:$false
}
if ((Get-VM -Name $VMName).State -ne 'Running') {
    Write-Line 'Starting the VM'
    Start-VM -Name $VMName
}

# --- 3. the VM answers ----------------------------------------------------------

Write-Line 'Waiting for the VM to answer'
$problem = Wait-RecertifyVM -VMName $VMName -Credential $Credential
if ($problem -like 'refused:*') { Stop-Checkpoint "The VM refused the sign-in: $($problem -replace '^refused: ', '')" }
if ($problem) { Stop-Checkpoint "The VM did not answer: $problem" }

Write-Line "The VM: $(Invoke-InVM { $os = Get-CimInstance Win32_OperatingSystem; "$($os.Caption) build $($os.BuildNumber), user $env:USERNAME, computer $env:COMPUTERNAME" })"

$licenceBefore = Get-RecertifyLicence -VMName $VMName -Credential $Credential
if ($licenceBefore) {
    Write-Line "Licence: $(Format-Licence $licenceBefore)"
} else {
    Write-Line 'Licence: the VM reports no Windows licence to read'
}
$pendingBefore = Get-RestartPending
Write-Line "Restart pending: $pendingBefore"

# --- 3a. the rearm ------------------------------------------------------------

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if ($Rearm) {
    if (-not $licenceBefore) { Stop-Checkpoint 'There is no licence to rearm.' }
    if ($licenceBefore.Rearms -lt 1) {
        Stop-Checkpoint "No rearm is left. When the licence runs out the VM has to be rebuilt from the ISO: see 'The certification VM' in the README."
    }
    if ($licenceBefore.Days -gt 30 -and -not $Force) {
        Stop-Checkpoint "$($licenceBefore.Days) days remain. A rearm starts 90 days from today, so one made now throws those away. Wait until 30 or fewer remain, or give -Force."
    }

    Write-Line "Turning on automatic sign-in for $User, for one restart"
    Invoke-InVM {
        param($key, $user, $password)
        Set-ItemProperty $key -Name AutoAdminLogon -Value '1' -Type String
        Set-ItemProperty $key -Name DefaultUserName -Value $user -Type String
        Set-ItemProperty $key -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
        Set-ItemProperty $key -Name DefaultPassword -Value $password -Type String
    } -Arguments $winlogon, $User, $Credential.GetNetworkCredential().Password

    Write-Line 'Running slmgr /rearm'
    $rearmed = Invoke-InVM {
        $text = (cscript //nologo C:\Windows\System32\slmgr.vbs /rearm 2>&1 | Out-String).Trim()
        [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
    }
    foreach ($line in ($rearmed.Text -split "`r?`n")) { if ($line.Trim()) { Write-Line "    $($line.Trim())" } }
    if ($rearmed.Code -ne 0) { Stop-Checkpoint "slmgr /rearm failed (exit $($rearmed.Code)). Automatic sign-in is still on in the VM; a restore puts that back." }

    # A shutdown asked of Windows, not the power pulled: the rearm and any
    # pending servicing finish on the way down and on the way up.
    Write-Line 'Shutting the VM down'
    Stop-VM -Name $VMName -Force
    Write-Line 'Starting the VM'
    Start-VM -Name $VMName

    Write-Line 'Waiting for the VM to answer'
    $problem = Wait-RecertifyVM -VMName $VMName -Credential $Credential -Minutes 15
    if ($problem) { Stop-Checkpoint "After the restart the VM did not answer: $problem" }
    Write-Line 'Waiting for the automatic sign-in'
    if (-not (Wait-RecertifySignIn -VMName $VMName -Credential $Credential -User $User -Minutes 15)) {
        Stop-Checkpoint "After the restart $User was not signed in within 15 minutes: the automatic sign-in did not happen. It is still set in the VM; a restore puts that back."
    }

    $licenceAfter = Get-RecertifyLicence -VMName $VMName -Credential $Credential
    Write-Line "Licence after the rearm: $(Format-Licence $licenceAfter)"
    if ($licenceAfter.Minutes -le $licenceBefore.Minutes -or $licenceAfter.Rearms -ne ($licenceBefore.Rearms - 1)) {
        Stop-Checkpoint "The rearm did not take: expected more time than $($licenceBefore.Minutes) minutes and $($licenceBefore.Rearms - 1) rearm(s) left."
    }

    Write-Line 'Turning automatic sign-in off'
    Invoke-InVM {
        param($key)
        Set-ItemProperty $key -Name AutoAdminLogon -Value '0' -Type String
        Remove-ItemProperty $key -Name DefaultPassword -ErrorAction SilentlyContinue
        Remove-ItemProperty $key -Name AutoLogonCount -ErrorAction SilentlyContinue
    } -Arguments $winlogon

    Write-Line "Restart pending: $pendingBefore before the restart, $(Get-RestartPending) after"
}

# --- 4. no updates ------------------------------------------------------------

Write-Line 'Setting the update policy and stopping the update services'
Invoke-InVM {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item $key -Force | Out-Null
    Set-ItemProperty $key -Name NoAutoUpdate -Value 1 -Type DWord
    # Stopped, not disabled: script 11 installs the OpenSSH server through
    # Windows Update, and the services start again when asked. Asked to stop
    # and not waited for: each can take minutes, and the wait for servicing
    # to go quiet comes next anyway.
    Stop-Service UsoSvc, wuauserv -Force -NoWait -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

# --- 5. the state ---------------------------------------------------------------

Write-Line 'Checking the state'
$state = Invoke-InVM {
    param($winlogon)
    $logon = Get-ItemProperty $winlogon
    $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    $capability = 'could not be read'
    try { $capability = "$((Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1).State)" } catch { $capability = "could not be read: $($_.Exception.Message)" }
    [pscustomobject]@{
        Chezmoi        = [bool](Get-Command chezmoi -ErrorAction SilentlyContinue)
        ChezmoiSource  = (Test-Path (Join-Path $env:USERPROFILE '.local\share\chezmoi'))
        Capability     = $capability
        NoAutoUpdate   = $(if ($policy) { "$($policy.NoAutoUpdate)" } else { '' })
        AutoAdminLogon = "$($logon.AutoAdminLogon)"
        StoredPassword = ($null -ne $logon.DefaultPassword)
    }
} -Arguments $winlogon
$signedIn = Test-RecertifySignedIn -VMName $VMName -Credential $Credential -User $User

$checks = @(
    @{ Text = "$User is signed in";                      Pass = $signedIn;                         Found = "explorer running as ${User}: $signedIn" },
    @{ Text = 'chezmoi is not installed';                Pass = (-not $state.Chezmoi);             Found = "chezmoi on PATH: $($state.Chezmoi)" },
    @{ Text = 'the chezmoi source folder is not there';  Pass = (-not $state.ChezmoiSource);       Found = "folder exists: $($state.ChezmoiSource)" },
    @{ Text = 'the OpenSSH server is not present';       Pass = ($state.Capability -eq 'NotPresent'); Found = "capability: $($state.Capability)" },
    @{ Text = 'the update policy is set';                Pass = ($state.NoAutoUpdate -eq '1');     Found = "NoAutoUpdate: [$($state.NoAutoUpdate)]" },
    @{ Text = 'automatic sign-in is off';                Pass = ($state.AutoAdminLogon -ne '1');   Found = "AutoAdminLogon: [$($state.AutoAdminLogon)]" },
    @{ Text = 'no password is stored for sign-in';       Pass = (-not $state.StoredPassword);      Found = "DefaultPassword present: $($state.StoredPassword)" }
)
$wrong = @()
foreach ($check in $checks) {
    Write-Line ("    {0}  {1,-40} {2}" -f $(if ($check.Pass) { 'ok ' } else { 'NO ' }), $check.Text, $check.Found)
    if (-not $check.Pass) { $wrong += $check.Text }
}
if ($wrong) { Stop-Checkpoint "The VM is not in a state to checkpoint. Not so: $($wrong -join '; ')." }

# --- 6. servicing goes quiet ---------------------------------------------------

Write-Line "Waiting for servicing to go quiet: no TiWorker for $QuietMinutes minute(s), within $QuietLimitMinutes"
$waitStarted = Get-Date
$quietSince = $null
$busySeconds = 0
$quiet = $false
while (((Get-Date) - $waitStarted).TotalMinutes -lt $QuietLimitMinutes) {
    $busy = $true
    try { $busy = Invoke-InVM { [bool](Get-Process TiWorker -ErrorAction SilentlyContinue) } } catch { $busy = $true }
    if ($busy) {
        $quietSince = $null
        $busySeconds = [int]((Get-Date) - $waitStarted).TotalSeconds
    } else {
        if (-not $quietSince) { $quietSince = Get-Date }
        if (((Get-Date) - $quietSince).TotalMinutes -ge $QuietMinutes) { $quiet = $true; break }
    }
    Start-Sleep 5
}
if (-not $quiet) {
    Stop-Checkpoint "Servicing was still busy after $QuietLimitMinutes minutes. A checkpoint taken now would resume in the middle of that work on every restore."
}
Write-Line "Servicing is quiet. It was last seen busy $busySeconds s into the wait."
Write-Line "The update services: $(Invoke-InVM { (Get-Service UsoSvc, wuauserv | ForEach-Object { "$($_.Name) $($_.Status)" }) -join ', ' })"

# The wait can be long, and the checkpoint is no use without the desktop.
if (-not (Test-RecertifySignedIn -VMName $VMName -Credential $Credential -User $User)) {
    Stop-Checkpoint "$User is not signed in any more."
}

# --- 7. the checkpoint ----------------------------------------------------------

Write-Line "Taking the checkpoint, as '$tempName'"
try {
    Checkpoint-VM -Name $VMName -SnapshotName $tempName
} catch {
    Stop-Checkpoint "Checkpoint-VM failed: $($_.Exception.Message)$(if ($old) { " '$NewName' is still the checkpoint made $($old.CreationTime.ToString('yyyy-MM-dd HH:mm'))." })"
}
$made = @(Get-VMCheckpoint -VMName $VMName | Where-Object { $_.Name -eq $tempName })
if ($made.Count -ne 1) { Stop-Checkpoint "Checkpoint-VM returned, but $($made.Count) checkpoints are named '$tempName'." }
if ("$($made[0].CheckpointType)" -ne 'Standard') {
    Write-Line "STOPPED: the new checkpoint is $($made[0].CheckpointType), not Standard, so it holds no memory."
    Write-Line "It is kept as '$tempName' and nothing was renamed. Remove it by hand."
    exit 1
}

# From here a checkpoint has been taken, so a failure says where each one is.
# The name recertify.ps1 restores must not be left on no checkpoint.
if ($old) {
    Write-Line "Keeping the old '$NewName' as '$keptName'"
    try {
        $old | Rename-VMCheckpoint -NewName $keptName
    } catch {
        Write-Line "STOPPED: the old '$NewName' could not be renamed: $($_.Exception.Message)"
        Write-Line "Nothing was renamed: '$NewName' is still the old checkpoint, and the new one is kept as '$tempName'."
        exit 1
    }
}
Write-Line "Naming the new checkpoint '$NewName'"
try {
    $made[0] | Rename-VMCheckpoint -NewName $NewName
} catch {
    Write-Line "STOPPED: the new checkpoint could not be named '$NewName': $($_.Exception.Message)"
    Write-Line "The new checkpoint is kept as '$tempName'."
    if ($old) {
        try {
            $old | Rename-VMCheckpoint -NewName $NewName
            Write-Line "The old checkpoint has the name '$NewName' again, so recertify.ps1 still works."
        } catch {
            Write-Line "The old checkpoint could not be given its name back either: $($_.Exception.Message)"
            Write-Line "NO CHECKPOINT IS NAMED '$NewName' NOW, and recertify.ps1 needs one. To put the old one back:"
            Write-Line "    Rename-VMCheckpoint -VMName $VMName -Name '$keptName' -NewName '$NewName'"
        }
    }
    exit 1
}

# --- 8. what there is now --------------------------------------------------------

Write-Line ''
Write-Line 'The checkpoints now:'
foreach ($checkpoint in (Get-VMCheckpoint -VMName $VMName | Sort-Object CreationTime)) {
    Write-Line ("    {0,-36} made {1}  parent: {2}" -f $checkpoint.Name, $checkpoint.CreationTime.ToString('yyyy-MM-dd HH:mm'),
        $(if ($checkpoint.ParentCheckpointName) { $checkpoint.ParentCheckpointName } else { '(none)' }))
}
$folder = (Get-VM -Name $VMName).Path
$bytes = (Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Line ("The VM's folder, $folder, holds {0:N1} GB. This script deletes no checkpoint." -f ($bytes / 1GB))
Write-Line ''
Write-Line "MADE: '$NewName', from '$(if ($NoRestore) { 'the VM as it was' } else { $SourceCheckpoint })'$(if ($Rearm) { ', with the licence rearmed' })."
if ($Rearm) { Write-Line "Update the licence table in 'The certification VM' in the README: $(Format-Licence $licenceAfter), as of today." }
Write-Line "To certify from it:  & `"`$HOME\.local\bin\recertify.ps1`"$(if ($NewName -ne 'clean-windows') { " -Checkpoint '$NewName'" })"
exit 0
