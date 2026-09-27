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

    # Non-destructive WinRE confirmation/registration recovery mode.
    [Alias('RecoverWinRE')]
    [switch]$WinRERecovery,

    # User-selectable final WinRE partition size.
    [ValidateRange(870, 1100)]
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

    # Native stderr from reagentc.exe is surfaced by Windows PowerShell as
    # ErrorRecord objects. With the script-wide ErrorActionPreference='Stop',
    # that can otherwise turn a normal nonzero reagentc exit into a terminating
    # PowerShell exception before -AllowFailure can inspect the exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & "$env:SystemRoot\System32\reagentc.exe" @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

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

function Invoke-WinREConfirmationRecovery {
    <#
    .SYNOPSIS
        Confirms the current WinRE state and repairs registration when needed.

    .DESCRIPTION
        This mode is for interrupted/partial runs where the Windows partition
        is already extended and an existing Microsoft Recovery GPT partition
        remains on the OS disk.

        It never deletes, creates, shrinks, or resizes partitions.
    #>

    Write-Step 'WinRE confirmation / recovery'

    $osDrive = $env:SystemDrive.TrimEnd(':')
    if ($osDrive.Length -ne 1) {
        throw "Unexpected SystemDrive value: $env:SystemDrive"
    }

    $osLetter = [char]$osDrive
    $osRoot = ("{0}:\" -f $osLetter)
    $osPartition = Get-Partition -DriveLetter $osLetter
    $disk = Get-Disk -Number $osPartition.DiskNumber

    if ($disk.PartitionStyle -ne 'GPT') {
        throw "WinRE recovery mode currently supports GPT disks only. Disk $($disk.Number) is $($disk.PartitionStyle)."
    }

    $currentInfo = Invoke-ReAgentC -Arguments @('/info') -AllowFailure
    $locationPattern = 'GLOBALROOT\\device\\harddisk(?<disk>\d+)\\partition(?<partition>\d+)\\Recovery\\WindowsRE'
    $currentLocation = [regex]::Match($currentInfo.Output, $locationPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $currentEnabled = $currentInfo.Output -match '(?im)Windows RE status:\s*Enabled'

    if ($currentEnabled -and $currentLocation.Success) {
        $registeredDisk = [int]$currentLocation.Groups['disk'].Value
        $registeredPartitionNumber = [int]$currentLocation.Groups['partition'].Value
        $registeredPartition = Get-Partition -DiskNumber $registeredDisk -PartitionNumber $registeredPartitionNumber -ErrorAction SilentlyContinue

        if ($null -ne $registeredPartition) {
            $registeredType = "$($registeredPartition.GptType)".Trim('{}').ToLowerInvariant()
            if (($registeredDisk -eq $disk.Number) -and ($registeredType -eq $RecoveryGptTypeBare)) {
                Write-Host ''
                Write-Host 'WINRE CONFIRMED' -ForegroundColor Green
                Write-Host 'Status:              Enabled'
                Write-Host ("Location:            disk {0}, partition {1}" -f $registeredDisk, $registeredPartitionNumber)
                Write-Host ("Recovery size:       {0}" -f (Format-Bytes $registeredPartition.Size))
                Write-Host 'No recovery action was necessary.'
                return
            }
        }

        Write-Warning 'WinRE reports Enabled, but its registered location is not a valid Recovery partition on the Windows disk.'
        Write-Warning 'Recovery mode will rebuild only the WinRE registration.'
    }

    $recoveryCandidates = @(Get-Partition -DiskNumber $disk.Number | Where-Object { "$($_.GptType)".Trim('{}').ToLowerInvariant() -eq $RecoveryGptTypeBare } | Sort-Object Offset)

    if ($recoveryCandidates.Count -eq 0) {
        throw @"
No Microsoft Recovery GPT partition was found on Windows disk $($disk.Number).

Recovery mode deliberately does not create/delete/resize partitions.
Inspect the disk layout before doing any further partition work.
"@
    }

    if ($recoveryCandidates.Count -gt 1) {
        Write-Warning 'More than one Microsoft Recovery partition exists on the Windows disk.'
        $recoveryCandidates | Select-Object PartitionNumber, DriveLetter, Size, Offset, GptType | Format-Table -AutoSize
        throw 'Recovery mode will not guess which Recovery partition should be used.'
    }

    $recoveryPartition = $recoveryCandidates[0]

    $recoveryVolume = $null
    try {
        $recoveryVolume = $recoveryPartition | Get-Volume -ErrorAction Stop
    }
    catch {
        Write-Warning "The Recovery volume could not be queried through Get-Volume: $($_.Exception.Message)"
    }

    if (($null -ne $recoveryVolume) -and (-not [string]::IsNullOrWhiteSpace("$($recoveryVolume.FileSystem)")) -and ("$($recoveryVolume.FileSystem)" -ne 'NTFS')) {
        throw "Recovery partition $($recoveryPartition.PartitionNumber) is formatted as $($recoveryVolume.FileSystem), not NTFS."
    }

    $stagingDir = Join-Path $env:SystemRoot 'System32\Recovery'
    $stagedWimPath = Join-Path $stagingDir 'Winre.wim'
    $sourceWim = $null
    $sourceDescription = $null

    try {
        $sourceWim = Get-Item -LiteralPath $stagedWimPath -Force -ErrorAction Stop
        $sourceDescription = 'Windows staging location'
    }
    catch {
        $backupDirs = @(Get-ChildItem -Path (Join-Path $osRoot 'WinRE-Relayout-Backup-*') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

        foreach ($backupDirCandidate in $backupDirs) {
            $candidatePath = Join-Path $backupDirCandidate.FullName 'Winre.wim'
            try {
                $sourceWim = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
                $sourceDescription = "Relayout backup: $($backupDirCandidate.FullName)"
                break
            }
            catch {
            }
        }
    }

    if ($null -eq $sourceWim) {
        throw @"
No Winre.wim source was found.

Checked:
  $stagedWimPath
  $osRoot\WinRE-Relayout-Backup-*\Winre.wim

Recovery mode will not download or synthesize a WinRE image.
"@
    }

    if ($sourceWim.Length -lt 50MB) {
        throw "The Winre.wim candidate is unexpectedly small ($(Format-Bytes $sourceWim.Length)): $($sourceWim.FullName)"
    }

    if ($recoveryPartition.Size -lt ([uint64]$sourceWim.Length + 250MB)) {
        throw 'The Recovery partition is too small for Winre.wim plus 250 MB servicing headroom.'
    }

    Write-Host ''
    [pscustomobject]@{
        Disk                   = $disk.Number
        'Windows partition'    = ("{0}: (partition {1})" -f $osLetter, $osPartition.PartitionNumber)
        'WinRE status'         = if ($currentEnabled) { 'Enabled, registration requires repair' } else { 'Disabled / not registered' }
        'Recovery partition'   = $recoveryPartition.PartitionNumber
        'Recovery size'        = Format-Bytes $recoveryPartition.Size
        'Recovery filesystem'  = if ($null -ne $recoveryVolume) { "$($recoveryVolume.FileSystem)" } else { 'Could not query' }
        'Current drive letter' = if ($recoveryPartition.DriveLetter) { ("{0}:" -f $recoveryPartition.DriveLetter) } else { '(none)' }
        'Winre.wim source'     = $sourceWim.FullName
        'Winre.wim size'       = Format-Bytes $sourceWim.Length
        'Source type'          = $sourceDescription
    } | Format-List

    Write-Host 'Recovery mode will NOT delete, create, shrink, or resize any partition.' -ForegroundColor Yellow

    if (-not $Force) {
        $confirmation = Read-Host 'Type RECOVER to repair WinRE registration, or anything else to cancel'
        if ($confirmation -cne 'RECOVER') {
            Write-Host 'Cancelled. No recovery changes were made.'
            return
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $repairBackupDir = Join-Path $osRoot "WinRE-Registration-Recovery-$timestamp"
    New-Item -ItemType Directory -Path $repairBackupDir -Force | Out-Null

    Write-Step 'Normalizing the existing Recovery partition metadata'

    $diskPartCommands = @(
        "select disk $($disk.Number)"
        "select partition $($recoveryPartition.PartitionNumber)"
    )

    if ($recoveryPartition.DriveLetter) {
        $diskPartCommands += "remove letter=$($recoveryPartition.DriveLetter) noerr"
    }

    $diskPartCommands += @(
        "set id=$RecoveryGptTypeBare"
        'gpt attributes=0x8000000000000001'
        'exit'
    )

    Invoke-DiskPartScript -Commands $diskPartCommands

    Write-Step 'Preparing a staged WinRE image'

    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    if ($sourceWim.FullName -ne $stagedWimPath) {
        Copy-Item -LiteralPath $sourceWim.FullName -Destination $stagedWimPath -Force
    }

    $stagedWim = Get-Item -LiteralPath $stagedWimPath -Force -ErrorAction Stop
    Copy-Item -LiteralPath $stagedWimPath -Destination (Join-Path $repairBackupDir 'Winre.wim.staged-copy') -Force

    Write-Host ("Staged Winre.wim:     {0}" -f $stagedWim.FullName)
    Write-Host ("Staged image size:    {0}" -f (Format-Bytes $stagedWim.Length))

    Write-Step 'Backing up and resetting REAgentC registration metadata'

    Invoke-ReAgentC -Arguments @('/disable') -AllowFailure | Out-Null

    $reAgentConfigDir = Join-Path $env:SystemRoot 'System32\Recovery'
    foreach ($configName in @('ReAgent.xml', 'ReAgent_Merged.xml')) {
        $configPath = Join-Path $reAgentConfigDir $configName
        if (Test-Path -LiteralPath $configPath) {
            Copy-Item -LiteralPath $configPath -Destination (Join-Path $repairBackupDir ($configName + '.before-recovery')) -Force
            Remove-Item -LiteralPath $configPath -Force
        }
    }

    try {
        $stagedWim = Get-Item -LiteralPath $stagedWimPath -Force -ErrorAction Stop
    }
    catch {
        Copy-Item -LiteralPath (Join-Path $repairBackupDir 'Winre.wim.staged-copy') -Destination $stagedWimPath -Force
        $stagedWim = Get-Item -LiteralPath $stagedWimPath -Force -ErrorAction Stop
    }

    Write-Step 'Registering the staged WinRE image'

    $setLog = Join-Path $repairBackupDir 'reagent-set.log'
    $setResult = Invoke-ReAgentC -Arguments @('/setreimage', '/path', $stagingDir, '/logpath', $setLog) -AllowFailure

    if ($setResult.ExitCode -ne 0) {
        throw "REAgentC /setreimage failed. Log retained at: $setLog"
    }

    Write-Step 'Enabling WinRE'

    $enableLog = Join-Path $repairBackupDir 'reagent-enable.log'
    $enableResult = Invoke-ReAgentC -Arguments @('/enable', '/logpath', $enableLog) -AllowFailure

    if ($enableResult.ExitCode -ne 0) {
        Write-Host ''
        Write-Host 'WINRE RECOVERY DID NOT COMPLETE' -ForegroundColor Red
        Write-Host ("REAgentC log: {0}" -f $enableLog)

        if (Test-Path -LiteralPath $enableLog) {
            $interesting = @(Select-String -Path $enableLog -Pattern 'BitlockerEnabled|Partition has bitlocker|using winre.wim|failed to find target partition|failed to install winre|Error' -CaseSensitive:$false -ErrorAction SilentlyContinue | Select-Object -Last 20)

            if ($interesting.Count -gt 0) {
                Write-Host ''
                Write-Host 'Relevant REAgentC diagnostics:' -ForegroundColor Yellow
                foreach ($line in $interesting) {
                    Write-Host $line.Line
                }
            }
        }

        throw @"
WinRE could not be enabled.

No partition was deleted, created, shrunk, or resized by recovery mode.
Diagnostic files are retained at:
  $repairBackupDir
"@
    }

    Write-Step 'Verifying WinRE'

    $finalInfo = Invoke-ReAgentC -Arguments @('/info')
    $finalLocation = [regex]::Match($finalInfo.Output, $locationPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $finalEnabled = $finalInfo.Output -match '(?im)Windows RE status:\s*Enabled'

    if (-not $finalEnabled -or -not $finalLocation.Success) {
        throw "REAgentC returned success, but the final WinRE state could not be verified. Logs: $repairBackupDir"
    }

    $finalDiskNumber = [int]$finalLocation.Groups['disk'].Value
    $finalPartitionNumber = [int]$finalLocation.Groups['partition'].Value

    if (($finalDiskNumber -ne $disk.Number) -or ($finalPartitionNumber -ne $recoveryPartition.PartitionNumber)) {
        throw "WinRE enabled on unexpected disk/partition: disk $finalDiskNumber, partition $finalPartitionNumber."
    }

    Write-Host ''
    Write-Host 'WINRE RECOVERY SUCCESSFUL' -ForegroundColor Green
    Write-Host 'Status:              Enabled'
    Write-Host ("Location:            disk {0}, partition {1}" -f $finalDiskNumber, $finalPartitionNumber)
    Write-Host ("Recovery size:       {0}" -f (Format-Bytes $recoveryPartition.Size))
    Write-Host ("Recovery log/backup: {0}" -f $repairBackupDir)
    Write-Host ''
    Write-Host 'Reboot once, then run reagentc /info again before deleting any WinRE backup folders.' -ForegroundColor Yellow
}


# ---------------------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------------------

Assert-Administrator

if ($WinRERecovery) {
    Invoke-WinREConfirmationRecovery
    exit 0
}

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

    # The selected size is the requested final partition size. Verify it can
    # hold Winre.wim plus Microsoft's servicing headroom and a small filesystem
    # cushion; do not silently increase beyond the user's selected size.
    $wimSize = [uint64]$winreWimItem.Length
    $minimumByImage = Round-Up -Value ($wimSize + 250MB + 32MB) -Multiple 64MB
    $targetRecoveryBytes = $requestedRecoveryBytes

    if ($targetRecoveryBytes -lt $minimumByImage) {
        throw ("Selected Recovery size ({0} MB) is too small for this Winre.wim. Minimum required on this machine is approximately {1} MB." -f `
            $RecoverySizeMB, [math]::Ceiling($minimumByImage / 1MB))
    }

    Write-Host ("Winre.wim size:       {0}" -f (Format-Bytes $wimSize))
    Write-Host ("Selected WinRE size:  {0}" -f (Format-Bytes $targetRecoveryBytes))
    Write-Host ("Minimum for this WIM:  {0}" -f (Format-Bytes $minimumByImage))
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

    # Create the partition as Microsoft Recovery from the outset. Do not create
    # it as a Basic Data partition first: on systems with BitLocker/device-
    # encryption policy, a newly mounted Basic Data volume can be classified as
    # BitLocker-protected before we convert it, which makes REAgentC reject it.
    $newRecovery = New-Partition `
        -DiskNumber $disk.Number `
        -Size $targetRecoveryBytes `
        -GptType $RecoveryGptType `
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

    Write-Step 'Resetting REAgentC registration metadata'

    # REAgentC can retain stale metadata that still associates WinRE with the
    # BitLocker-protected OS volume even after /setreimage reports the new
    # Recovery partition. Preserve the XML files, then force REAgentC to build
    # fresh registration state from the new WinRE path.
    $reAgentConfigDir = Join-Path $env:SystemRoot 'System32\Recovery'
    foreach ($configName in @('ReAgent.xml', 'ReAgent_Merged.xml')) {
        $configPath = Join-Path $reAgentConfigDir $configName
        if (Test-Path -LiteralPath $configPath) {
            Copy-Item -LiteralPath $configPath `
                -Destination (Join-Path $backupDir ($configName + '.pre-register')) `
                -Force
            Remove-Item -LiteralPath $configPath -Force
        }
    }

    Write-Step 'Registering the WinRE image'

    Invoke-ReAgentC -Arguments @('/setreimage', '/path', $newWinREDir) | Out-Null

    Write-Step 'Finalizing the Microsoft Recovery partition'

    # The partition was created with the Recovery GUID from the outset. Remove
    # its temporary drive letter and apply Microsoft's required GPT attributes
    # before asking REAgentC to enable WinRE.
    Invoke-DiskPartScript -Commands @(
        "select disk $($disk.Number)"
        "select partition $($newRecovery.PartitionNumber)"
        "remove letter=$recoveryLetter"
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