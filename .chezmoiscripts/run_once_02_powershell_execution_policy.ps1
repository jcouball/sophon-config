# Let interactive PowerShell run the profile stubs that script 02 writes.
#
# Without this, the stubs are written correctly and never execute. Windows
# PowerShell 5.1 refuses them:
#
#   . : File ...\WindowsPowerShell\Microsoft.PowerShell_profile.ps1 cannot be
#   loaded because running scripts is disabled on this system.
#
# and the consequences are entirely silent afterwards: no `mise activate`, so no
# ruby, no irb, no node, no JAVA_HOME, no ANT_HOME. The shell opens normally and
# every managed tool is simply absent. Observed on sophon, not only on the
# certification VM -- `ruby -v` in a 5.1 window said "not recognized" while the
# same command in pwsh 7 printed 4.0.6.
#
# THE TWO EDITIONS DO NOT SHARE A POLICY. This is the whole reason the failure
# hides. Measured on sophon:
#
#   pwsh 7   RemoteSigned, from a powershell.config.json shipped *inside* the
#            install directory -- for the Store build that is
#            C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.5.0_...\
#            powershell.config.json, written by the installer, not the registry.
#   5.1      no ExecutionPolicy value anywhere. HKLM:\SOFTWARE\Microsoft\
#            PowerShell\1\ShellIds\Microsoft.PowerShell has none and neither does
#            HKCU, so it falls back to the Windows client default: Restricted.
#
# So pwsh 7 works out of the box and 5.1 never has. Anything that opens the old
# blue-icon PowerShell -- the Start menu entry, VS Code's default terminal on
# Windows, a shortcut predating the switch of Terminal's default to pwsh 7 --
# gets a shell with none of this repo's environment in it.
#
# WHY THE BYPASS IN .chezmoi.toml.tmpl DOES NOT COVER THIS
#
# That block scopes -ExecutionPolicy Bypass to chezmoi's own script interpreter,
# which is what makes the bootstrap work on a machine whose policy is still
# Restricted. It is still required and still correct -- it has to be, because it
# is what allows THIS script to run at all. But it applies only to processes
# chezmoi launches. An interactive shell the user opens is unaffected, which is
# why that header's "the machine's policy is left alone" was true and not
# sufficient. Bootstrap and interactive use are separate problems.
#
# RemoteSigned rather than Unrestricted: local unsigned scripts run, downloaded
# ones still need Unblock-File. Worth naming because the stubs live in
# OneDrive-synced Documents, and a file carrying a zone marker would still be
# refused. sophon's stubs have no Zone.Identifier stream today (checked with
# Get-Item -Stream *); if that ever changes the fix is Unblock-File, not a weaker
# policy.
#
# CurrentUser scope writes HKCU, so this needs no elevation and changes nothing
# for other accounts on the machine.

# DO NOT write the policy registry keys by hand. Each edition reads its own
# location and they are not guessable from one another -- 5.1 uses
# ...\PowerShell\1\ShellIds\..., pwsh 7 does not use ...\PowerShell\7\... on this
# host at all. Ask each edition to set its own, the same way script 02 asks each
# edition where its own $PROFILE lives instead of constructing the path.
#
# Refresh PATH from the registry first, for the same reason scripts 02, 04 and 06
# do it: pwsh 7 arrives from the winget manifest in script 01 of this same run,
# and Windows never propagates PATH into an already-running process. Without
# this, a fresh machine silently skips the pwsh half.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

# Clear PSExecutionPolicyPreference before launching anything. chezmoi runs this
# script with -ExecutionPolicy Bypass, which sets that variable in this process,
# and it is INHERITED by every child process. It has to go for two separate
# reasons, and both were hit for real:
#
#   - Reading. Leave it set and the check below reads Bypass for both editions
#     and reports success on a machine where nothing was fixed. That exact
#     inheritance masked this bug while it was being diagnosed.
#   - Writing. `Set-ExecutionPolicy -Scope CurrentUser` still writes the value,
#     but a child running under Bypass then fails the call with a red
#     ExecutionPolicyOverride block -- "the setting is overridden by a policy
#     defined at a more specific scope" -- because Process scope outranks
#     CurrentUser. The change succeeded; the transcript said PermissionDenied.
#
# Safe to clear here: this process loads no further scripts or modules.
$env:PSExecutionPolicyPreference = $null

$permissive = 'RemoteSigned', 'Unrestricted', 'Bypass'

# Clear PSModulePath around every child launch, and this is not defensive
# programming -- without it this script cannot work at all when chezmoi is run
# from pwsh 7, which is the documented way to run it.
#
# chezmoi inherits PSModulePath from the shell that started it and passes it to
# the `powershell` interpreter declared in .chezmoi.toml.tmpl. Started from
# pwsh 7, that value leads with pwsh's own module directory:
#
#   ...\WindowsApps\microsoft.powershell_7.6.5.0_x64__8wekyb3d8bbwe\Modules
#
# which ships a PowerShell *Core* build of Microsoft.PowerShell.Security, and it
# precedes C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules. Windows PowerShell
# 5.1 therefore resolves Get-ExecutionPolicy and Set-ExecutionPolicy to the Core
# module and cannot load it:
#
#   The 'Get-ExecutionPolicy' command was found in the module
#   'Microsoft.PowerShell.Security', but the module could not be loaded.
#
# Both halves break, and the failure is shaped exactly like the answer: the read
# returns nothing, which looks like a restrictive policy, and the write then dies
# with CommandNotFoundException. The first run of this script through chezmoi hit
# precisely that and reported a Group Policy problem that did not exist.
#
# Clearing the variable makes each child compute its own edition-correct default.
# Restore it afterwards rather than nulling it for the whole process, because
# this process still needs to autoload its own modules.
function Invoke-Edition($exe, $command) {
    $saved = $env:PSModulePath
    $env:PSModulePath = $null
    try {
        & $exe -NoProfile -NonInteractive -Command $command 2>&1 | ForEach-Object { "$_" }
    } finally {
        $env:PSModulePath = $saved
    }
}

# Match the policy name rather than taking the first line: stderr is merged in
# above, so a failed call must come back as $null and not as the first line of an
# error record.
function Get-EditionPolicy($exe) {
    $out = Invoke-Edition $exe 'Get-ExecutionPolicy' |
           Where-Object { $_ -match '^\s*(Restricted|AllSigned|RemoteSigned|Unrestricted|Bypass|Undefined)\s*$' } |
           Select-Object -First 1
    if ($out) { return "$out".Trim() }
    return $null
}

foreach ($exe in 'powershell.exe', 'pwsh.exe') {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        Write-Host "$exe not available - skipping"
        continue
    }

    $before = Get-EditionPolicy $exe
    if ($before -in $permissive) {
        Write-Host "$exe already permits local scripts ($before)"
        continue
    }

    $was = if ($before) { $before } else { 'unreadable' }
    Write-Host "$exe is $was - setting CurrentUser to RemoteSigned ..."
    Invoke-Edition $exe 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force'

    $after = Get-EditionPolicy $exe
    if ($after -in $permissive) {
        Write-Host "$exe now $after"
    } else {
        # Two causes, and they need different responses, so do not collapse them.
        # A Group Policy at MachinePolicy or UserPolicy scope outranks CurrentUser
        # and cannot be overridden from here. An unreadable policy means the
        # cmdlet would not load at all, which is the PSModulePath shadowing
        # described above and a bug in this script, not in the machine.
        $why = if ($after) { "is still $after" } else { 'would not report its policy' }
        Write-Warning ("$exe $why after setting CurrentUser. Run " +
                       "``Get-ExecutionPolicy -List`` in ${exe}: a Group Policy scope " +
                       'outranking CurrentUser explains the first case, and a ' +
                       'Microsoft.PowerShell.Security load failure the second. Until ' +
                       'this is resolved that shell will not load the profile, so mise ' +
                       'will not activate in it.')
    }
}
