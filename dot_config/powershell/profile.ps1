# sophon PowerShell profile
# Managed by chezmoi (jcouball/sophon-config). This is the real profile; the
# files at $PROFILE are one-line stubs that source it. Edit here, not there.

if (Get-Command mise -ErrorAction SilentlyContinue) {
    # Activation exports JAVA_HOME, ANT_HOME, GOROOT, CARGO_HOME and RUSTUP_HOME
    # as well as PATH -- the JRuby build reads JAVA_HOME and ANT_HOME.
    #
    # This works in Windows PowerShell 5.1 as well, with one limitation: mise's
    # chpwd hook needs pwsh 7, so per-directory version switching only happens
    # there. 5.1 still gets the globals. Silence the nag about it.
    if ($PSVersionTable.PSEdition -ne 'Core') { $env:MISE_PWSH_CHPWD_WARNING = 0 }

    (& mise activate pwsh) | Out-String | Invoke-Expression
}
