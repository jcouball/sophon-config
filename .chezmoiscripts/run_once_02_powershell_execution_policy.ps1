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

function Get-EditionPolicy($exe) {
    $out = & $exe -NoProfile -NonInteractive -Command 'Get-ExecutionPolicy' 2>$null |
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

    Write-Host "$exe is $before - setting CurrentUser to RemoteSigned ..."
    & $exe -NoProfile -NonInteractive -Command `
        'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force' 2>&1 |
        ForEach-Object { "$_" }

    $after = Get-EditionPolicy $exe
    if ($after -in $permissive) {
        Write-Host "$exe now $after"
    } else {
        # A Group Policy at MachinePolicy or UserPolicy scope outranks CurrentUser
        # and cannot be overridden from here. Say so, rather than reporting a
        # clean run over a shell that will still open with no environment in it.
        Write-Warning ("$exe is still $after after setting CurrentUser. A Group Policy " +
                       'scope likely outranks it - run `Get-ExecutionPolicy -List` in ' +
                       "$exe to see which. Until that is resolved, that shell will not " +
                       'load the profile and mise will not activate in it.')
    }
}
