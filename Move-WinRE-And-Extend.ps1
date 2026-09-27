<#
.SYNOPSIS
    Moves the Windows Recovery Environment (WinRE) partition to the end of the
    OS disk by recreating it, then extends the Windows partition into the space
    that was previously blocked by WinRE.

.DESCRIPTION
    SAFETY MODEL:
      - Dry-run by default. Nothing is modified unless -Execute is supplied.
      - GPT/UEFI disks only.
      - Automatically detects the Windows partition and the WinRE partition.
      - Requires WinRE to be the partition immediately after Windows and the
        last existing partition on the disk.
      - Requires unallocated space after WinRE.
      - Refuses to run while BitLocker protection is ON (when detectable).
      - Backs up Winre.wim before deleting the existing recovery partition.
      - Recreates WinRE using Microsoft's recovery GUID and GPT attributes.
      - Verifies WinRE at the end.

    Recommended usage:
      1. Reboot Windows first.
      2. Open Windows PowerShell / Terminal as Administrator.
      3. Run:
            .\Move-WinRE-And-Extend.ps1
         Review the dry-run output.
      4. If correct:
            .\Move-WinRE-And-Extend.ps1 -Execute
         To suppress the final typed confirmation:
            .\Move-WinRE-And-Extend.ps1 -Execute -Force

.NOTES
    Designed for the common layout:
        [ EFI ] [ MSR ] [ Windows C: ] [ WinRE ] [ unallocated space ]

    This script does NOT support:
      - MBR disks
      - Dynamic disks
      - WinRE on another disk
      - Another partition between Windows and WinRE
      - Any existing partition after WinRE

    Keep a current backup before changing partition tables.
#>

[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$Force,

    # Microsoft recommends ~990 MB for WinRE; 1024 MB is the default here.
    [ValidateRange(990, 8192)]
    [int]$RecoverySizeMB = 1024
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MiB = [uint64](1MB)
$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$RecoveryGptTypeBare = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Format-Bytes([uint64]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated (Administrator) PowerShell session.'
    }
}

function Invoke-ReAgentC {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & "$env:SystemRoot\System32\reagentc.exe" @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        Write-Host $line
    }

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "REAgentC failed with exit code ${exitCode}: reagentc $($Arguments -join ' ')"
    }

    return @{
        ExitCode = $exitCode
        Output   = ($output -join "`n")
    }
}

function Invoke-DiskPartScript {
    param(
        [Parameter(Mandatory)]
        [string[]]$Commands
    )

    $tmp = Join-Path $env:TEMP ("winre-diskpart-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        $Commands | Set-Content -LiteralPath $tmp -Encoding ASCII
        $output = & "$env:SystemRoot\System32\diskpart.exe" /s $tmp 2>&1
        $exitCode = $LASTEXITCODE

        foreach ($line in $output) {
            Write-Host $line
        }

        if ($exitCode -ne 0) {
            throw "DiskPart failed with exit code $exitCode."
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-WinRELocation {
    $result = Invoke-ReAgentC -Arguments @('/info')
    $m = [regex]::Match(
        $result.Output,
        'GLOBALROOT\\device\\harddisk(?<disk>\d+)\\partition(?<partition>\d+)\\Recovery\\WindowsRE',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        throw @'
Could not identify an enabled WinRE partition from "reagentc /info".
This script intentionally stops rather than guessing.
'@
    }

    [pscustomobject]@{
        DiskNumber      = [int]$m.Groups['disk'].Value
        PartitionNumber = [int]$m.Groups['partition'].Value
        RawInfo         = $result.Output
    }
}

function Test-BitLocker {
    param([char]$DriveLetter)

    $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Warning 'Get-BitLockerVolume is unavailable; BitLocker status could not be verified automatically.'
        return
    }

    try {
        $bl = Get-BitLockerVolume -MountPoint ("{0}:" -f $DriveLetter)
        if ($null -ne $bl -and "$($bl.ProtectionStatus)" -eq 'On') {
            throw @"
BitLocker protection is ON for $DriveLetter`:.

Suspend it before continuing, for example:

    Suspend-BitLocker -MountPoint '$DriveLetter`:' -RebootCount 1

Then run this script again.
"@
        }

        if ($null -ne $bl) {
            Write-Host ("BitLocker protection: {0}" -f $bl.ProtectionStatus)
        }
    }
    catch {
        if ($_.Exception.Message -like 'BitLocker protection is ON*') {
            throw
        }
        Write-Warning "Could not verify BitLocker status: $($_.Exception.Message)"
    }
}

function Round-Up {
    param(
        [uint64]$Value,
        [uint64]$Multiple
    )
    return [uint64]([math]::Ceiling($Value / [double]$Multiple) * $Multiple)
}


# ---------------------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------------------

Assert-Administrator

Write-Step 'Detecting Windows and WinRE layout'

$osDrive = $env:SystemDrive.TrimEnd(':')
if ($osDrive.Length -ne 1) {
    throw "Unexpected SystemDrive value: $env:SystemDrive"
}
$osLetter = [char]$osDrive

$osPartition = Get-Partition -DriveLetter $osLetter
$disk = Get-Disk -Number $osPartition.DiskNumber

if ($disk.PartitionStyle -ne 'GPT') {
    throw "Disk $($disk.Number) is $($disk.PartitionStyle), not GPT. This script intentionally supports GPT only."
}

if ($disk.IsReadOnly) {
    throw "Disk $($disk.Number) is read-only."
}

if ("$($disk.OperationalStatus)" -notmatch 'Online') {
    throw "Disk $($disk.Number) is not online. Status: $($disk.OperationalStatus)"
}

$winre = Get-WinRELocation

if ($winre.DiskNumber -ne $osPartition.DiskNumber) {
    throw "WinRE is on disk $($winre.DiskNumber), but Windows is on disk $($osPartition.DiskNumber). Refusing to continue."
}

$recoveryPartition = Get-Partition `
    -DiskNumber $winre.DiskNumber `
    -PartitionNumber $winre.PartitionNumber

$actualType = "$($recoveryPartition.GptType)".Trim('{}').ToLowerInvariant()
if ($actualType -ne $RecoveryGptTypeBare) {
    throw "The partition registered as WinRE does not have Microsoft's Recovery GPT type. Found: $($recoveryPartition.GptType)"
}

$partitions = @(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)

$nextAfterOS = @($partitions | Where-Object { $_.Offset -gt $osPartition.Offset } | Select-Object -First 1)
if (($nextAfterOS.Count -ne 1) -or ($nextAfterOS[0].PartitionNumber -ne $recoveryPartition.PartitionNumber)) {
    throw 'WinRE is not the partition immediately after the Windows partition. Refusing to modify the disk.'
}

$partitionsAfterRecovery = @($partitions | Where-Object { $_.Offset -gt $recoveryPartition.Offset })
if ($partitionsAfterRecovery.Count -ne 0) {
    throw 'There is another partition after WinRE. This script only handles WinRE as the last existing partition.'
}

$recoveryEnd = [uint64]($recoveryPartition.Offset + $recoveryPartition.Size)
$tailFree = if ($disk.Size -gt $recoveryEnd) {
    [uint64]($disk.Size - $recoveryEnd)
} else {
    [uint64]0
}

# Ignore only the tiny GPT/alignment tail. The intended scenario has real free space.
if ($tailFree -lt 64MB) {
    throw "Less than 64 MB of unallocated space was detected after WinRE ($(Format-Bytes $tailFree)). This does not match the intended layout."
}

Test-BitLocker -DriveLetter $osLetter

$requestedRecoveryBytes = [uint64]$RecoverySizeMB * $MiB
$estimatedGain = [int64]$recoveryPartition.Size + [int64]$tailFree - [int64]$requestedRecoveryBytes

Write-Host ''
[pscustomobject]@{
    Disk                    = $disk.Number
    'Disk size'             = Format-Bytes $disk.Size
    'Windows partition'     = "$osLetter`: (partition $($osPartition.PartitionNumber))"
    'Windows size now'      = Format-Bytes $osPartition.Size
    'WinRE partition'       = $recoveryPartition.PartitionNumber
    'WinRE size now'        = Format-Bytes $recoveryPartition.Size
    'Free after WinRE'      = Format-Bytes $tailFree
    'Requested new WinRE'   = Format-Bytes $requestedRecoveryBytes
    'Estimated C: increase' = if ($estimatedGain -gt 0) { Format-Bytes ([uint64]$estimatedGain) } else { 'NONE' }
} | Format-List

if ($estimatedGain -le 0) {
    throw 'The requested WinRE size would leave no space to extend Windows.'
}

if (-not $Execute) {
    Write-Host @'

DRY RUN ONLY — no changes were made.

If the layout above is correct, reboot Windows first, then run:

    .\Move-WinRE-And-Extend.ps1 -Execute

The script will ask you to type RELAYOUT before doing anything destructive.
'@ -ForegroundColor Yellow
    exit 0
}

if (-not $Force) {
    Write-Warning 'This operation modifies the partition table.'
    Write-Warning 'A current backup is strongly recommended.'
    $confirmation = Read-Host 'Type RELAYOUT to continue'
    if ($confirmation -cne 'RELAYOUT') {
        Write-Host 'Cancelled. No changes were made.'
        exit 1
    }
}


# ---------------------------------------------------------------------------
# EXECUTION
# ---------------------------------------------------------------------------

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path "$osLetter`:\" "WinRE-Relayout-Backup-$timestamp"
$destructiveStarted = $false

try {
    Write-Step 'Creating a local WinRE backup directory'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $reAgentXml = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
    if (Test-Path -LiteralPath $reAgentXml) {
        Copy-Item -LiteralPath $reAgentXml -Destination (Join-Path $backupDir 'ReAgent.xml.before') -Force
    }

    Write-Step 'Disabling WinRE'
    Invoke-ReAgentC -Arguments @('/disable') | Out-Null

    $winreWim = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
    try {
        $winreWimItem = Get-Item -LiteralPath $winreWim -Force -ErrorAction Stop
    }
    catch {
        # No destructive action has occurred yet.
        Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
        throw "WinRE was disabled, but $winreWim could not be accessed. The old recovery partition has NOT been deleted."
    }

    Copy-Item -LiteralPath $winreWim -Destination (Join-Path $backupDir 'Winre.wim') -Force

    # Microsoft requires free room for WinRE servicing. Reserve 250 MB plus
    # a small NTFS/alignment cushion, and round to 64 MB.
    $wimSize = [uint64]$winreWimItem.Length
    $minimumByImage = Round-Up -Value ($wimSize + 250MB + 32MB) -Multiple 64MB
    $targetRecoveryBytes = [uint64][math]::Max(
        [double]$requestedRecoveryBytes,
        [double]$minimumByImage
    )

    Write-Host ("Winre.wim size:       {0}" -f (Format-Bytes $wimSize))
    Write-Host ("New WinRE target:     {0}" -f (Format-Bytes $targetRecoveryBytes))
    Write-Host ("Backup directory:     {0}" -f $backupDir)

    $availableAfterDeleteEstimate = [uint64]($recoveryPartition.Size + $tailFree)
    if ($availableAfterDeleteEstimate -le $targetRecoveryBytes) {
        Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
        throw 'There is not enough recoverable+unallocated space to keep the required WinRE size and also extend Windows.'
    }

    Write-Step 'Deleting the existing WinRE partition'
    $destructiveStarted = $true

    Invoke-DiskPartScript -Commands @(
        "select disk $($disk.Number)"
        "select partition $($recoveryPartition.PartitionNumber)"
        'delete partition override'
        'exit'
    )

    Start-Sleep -Seconds 1

    $oldStillExists = Get-Partition `
        -DiskNumber $disk.Number `
        -PartitionNumber $recoveryPartition.PartitionNumber `
        -ErrorAction SilentlyContinue

    if ($null -ne $oldStillExists) {
        throw 'The old WinRE partition still exists after DiskPart reported completion.'
    }

    Write-Step 'Extending the Windows partition while reserving space for WinRE'

    # Refresh the OS partition after the partition table change.
    $osPartition = Get-Partition -DriveLetter $osLetter
    $supported = Get-PartitionSupportedSize `
        -DiskNumber $osPartition.DiskNumber `
        -PartitionNumber $osPartition.PartitionNumber

    if ($supported.SizeMax -le $targetRecoveryBytes) {
        throw 'Unexpected disk geometry: supported Windows SizeMax is smaller than the WinRE reservation.'
    }

    # Align down to a MiB boundary so the remainder is at least the requested WinRE size.
    $targetOSSize = [uint64](
        [math]::Floor(
            (($supported.SizeMax - $targetRecoveryBytes) / [double]$MiB)
        ) * $MiB
    )

    if ($targetOSSize -le $osPartition.Size) {
        throw 'Calculated Windows target size is not larger than the current Windows partition.'
    }

    Write-Host ("Windows size before:  {0}" -f (Format-Bytes $osPartition.Size))
    Write-Host ("Windows size target:  {0}" -f (Format-Bytes $targetOSSize))
    Write-Host ("Increase:             {0}" -f (Format-Bytes ([uint64]($targetOSSize - $osPartition.Size))))

    Resize-Partition `
        -DiskNumber $osPartition.DiskNumber `
        -PartitionNumber $osPartition.PartitionNumber `
        -Size $targetOSSize

    Write-Step 'Creating the new WinRE partition at the end of the disk'

    # Create as basic data temporarily so a drive letter is guaranteed while
    # we populate it. It is converted to the official Recovery type afterward.
    $newRecovery = New-Partition `
        -DiskNumber $disk.Number `
        -UseMaximumSize `
        -AssignDriveLetter

    $newRecovery | Format-Volume `
        -FileSystem NTFS `
        -NewFileSystemLabel 'Windows RE tools' `
        -Confirm:$false | Out-Null

    $newRecovery = Get-Partition `
        -DiskNumber $disk.Number `
        -PartitionNumber $newRecovery.PartitionNumber

    if (-not $newRecovery.DriveLetter) {
        throw 'The new recovery partition did not receive a temporary drive letter.'
    }

    $recoveryLetter = [char]$newRecovery.DriveLetter
    $newRecoveryRoot = "$recoveryLetter`:\"
    $newWinREDir = Join-Path $newRecoveryRoot 'Recovery\WindowsRE'

    New-Item -ItemType Directory -Path $newWinREDir -Force | Out-Null
    Copy-Item -LiteralPath $winreWim -Destination (Join-Path $newWinREDir 'Winre.wim') -Force

    $copiedWim = Join-Path $newWinREDir 'Winre.wim'
    if (-not (Test-Path -LiteralPath $copiedWim)) {
        throw 'Failed to copy Winre.wim to the newly created recovery partition.'
    }

    Write-Step 'Registering the WinRE image'

    Invoke-ReAgentC -Arguments @('/setreimage', '/path', $newWinREDir) | Out-Null

    Write-Step 'Converting the new partition to the Microsoft Recovery type'

    # WinRE must be on the dedicated Recovery partition before /enable is called,
    # particularly on BitLocker-enabled systems. Remove the temporary letter,
    # then apply Microsoft's Recovery GPT type and required attributes.
    Invoke-DiskPartScript -Commands @(
        "select disk $($disk.Number)"
        "select partition $($newRecovery.PartitionNumber)"
        "remove letter=$recoveryLetter"
        "set id=$RecoveryGptTypeBare"
        'gpt attributes=0x8000000000000001'
        'exit'
    )

    Start-Sleep -Seconds 1

    Write-Step 'Enabling WinRE'
    Invoke-ReAgentC -Arguments @('/enable') | Out-Null

    Write-Step 'Final verification'

    $finalInfo = Invoke-ReAgentC -Arguments @('/info')

    $finalOS = Get-Partition -DriveLetter $osLetter
    $finalRecovery = Get-Partition `
        -DiskNumber $disk.Number `
        -PartitionNumber $newRecovery.PartitionNumber

    $finalType = "$($finalRecovery.GptType)".Trim('{}').ToLowerInvariant()
    if ($finalType -ne $RecoveryGptTypeBare) {
        throw "Final recovery partition type is incorrect: $($finalRecovery.GptType)"
    }

    $finalMatch = [regex]::Match(
        $finalInfo.Output,
        'GLOBALROOT\\device\\harddisk(?<disk>\d+)\\partition(?<partition>\d+)\\Recovery\\WindowsRE',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $finalMatch.Success) {
        throw 'REAgentC completed, but the final WinRE location could not be verified.'
    }

    if (
        ([int]$finalMatch.Groups['disk'].Value -ne $disk.Number) -or
        ([int]$finalMatch.Groups['partition'].Value -ne $finalRecovery.PartitionNumber)
    ) {
        throw 'WinRE is enabled, but REAgentC points to an unexpected disk/partition.'
    }

    Write-Host ''
    Write-Host 'SUCCESS' -ForegroundColor Green
    Write-Host ("Windows partition is now: {0}" -f (Format-Bytes $finalOS.Size))
    Write-Host ("WinRE partition is now:   {0} (partition {1})" -f `
        (Format-Bytes $finalRecovery.Size), $finalRecovery.PartitionNumber)
    Write-Host ("WinRE backup retained at: {0}" -f $backupDir)
    Write-Host ''
    Write-Host 'Keep the backup directory until you have rebooted and verified:' -ForegroundColor Yellow
    Write-Host '    reagentc /info'
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host 'ERROR' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($destructiveStarted) {
        Write-Warning 'A partition-table change has already occurred.'
        Write-Warning "Do NOT delete the backup directory: $backupDir"
    }

    Write-Warning 'Attempting to leave WinRE enabled if Windows can do so...'
    try {
        Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
    }
    catch {
        # Preserve the original failure.
    }

    throw
}