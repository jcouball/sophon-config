# Tests of four functions in script 01: Split-WingetManifest, which divides
# the winget manifest into the portable packages and the rest,
# Get-WingetBusyIds, which reads from winget's output the packages whose
# installer found Windows Installer busy, Get-WingetAgainResult, which
# says what became of a package that was imported again, and
# Get-WingetMainNext, which says what to do about the main import's exit code.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\winget-install.tests.ps1
#   pwsh       -NoProfile -File tests\winget-install.tests.ps1
#
# Run it both ways. The functions are read out of the script's template and
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
if ($text -notmatch '(?ms)^function Get-WingetBusyIds\(.*?^\}') {
    Write-Host "FAIL  could not find Get-WingetBusyIds in $Script"
    exit 1
}
Invoke-Expression $Matches[0]
if ($text -notmatch '(?ms)^function Get-WingetAgainResult\(.*?^\}') {
    Write-Host "FAIL  could not find Get-WingetAgainResult in $Script"
    exit 1
}
Invoke-Expression $Matches[0]
if ($text -notmatch '(?ms)^function Get-WingetMainNext\(.*?^\}') {
    Write-Host "FAIL  could not find Get-WingetMainNext in $Script"
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

# Get-WingetBusyIds. The lines are winget's own, from the certification run
# of 2026-11-28 in which Tailscale was not installed.
$run = @'
(18/20) Found Windows Subsystem for Linux [Microsoft.WSL] Version 3.0.5
This application is licensed to you by its owner.
Starting package install...
Successfully installed
(19/20) Found Tailscale [Tailscale.Tailscale] Version 1.104.7
This application is licensed to you by its owner.
Microsoft is not responsible for, nor does it grant any licenses to, third-party packages.
Downloading https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-amd64.msi
Successfully verified installer hash
Starting package install...
Another installation is already in progress. Try again later.
Installer failed with exit code: 1618
Installer log is available at: C:\Users\certuser\AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir\Tailscale.Tailscale.1.104.7-26-11-28-08-58-50.log
(20/20) Found Telegram Desktop [Telegram.TelegramDesktop] Version 7.4.7
This application is licensed to you by its owner.
Starting package install...
Successfully installed
'@ -split "`r?`n"

$ids = @(Get-WingetBusyIds $run)
Check 'busy: the package whose installer ended with 1618 is found' ($ids -join ',' -eq 'Tailscale.Tailscale') ($ids -join ',')

$ids = @(Get-WingetBusyIds ($run | Where-Object { $_ -notmatch '1618' }))
Check 'busy: a run with no 1618 gives nothing' ($ids.Count -eq 0) ($ids -join ',')

$ids = @(Get-WingetBusyIds ($run -replace '1618', '1603'))
Check 'busy: another exit code is not a busy installer' ($ids.Count -eq 0) ($ids -join ',')

$ids = @(Get-WingetBusyIds ($run -replace 'exit code: 1618', 'exit code: 16180'))
Check 'busy: a longer code that starts with 1618 is not one' ($ids.Count -eq 0) ($ids -join ',')

$ids = @(Get-WingetBusyIds ($run + $run))
Check 'busy: two failures give two ids, in order' ($ids.Count -eq 2) ($ids -join ',')

$twoBusy = @(
    '(1/3) Found One [A.One] Version 1', 'Installer failed with exit code: 1618',
    '(2/3) Found Two [B.Two] Version 2', 'Successfully installed',
    '(3/3) Found Three [C.Three] Version 3', 'Installer failed with exit code: 1618')
$ids = @(Get-WingetBusyIds $twoBusy)
Check 'busy: the failures of two packages, with one between that installed' ($ids -join ',' -eq 'A.One,C.Three') ($ids -join ',')

$ids = @(Get-WingetBusyIds @('(1/1) Found Tool [beta] [A.One] Version 1', 'Installer failed with exit code: 1618'))
Check 'busy: a name with brackets in it: the id is the last pair' ($ids -join ',' -eq 'A.One') ($ids -join ',')

$ids = @(Get-WingetBusyIds @('Installer failed with exit code: 1618'))
Check 'busy: a 1618 before any package is named gives nothing' ($ids.Count -eq 0) ($ids -join ',')

$ids = @(Get-WingetBusyIds @('  (1/1) Found One [A.One] Version 1  ', 'Installer failed with exit code: 1618  '))
Check 'busy: spaces around the lines do not matter' ($ids -join ',' -eq 'A.One') ($ids -join ',')

$ids = @(Get-WingetBusyIds @())
Check 'busy: no lines at all gives nothing' ($ids.Count -eq 0)

$ids = @(Get-WingetBusyIds $null)
Check 'busy: winget printing nothing gives nothing' ($ids.Count -eq 0)

# What the script does with the ids: the split, given them, is the manifest
# to import again.
$r = Split-WingetManifest $two @(Get-WingetBusyIds $twoBusy)
Check 'busy: the manifest to import again has those packages only' ((Ids $r.Portable) -join ',' -eq 'A.One,C.Three') ((Ids $r.Portable) -join ',')

# Get-WingetAgainResult. -1978335180 is the exit code winget import gave in
# the certification VM for "One or more imported packages failed to install".
$one = @('(1/1) Found Tailscale [Tailscale.Tailscale] Version 1.104.7', 'Starting package install...')
$r = Get-WingetAgainResult ($one + 'Successfully installed') 0
Check 'again: exit code 0 is installed' ($r -eq 'installed') $r
$r = Get-WingetAgainResult @('Package is already installed: Tailscale.Tailscale') 0
Check 'again: already installed, which also exits 0, is installed' ($r -eq 'installed') $r
$r = Get-WingetAgainResult ($one + 'Installer failed with exit code: 1618') -1978335180
Check 'again: 1618 once more is busy' ($r -eq 'busy') $r
$r = Get-WingetAgainResult ($one + 'Installer failed with exit code: 1603') -1978335180
Check 'again: another installer exit code is failed, not installed' ($r -eq 'failed') $r
$r = Get-WingetAgainResult @('The source could not be found.') -1978335180
Check 'again: winget failing before it names the package is failed' ($r -eq 'failed') $r
$r = Get-WingetAgainResult @() 1
Check 'again: no output and a failing exit code is failed' ($r -eq 'failed') $r
$r = Get-WingetAgainResult $null -1
Check 'again: nothing printed at all is failed' ($r -eq 'failed') $r

# Get-WingetMainNext, with the exit code and the number of busy packages.
$r = Get-WingetMainNext 0 0
Check 'main: exit code 0 and nothing busy is done' ($r -eq 'done') $r
$r = Get-WingetMainNext -1978335180 0
Check 'main: a failing exit code and nothing busy is failed' ($r -eq 'failed') $r
$r = Get-WingetMainNext -1978335214 0
Check 'main: winget failing before any package, such as a missing source, is failed' ($r -eq 'failed') $r
$r = Get-WingetMainNext 1 0
Check 'main: a small positive exit code is failed too' ($r -eq 'failed') $r
$r = Get-WingetMainNext -1978335180 1
Check 'main: a failing exit code with one busy package is check' ($r -eq 'check') $r
$r = Get-WingetMainNext -1978335180 2
Check 'main: a failing exit code with two busy packages is check' ($r -eq 'check') $r
$r = Get-WingetMainNext 0 1
Check 'main: exit code 0 is done whatever was read as busy' ($r -eq 'done') $r
$r = Get-WingetMainNext -1978335180 @(Get-WingetBusyIds $run).Count
Check 'main: the failed run of 2026-11-28, one busy package, is check' ($r -eq 'check') $r

Write-Host ''
Write-Host "$passed passed, $failed failed."
if ($failed -gt 0) { exit 1 }
exit 0
