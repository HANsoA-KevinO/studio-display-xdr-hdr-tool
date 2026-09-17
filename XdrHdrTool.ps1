[CmdletBinding()]
param(
    [ValidateSet('Status', 'Apply', 'Restore', 'Diagnose', 'SelfTest')]
    [string]$Mode = 'Status',

    [ValidatePattern('^\d{4}$')]
    [string]$GpuKey = '',

    [ValidateSet('', 'APPLY', 'RESTORE')]
    [string]$Confirm = '',

    [switch]$Interactive,

    [switch]$ElevatedChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.0.0'
$script:ValueName = 'DISABLE_NATIVE_DISPLAYID2X_SUPPORT'
$script:RegistryHive = [Microsoft.Win32.RegistryHive]::LocalMachine
$script:RegistryView = [Microsoft.Win32.RegistryView]::Registry64
$script:RegistryRootName = 'HKEY_LOCAL_MACHINE'
$script:ClassRelativePath = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$script:BackupRoot = Join-Path $PSScriptRoot 'backups'
$script:DiagnosticRoot = Join-Path $PSScriptRoot 'diagnostics'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Open-BaseRegistryKey {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($script:RegistryHive, $script:RegistryView)
}

function Open-ClassRegistryKey {
    $base = Open-BaseRegistryKey
    $key = $base.OpenSubKey($script:ClassRelativePath, $false)
    if (-not $key) {
        $base.Dispose()
        throw "Cannot open $($script:RegistryRootName)\$($script:ClassRelativePath)"
    }
    return [pscustomobject]@{ Base = $base; Key = $key }
}

function Get-WorkaroundValue {
    param([Parameter(Mandatory = $true)][pscustomobject]$Device)

    $base = Open-BaseRegistryKey
    $key = $base.OpenSubKey($Device.RelativePath, $false)
    if (-not $key) {
        $base.Dispose()
        throw "Cannot read $($Device.FullPath)"
    }
    try {
        $present = $key.GetValueNames() -contains $script:ValueName
        if (-not $present) {
            return [pscustomobject]@{ Present = $false; Kind = $null; Data = $null }
        }
        return [pscustomobject]@{
            Present = $true
            Kind    = [string]$key.GetValueKind($script:ValueName)
            Data    = $key.GetValue(
                $script:ValueName,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        }
    } finally {
        $key.Dispose()
        $base.Dispose()
    }
}

function Get-PresentNvidiaDriverKeys {
    try {
        $keys = @()
        $devices = @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction Stop | Where-Object {
            $_.InstanceId -match '^PCI\\VEN_10DE'
        })
        foreach ($device in $devices) {
            $property = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_Driver' -ErrorAction Stop
            $driverKey = [string]$property.Data
            if ($driverKey -match '(\d{4})$') {
                $keys += $Matches[1]
            }
        }
        return [pscustomobject]@{
            Available = $true
            Keys      = @($keys | Sort-Object -Unique)
        }
    } catch {
        return [pscustomobject]@{
            Available = $false
            Keys      = @()
        }
    }
}

function Get-NvidiaDevices {
    $presence = Get-PresentNvidiaDriverKeys
    $container = Open-ClassRegistryKey
    try {
        $devices = @()
        foreach ($subName in $container.Key.GetSubKeyNames()) {
            if ($subName -notmatch '^\d{4}$') {
                continue
            }
            $subKey = $container.Key.OpenSubKey($subName, $false)
            if (-not $subKey) {
                continue
            }
            try {
                $provider = [string]$subKey.GetValue('ProviderName', '')
                $driverDesc = [string]$subKey.GetValue('DriverDesc', '')
                $matchingDeviceId = [string]$subKey.GetValue('MatchingDeviceId', '')
                $isNvidia = $provider -eq 'NVIDIA' -or
                    $driverDesc -match '^NVIDIA\s' -or
                    $matchingDeviceId -match '^pci\\ven_10de'
                if (-not $isNvidia) {
                    continue
                }
                $device = [pscustomobject]@{
                    KeyName          = $subName
                    RelativePath     = "$($script:ClassRelativePath)\$subName"
                    FullPath         = "$($script:RegistryRootName)\$($script:ClassRelativePath)\$subName"
                    DriverDesc       = $driverDesc
                    DriverVersion    = [string]$subKey.GetValue('DriverVersion', '')
                    ProviderName     = $provider
                    MatchingDeviceId = $matchingDeviceId
                    InfPath          = [string]$subKey.GetValue('InfPath', '')
                    Present          = if ($presence.Available) { $presence.Keys -contains $subName } else { $null }
                }
                $value = Get-WorkaroundValue -Device $device
                $device | Add-Member -NotePropertyName Workaround -NotePropertyValue $value
                $devices += $device
            } finally {
                $subKey.Dispose()
            }
        }
        return @($devices | Sort-Object KeyName)
    } finally {
        $container.Key.Dispose()
        $container.Base.Dispose()
    }
}

function Get-RunningDriverVersion {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($exitCode -ne 0 -or $output.Count -eq 0) {
        return 'Unavailable'
    }
    return (($output | Select-Object -First 1).ToString()).Trim()
}

function Format-WorkaroundState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Value)
    if (-not $Value.Present) {
        return 'absent'
    }
    return "$($Value.Data) ($($Value.Kind))"
}

function Show-Status {
    param([pscustomobject[]]$Devices)

    Write-Host "Studio Display XDR HDR Tool v$($script:ToolVersion)"
    Write-Host "Running NVIDIA driver: $(Get-RunningDriverVersion)"
    Write-Host ''
    if ($Devices.Count -eq 0) {
        Write-Host 'No NVIDIA display-class device was found.'
        return
    }

    foreach ($device in $Devices) {
        $activeBackup = Join-Path $script:BackupRoot ("active-{0}.json" -f $device.KeyName)
        Write-Host "[$($device.KeyName)] $($device.DriverDesc)"
        $presentText = if ($null -eq $device.Present) { 'unknown' } elseif ($device.Present) { 'yes' } else { 'no' }
        Write-Host "  Present device: $presentText"
        Write-Host "  Driver: $($device.DriverVersion)"
        Write-Host "  Device: $($device.MatchingDeviceId)"
        Write-Host "  $($script:ValueName): $(Format-WorkaroundState $device.Workaround)"
        Write-Host "  Restore backup in this tool: $(if (Test-Path -LiteralPath $activeBackup) { 'yes' } else { 'no' })"
    }
}

function Select-NvidiaDevice {
    param(
        [pscustomobject[]]$Devices,
        [string]$RequestedKey,
        [bool]$AllowPrompt
    )

    if ($Devices.Count -eq 0) {
        throw 'No NVIDIA display-class device was found.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedKey)) {
        $selected = @($Devices | Where-Object { $_.KeyName -eq $RequestedKey })
        if ($selected.Count -ne 1) {
            throw "GPU key '$RequestedKey' was not found among the NVIDIA devices."
        }
        return $selected[0]
    }
    $presentDevices = @($Devices | Where-Object { $_.Present -eq $true })
    $candidates = if ($presentDevices.Count -gt 0) { $presentDevices } else { $Devices }
    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }
    if (-not $AllowPrompt) {
        throw 'Multiple NVIDIA devices were found. Specify -GpuKey with the four-digit key shown by Status.'
    }

    Write-Host 'Multiple NVIDIA device keys were found:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host "  $($i + 1). [$($candidates[$i].KeyName)] $($candidates[$i].DriverDesc) / $($candidates[$i].DriverVersion)"
    }
    $answer = Read-Host 'Select the GPU physically connected to Studio Display XDR'
    $choice = 0
    if (-not [int]::TryParse($answer, [ref]$choice) -or $choice -lt 1 -or $choice -gt $candidates.Count) {
        throw 'Invalid GPU selection.'
    }
    return $candidates[$choice - 1]
}

function Assert-SafeRealTarget {
    param([Parameter(Mandatory = $true)][pscustomobject]$Device)

    $expected = '^SYSTEM\\CurrentControlSet\\Control\\Class\\\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$'
    if ($script:RegistryHive -ne [Microsoft.Win32.RegistryHive]::LocalMachine -or
        $Device.RelativePath -notmatch $expected -or
        $Device.MatchingDeviceId -notmatch '^pci\\ven_10de') {
        throw 'The selected registry target failed the NVIDIA display-device safety check.'
    }
    if ($Device.Present -eq $false) {
        throw 'The selected NVIDIA registry key belongs to a device that Windows reports as not currently present.'
    }
}

function Set-WorkaroundDword {
    param([Parameter(Mandatory = $true)][pscustomobject]$Device)

    $base = Open-BaseRegistryKey
    $key = $base.OpenSubKey($Device.RelativePath, $true)
    if (-not $key) {
        $base.Dispose()
        throw "Cannot open $($Device.FullPath) for writing."
    }
    try {
        $key.SetValue($script:ValueName, 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
    } finally {
        $key.Dispose()
        $base.Dispose()
    }
}

function Restore-OriginalValue {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Device,
        [Parameter(Mandatory = $true)][pscustomobject]$Original
    )

    $base = Open-BaseRegistryKey
    $key = $base.OpenSubKey($Device.RelativePath, $true)
    if (-not $key) {
        $base.Dispose()
        throw "Cannot open $($Device.FullPath) for restoration."
    }
    try {
        if (-not $Original.Present) {
            if ($key.GetValueNames() -contains $script:ValueName) {
                $key.DeleteValue($script:ValueName, $false)
            }
        } else {
            if ($Original.Kind -ne 'DWord') {
                throw "Unsupported original registry type '$($Original.Kind)'."
            }
            $key.SetValue(
                $script:ValueName,
                [int]$Original.Data,
                [Microsoft.Win32.RegistryValueKind]::DWord
            )
        }
        $key.Flush()
    } finally {
        $key.Dispose()
        $base.Dispose()
    }
}

function Get-Confirmation {
    param(
        [string]$RequiredText,
        [string]$ProvidedText,
        [bool]$AllowPrompt
    )

    if ($ProvidedText -eq $RequiredText) {
        return
    }
    if (-not $AllowPrompt) {
        throw "Confirmation required. Re-run with -Confirm $RequiredText after reviewing Status and the README."
    }
    $answer = Read-Host "Type $RequiredText to continue"
    if ($answer -cne $RequiredText) {
        throw 'Confirmation text did not match. No change was made.'
    }
}

function Invoke-Apply {
    param([pscustomobject]$Device)

    Assert-SafeRealTarget -Device $Device
    $current = Get-WorkaroundValue -Device $Device
    if ($current.Present -and $current.Kind -ne 'DWord') {
        throw "The existing value type is '$($current.Kind)', not DWord. Refusing to overwrite it."
    }
    if ($current.Present -and [int]$current.Data -eq 1) {
        Write-Host 'The workaround is already present as DWord 1. No registry change was made.'
        $activePath = Join-Path $script:BackupRoot ("active-{0}.json" -f $Device.KeyName)
        if (-not (Test-Path -LiteralPath $activePath)) {
            Write-Warning 'This copy of the tool did not create the existing setting, so it cannot reconstruct its original state.'
        }
        return
    }

    Get-Confirmation -RequiredText 'APPLY' -ProvidedText $Confirm -AllowPrompt $Interactive.IsPresent

    New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    $activeBackupPath = Join-Path $script:BackupRoot ("active-{0}.json" -f $Device.KeyName)
    if (Test-Path -LiteralPath $activeBackupPath) {
        throw "An active backup already exists at '$activeBackupPath'. Restore or inspect it first."
    }

    $backup = [pscustomobject]@{
        SchemaVersion        = 1
        ToolVersion          = $script:ToolVersion
        CreatedAt            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        RunningDriver        = Get-RunningDriverVersion
        DriverDesc           = $Device.DriverDesc
        DriverVersion        = $Device.DriverVersion
        MatchingDeviceId     = $Device.MatchingDeviceId
        InfPath              = $Device.InfPath
        RegistryPath         = $Device.FullPath
        RegistryRelativePath = $Device.RelativePath
        GpuKey               = $Device.KeyName
        ValueName            = $script:ValueName
        Original             = $current
    }
    $timestampedPath = Join-Path $script:BackupRoot ("backup-{0}-{1}.json" -f $Device.KeyName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $backupJson = $backup | ConvertTo-Json -Depth 8
    $backupJson | Set-Content -LiteralPath $timestampedPath -Encoding utf8
    $backupJson | Set-Content -LiteralPath $activeBackupPath -Encoding utf8

    Set-WorkaroundDword -Device $Device
    $verified = Get-WorkaroundValue -Device $Device
    if (-not $verified.Present -or $verified.Kind -ne 'DWord' -or [int]$verified.Data -ne 1) {
        throw 'Write verification failed. The original-state backup was kept for inspection.'
    }

    Write-Host ''
    Write-Host "Applied and verified: $($script:ValueName)=1 (DWord)"
    Write-Host "Backup: $timestampedPath"
    Write-Host 'Save your work and choose Windows Restart. Do not substitute shutdown followed by power-on.'
}

function Invoke-Restore {
    param([pscustomobject]$Device)

    Assert-SafeRealTarget -Device $Device
    $activeBackupPath = Join-Path $script:BackupRoot ("active-{0}.json" -f $Device.KeyName)
    if (-not (Test-Path -LiteralPath $activeBackupPath)) {
        throw "No active backup exists for GPU key $($Device.KeyName). Refusing an unverified restoration."
    }
    $backup = Get-Content -LiteralPath $activeBackupPath -Raw | ConvertFrom-Json
    if ($backup.DriverDesc -ne $Device.DriverDesc -or
        $backup.MatchingDeviceId -ne $Device.MatchingDeviceId -or
        $backup.RegistryPath -ne $Device.FullPath -or
        $backup.ValueName -ne $script:ValueName) {
        throw 'The active backup does not match the selected NVIDIA device and value. No change was made.'
    }

    $current = Get-WorkaroundValue -Device $Device
    if (-not $current.Present -or $current.Kind -ne 'DWord' -or [int]$current.Data -ne 1) {
        throw 'The current setting is not DWord 1. Refusing to overwrite an unexpected registry state.'
    }

    Get-Confirmation -RequiredText 'RESTORE' -ProvidedText $Confirm -AllowPrompt $Interactive.IsPresent
    Restore-OriginalValue -Device $Device -Original $backup.Original
    $verified = Get-WorkaroundValue -Device $Device
    if ($backup.Original.Present) {
        if (-not $verified.Present -or
            $verified.Kind -ne $backup.Original.Kind -or
            [int]$verified.Data -ne [int]$backup.Original.Data) {
            throw 'Restore verification failed.'
        }
    } elseif ($verified.Present) {
        throw 'Restore verification failed: the value should be absent.'
    }

    $restoredDir = Join-Path $script:BackupRoot 'restored'
    New-Item -ItemType Directory -Path $restoredDir -Force | Out-Null
    $archivedBackup = Join-Path $restoredDir ("restored-{0}-{1}.json" -f $Device.KeyName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $activeBackupPath -Destination $archivedBackup

    Write-Host ''
    Write-Host 'The exact original registry state was restored and verified.'
    Write-Host "Archived backup: $archivedBackup"
    Write-Host 'Save your work and choose Windows Restart.'
}

function Get-DxField {
    param([string[]]$Lines, [string]$Name)
    $pattern = '^\s*' + [regex]::Escape($Name) + ':\s*(.*)$'
    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Read-DxDisplays {
    param([string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    $starts = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Card name:') {
            $starts += $i
        }
    }
    $displays = @()
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $start = $starts[$i]
        $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] - 1 } else { $lines.Count - 1 }
        $block = @($lines[$start..$end])
        $model = Get-DxField -Lines $block -Name 'Monitor Model'
        if ([string]::IsNullOrWhiteSpace($model)) {
            continue
        }
        $display = [pscustomobject]@{
            Gpu                 = Get-DxField -Lines $block -Name 'Card name'
            MonitorModel        = $model
            MonitorId           = Get-DxField -Lines $block -Name 'Monitor Id'
            CurrentMode         = Get-DxField -Lines $block -Name 'Current Mode'
            NativeMode          = Get-DxField -Lines $block -Name 'Native Mode'
            OutputType          = Get-DxField -Lines $block -Name 'Output Type'
            HdrSupport          = Get-DxField -Lines $block -Name 'HDR Support'
            MonitorCapabilities = Get-DxField -Lines $block -Name 'Monitor Capabilities'
            AdvancedColor       = Get-DxField -Lines $block -Name 'Advanced Color'
            ActiveColorMode     = Get-DxField -Lines $block -Name 'Active Color Mode'
            DisplayColorSpace   = Get-DxField -Lines $block -Name 'Display Color Space'
            DisplayLuminance    = Get-DxField -Lines $block -Name 'Display Luminance'
            DriverVersion       = Get-DxField -Lines $block -Name 'Driver Version'
            DeviceProblemCode   = Get-DxField -Lines $block -Name 'Device Problem Code'
        }
        $isXdr = $display.MonitorModel -match 'Studio XDR' -or
            $display.MonitorId -eq 'APPAE42' -or
            ($display.CurrentMode -match '^5120 x 2880 .*\(120Hz\)$' -and $display.OutputType -eq 'Displayport External')
        $display | Add-Member -NotePropertyName StudioXdrCandidate -NotePropertyValue $isXdr
        $displays += $display
    }
    return @($displays)
}

function Invoke-Diagnose {
    param([pscustomobject[]]$Devices)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $captureDir = Join-Path $script:DiagnosticRoot $stamp
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    $dxdiagPath = Join-Path $captureDir 'dxdiag.txt'
    $arguments = "/dontskip /whql:off /t `"$dxdiagPath`""
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\dxdiag.exe') -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $dxdiagPath)) {
        throw "DxDiag failed to create '$dxdiagPath'."
    }

    $displays = @(Read-DxDisplays -Path $dxdiagPath)
    $report = [pscustomobject]@{
        ToolVersion = $script:ToolVersion
        CapturedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        RunningDriver = Get-RunningDriverVersion
        NvidiaDevices = $Devices
        Displays      = $displays
    }
    $jsonPath = Join-Path $captureDir 'diagnostics.json'
    $report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $jsonPath -Encoding utf8

    Write-Host "Diagnostics: $captureDir"
    Write-Host ''
    foreach ($display in $displays) {
        $prefix = if ($display.StudioXdrCandidate) { '[Studio XDR candidate]' } else { '[Display]' }
        Write-Host "$prefix $($display.MonitorModel) / $($display.MonitorId)"
        Write-Host "  Mode: $($display.CurrentMode)"
        Write-Host "  HDR: $($display.HdrSupport)"
        Write-Host "  Active color: $($display.ActiveColorMode)"
        Write-Host "  Color space: $($display.DisplayColorSpace)"
        Write-Host "  Luminance: $($display.DisplayLuminance)"
    }
    Write-Host ''
    Write-Host 'Keep dxdiag.txt private; it can contain machine and device identifiers.'
}

function Invoke-SelfTest {
    $testId = [guid]::NewGuid().ToString('N')
    $testRoot = "Software\StudioDisplayXdrHdrToolTests\$testId"
    $originalHive = $script:RegistryHive
    $originalView = $script:RegistryView
    $originalRootName = $script:RegistryRootName
    $originalClassPath = $script:ClassRelativePath

    try {
        $script:RegistryHive = [Microsoft.Win32.RegistryHive]::CurrentUser
        $script:RegistryView = [Microsoft.Win32.RegistryView]::Default
        $script:RegistryRootName = 'HKEY_CURRENT_USER'
        $script:ClassRelativePath = $testRoot

        $base = Open-BaseRegistryKey
        $mock = $base.CreateSubKey("$testRoot\0007")
        try {
            $mock.SetValue('ProviderName', 'NVIDIA', [Microsoft.Win32.RegistryValueKind]::String)
            $mock.SetValue('DriverDesc', 'NVIDIA Test GPU', [Microsoft.Win32.RegistryValueKind]::String)
            $mock.SetValue('DriverVersion', '0.0.0.0', [Microsoft.Win32.RegistryValueKind]::String)
            $mock.SetValue('MatchingDeviceId', 'pci\ven_10de&dev_test', [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $mock.Dispose()
            $base.Dispose()
        }

        $base = Open-BaseRegistryKey
        $secondMock = $base.CreateSubKey("$testRoot\0008")
        try {
            $secondMock.SetValue('ProviderName', 'NVIDIA', [Microsoft.Win32.RegistryValueKind]::String)
            $secondMock.SetValue('DriverDesc', 'NVIDIA Second Test GPU', [Microsoft.Win32.RegistryValueKind]::String)
            $secondMock.SetValue('DriverVersion', '0.0.0.1', [Microsoft.Win32.RegistryValueKind]::String)
            $secondMock.SetValue('MatchingDeviceId', 'pci\ven_10de&dev_test2', [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $secondMock.Dispose()
            $base.Dispose()
        }

        $devices = @(Get-NvidiaDevices)
        if ($devices.Count -ne 2 -or $devices[0].KeyName -ne '0007' -or $devices[1].KeyName -ne '0008') {
            throw 'Self-test discovery failed.'
        }
        $selected = Select-NvidiaDevice -Devices $devices -RequestedKey '0007' -AllowPrompt $false
        if ($selected.KeyName -ne '0007') {
            throw 'Self-test explicit multi-GPU selection failed.'
        }
        $before = Get-WorkaroundValue -Device $selected
        if ($before.Present) {
            throw 'Self-test expected an absent initial value.'
        }
        Set-WorkaroundDword -Device $selected
        $applied = Get-WorkaroundValue -Device $selected
        if (-not $applied.Present -or $applied.Kind -ne 'DWord' -or [int]$applied.Data -ne 1) {
            throw 'Self-test apply/verify failed.'
        }
        Restore-OriginalValue -Device $selected -Original $before
        $restored = Get-WorkaroundValue -Device $selected
        if ($restored.Present) {
            throw 'Self-test restoration failed.'
        }
        Write-Host 'Self-test PASS: multi-GPU discovery/selection, absent-state capture, DWORD apply, verification, and restoration.'
    } finally {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::CurrentUser,
                [Microsoft.Win32.RegistryView]::Default
            )
            $base.DeleteSubKeyTree($testRoot, $false)
            $base.Dispose()
        } catch {
            Write-Warning "Could not remove temporary self-test key HKCU:\$testRoot"
        }
        $script:RegistryHive = $originalHive
        $script:RegistryView = $originalView
        $script:RegistryRootName = $originalRootName
        $script:ClassRelativePath = $originalClassPath
    }
}

function Start-ElevatedOperation {
    $scriptPath = $PSCommandPath
    $escapedScriptPath = $scriptPath.Replace('"', '""')
    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScriptPath`" -Mode $Mode -Interactive -ElevatedChild"
    if (-not [string]::IsNullOrWhiteSpace($GpuKey)) {
        $argumentLine += " -GpuKey $GpuKey"
    }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -WindowStyle Normal
    if ($process.ExitCode -ne 0) {
        throw "The elevated operation exited with code $($process.ExitCode)."
    }
    Write-Host 'Elevated operation completed. Current status:'
    Show-Status -Devices @(Get-NvidiaDevices)
}

function Invoke-Main {
    if ($Mode -eq 'SelfTest') {
        Invoke-SelfTest
        return
    }

    $devices = @(Get-NvidiaDevices)
    if ($Mode -eq 'Status') {
        Show-Status -Devices $devices
        return
    }
    if ($Mode -eq 'Diagnose') {
        Show-Status -Devices $devices
        Write-Host ''
        Invoke-Diagnose -Devices $devices
        return
    }

    if (-not (Test-Administrator)) {
        if ($Interactive.IsPresent -and -not $ElevatedChild.IsPresent) {
            Start-ElevatedOperation
            return
        }
        throw "$Mode requires an elevated PowerShell process. Run as administrator or use the CMD launcher."
    }

    $device = Select-NvidiaDevice -Devices $devices -RequestedKey $GpuKey -AllowPrompt $Interactive.IsPresent
    Write-Host "Selected GPU key [$($device.KeyName)]: $($device.DriverDesc)"
    Write-Host "Registry path: $($device.FullPath)"
    Write-Host "Current setting: $(Format-WorkaroundState $device.Workaround)"
    Write-Host ''

    if ($Mode -eq 'Apply') {
        Invoke-Apply -Device $device
    } else {
        Invoke-Restore -Device $device
    }
}

try {
    Invoke-Main
    exit 0
} catch {
    Write-Error $_
    exit 1
}
