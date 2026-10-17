# Keep `winget upgrade --all` away from Microsoft Edge.
#
# Edge ships with Windows, and Edge Update keeps it current in the background.
# winget's catalog entry for Edge uses a different installer type from the copy
# Windows installed, so `winget upgrade --all` fails on Edge every time with
# "the install technology is different from the current version installed".
# topgrade runs that command weekly, reports winget as FAILED, and stops at a
# retry prompt. winget's advice, uninstall and reinstall, does not apply to a
# browser Windows owns.
#
# A pin excludes Edge from `upgrade --all`. `winget upgrade --id Microsoft.Edge`
# still works by hand. A pin lives on the machine, in no file this repo
# manages, so this script recreates it on a rebuild. It checks first because
# `winget pin add` fails when the pin already exists.

$ErrorActionPreference = 'Stop'

# `winget pin list` ignores --id (verified on v1.29.380: a filter for a package
# that does not exist still lists every pin), so the check parses the table.
# The \s anchors keep Microsoft.Edge.Beta, .Dev, and EdgeWebView2Runtime pins
# from counting as the stable Edge pin.
$pins = & winget pin list | Out-String
if ($pins -match '\sMicrosoft\.Edge\s') {
    Write-Host 'Microsoft.Edge already pinned'
    exit 0
}

# --source winget for the reason script 03 gives: a fresh image's msstore source
# fails its certificate check and winget then refuses to pick a source.
& winget pin add --id Microsoft.Edge --exact --source winget --accept-source-agreements
if ($LASTEXITCODE -ne 0) {
    Write-Warning "winget could not pin Microsoft.Edge (exit $LASTEXITCODE)."
    exit 1
}
