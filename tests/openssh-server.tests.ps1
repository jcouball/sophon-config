# Tests of Test-TailnetAddress and Test-AddressAssigned, the functions script
# 11 uses to tell a firewall rule that is limited to sophon's own tailnet
# address from one that is not.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\openssh-server.tests.ps1
#   pwsh       -NoProfile -File tests\openssh-server.tests.ps1
#
# Run it both ways. The functions are read out of the script's template and
# defined here, so the script itself is not run and nothing on the machine is
# read or changed. TESTING.md says where this fits.
#
# Each case prints "ok" or "FAIL". The exit code is 1 if any case failed.

param(
    # The script under test. Left out: the one in this checkout.
    [string]$Script = (Join-Path (Split-Path $PSScriptRoot -Parent) '.chezmoiscripts\run_onchange_after_11_openssh_server.ps1.tmpl')
)

$ErrorActionPreference = 'Stop'

$text = [IO.File]::ReadAllText($Script)
foreach ($name in 'Test-TailnetAddress', 'Test-AddressAssigned') {
    if ($text -notmatch "(?ms)^function $name\(.*?^\}") {
        Write-Host "FAIL  could not find $name in $Script"
        exit 1
    }
    Invoke-Expression $Matches[0]
}

$cases = @(
    @{ Address = '100.121.213.115';            Expect = $true;  Why = 'a tailnet IPv4 address' }
    @{ Address = '100.64.0.0';                 Expect = $true;  Why = 'the first address of 100.64.0.0/10' }
    @{ Address = '100.127.255.255';            Expect = $true;  Why = 'the last address of 100.64.0.0/10' }
    @{ Address = '100.121.213.115/32';         Expect = $true;  Why = 'one address written with /32' }
    @{ Address = '100.121.213.115/255.255.255.255'; Expect = $true; Why = 'one address written with a full mask' }
    @{ Address = 'fd7a:115c:a1e0::2449:d574';  Expect = $true;  Why = 'a tailnet IPv6 address' }
    @{ Address = 'FD7A:115C:A1E0::2449:D574';  Expect = $true;  Why = 'the same in upper case' }
    @{ Address = 'fd7a:115c:a1e0::2449:d574/128'; Expect = $true; Why = 'one IPv6 address written with /128' }
    @{ Address = 'fd7a:115c:a1e0:0:0:0:2449:d574'; Expect = $true; Why = 'the same IPv6 address written out in full' }
    @{ Address = 'FD7A:115C:A1E0:0000:0000:0000:2449:D574'; Expect = $true; Why = 'in full, with leading zeros, in upper case' }
    @{ Address = 'fd7a:115c:a1e0:0:0:0:2449:d574/128'; Expect = $true; Why = 'in full, with /128' }
    @{ Address = 'fd7a:115c:a1e1:0:0:0:0:1';   Expect = $false; Why = 'in full, outside fd7a:115c:a1e0::/48' }
    @{ Address = 'fd7a:115c:a1e0:0:0:0:2449:d574/64'; Expect = $false; Why = 'in full, with a prefix that is not one address' }
    @{ Address = '100.064.0.1';                Expect = $false; Why = 'IPv4 with a leading zero, which is not the address as written out' }
    @{ Address = '100.63.255.255';             Expect = $false; Why = 'just below 100.64.0.0/10' }
    @{ Address = '100.128.0.0';                Expect = $false; Why = 'just above 100.64.0.0/10' }
    @{ Address = '192.168.0.199';              Expect = $false; Why = 'a LAN address' }
    @{ Address = 'fd7a:115c:a1e1::1';          Expect = $false; Why = 'outside fd7a:115c:a1e0::/48' }
    @{ Address = 'fe80::1';                    Expect = $false; Why = 'a link-local address' }
    @{ Address = 'Any';                        Expect = $false; Why = 'Any' }
    @{ Address = 'LocalSubnet';                Expect = $false; Why = 'a keyword' }
    @{ Address = '100.64.0.0/10';              Expect = $false; Why = 'the whole range, not one address' }
    @{ Address = '100.64.0.1-100.64.0.9';      Expect = $false; Why = 'a range' }
    @{ Address = '100.100';                    Expect = $false; Why = 'a short form TryParse would fill in' }
    @{ Address = 'fd7a:115c:a1e0::/32';        Expect = $false; Why = 'an IPv6 prefix: /32 is one address only in IPv4' }
    @{ Address = 'fd7a:115c:a1e0::1/32';       Expect = $false; Why = 'an IPv6 address with an IPv4 suffix' }
    @{ Address = 'fd7a:115c:a1e0::1/255.255.255.255'; Expect = $false; Why = 'an IPv6 address with an IPv4 mask' }
    @{ Address = '100.64.0.1/128';             Expect = $false; Why = 'an IPv4 address with an IPv6 suffix' }
    @{ Address = '100.64.0.1/31';              Expect = $false; Why = 'two addresses' }
    @{ Address = 'fd7a:115c:a1e0::1/127';      Expect = $false; Why = 'two IPv6 addresses' }
    @{ Address = '100.64.0.1/';                Expect = $false; Why = 'a slash and no suffix' }
    @{ Address = '100.64.0.1/32/32';           Expect = $false; Why = 'two suffixes' }
    @{ Address = '';                           Expect = $false; Why = 'nothing' }
)

$passed = 0
$failed = 0
foreach ($case in $cases) {
    $got = Test-TailnetAddress $case.Address
    if ($got -eq $case.Expect) {
        $passed++
        Write-Host "ok    '$($case.Address)' is $($case.Expect): $($case.Why)"
    } else {
        $failed++
        Write-Host "FAIL  '$($case.Address)' gave $got, expected $($case.Expect): $($case.Why)"
    }
}

# What the adapter named Tailscale holds on sophon, as Get-NetIPAddress gives
# it: the two tailnet addresses and a link-local one with a zone.
$held = @('100.121.213.115', 'fd7a:115c:a1e0::2449:d574', 'fe80::99d0:ec11:8c6a:2cd7%14')

$assignedCases = @(
    @{ Address = '100.121.213.115';           Assigned = $held; Expect = $true;  Why = 'the IPv4 address the adapter holds' }
    @{ Address = 'fd7a:115c:a1e0::2449:d574'; Assigned = $held; Expect = $true;  Why = 'the IPv6 address the adapter holds' }
    @{ Address = 'FD7A:115C:A1E0::2449:D574'; Assigned = $held; Expect = $true;  Why = 'the same in upper case' }
    @{ Address = 'fd7a:115c:a1e0:0:0:0:2449:d574'; Assigned = $held; Expect = $true; Why = 'the same written out in full' }
    @{ Address = '100.121.213.115/32';        Assigned = $held; Expect = $true;  Why = 'with a suffix, which Test-TailnetAddress judges' }
    @{ Address = 'fe80::99d0:ec11:8c6a:2cd7'; Assigned = $held; Expect = $true;  Why = 'held with a zone, asked for without' }
    @{ Address = '100.64.7.7';                Assigned = $held; Expect = $false; Why = 'in the range and not held: a carrier address on another adapter' }
    @{ Address = 'fd7a:115c:a1e0::1';         Assigned = $held; Expect = $false; Why = 'in the IPv6 range and not held' }
    @{ Address = '100.121.213.115';           Assigned = @();   Expect = $false; Why = 'the adapter holds nothing: Tailscale is down' }
    @{ Address = '100.121.213.115';           Assigned = $null; Expect = $false; Why = 'there is no such adapter' }
    @{ Address = 'Any';                       Assigned = $held; Expect = $false; Why = 'Any' }
    @{ Address = '';                          Assigned = $held; Expect = $false; Why = 'nothing' }
)

foreach ($case in $assignedCases) {
    $got = Test-AddressAssigned $case.Address $case.Assigned
    $shown = "'$($case.Address)' among $(@($case.Assigned).Count) held"
    if ($got -eq $case.Expect) {
        $passed++
        Write-Host "ok    $shown is $($case.Expect): $($case.Why)"
    } else {
        $failed++
        Write-Host "FAIL  $shown gave $got, expected $($case.Expect): $($case.Why)"
    }
}

Write-Host ''
Write-Host "$passed passed, $failed failed."
if ($failed -gt 0) { exit 1 }
exit 0
