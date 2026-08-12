# Write the PowerShell profile stubs.
#
# chezmoi owns ~/.config/powershell/profile.ps1. These stubs just source it, so
# they can live wherever PowerShell expects a profile -- including inside a
# OneDrive-synced Documents folder, where chezmoi itself must never write. The
# stub never changes, so OneDrive has nothing to conflict over.
#
# DO NOT construct the profile path by hand. An earlier version hardcoded
# "$HOME\OneDrive\Documents\..." because sophon's Documents folder is redirected
# to OneDrive. On any machine without that redirection it would have created a
# bogus OneDrive folder and written the stub somewhere PowerShell never looks --
# no error, no profile, no mise activation, no JAVA_HOME. Ask each edition where
# its own profile goes instead; $PROFILE already accounts for redirection.
#
# Runs AFTER the winget script, because pwsh 7 arrives from the manifest.

function Get-ProfilePath([string]$exe) {
    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $p = & $exe -NoProfile -NonInteractive -Command '$PROFILE.CurrentUserCurrentHost' 2>$null
        if ($p) { return $p.Trim() }
    } catch { }
    return $null
}

$stub = @'
# Stub only - the real profile is managed by chezmoi and lives outside any synced
# folder. Do not add configuration here; edit ~/.config/powershell/profile.ps1.
. "$HOME\.config\powershell\profile.ps1"
'@

$targets = @()
foreach ($exe in 'powershell.exe', 'pwsh.exe') {
    $p = Get-ProfilePath $exe
    if ($p) { $targets += $p } else { Write-Host "$exe not available - skipping" }
}
$targets = $targets | Select-Object -Unique

if (-not $targets) {
    Write-Warning 'No PowerShell profile paths resolved - nothing written.'
    return
}

foreach ($target in $targets) {
    New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null

    if (Test-Path $target) {
        if ((Get-Content $target -Raw) -match '\.config\\powershell\\profile\.ps1') {
            Write-Host "already correct: $target"
            continue
        }
        Copy-Item $target "$target.bak" -Force
        Write-Host "existing profile backed up: $target.bak"
    }

    Set-Content $target -Value $stub -Encoding utf8
    Write-Host "stub written: $target"
}
