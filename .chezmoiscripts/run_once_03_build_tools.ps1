# Visual Studio 2022 Build Tools, with the C++ workload.
#
# THIS CANNOT COME FROM THE WINGET MANIFEST. `winget export` records the package
# id but not --override, so a plain `winget import` installs Build Tools without
# the C++ workload: present in the manifest, still no linker, and rust fails only
# at link time with a confusing error. It has to be an explicit line here.
#
# Needed because rustup installs the msvc toolchain by default, which requires
# link.exe. Also required by node-gyp for npm packages with native modules.

$vcTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC'

if (Test-Path $vcTools) {
    Write-Host "VC++ build tools already present at $vcTools"
    return
}

Write-Host 'Installing VS 2022 Build Tools with the C++ workload (several GB, no progress bar)...'
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact `
    --accept-package-agreements --accept-source-agreements `
    --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'

if (Test-Path $vcTools) {
    Write-Host 'C++ workload installed.'
} else {
    Write-Warning 'Build Tools installed but the VC++ workload is missing - check the --override arguments.'
}
