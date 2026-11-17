# Make sure mise.exe is on the persisted user PATH, and put it back when it is
# not.
#
# winget installs mise as a portable package and makes it reachable one of two
# ways: a link in WinGet\Links, or the package's own directory on the user PATH.
# An upgrade can remove that PATH entry and not add it back
# (https://github.com/microsoft/winget-cli/issues/6461, open as of winget
# 1.29.380). It happened on sophon when winget upgraded mise on 2026-11-09.
#
# Nothing reports it. mise.exe is still on disk and `winget list` still shows
# the package, but:
#
#   - the profile skips `mise activate`, because `Get-Command mise` fails
#   - every shim fails with "mise-shim: failed to execute mise: program not
#     found", so no mise-managed tool runs by name in any shell
#   - script 04 cannot run `mise install`
#
# Three callers:
#
#   - script 04, before `mise install`, on an apply
#   - topgrade, as a custom command after its winget step (see topgrade.toml),
#     so an entry lost in the weekly upgrade is back before the run ends
#   - the PowerShell profile, with -PassThru, when a new shell cannot find mise.
#     That covers a `winget upgrade` run by hand, outside topgrade.
#
# It looks for mise.exe in the directories on the machine and user PATH as the
# registry holds them, not in this process's PATH: a process keeps the PATH it
# started with, and the question here is what the next shell will get. If no
# directory there holds mise.exe, it finds the one in winget's package directory
# and appends that directory to the user PATH. That is the same entry winget
# writes, so winget's own record of the package stays true.
#
# Exits 0 when mise.exe is on the PATH, already or now. Exits 1 when mise.exe
# cannot be found at all, which means winget has not installed it.
#
# Written for Windows PowerShell 5.1, because that is what chezmoi runs scripts
# with (see .chezmoi.toml.tmpl).

param(
    # Also write the full path of mise.exe to the output. The profile uses it to
    # fix the shell that is starting, which already has its PATH.
    [switch]$PassThru
)

function Find-OnRegistryPath {
    $dirs = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) -join ';' -split ';'

    foreach ($dir in $dirs) {
        $dir = "$dir".Trim().Trim('"').TrimEnd('\')
        if (-not $dir) { continue }
        # [IO.File]::Exists returns false for a malformed entry where Test-Path
        # would write an error. It follows a link, so a link in WinGet\Links
        # whose target is gone does not count.
        $exe = "$dir\mise.exe"
        if ([IO.File]::Exists($exe)) { return $exe }
    }
}

function Find-InWingetPackage {
    # User scope first: that is where the manifest installs mise. The package
    # directory's name has no version in it, so it is the same after an upgrade.
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
        (Join-Path $env:ProgramFiles 'WinGet\Packages')
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($package in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'jdx.mise_*')) {
            # Searched for, not assumed to be at mise\bin: that layout belongs
            # to mise's release archive and could change.
            $exe = Get-ChildItem -LiteralPath $package.FullName -Recurse -File -Filter 'mise.exe' |
                   Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
}

function Add-ToUserPath([string]$dir) {
    # Read the raw value and keep its kind, for the reasons script 07 gives:
    # [Environment]::GetEnvironmentVariable expands %VARS%, and writing that back
    # replaces every such entry with whatever it expanded to.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { return $false }

    try {
        $raw  = [string]$key.GetValue('Path', '',
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path') }
                else { [Microsoft.Win32.RegistryValueKind]::ExpandString }

        # Appended, as winget does. The shims directory stays first.
        $new = if ($raw.TrimEnd(';')) { $raw.TrimEnd(';') + ';' + $dir } else { $dir }
        $key.SetValue('Path', $new, $kind)
    } finally {
        $key.Close()
    }

    # Tell running programs the environment changed, so that what Explorer
    # starts from now on sees the entry without a sign-out. If this fails the
    # entry is still written.
    try {
        if (-not ('Win32.MisePathNative' -as [type])) {
            Add-Type -Namespace Win32 -Name MisePathNative -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        # HWND_BROADCAST = 0xffff, WM_SETTINGCHANGE = 0x1a, SMTO_ABORTIFHUNG = 0x2
        [void][Win32.MisePathNative]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
    } catch {
        Write-Host 'Could not announce the PATH change. Sign out and back in for Explorer to pick it up.'
    }

    return $true
}

$mise = Find-OnRegistryPath

if ($mise) {
    # Say nothing to a shell that is starting: -PassThru is the profile.
    if (-not $PassThru) { Write-Host "mise is on the PATH ($mise)" }
} else {
    $mise = Find-InWingetPackage

    if (-not $mise) {
        Write-Warning ('mise.exe is not on the PATH and not in a winget package directory. ' +
                       'Install it with `winget install jdx.mise`, then run chezmoi apply.')
        exit 1
    }

    $dir = Split-Path -Parent $mise
    if (-not (Add-ToUserPath $dir)) {
        Write-Warning "mise.exe is at $mise but not on the PATH, and HKCU:\Environment could not be opened to add it."
        exit 1
    }

    Write-Warning ("mise was not on the PATH, so no mise-managed tool could run. Added $dir " +
                   'to the user PATH. A winget upgrade of mise removes that entry ' +
                   '(winget-cli issue 6461). Shells that are already open still lack it.')
}

if ($PassThru) { $mise }
exit 0
