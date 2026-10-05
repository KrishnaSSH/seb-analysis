# checks if this pc looks like a vm, same way seb does it
# based on VirtualMachineDetector.cs and SystemInfo.cs
#
# usage:
#   .\Test-SebVirtualMachine.ps1
#   .\Test-SebVirtualMachine.ps1 -SebPath "C:\Program Files\SafeExamBrowser\Application"
#
# -SebPath is optional, it runs the check from seb_x64.dll too
# exit code 1 = vm, 0 = not vm
[CmdletBinding()]
param(
    [string] $SebPath
)

$ErrorActionPreference = 'Stop'

# values from VirtualMachineDetector.cs

$Manipulated = '000000000000'
$QemuMacPrefix = '525400'
$VirtualBoxMacPrefix = '080027'

$DeviceBlacklist = @(
    # hyper-v
    'PROD_VIRTUAL', 'HYPER_V',
    # qemu
    'qemu', 'ven_1af4', 'ven_1b36', 'subsys_11001af4',
    # virtualbox
    'VEN_VBOX', 'vid_80ee',
    # vmware
    'PROD_VMWARE', 'VEN_VMWARE', 'VMWARE_IDE'
)

$DeviceWhitelist = @(
    # microsoft virtual disk
    'PROD_VIRTUAL_DISK',
    # microsoft virtual dvd
    'PROD_VIRTUAL_DVD'
)

$SystemHardware = @(
    'CIM_Memory',
    'CIM_NumericSensor',
    'CIM_Sensor',
    'CIM_TemperatureSensor',
    'CIM_VoltageSensor',
    'Win32_CacheMemory',
    'Win32_Fan',
    'Win32_VoltageProbe'
)

$DeviceCacheKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\TaskFlow\DeviceCache'

# system info, same as SystemInfo.cs

function Get-BiosInfo {
    try {
        $bios = Get-CimInstance -Query 'SELECT * FROM Win32_BIOS' | Select-Object -First 1
        if ($null -eq $bios) { throw 'No BIOS information.' }
        return "$($bios.Manufacturer) $($bios.Name)"
    }
    catch {
        return ''
    }
}

function Get-CpuName {
    try {
        $name = ''
        # seb keeps the last cpu name
        foreach ($cpu in Get-CimInstance -Query 'SELECT * FROM Win32_Processor') {
            $name = [string] $cpu.Name
        }
        return $name
    }
    catch {
        return ''
    }
}

function Get-MachineInfo {
    try {
        $system = Get-CimInstance -Query 'SELECT * FROM Win32_ComputerSystem' | Select-Object -First 1
        if ($null -eq $system) { throw 'No computer system information.' }
        return [pscustomobject] @{
            Manufacturer = [string] $system.Manufacturer
            Model        = "$($system.SystemFamily) $($system.Model)"
            Name         = [string] $system.Name
        }
    }
    catch {
        return [pscustomobject] @{ Manufacturer = ''; Model = ''; Name = '' }
    }
}

function Get-MacAddress {
    $undefined = '000000000000'
    try {
        $adapter = Get-CimInstance -Query 'SELECT MACAddress FROM Win32_NetworkAdapterConfiguration WHERE DNSHostName IS NOT NULL' | Select-Object -First 1
        if ($null -eq $adapter -or [string]::IsNullOrEmpty($adapter.MACAddress)) {
            return $undefined
        }
        return ([string] $adapter.MACAddress).Replace(':', '').ToUpper()
    }
    catch {
        return $undefined
    }
}

function Get-PnPDeviceIds {
    try {
        return @(Get-CimInstance -Namespace 'root\CIMV2' -Query 'SELECT DeviceID FROM Win32_PnPEntity' |
            ForEach-Object { ([string] $_.DeviceID).ToLower() })
    }
    catch {
        return @()
    }
}

# checks

function Test-NoSystemHardware {
    $found = @()
    try {
        foreach ($hardware in $SystemHardware) {
            $count = @(Get-CimInstance -Query "SELECT * FROM $hardware").Count
            if ($count -gt 0) { $found += "$hardware ($count)" }
        }
    }
    catch {
        # seb counts an error as vm
        return [pscustomobject] @{ IsVm = $true; Details = "WMI query failed: $($_.Exception.Message)" }
    }

    if ($found.Count -gt 0) {
        return [pscustomobject] @{ IsVm = $false; Details = "Found: $($found -join ', ')" }
    }
    return [pscustomobject] @{ IsVm = $true; Details = 'no hardware found' }
}

function Test-VirtualDevice ([string[]] $DeviceIds) {
    $deviceHits = @()
    foreach ($device in $DeviceIds) {
        $lower = $device.ToLower()
        $blacklisted = $DeviceBlacklist | Where-Object { $lower.Contains($_.ToLower()) }
        $whitelisted = $DeviceWhitelist | Where-Object { $lower.Contains($_.ToLower()) }
        if ($blacklisted -and -not $whitelisted) {
            $deviceHits += "$device [$($blacklisted -join ', ')]"
        }
    }

    if ($deviceHits.Count -gt 0) {
        return [pscustomobject] @{ IsVm = $true; Details = "Matching devices:`n      " + ($deviceHits -join "`n      ") }
    }
    return [pscustomobject] @{ IsVm = $false; Details = "Checked $($DeviceIds.Count) devices, none matched." }
}

function Test-VirtualMacAddress ([string] $MacAddress) {
    $isVm = $false
    $reason = 'No VM prefix.'
    if ($null -ne $MacAddress -and $MacAddress.Length -gt 2) {
        if ($MacAddress.StartsWith($Manipulated)) { $isVm = $true; $reason = 'all zeros' }
        elseif ($MacAddress.StartsWith($QemuMacPrefix)) { $isVm = $true; $reason = 'QEMU prefix (525400).' }
        elseif ($MacAddress.StartsWith($VirtualBoxMacPrefix)) { $isVm = $true; $reason = 'VirtualBox prefix (080027).' }
    }
    return [pscustomobject] @{ IsVm = $isVm; Details = "MAC '$MacAddress': $reason" }
}

function Test-VirtualCpu ([string] $CpuName) {
    $isVm = $CpuName.ToLower().Contains(' kvm ')
    return [pscustomobject] @{ IsVm = $isVm; Details = "CPU '$CpuName'" }
}

function Get-VirtualSystemMatches ([string] $BiosInfo, [string] $Manufacturer, [string] $Model) {
    $BiosInfo = $BiosInfo.ToLower()
    $Manufacturer = $Manufacturer.ToLower()
    $Model = $Model.ToLower()
    $hits = @()

    if ($BiosInfo.Contains('hyper-v')) { $hits += "BIOS contains 'hyper-v'" }
    if ($BiosInfo.Contains('virtualbox')) { $hits += "BIOS contains 'virtualbox'" }
    if ($BiosInfo.Contains('vmware')) { $hits += "BIOS contains 'vmware'" }
    if ($BiosInfo.Contains('ovmf')) { $hits += "BIOS contains 'ovmf'" }
    if ($BiosInfo.Contains('edk ii unknown')) { $hits += "BIOS contains 'edk ii unknown'" }
    if ($Manufacturer.Contains('microsoft corporation') -and -not $Model.Contains('surface')) { $hits += "Manufacturer is Microsoft Corporation and model is not Surface" }
    if ($Manufacturer.Contains('parallels software')) { $hits += "Manufacturer contains 'parallels software'" }
    if ($Manufacturer.Contains('qemu')) { $hits += "Manufacturer contains 'qemu'" }
    if ($Manufacturer.Contains('vmware')) { $hits += "Manufacturer contains 'vmware'" }
    if ($Model.Contains('virtualbox')) { $hits += "Model contains 'virtualbox'" }
    # same bug as seb, this never matches because the string is lowercase
    if ($Model.Contains('Q35 +')) { $hits += "Model contains 'Q35 +'" }

    return , $hits
}

function Test-VirtualSystem ([string] $BiosInfo, [string] $Manufacturer, [string] $Model) {
    $hits = Get-VirtualSystemMatches $BiosInfo $Manufacturer $Model
    $details = "BIOS '$BiosInfo', Manufacturer '$Manufacturer', Model '$Model'"
    if ($hits.Count -gt 0) { $details += "`n      " + ($hits -join "`n      ") }
    return [pscustomobject] @{ IsVm = ($hits.Count -gt 0); Details = $details }
}

function Test-VirtualRegistry {
    $deviceName = $env:COMPUTERNAME
    $hits = @()
    $entries = 0

    if ($deviceName -and (Test-Path $DeviceCacheKey)) {
        foreach ($cache in Get-ChildItem -Path $DeviceCacheKey -ErrorAction SilentlyContinue) {
            $values = Get-ItemProperty -Path $cache.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $values -or $null -eq $values.DeviceName) { continue }
            if ($deviceName.ToLower() -ne ([string] $values.DeviceName).ToLower()) { continue }
            if ($null -eq $values.DeviceMake -or $null -eq $values.DeviceModel) { continue }

            $entries++
            $matched = Get-VirtualSystemMatches '' ([string] $values.DeviceMake) ([string] $values.DeviceModel)
            if ($matched.Count -gt 0) {
                $hits += "$($cache.PSChildName): Make '$($values.DeviceMake)', Model '$($values.DeviceModel)' -> $($matched -join '; ')"
            }
        }
    }

    if ($hits.Count -gt 0) {
        return [pscustomobject] @{ IsVm = $true; Details = "Virtual device cache entries:`n      " + ($hits -join "`n      ") }
    }
    return [pscustomobject] @{ IsVm = $false; Details = "Checked $entries device cache entries for '$deviceName', none matched." }
}

function Test-IntegrityModule ([string] $Path) {
    if (-not $Path) {
        return [pscustomobject] @{ IsVm = $false; Skipped = $true; Details = 'skipped, use -SebPath to run it' }
    }

    $dllName = if ([Environment]::Is64BitProcess) { 'seb_x64.dll' } else { 'seb_x86.dll' }
    $dll = Join-Path $Path $dllName

    if (-not (Test-Path $dll)) {
        # seb says not vm if the dll is missing
        return [pscustomobject] @{ IsVm = $false; Skipped = $true; Details = "Skipped ($dll not found)." }
    }

    try {
        $escaped = $dll.Replace('\', '\\')
        if (-not ('SebIntegrityNative' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SebIntegrityNative
{
    [DllImport("$escaped", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool IsVirtualMachine(out IntPtr manufacturer, out int probability);
}
"@
        }

        $bstr = [IntPtr]::Zero
        $probability = 0
        $isVm = [SebIntegrityNative]::IsVirtualMachine([ref] $bstr, [ref] $probability)
        $manufacturer = ''

        if ($bstr -ne [IntPtr]::Zero) {
            $manufacturer = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            [Runtime.InteropServices.Marshal]::FreeBSTR($bstr)
        }

        return [pscustomobject] @{ IsVm = $isVm; Skipped = $false; Details = "Manufacturer '$manufacturer', probability $probability%" }
    }
    catch {
        return [pscustomobject] @{ IsVm = $false; Skipped = $true; Details = "Failed: $($_.Exception.Message)" }
    }
}

# main

Write-Host 'Collecting system information...' -ForegroundColor DarkGray

$biosInfo = Get-BiosInfo
$cpuName = Get-CpuName
$machine = Get-MachineInfo
$macAddress = Get-MacAddress
$deviceIds = Get-PnPDeviceIds

$checks = [ordered] @{
    '1. HasNoSystemHardware'  = Test-NoSystemHardware
    '2. HasVirtualDevice'     = Test-VirtualDevice $deviceIds
    '3. HasVirtualMacAddress' = Test-VirtualMacAddress $macAddress
    '4. IsVirtualCpu'         = Test-VirtualCpu $cpuName
    '5. IsVirtualRegistry'    = Test-VirtualRegistry
    '6. IsVirtualSystem'      = Test-VirtualSystem $biosInfo $machine.Manufacturer $machine.Model
    '7. IntegrityModule'      = Test-IntegrityModule $SebPath
}

Write-Host ''
Write-Host "Computer: $($machine.Name)"
Write-Host ''

$isVm = $false

foreach ($name in $checks.Keys) {
    $result = $checks[$name]
    $isVm = $isVm -or $result.IsVm

    if ($result.PSObject.Properties['Skipped'] -and $result.Skipped) {
        $label = 'SKIPPED'; $color = 'DarkGray'
    }
    elseif ($result.IsVm) {
        $label = 'VM'; $color = 'Red'
    }
    else {
        $label = 'OK'; $color = 'Green'
    }

    Write-Host ('[{0,-7}] {1}' -f $label, $name) -ForegroundColor $color
    Write-Host "      $($result.Details)" -ForegroundColor DarkGray
}

Write-Host ''
if ($isVm) {
    Write-Host 'Result: IS VM' -ForegroundColor Red
    exit 1
}
else {
    Write-Host 'Result: IS NOT VM' -ForegroundColor Green
    exit 0
}
