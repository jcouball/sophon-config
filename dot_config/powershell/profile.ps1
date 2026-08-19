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

function Update-WingetManifest {
    <#
    .SYNOPSIS
    Regenerate layer 2's manifest from what is actually installed.

    .DESCRIPTION
    Run this after every `winget install` or `winget uninstall`, so the repo
    never lags the machine. It exports the current package set over
    winget-packages.json in the chezmoi source directory and strips the
    deliberate exclusions, which `winget export` re-adds every single time.

    $skip below is the ONLY executable definition of those exclusions -- do not
    duplicate the list into script 01's header or the README.
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path (chezmoi source-path) 'winget-packages.json'))

    # Windows PowerShell 5.1 emits a different JSON layout and a UTF-8 BOM, which
    # rewrites all 114 lines of the manifest and flips script 01's hash for no
    # reason. Verified, not theoretical.
    if ($PSVersionTable.PSEdition -ne 'Core') {
        Write-Error 'Run this in pwsh 7 -- 5.1 reformats the whole manifest and adds a BOM.'
        return
    }

    # DELIBERATE EXCLUSIONS
    #   Warp.Warp -- its installer takes an extraordinarily long time, launches a
    #     welcome window mid-run, and was one of the packages that stalled a bulk
    #     upgrade on sophon. Cause unknown. Install it by hand when wanted:
    #     `winget install Warp.Warp`. Revisit if the installer improves.
    $skip = @('Warp.Warp')

    $before = if (Test-Path $Path) { Get-Content $Path -Raw | ConvertFrom-Json }
    $was    = if ($before) { @($before.Sources[0].Packages.PackageIdentifier) } else { @() }

    winget export -o $Path --disable-interactivity | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "winget export failed (exit $LASTEXITCODE)"; return }

    $json = Get-Content $Path -Raw | ConvertFrom-Json
    $json.Sources[0].Packages = @(
        $json.Sources[0].Packages | Where-Object { $_.PackageIdentifier -notin $skip }
    )
    $now = @($json.Sources[0].Packages.PackageIdentifier)

    # CreationDate is stamped fresh by every export. Left alone it changes the
    # file -- and so script 01's manifest hash -- even when nothing was installed,
    # re-running the whole 33-package import for nothing.
    $delta = Compare-Object -ReferenceObject $was -DifferenceObject $now
    if ($before -and -not $delta) { $json.CreationDate = $before.CreationDate }

    $json | ConvertTo-Json -Depth 10 | Set-Content $Path -Encoding utf8

    if ($delta) {
        $delta | ForEach-Object {
            '{0} {1}' -f ($_.SideIndicator -replace '=>', 'added:' -replace '<=', 'gone: '), $_.InputObject
        }
        Write-Host 'Commit the manifest: chezmoi cd; git commit -am "..."; git push'
    }
    else { Write-Host 'manifest already matches the machine' }
}
