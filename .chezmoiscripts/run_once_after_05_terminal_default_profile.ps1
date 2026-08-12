# Point Windows Terminal's default profile at PowerShell 7.
#
# settings.json is deliberately NOT managed as a file. Windows Terminal rewrites
# it whenever its generated profiles change -- installing WSL, Git or VS adds
# entries -- so chezmoi reported permanent "MM" drift on every status check. That
# is worse than not managing it: constant false drift trains you to ignore the
# one command that tells you whether the repo is honest.
#
# So patch the single setting that matters and leave the rest of the file alone.
#
# The GUID is Windows Terminal's deterministic identifier for the PowerShell Core
# profile: derived from the profile source and name, so it is the same on every
# machine rather than something generated per-install.

$settings = Join-Path $env:LOCALAPPDATA `
    'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
$pwshGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

if (-not (Test-Path $settings)) {
    Write-Host 'Windows Terminal settings not found - skipping (Terminal may not have run yet).'
    return
}

try {
    $raw = Get-Content $settings -Raw
    $json = $raw | ConvertFrom-Json
} catch {
    Write-Warning "Could not parse $settings - leaving it alone."
    return
}

if ($json.defaultProfile -eq $pwshGuid) {
    Write-Host 'Windows Terminal already defaults to PowerShell 7.'
    return
}

# Confirm the profile actually exists before pointing at it -- on a machine
# without pwsh installed this GUID would name nothing and Terminal would fall
# back with no explanation.
if (-not ($json.profiles.list | Where-Object { $_.guid -eq $pwshGuid })) {
    Write-Warning 'No PowerShell 7 profile in Windows Terminal yet - leaving defaultProfile alone.'
    return
}

Copy-Item $settings "$settings.bak" -Force

# Targeted string replacement rather than re-serialising: settings.json carries
# comments and formatting that ConvertTo-Json would discard.
$pattern = '("defaultProfile"\s*:\s*")\{[0-9a-fA-F-]+\}(")'
$updated = [regex]::Replace($raw, $pattern, ('${1}' + $pwshGuid + '${2}'), 1)

if ($updated -eq $raw) {
    Write-Warning 'defaultProfile not found in settings.json - nothing changed.'
} else {
    Set-Content $settings -Value $updated -Encoding utf8
    Write-Host "Windows Terminal default profile set to PowerShell 7 (backup: $settings.bak)"
}
