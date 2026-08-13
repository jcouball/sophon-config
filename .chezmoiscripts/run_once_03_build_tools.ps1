# Verify the Visual Studio 2022 Build Tools C++ workload is present.
#
# THIS SCRIPT DOES REAL WORK - it is not a safety net. Verified on a clean VM.
#
# `winget export` does record the override arguments -- the manifest carries:
#
#   "InitialOverrideArguments": "--wait --quiet --norestart
#                                --add Microsoft.VisualStudio.Workload.VCTools
#                                --includeRecommended"
#
# but `winget import` does NOT apply them. The data survives the round-trip; the
# effect does not. On a clean rebuild the import installs Build Tools with no C++
# workload at all, which looks like success: the package is listed, the manifest
# is satisfied, and nothing complains until rust reaches the link step and fails
# with an error that points nowhere near the real cause.
#
# Needed because rustup defaults to the msvc toolchain, which requires link.exe.
# node-gyp needs it too, for npm packages with native modules.

$vcTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC'

if (Test-Path $vcTools) {
    $v = (Get-ChildItem $vcTools -Directory | Select-Object -Last 1).Name
    Write-Host "C++ build tools present (MSVC $v)"
    return
}

Write-Warning 'Build Tools present but the C++ workload is missing.'
Write-Host 'Adding the workload explicitly (several GB, no progress bar)...'

# --force is REQUIRED here, not defensive. Script 01's `winget import` has
# already installed the package -- without the workload, because import records
# InitialOverrideArguments in the manifest but does not apply them. A plain
# `winget install` against an installed package answers "no available upgrade"
# and silently skips the --override, leaving the workload missing and rust
# failing at link time much later. --force reruns the installer so --add applies.
# --source winget is REQUIRED. A fresh Windows image's msstore source fails its
# certificate check (0x8a15005e), and winget then refuses to auto-select a
# source -- so this call died with "Failed when searching source: msstore" and
# the workload never installed. Verified on a clean VM.
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --force `
    --source winget `
    --accept-package-agreements --accept-source-agreements `
    --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'

if (Test-Path $vcTools) {
    Write-Host 'C++ workload installed.'
} else {
    Write-Warning 'Still missing - rust will fail at link time. Check the --override arguments.'
}
