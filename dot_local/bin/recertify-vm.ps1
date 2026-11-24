# What recertify.ps1 and recertify-checkpoint.ps1 both need to reach the
# certification VM. Each dot-sources this file from its own folder:
#
#   . (Join-Path $PSScriptRoot 'recertify-vm.ps1')
#
# It only defines functions. It is not run by hand.
#
# One copy, so the two scripts cannot come to disagree about where the
# password is, how long the VM is waited for, or what "signed in" means.
#
# It runs under Windows PowerShell 5.1 and pwsh 7.

# Unelevated, the Hyper-V cmdlets return empty lists, not an error.
function Test-RecertifyElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# THE PASSWORD. PowerShell Direct needs the guest account's password. It is
# the first line of ~\.config\recertify\password.txt if that file exists, or
# asked for. The file is for running over ssh, where nobody can be asked; it
# is a plain file, so use it only for a password that opens nothing but the
# VM. The password is never written to a log.
function Get-RecertifyCredential {
    param([string]$User, [string]$VMName)

    $passwordFile = Join-Path $HOME '.config\recertify\password.txt'
    if (Test-Path $passwordFile) {
        $secure = ConvertTo-SecureString (@(Get-Content $passwordFile)[0]) -AsPlainText -Force
        return New-Object pscredential ($User, $secure)
    }
    Write-Host "No password file at $passwordFile, so asking for the password of $User."
    Write-Host 'To run without being asked, put the password on the first line of that file.'
    Write-Host 'Nothing typed here is saved.'
    Get-Credential -UserName $User -Message "The password of $User in the VM $VMName"
}

# One job at a time for a VM: a certification, or the making of a checkpoint.
# A second one would restore a checkpoint under the first. The lock is
# system-wide, so it holds between a job at the desktop and one over ssh, and
# Windows lets go of it when the process ends, however it ends.
#
# Returns the lock, or $null when another job holds it. Keep the lock in a
# variable for as long as the job runs.
function Enter-RecertifyLock {
    param([string]$VMName)

    $lock = New-Object Threading.Mutex ($false, ('Global\recertify-' + ($VMName -replace '[^\w.-]', '-')))
    try {
        $haveLock = $lock.WaitOne(0)
    } catch {
        # The job that held it was killed without letting go. Windows reports
        # that as an error and gives the lock to whoever asked, which is this
        # job. PowerShell wraps the error, so look inside it.
        if ($_.Exception.GetBaseException() -isnot [Threading.AbandonedMutexException]) { throw }
        $haveLock = $true
    }
    if ($haveLock) { return $lock }
    $null
}

# Wait for the VM to answer through PowerShell Direct. Returns '' when it
# does. Otherwise returns why not, starting with 'refused:' when the VM
# turned the sign-in down, which no amount of waiting cures.
function Wait-RecertifyVM {
    param([string]$VMName, [pscredential]$Credential, [int]$Minutes = 5)

    $problem = ''
    foreach ($try in 1..($Minutes * 12)) {
        try {
            [void](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $env:COMPUTERNAME })
            return ''
        } catch {
            $problem = $_.Exception.Message
            if ($problem -match 'credential|password|user name') { return "refused: $problem" }
            Start-Sleep 5
        }
    }
    "no answer within $Minutes minutes: $problem"
}

# Whether $User is signed in at the VM's desktop: an explorer process owned
# by that account exists. Steps run as tasks in that account's desktop
# session, so another account's desktop does not count. Throws when the VM
# does not answer.
function Test-RecertifySignedIn {
    param([string]$VMName, [pscredential]$Credential, [string]$User)

    Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $User -ScriptBlock {
        param($user)
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'")) {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($owner -and $owner.User -eq $user) { return $true }
        }
        $false
    }
}

# Wait for $User to be signed in at the VM's desktop. A checkpoint is only
# useful if it was taken there. Waits up to $Minutes; $OnWait is run once,
# the first time the account is not found, so the caller can say what it is
# waiting for.
function Wait-RecertifySignIn {
    param([string]$VMName, [pscredential]$Credential, [string]$User, [int]$Minutes = 10, [scriptblock]$OnWait)

    foreach ($try in 1..($Minutes * 6)) {
        $found = $false
        try {
            $found = Test-RecertifySignedIn -VMName $VMName -Credential $Credential -User $User
        } catch {
            # A VM that is starting does not answer yet. That is not signed in.
            $found = $false
        }
        if ($found) { return $true }
        if ($try -eq 1 -and $OnWait) { & $OnWait }
        Start-Sleep 10
    }
    $false
}

# The evaluation licence, as Windows' own licensing service reports it. The
# same numbers `slmgr /dlv` prints for a person:
#
#   Days      whole days left, rounded down
#   Minutes   the same, as Windows counts it
#   Rearms    how many times `slmgr /rearm` can still be run. Windows keeps
#             two counts, one for Windows and one for the edition, and a rearm
#             needs both, so this is the smaller
#   Licensed  whether the licence is in force now
#
# Returns $null when the VM has no Windows licence to report, which a VM that
# is not an evaluation image may not.
function Get-RecertifyLicence {
    param([string]$VMName, [pscredential]$Credential)

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $product = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'")[0]
        if (-not $product) { return $null }
        $service = Get-CimInstance SoftwareLicensingService
        $counts = @([int]$product.RemainingSkuReArmCount, [int]$service.RemainingWindowsReArmCount)
        [pscustomobject]@{
            Days     = [int][math]::Floor($product.GracePeriodRemaining / 1440)
            Minutes  = [int]$product.GracePeriodRemaining
            Rearms   = ($counts | Measure-Object -Minimum).Minimum
            Licensed = ($product.LicenseStatus -eq 1)
            Name     = $product.Name
        }
    }
}
