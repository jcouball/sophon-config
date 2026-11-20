# One step of a re-certification, run inside the certification VM.
#
# recertify.ps1 copies this file into the VM and starts it once per step, as a
# scheduled task in the signed-in user's desktop session. It is not run by
# hand, and it does nothing useful on sophon.
#
# WHY ONE PROCESS PER STEP. A process keeps the PATH it started with. The
# README's rebuild says to install chezmoi in one terminal and run it from a
# new one for that reason, and to check the result in a new shell. A task
# started by Task Scheduler gets the environment as it is at that moment, so
# each step sees what a newly opened terminal would.
#
# WHERE THE OUTPUT GOES. Each command is run through cmd.exe with its output
# sent to <step>.log. That is a file, not a pipe: Windows PowerShell does not
# record what chezmoi's scripts write, and a pipe has made programs here
# behave differently (sshd, in script 11). Input stays the console, so a
# program that stops to ask a question waits, as it would for a person. Nobody
# answers, the log stops growing, and recertify.ps1 reports the step as
# stalled. That is the outcome wanted: a rebuild that needs an answer has
# failed.
#
# WHEN IT IS DONE. The last thing a step does is write <step>.done, holding
# its exit code. recertify.ps1 waits for that file.
#
# It runs under Windows PowerShell 5.1, the only PowerShell a clean machine has.

param(
    [Parameter(Mandatory)][ValidateSet('install-chezmoi', 'apply', 'terminal', 'checks')][string]$Step,
    # The folder in the VM that holds this file, the logs and the results.
    [Parameter(Mandatory)][string]$Dir,
    # Both go on a command line run through cmd.exe, elevated, so only the
    # characters a repository address or a branch can have are let in.
    [ValidatePattern('^[\w][\w.@:/-]*$')][string]$Repo = 'jcouball/sophon-config',
    # A branch to build from. Left out for the default branch.
    [ValidatePattern('^[\w][\w./-]*$')][string]$Branch
)

$log = Join-Path $Dir "$Step.log"
$utf8 = New-Object Text.UTF8Encoding $false
$settings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
$worst = 0

function Write-Note {
    param([string]$Text)
    [IO.File]::AppendAllText($log, "### $Text`r`n", $utf8)
}

# Run one command line with its output appended to the log, and remember the
# worst exit code of the step.
function Invoke-Logged {
    param([string]$CommandLine)

    Write-Note "run: $CommandLine"
    cmd /d /c "$CommandLine >> `"$log`" 2>&1"
    $code = $LASTEXITCODE
    Write-Note "exit $code"
    if ($code -ne 0 -and $script:worst -eq 0) { $script:worst = $code }
}

try {
    Write-Note "step $Step, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), PowerShell $($PSVersionTable.PSVersion)"

    # PATH as a terminal opened now would have it: the machine's, then the
    # user's, read from the registry. Task Scheduler is not relied on to have
    # done that.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    switch ($Step) {
        'install-chezmoi' {
            # The first line of "Rebuild from nothing", as written.
            Invoke-Logged 'winget install twpayne.chezmoi --source winget'
        }

        'apply' {
            Write-Note "Windows Terminal's settings.json exists before the apply: $(Test-Path $settings)"
            $from = if ($Branch) { "--branch $Branch $Repo" } else { $Repo }
            Invoke-Logged "chezmoi init --apply $from"
        }

        'terminal' {
            # "Open Windows Terminal once, then run chezmoi apply again."
            # Which commit was built. Here and not in the apply step: git is
            # installed by that apply, and is not on its PATH.
            Invoke-Logged 'chezmoi git -- log --oneline -1'
            Write-Note "settings.json exists before Terminal is opened: $(Test-Path $settings)"
            Start-Process wt.exe
            $waited = 0
            while (-not (Test-Path $settings) -and $waited -lt 120) { Start-Sleep 5; $waited += 5 }
            # Terminal writes the file, then adds the profiles it generates.
            Start-Sleep 20
            Write-Note "settings.json exists after Terminal was opened: $(Test-Path $settings) (waited $waited s)"
            Invoke-Logged 'chezmoi apply'
            # Script 05 changes the file it is keyed on, so one more apply.
            Invoke-Logged 'chezmoi apply'
            Invoke-Logged 'chezmoi status'
        }

        'checks' {
            $checks = Join-Path $HOME '.local\bin\recertify-checks.ps1'
            if (-not (Test-Path $checks)) {
                Write-Note "$checks is missing: the apply did not write it."
                $worst = 1
            } else {
                # pwsh, with the profile: that is the shell the rebuild is for.
                $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell -ExecutionPolicy Bypass' }
                Invoke-Logged "$shell -NoLogo -File `"$checks`" -OutFile `"$(Join-Path $Dir 'checks.json')`""
            }
        }
    }
} catch {
    Write-Note "the step itself failed: $($_.Exception.Message)"
    $worst = 1
}

Write-Note "step $Step finished, exit $worst"
[IO.File]::WriteAllText((Join-Path $Dir "$Step.done"), "$worst", $utf8)
exit $worst
