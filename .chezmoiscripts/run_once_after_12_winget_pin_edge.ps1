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
#
# The flags are not optional. On a machine that has never used winget
# interactively, a bare `winget pin list` asks whether to accept the msstore
# source's agreements and waits. Its output is captured here, so the question
# is never shown and the apply stops with nothing on screen. The November 2026
# certification run sat there until someone typed Y. --source winget keeps
# msstore out of it, --accept-source-agreements answers the question, and
# --disable-interactivity makes any other question an error and not a wait.
$pins = & winget pin list --source winget --accept-source-agreements --disable-interactivity | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Warning "winget pin list failed (exit $LASTEXITCODE):`n$pins"
    exit 1
}
if ($pins -match '\sMicrosoft\.Edge\s') {
    Write-Host 'Microsoft.Edge already pinned'
    exit 0
}

# --source winget for the reason script 03 gives: a fresh image's msstore source
# fails its certificate check and winget then refuses to pick a source.
& winget pin add --id Microsoft.Edge --exact --source winget --accept-source-agreements --disable-interactivity
if ($LASTEXITCODE -ne 0) {
    Write-Warning "winget could not pin Microsoft.Edge (exit $LASTEXITCODE)."
    exit 1
}
