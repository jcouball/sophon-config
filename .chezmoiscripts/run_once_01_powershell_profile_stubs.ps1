# Create the PowerShell profile stubs.
#
# $PROFILE resolves under OneDrive on this machine (Documents is redirected), and
# chezmoi must never manage a file inside a synced folder -- both tools write the
# path independently and you get "-SOPHON.ps1" conflict copies with no winner.
#
# So: chezmoi owns ~/.config/powershell/profile.ps1, and these stubs just source
# it. They are written once and never change, so OneDrive has nothing to conflict
# over. One stub per edition -- pwsh 7 reads PowerShell\, 5.1 reads
# WindowsPowerShell\.

$stub = @'
# Stub only - the real profile is managed by chezmoi and lives outside OneDrive.
# Do not add configuration here; edit ~/.config/powershell/profile.ps1 instead.
. "$HOME\.config\powershell\profile.ps1"
'@

foreach ($edition in 'PowerShell', 'WindowsPowerShell') {
    $dir = Join-Path $HOME "OneDrive\Documents\$edition"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $target = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'

    if (Test-Path $target) {
        $existing = Get-Content $target -Raw
        if ($existing -match '\.config\\powershell\\profile\.ps1') {
            Write-Host "stub already correct: $target"
            continue
        }
        Copy-Item $target "$target.bak" -Force
        Write-Host "existing profile backed up to $target.bak"
    }

    Set-Content $target -Value $stub -Encoding utf8
    Write-Host "stub written: $target"
}
