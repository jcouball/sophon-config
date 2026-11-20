# Write a copy of each dated package set in the toolchain cache as one .tar,
# and a copy of each MSYS2 base archive, ready to be uploaded.
#
#   & "$HOME\.local\bin\ruby-toolchains-archive.ps1" -OutDir "$HOME\toolchain-sets"
#
# WHY. MSYS2 deletes old package files without notice, and a rebuilt machine
# has no cache. The copies are kept as assets of one release of this repo
# ([rubyToolchains] archive in .chezmoidata.toml), where
# ruby-toolchains-packages.sh looks for a set the cache cannot supply and
# ruby-toolchains.ps1 looks for a base archive MSYS2 no longer has.
#
# A set's .tar is named after its list, set-<day>-<id>.tar, and holds the list
# and every package and signature the list names, with no folders. The name
# changes when the day or the package list does, so a .tar is uploaded once
# and never replaced. A package that two sets share is in both: each .tar
# restores its set without the others.
#
# This script only writes files. Uploading them is a step by hand, in "Add or
# move a gcc toolchain" in the README. It runs under Windows PowerShell 5.1
# and pwsh 7, and uses the tar.exe that comes with Windows.

param(
    # Where the .tar files and base archives are written.
    [Parameter(Mandatory)][string]$OutDir,
    # Where the toolchains live.
    [string]$Root = (Join-Path $HOME '.local\opt\msys2')
)

$ErrorActionPreference = 'Stop'

$cache = Join-Path $Root 'cache'
$sets = Join-Path $cache 'ucrt64'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

$lists = @(Get-ChildItem $sets -Filter 'set-*.list' -ErrorAction SilentlyContinue)
if (-not $lists) {
    Write-Warning "No set-*.list in $sets. Build a toolchain first."
    exit 1
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$failed = $false
foreach ($list in $lists) {
    $names = @($list.Name)
    foreach ($file in [IO.File]::ReadAllLines($list.FullName)) {
        if (-not $file) { continue }
        $names += $file, "$file.sig"
    }
    $missing = @($names | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sets $_)) })
    if ($missing) {
        Write-Warning "$($list.Name) names files the cache does not hold, so no copy was written: $($missing -join ', ')"
        $failed = $true
        continue
    }

    $out = Join-Path $OutDir ($list.BaseName + '.tar')
    # tar reads the names from a file: there are too many for a command line.
    # No BOM, or tar takes it as part of the first name.
    $nameFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllLines($nameFile, [string[]]$names, (New-Object Text.UTF8Encoding $false))
        & $tar -cf "$out.partial" -C $sets -T $nameFile
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $($list.Name) (exit $LASTEXITCODE)." }
    } finally {
        Remove-Item $nameFile -Force -ErrorAction SilentlyContinue
    }
    Move-Item "$out.partial" $out -Force
    Write-Host ("{0}  {1} files, {2:N0} MB" -f (Split-Path $out -Leaf), $names.Count, ((Get-Item $out).Length / 1MB))
}

foreach ($base in Get-ChildItem $cache -Filter 'msys2-base-*.sfx.exe' -ErrorAction SilentlyContinue) {
    Copy-Item $base.FullName (Join-Path $OutDir $base.Name) -Force
    Write-Host ("{0}  {1:N0} MB" -f $base.Name, ($base.Length / 1MB))
}

if ($failed) { exit 1 }
