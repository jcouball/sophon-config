# Delete persisted MISE_*_VERSION environment variables from the user scope.
#
# mise resolves a tool's version from, highest precedence first: a
# MISE_<TOOL>_VERSION environment variable, then per-project config, then the
# global ~/.config/mise/config.toml this repo manages. A MISE_*_VERSION value
# persisted in HKCU:\Environment therefore outranks layer 3's declaration in
# every process on the machine, invisibly and indefinitely. There is no
# legitimate persistent use: a global pin belongs in config.toml
# (`mise use -g`), a project pin in that project's own mise config, and a
# temporary override in the one shell session that sets it.
#
# WHAT THIS CLEANS UP (found 2026-08-28): HKCU:\Environment held
# MISE_RUBY_VERSION as an empty string - the remnant of a real "3.4.2" pin
# cleared incompletely - and the logon session still carried the original
# value, because Explorer's environment block is built at sign-in. Everything
# Explorer launched (VS Code -> its terminals and Claude Code's shells)
# inherited MISE_RUBY_VERSION=3.4.2, mise silently selected Ruby 3.4.2 over
# config.toml's 4.0.6, and `bundle exec rake spec` in process_executer died
# with Bundler::GemNotFound - the gems were installed, just under the other
# Ruby. Nothing prints "an environment variable chose your Ruby"; the one
# breadcrumb is `mise ls ruby`, whose source column named the culprit. Hence a
# script rather than a note: on a clean rebuild this is a no-op, and that is
# fine - it exists to delete the class of problem, not just the instance.

$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
if (-not $key) {
    Write-Warning 'Could not open HKCU:\Environment for writing - nothing checked.'
    return
}

try {
    $stale = @($key.GetValueNames() | Where-Object { $_ -like 'MISE_*_VERSION' })
    if (-not $stale) {
        Write-Host 'no persisted MISE_*_VERSION pins - nothing to do'
    } else {
        foreach ($name in $stale) {
            $value = $key.GetValue($name, '',
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $key.DeleteValue($name)
            Write-Host ("deleted user environment variable {0}='{1}'" -f $name, $value)
        }

        # Broadcast so processes Explorer launches from now on stop seeing it.
        # Best effort, and honestly limited either way: a process that already
        # holds the old value (this sign-in's Explorer included, if the value
        # predates it) keeps it until it exits - sign out or reboot to be sure.
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
        } catch {}
        Write-Host ('The logon session may still carry an old value - sign out and back ' +
                    'in (or reboot) before trusting an Explorer-launched process.')
    }
} finally {
    $key.Close()
}

# Machine scope should never hold one either, but fixing it needs elevation and
# this script may not have it - look and warn, do not try.
foreach ($name in ([Environment]::GetEnvironmentVariables('Machine').Keys |
        Where-Object { $_ -like 'MISE_*_VERSION' })) {
    Write-Warning "machine-scope $name is set - remove it from an elevated shell."
}
