# Tests of Split-WingetManifest, the function script 01 uses to divide the
# winget manifest into the portable packages and the rest.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\winget-install.tests.ps1
#   pwsh       -NoProfile -File tests\winget-install.tests.ps1
#
# Run it both ways. The function is read out of the script's template and
# defined here, so the script itself is not run, winget is not called and
# nothing on the machine is read or changed. TESTING.md says where this fits.
#
# Each case prints "ok" or "FAIL". The exit code is 1 if any case failed.

param(
    # The script under test. Left out: the one in this checkout.
    [string]$Script = (Join-Path (Split-Path $PSScriptRoot -Parent) '.chezmoiscripts\run_onchange_01_winget_install.ps1.tmpl'),
    # The repository's own manifest. Left out: the one in this checkout.
    [string]$Manifest = (Join-Path (Split-Path $PSScriptRoot -Parent) 'winget-packages.json')
)

$ErrorActionPreference = 'Stop'

$text = [IO.File]::ReadAllText($Script)
if ($text -notmatch '(?ms)^function Split-WingetManifest\(.*?^\}') {
    Write-Host "FAIL  could not find Split-WingetManifest in $Script"
    exit 1
}
Invoke-Expression $Matches[0]
if ($text -notmatch '(?m)^\$portableIds = (.+)$') {
    Write-Host "FAIL  could not find `$portableIds in $Script"
    exit 1
}
$portableIds = Invoke-Expression $Matches[1]

$passed = 0
$failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:passed++; Write-Host "ok    $Name" }
    else { $script:failed++; Write-Host "FAIL  $Name"; if ($Detail) { Write-Host "      $Detail" } }
}
function Ids($Json) {
    @(($Json | ConvertFrom-Json).Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier })
}

$two = @'
{
  "$schema": "https://aka.ms/winget-packages.schema.2.0.json",
  "CreationDate": "2026-01-01T00:00:00.000-00:00",
  "Sources": [
    { "Packages": [ { "PackageIdentifier": "A.One" }, { "PackageIdentifier": "B.Two" }, { "PackageIdentifier": "C.Three" } ],
      "SourceDetails": { "Argument": "https://cdn.winget.microsoft.com/cache", "Identifier": "Microsoft.Winget.Source_8wekyb3d8bbwe", "Name": "winget", "Type": "Microsoft.PreIndexed.Package" } },
    { "Packages": [ { "PackageIdentifier": "D.Four" } ],
      "SourceDetails": { "Argument": "https://storeedgefd.dsx.mp.microsoft.com/v9.0", "Identifier": "StoreEdgeFD", "Name": "msstore", "Type": "Microsoft.Rest" } }
  ],
  "WinGetVersion": "1.0.0"
}
'@

$r = Split-WingetManifest $two @('B.Two')
Check 'one of three: the named package is the portable part' ((Ids $r.Portable) -join ',' -eq 'B.Two') ((Ids $r.Portable) -join ',')
Check 'one of three: the rest keep their order' ((Ids $r.Main) -join ',' -eq 'A.One,C.Three,D.Four') ((Ids $r.Main) -join ',')
Check 'one of three: the counts' ($r.PortableCount -eq 1 -and $r.MainCount -eq 3) "$($r.PortableCount), $($r.MainCount)"
Check 'a part with one package still has a list of packages' ($r.Portable -match '"Packages":\s*\[') $r.Portable
Check 'a part with one source still has a list of sources' ($r.Portable -match '"Sources":\s*\[') $r.Portable
Check 'the portable part has only the source it uses' (@(($r.Portable | ConvertFrom-Json).Sources).Count -eq 1)
Check 'the source details come with it' ((($r.Portable | ConvertFrom-Json).Sources[0].SourceDetails.Name) -eq 'winget')
Check 'the schema line is kept in both' ($r.Main -match 'winget-packages\.schema' -and $r.Portable -match 'winget-packages\.schema')

$r = Split-WingetManifest $two @('D.Four')
Check 'the only package of a source: that source leaves the main part' (@(($r.Main | ConvertFrom-Json).Sources).Count -eq 1 -and (Ids $r.Main) -join ',' -eq 'A.One,B.Two,C.Three')
Check 'the only package of a source: it is the portable part' ((Ids $r.Portable) -join ',' -eq 'D.Four' -and (($r.Portable | ConvertFrom-Json).Sources[0].SourceDetails.Name) -eq 'msstore')

$r = Split-WingetManifest $two @()
Check 'no names: nothing is portable' ($r.PortableCount -eq 0 -and $r.MainCount -eq 4)

$r = Split-WingetManifest $two @('Not.There')
Check 'a name that is not in the manifest: nothing is portable' ($r.PortableCount -eq 0 -and $r.MainCount -eq 4)

$r = Split-WingetManifest $two @('A.One', 'B.Two', 'C.Three', 'D.Four')
Check 'every name: nothing is left in the main part' ($r.MainCount -eq 0 -and $r.PortableCount -eq 4)

$r = Split-WingetManifest $two @('b.two')
Check 'a name in another case still matches, as winget matches ids' ($r.PortableCount -eq 1)

# The repository's own manifest and the script's own list.
$real = [IO.File]::ReadAllText($Manifest)
$all = Ids $real
$r = Split-WingetManifest $real $portableIds
Check "the real manifest: every package is in exactly one part ($($all.Count) packages)" ($r.MainCount + $r.PortableCount -eq $all.Count -and @(Compare-Object $all ((Ids $r.Main) + (Ids $r.Portable))).Count -eq 0)
Check "the real manifest: each of the script's portable packages is in it ($($portableIds -join ', '))" ($r.PortableCount -eq $portableIds.Count) "found $($r.PortableCount) of $($portableIds.Count)"
Check 'the real manifest: the Visual C++ runtime the portable packages need is in the main part' ((Ids $r.Main) -contains 'Microsoft.VCRedist.2015+.x64')

Write-Host ''
Write-Host "$passed passed, $failed failed."
if ($failed -gt 0) { exit 1 }
exit 0
