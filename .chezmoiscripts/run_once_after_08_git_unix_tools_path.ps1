# Put Git for Windows' Unix tools (usr\bin) on the persisted user PATH.
#
# process_executer's spec suite spawns `cat`, `false`, `sleep` and `echo` as
# real executables via Process.spawn. On Windows those binaries exist in exactly
# one place this repo manages: Git for Windows' usr\bin (Git.Git, layer 2). Git
# Bash prepends it for its own sessions and nothing else ever did, so
# `bundle exec rake spec` passed in Git Bash and failed in every other shell
# with Errno::ENOENT - which surfaces as ~25 apparently unrelated spec
# failures, not as anything that says PATH.
#
# THE PROFILE CANNOT CARRY THIS. The consumer that forced the issue is Claude
# Code inside VS Code, which runs every command in `pwsh -NoProfile
# -NonInteractive`. A -NoProfile shell has exactly the environment it inherits:
# extension host -> VS Code -> Explorer -> the registry PATH. The integrated
# terminal starts from that same chain before its profile runs, so the
# persisted user PATH is the one channel that reaches both. Script 07 reached
# the same conclusion for cmd.exe and mise shims; this is the same move for a
# different set of tools.
#
# APPEND, DO NOT PREPEND. Two orderings protect against usr\bin's name
# collisions (find.exe, sort.exe, ssh.exe, bash.exe):
#   - Windows composes machine scope first, so System32's find/sort/ssh win no
#     matter what this script does to user scope.
#   - Within user scope, script 07 PREPENDS mise shims and this script APPENDS,
#     so the managed toolchain stays ahead and usr\bin only answers for names
#     nothing else on PATH provides - which is the point.
#
# HONEST LIMIT: this fixes resolution for spawned processes, not for
# interactive PowerShell, where `cat` and `sleep` remain aliases for
# Get-Content and Start-Sleep. Ruby's Process.spawn does a real PATH lookup and
# never sees aliases, which is why the specs care about PATH and pwsh does not.
# Check with `cat.exe` when testing by hand.

# Refresh PATH from the registry first, for the same reason scripts 02, 04, 06
# and 07 do: on a rebuild, Git arrives from the winget manifest in script 01 of
# this same run, and Windows never propagates PATH into a running process.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

# Resolve usr\bin from wherever git.exe actually is (...\Git\cmd\git.exe ->
# ...\Git\usr\bin) rather than hardcoding Program Files - winget installs
# Git.Git machine-wide today, but the derivation stays correct if that changes.
$git = Get-Command git.exe -ErrorAction SilentlyContinue
$usrBin = if ($git) {
    Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'usr\bin'
} else {
    'C:\Program Files\Git\usr\bin'
}

if (-not (Test-Path (Join-Path $usrBin 'cat.exe'))) {
    Write-Warning ("Git's Unix tools not found at $usrBin - is Git.Git installed? " +
                   'Not touching PATH; spawned cat/false/sleep stay unresolvable.')
    return
}

# Registry discipline identical to script 07, for the reasons its header lays
# out: read the RAW value unexpanded (the expand-and-write-back API permanently
# rewrites %VAR%-style entries it never meant to touch), preserve the value
# kind, and never use setx (truncates at 1024 characters).
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
if (-not $key) {
    Write-Warning 'Could not open HKCU:\Environment for writing - PATH not changed.'
    return
}

try {
    $raw  = [string]$key.GetValue('Path', '',
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path') }
            else { [Microsoft.Win32.RegistryValueKind]::ExpandString }

    $target = $usrBin.TrimEnd('\')
    $present = $raw -split ';' |
        Where-Object { $_ } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).Trim().TrimEnd('\') } |
        Where-Object { $_ -eq $target }

    if ($present) {
        Write-Host "Git usr\bin already on the user PATH ($target)"
    } else {
        $new = if ($raw.Trim(';')) { $raw.TrimEnd(';') + ';' + $target } else { $target }
        $key.SetValue('Path', $new, $kind)
        Write-Host "added to the user PATH: $target"

        # Tell the shell to reload the environment, same as script 07. Without
        # this the change waits for the next sign-in; best effort.
        try {
            if (-not ('Win32.NativeMethods' -as [type])) {
                Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            }
            $result = [UIntPtr]::Zero
            # HWND_BROADCAST = 0xffff, WM_SETTINGCHANGE = 0x1a, SMTO_ABORTIFHUNG = 0x2
            [void][Win32.NativeMethods]::SendMessageTimeout(
                [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
        } catch {
            Write-Host 'Could not broadcast the environment change - sign out and back in to pick it up.'
        }
    }
} finally {
    $key.Close()
}

# Prove it the way the failure presented: a spawned process resolving `cat`
# from PATH, no shell aliases in the way. Extend this process's PATH first -
# the registry write is not visible to an already-running process.
$env:Path = $env:Path + ';' + $usrBin
$out = & cmd.exe /c 'cat --version' 2>&1 | Select-Object -First 1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -eq 0) {
    Write-Host "cmd.exe now resolves cat: $out"
} else {
    Write-Warning "cat.exe is in $usrBin but cmd.exe could not run it: $out"
}
