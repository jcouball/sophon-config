# Verify the Visual Studio 2022 Build Tools C++ workload is present.
#
# This is a SAFETY NET, not the primary install path. winget 1.29's export does
# record override arguments -- the manifest carries:
#
#   "InitialOverrideArguments": "--wait --quiet --norestart
#                                --add Microsoft.VisualStudio.Workload.VCTools
#                                --includeRecommended"
#
# so run_onchange_02's `winget import` should install the workload correctly on a
# rebuild. This script exists because the failure mode is expensive and silent:
# Build Tools without the C++ workload looks installed, satisfies the manifest,
# and only fails when rust reaches the link step with a confusing error. Cheap to
# check, costly to miss.
#
# Needed because rustup defaults to the msvc toolchain, which requires link.exe.
# node-gyp needs it too, for npm packages with native modules.

$vcTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC'

if (Test-Path $vcTools) {
    $v = (Get-ChildItem $vcTools -Directory | Select-Object -Last 1).Name
    Write-Host "C++ build tools present (MSVC $v)"
    return
}

Write-Warning 'Build Tools present but the C++ workload is missing - the manifest override did not take.'
Write-Host 'Installing the workload explicitly (several GB, no progress bar)...'

winget install --id Microsoft.VisualStudio.2022.BuildTools --exact `
    --accept-package-agreements --accept-source-agreements `
    --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'

if (Test-Path $vcTools) {
    Write-Host 'C++ workload installed.'
} else {
    Write-Warning 'Still missing - rust will fail at link time. Check the --override arguments.'
}
