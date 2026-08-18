# Put mise's shims directory on the persisted user PATH.
#
# Everything this repo manages reaches a shell exactly one way today: `mise
# activate pwsh` in the PowerShell profile. That covers PowerShell and nothing
# else. In particular it does not, and cannot, cover cmd.exe -- mise has no
# cmd.exe activation at all. There is no profile to hook, no equivalent of
# `activate`, nothing. So `ruby`, `irb`, `node` and the rest have never been
# findable from a cmd window, and never would be under the previous design.
#
# Verified on sophon before writing this:
#
#   cmd /c "ruby -v"                                -> not recognized
#   $env:Path = "$HOME\AppData\Local\mise\shims;" + $env:Path
#   cmd /c "ruby -v"                                -> ruby 4.0.6 ... +PRISM
#
# Shims work where activation cannot because they are real .exe files on disk
# that re-dispatch through mise, so any process that can read PATH finds them --
# cmd.exe, a 5.1 window whose policy is locked down, an editor or GUI app
# launched from Explorer, a scheduled task.
#
# dot_config/husky/init.sh reached the same conclusion first, from an unrelated
# direction: `mise activate bash` emits a Windows-form, semicolon-separated PATH
# that destroys a POSIX one, so git hooks prepend this exact directory instead.
# Shims are what mise itself recommends for non-interactive contexts. Keep that
# prepend in init.sh even though the directory is on the user PATH now -- a hook
# launched from a long-running GUI git client inherits whatever environment that
# client started with, which can predate this script by weeks.
#
# THIS SUPPLEMENTS ACTIVATION, IT DOES NOT REPLACE IT. Do not be tempted to drop
# `mise activate` from the profile now that shims are on PATH. Shims resolve a
# tool per invocation; they do not export the environment. Activation is what
# sets JAVA_HOME, ANT_HOME, GOROOT, CARGO_HOME and RUSTUP_HOME, and the JRuby
# build reads JAVA_HOME and ANT_HOME -- see the profile header, and the
# "Ant in C:\Tools is probably vestigial" entry in the README for what a missing
# ANT_HOME costs (a `warn` that is swallowed, and a silently wrong build).
#
# This reverses a decision recorded in script 06's header, which said the shims
# directory was deliberately kept off PATH. That was a real choice, made when
# PowerShell was assumed to be the only shell worth serving; the cmd.exe gap is
# what changed. Script 06's comment has been updated to match, and it still
# resolves every path explicitly rather than trusting PATH, which stays correct
# regardless -- chezmoi runs scripts with -NoProfile, and on a fresh machine this
# script has not run yet when 06 does.
#
# HONEST LIMIT: Windows composes the effective PATH as machine-scope first, then
# user-scope. A Ruby installed to the machine PATH -- RubyInstaller's own
# installer does this -- would still win over these shims. There is no user-scope
# fix for that; remove the competing install instead.

# Refresh PATH from the registry, for the same reason scripts 02, 04 and 06 do
# it: mise arrives from the winget manifest in script 01 of this same run, and
# Windows never propagates PATH into an already-running process.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

$shims = Join-Path $env:LOCALAPPDATA 'mise\shims'

if (-not (Test-Path $shims)) {
    # mise generates shims as script 04 installs the runtimes, so this directory
    # normally exists by now. Ask for them explicitly before giving up -- on a
    # first-ever run there is nothing to lose, and it is the difference between a
    # rebuild that ends with a working cmd.exe and one that ends with a warning.
    if (Get-Command mise -ErrorAction SilentlyContinue) {
        Write-Host 'No shims directory yet - running `mise reshim` ...'
        & mise reshim 2>&1 | ForEach-Object { "$_" }
    }
}

if (-not (Test-Path $shims)) {
    # Still absent means script 04 did not do its job -- not that there is nothing
    # to do here. Reporting "nothing to do" would be exactly the silent success
    # that script 04's header records.
    Write-Warning ("mise shims directory not found at $shims - script 04 should have " +
                   'created it. Not touching PATH; tools will remain invisible to cmd.exe.')
    return
}

# Read the RAW user PATH, unexpanded.
#
# [Environment]::GetEnvironmentVariable('Path', 'User') expands %VARS% before
# returning, and SetEnvironmentVariable writes back whatever string it is given.
# Read-modify-write through that API therefore replaces every %USERPROFILE%-style
# entry with the text it happened to expand to at that moment -- permanently, and
# invisibly, for entries this script never meant to touch. Go through the
# registry with DoNotExpandEnvironmentNames instead, and preserve the value kind
# so a REG_EXPAND_SZ PATH does not silently become REG_SZ.
#
# `setx` is not an option either: it truncates the value at 1024 characters.
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

    # Compare on expanded, normalised forms. An existing entry may be written as
    # %LOCALAPPDATA%\mise\shims, or with a trailing backslash, or in different
    # case -- all of which are the same directory and none of which match a naive
    # string compare against $shims.
    $target = $shims.TrimEnd('\')
    $present = $raw -split ';' |
        Where-Object { $_ } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).Trim().TrimEnd('\') } |
        Where-Object { $_ -eq $target }

    if ($present) {
        Write-Host "mise shims already on the user PATH ($target)"
    } else {
        # Prepend, so the managed toolchain wins over anything else in user scope.
        $new = $target + ';' + $raw.TrimStart(';')
        $key.SetValue('Path', $new, $kind)
        Write-Host "added to the user PATH: $target"

        # Tell the shell to reload the environment. Without this the change is
        # only visible to processes started after the next sign-in; with it,
        # anything Explorer launches from now on sees it. Best effort -- a failure
        # here costs a sign-in, not correctness.
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

# Prove it end to end, in the shell this exists for. $env:Path in this process
# does not include the new entry -- Windows does not propagate PATH into a
# running process, and cmd.exe would inherit this process's stale copy -- so
# extend it here first. This only checks the resolution mechanism; it is not a
# claim about what an already-open window can see.
if (-not (Test-Path (Join-Path $shims 'ruby.exe'))) {
    Write-Host 'No ruby shim present - skipping the cmd.exe check (no ruby in the mise config?).'
    return
}

$env:Path = $shims + ';' + $env:Path
$out = & cmd.exe /c 'ruby -v' 2>&1 | ForEach-Object { "$_" }

if ($LASTEXITCODE -eq 0) {
    Write-Host "cmd.exe now resolves ruby: $out"
} else {
    Write-Warning ("ruby.exe is in $shims but cmd.exe still could not run it: $out " +
                   'The PATH entry is written; the shim itself looks broken. Try `mise reshim`.')
}
