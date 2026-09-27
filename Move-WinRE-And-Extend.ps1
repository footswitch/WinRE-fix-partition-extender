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
      - Supports both free space after WinRE and an already-completed layout.
      - Manages BitLocker as a known one-reboot suspension for Execute.
      - Backs up Winre.wim before deleting the existing recovery partition.
      - Warns when there is no real free space to reclaim and the only gain
        comes from making WinRE smaller.
      - Attempts to restore the original C: size, WinRE offset, and WinRE
        size automatically if a destructive relayout step fails.
      - Recreates WinRE using Microsoft's recovery GUID and GPT attributes.
      - Treats same-session WinRE enablement as provisional.
      - Requires post-reboot WinRE / disk / BitLocker confirmation.

    Recommended BAT workflow:
      1. Run Move-WinRE-And-Extend.bat and choose Dry run.
      2. Review the proposed layout and selected WinRE size.
      3. Restart Windows.
      4. Run the BAT again and choose Execute.
      5. Type RELAYOUT when prompted.
      6. After Execute succeeds, restart Windows again.
      7. Run the BAT and choose WinRE confirmation / recovery.
      8. Finish only when it reports:
            FINAL DISK / WINRE STATE CONFIRMED

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

function Get-VolumeFreeBytes {
    param([char]$DriveLetter)

    $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
    return [uint64]$volume.SizeRemaining
}

function Assert-FreeSpace {
    param(
        [char]$DriveLetter,
        [uint64]$RequiredBytes,
        [string]$Purpose
    )

    $freeBytes = Get-VolumeFreeBytes -DriveLetter $DriveLetter

    if ($freeBytes -lt $RequiredBytes) {
        throw ("Insufficient free space on {0}: for {1}. Available: {2}; required: {3}." -f `
            $DriveLetter, $Purpose, (Format-Bytes $freeBytes), (Format-Bytes $RequiredBytes))
    }

    return [pscustomobject]@{
        FreeBytes     = $freeBytes
        RequiredBytes = $RequiredBytes
        Purpose       = $Purpose
    }
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
    param([string]$InfoOutput)

    if ([string]::IsNullOrWhiteSpace($InfoOutput)) {
        $result = Invoke-ReAgentC -Arguments @('/info')
        $InfoOutput = $result.Output
    }

    $m = [regex]::Match(
        $InfoOutput,
        'GLOBALROOT\\device\\harddisk(?<disk>\d+)\\partition(?<partition>\d+)\\Recovery\\WindowsRE',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        return $null
    }

    [pscustomobject]@{
        DiskNumber      = [int]$m.Groups['disk'].Value
        PartitionNumber = [int]$m.Groups['partition'].Value
        RawInfo         = $InfoOutput
    }
}

function Get-InterruptedWinREState {
    param(
        [Parameter(Mandatory)] [int]$DiskNumber,
        [Parameter(Mandatory)] [char]$OsLetter
    )

    $osPartition = Get-Partition -DriveLetter $OsLetter
    $partitions = @(Get-Partition -DiskNumber $DiskNumber | Sort-Object Offset)
    $recoveryCandidates = @(
        $partitions |
            Where-Object { "$($_.GptType)".Trim('{}').ToLowerInvariant() -eq $RecoveryGptTypeBare }
    )

    $stagedWimPath = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
    $stagedWimPresent = Test-Path -LiteralPath $stagedWimPath

    $osRoot = ("{0}:\" -f $OsLetter)
    $backupDirs = @(Get-ChildItem -Path (Join-Path $osRoot 'WinRE-Relayout-Backup-*') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $backupWim = $null
    foreach ($backupDir in $backupDirs) {
        $candidateBackupWim = Join-Path $backupDir.FullName 'Winre.wim'
        if (Test-Path -LiteralPath $candidateBackupWim) {
            $backupWim = $candidateBackupWim
            break
        }
    }

    $sourceWimPath = if ($null -ne $backupWim) { $backupWim } elseif ($stagedWimPresent) { $stagedWimPath } else { $null }
    $sourceWimItem = $null
    $requiredRecoveryBytes = $null
    if ($null -ne $sourceWimPath) {
        $sourceWimItem = Get-Item -LiteralPath $sourceWimPath -Force -ErrorAction Stop
        $requiredRecoveryBytes = Round-Up -Value ([uint64]$sourceWimItem.Length + 200MB) -Multiple 1MB
    }

    $candidate = $null
    $candidateImmediatelyAfterOS = $false
    $candidateLast = $false
    if ($recoveryCandidates.Count -eq 1) {
        $candidate = $recoveryCandidates[0]
        $nextAfterOS = @($partitions | Where-Object { $_.Offset -gt $osPartition.Offset } | Select-Object -First 1)
        $afterCandidate = @($partitions | Where-Object { $_.Offset -gt $candidate.Offset })
        $candidateImmediatelyAfterOS = (($nextAfterOS.Count -eq 1) -and ($nextAfterOS[0].PartitionNumber -eq $candidate.PartitionNumber))
        $candidateLast = $afterCandidate.Count -eq 0
    }

    $usableCandidate = (($null -ne $candidate) -and $candidateImmediatelyAfterOS -and $candidateLast -and ($null -ne $sourceWimItem))
    $candidateMeetsMinimum = ($usableCandidate -and ([uint64]$candidate.Size -ge [uint64]$requiredRecoveryBytes))

    return [pscustomobject]@{
        Partitions                  = $partitions
        RecoveryCandidateCount      = $recoveryCandidates.Count
        RecoveryPartition           = $candidate
        CandidateImmediatelyAfterOS = $candidateImmediatelyAfterOS
        CandidateLast               = $candidateLast
        StagedWimPresent             = $stagedWimPresent
        BackupWimPath                = $backupWim
        SourceWimPath                = $sourceWimPath
        SourceWimSize                = if ($null -ne $sourceWimItem) { [uint64]$sourceWimItem.Length } else { $null }
        RequiredRecoveryBytes        = $requiredRecoveryBytes
        UsableCandidate              = $usableCandidate
        CandidateMeetsMinimum        = $candidateMeetsMinimum
    }
}

function Write-InterruptedWinREGuidance {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [int]$DiskNumber
    )

    Write-Host ''
    Write-Host 'WINRE IS DISABLED - INTERRUPTED STATE DETECTED' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'This usually means a previous WinRE operation was interrupted or is still awaiting recovery/confirmation.'
    Write-Host 'The script will not guess an active WinRE registration.'
    Write-Host ''
    Write-Host ("Windows disk:              {0}" -f $DiskNumber)
    Write-Host ("Recovery GPT candidates:   {0}" -f $State.RecoveryCandidateCount)
    Write-Host ("Staged Winre.wim present:  {0}" -f $(if ($State.StagedWimPresent) { 'Yes' } else { 'No' }))
    Write-Host ("Relayout backup present:   {0}" -f $(if ($null -ne $State.BackupWimPath) { 'Yes' } else { 'No' }))
    if ($null -ne $State.BackupWimPath) {
        Write-Host ("Newest usable backup:      {0}" -f $State.BackupWimPath)
    }
    if ($null -ne $State.SourceWimPath) {
        Write-Host ("Selected Winre.wim source: {0}" -f $State.SourceWimPath)
        Write-Host ("Winre.wim size:            {0}" -f (Format-Bytes $State.SourceWimSize))
        Write-Host ("Minimum Recovery size:     {0}" -f (Format-Bytes $State.RequiredRecoveryBytes))
    }

    if ($null -ne $State.RecoveryPartition) {
        $candidate = $State.RecoveryPartition
        Write-Host ''
        Write-Host 'Detected Recovery candidate:' -ForegroundColor Cyan
        Write-Host ("  Partition:               {0}" -f $candidate.PartitionNumber)
        Write-Host ("  Size:                    {0}" -f (Format-Bytes $candidate.Size))
        Write-Host ("  Immediately after C:     {0}" -f $(if ($State.CandidateImmediatelyAfterOS) { 'Yes' } else { 'No' }))
        Write-Host ("  Last partition on disk:  {0}" -f $(if ($State.CandidateLast) { 'Yes' } else { 'No' }))
    }

    if ($State.CandidateMeetsMinimum) {
        Write-Host ''
        Write-Host 'RECOMMENDED NEXT STEP:' -ForegroundColor Green
        Write-Host '  Choose [3] WinRE confirmation / recovery.'
        Write-Host 'The existing Recovery partition is large enough, so partition changes are not needed.'
        return
    }

    if ($State.UsableCandidate) {
        Write-Host ''
        Write-Warning 'The existing Recovery partition is too small for this Winre.wim under the Windows 11 minimum free-space requirement.'
        Write-Warning 'Option 3 cannot resize partitions.'
        Write-Host 'Dry run can evaluate an interrupted-relayout repair using the retained Winre.wim backup.' -ForegroundColor Yellow
        return
    }

    if ($State.RecoveryCandidateCount -eq 0) {
        Write-Warning 'No Microsoft Recovery GPT partition exists on the Windows disk.'
    }
    elseif ($State.RecoveryCandidateCount -gt 1) {
        Write-Warning 'More than one Microsoft Recovery GPT partition exists on the Windows disk.'
    }
    elseif (-not $State.CandidateImmediatelyAfterOS -or -not $State.CandidateLast) {
        Write-Warning 'The Recovery GPT partition placement does not match the supported layout.'
    }
    if ($null -eq $State.SourceWimPath) {
        Write-Warning 'No staged or retained Winre.wim source is available.'
    }
    Write-Warning 'The script will not attempt partition changes in this state.'
    Write-Host ''
    Write-Host 'Current partition layout:' -ForegroundColor Cyan
    $State.Partitions |
        Select-Object PartitionNumber, DriveLetter, Offset, Size, GptType, IsHidden, NoDefaultDriveLetter |
        Format-Table -AutoSize
}
function Get-BitLockerState {
    param([char]$DriveLetter)

    $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return [pscustomobject]@{
            Available            = $false
            DriveLetter          = $DriveLetter
            VolumeStatus         = 'Unknown'
            ProtectionStatus     = 'Unknown'
            LockStatus           = 'Unknown'
            EncryptionPercentage = $null
            IsEncrypted          = $null
            KeyProtectorCount    = $null
            KeyProtectorTypes    = @()
        }
    }

    try {
        $bl = Get-BitLockerVolume -MountPoint (("{0}:" -f $DriveLetter)) -ErrorAction Stop
        $volumeStatus = "$($bl.VolumeStatus)"
        $isEncrypted = $volumeStatus -ne 'FullyDecrypted'

        $keyProtectors = @($bl.KeyProtector)
        $keyProtectorTypes = @(
            $keyProtectors |
                ForEach-Object { "$($_.KeyProtectorType)" } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        return [pscustomobject]@{
            Available            = $true
            DriveLetter          = $DriveLetter
            VolumeStatus         = $volumeStatus
            ProtectionStatus     = "$($bl.ProtectionStatus)"
            LockStatus           = "$($bl.LockStatus)"
            EncryptionPercentage = $bl.EncryptionPercentage
            IsEncrypted          = $isEncrypted
            KeyProtectorCount    = $keyProtectors.Count
            KeyProtectorTypes    = $keyProtectorTypes
        }
    }
    catch {
        Write-Warning "Could not query BitLocker state: $($_.Exception.Message)"
        return [pscustomobject]@{
            Available            = $false
            DriveLetter          = $DriveLetter
            VolumeStatus         = 'Unknown'
            ProtectionStatus     = 'Unknown'
            LockStatus           = 'Unknown'
            EncryptionPercentage = $null
            IsEncrypted          = $null
            KeyProtectorCount    = $null
            KeyProtectorTypes    = @()
        }
    }
}

function Write-BitLockerState {
    param(
        [Parameter(Mandatory)]
        $State,
        [string]$Prefix = 'BitLocker'
    )

    if (-not $State.Available) {
        Write-Warning "$Prefix state could not be verified automatically."
        return
    }

    Write-Host ("{0} volume status:     {1}" -f $Prefix, $State.VolumeStatus)
    Write-Host ("{0} protection:        {1}" -f $Prefix, $State.ProtectionStatus)
    Write-Host ("{0} lock status:       {1}" -f $Prefix, $State.LockStatus)
    if ($null -ne $State.EncryptionPercentage) {
        Write-Host ("{0} encrypted:         {1}%" -f $Prefix, $State.EncryptionPercentage)
    }

    if ($State.IsEncrypted) {
        if ($null -ne $State.KeyProtectorCount) {
            Write-Host ("{0} key protectors:     {1}" -f $Prefix, $State.KeyProtectorCount)
            if ($State.KeyProtectorCount -gt 0) {
                Write-Host ("{0} protector types:    {1}" -f $Prefix, ($State.KeyProtectorTypes -join ', '))
            }
            else {
                Write-Warning 'The encrypted OS volume has no configured BitLocker key protectors.'
            }
        }

        if ($State.ProtectionStatus -eq 'Off') {
            Write-Warning 'The OS volume is encrypted, but BitLocker protection is suspended.'
        }
    }
}

function Set-BitLockerKnownOneRebootSuspension {
    param([char]$DriveLetter)

    $state = Get-BitLockerState -DriveLetter $DriveLetter
    Write-BitLockerState -State $state -Prefix 'BitLocker before Execute'

    if (-not $state.Available) {
        throw 'BitLocker state could not be verified. Refusing to start partition changes.'
    }

    if (-not $state.IsEncrypted) {
        Write-Host 'BitLocker is not enabled on the OS volume; no suspension is required.'
        return $state
    }

    $mountPoint = ("{0}:" -f $DriveLetter)

    if ($state.KeyProtectorCount -eq 0) {
        throw 'The OS volume is encrypted but has no configured BitLocker key protectors. Refusing to change partitions until BitLocker protection is repaired.'
    }

    if ($state.ProtectionStatus -eq 'Off') {
        Write-Warning 'BitLocker was already suspended before this run.'
        Write-Host 'Resetting it to a known one-reboot suspension so protection should resume after the required restart.'
        Resume-BitLocker -MountPoint $mountPoint -ErrorAction Stop | Out-Null
        Start-Sleep -Milliseconds 500
        $state = Get-BitLockerState -DriveLetter $DriveLetter
        if ((-not $state.Available) -or ($state.ProtectionStatus -ne 'On')) {
            throw 'BitLocker could not be resumed before establishing the controlled one-reboot suspension.'
        }
    }

    Suspend-BitLocker -MountPoint $mountPoint -RebootCount 1 -ErrorAction Stop | Out-Null
    $after = Get-BitLockerState -DriveLetter $DriveLetter

    if ((-not $after.Available) -or ($after.ProtectionStatus -ne 'Off')) {
        throw 'Could not establish the required one-reboot BitLocker suspension.'
    }

    Write-Host 'BitLocker protection is suspended for one reboot.' -ForegroundColor Yellow
    Write-Host 'It should automatically resume after the required post-Execute restart.' -ForegroundColor Yellow
    return $after
}

function Ensure-BitLockerResumedForFinalConfirmation {
    param([char]$DriveLetter)

    $state = Get-BitLockerState -DriveLetter $DriveLetter

    if (-not $state.Available) {
        return [pscustomobject]@{ State = $state; Issue = 'BitLocker state could not be verified.' }
    }

    if (-not $state.IsEncrypted) {
        return [pscustomobject]@{ State = $state; Issue = $null }
    }

    if ($state.ProtectionStatus -eq 'On') {
        return [pscustomobject]@{ State = $state; Issue = $null }
    }

    if ($state.KeyProtectorCount -eq 0) {
        return [pscustomobject]@{
            State = $state
            Issue = 'BitLocker protection is suspended and the encrypted OS volume has no configured key protectors. Add or restore an appropriate key protector before attempting to resume protection.'
        }
    }

    Write-Warning 'BitLocker is encrypted but protection is still suspended after reboot.'
    Write-Host 'Attempting to resume BitLocker protection now.'

    try {
        Resume-BitLocker -MountPoint (("{0}:" -f $DriveLetter)) -ErrorAction Stop | Out-Null
        Start-Sleep -Milliseconds 500
        $state = Get-BitLockerState -DriveLetter $DriveLetter
    }
    catch {
        return [pscustomobject]@{ State = $state; Issue = "BitLocker protection is suspended and could not be resumed: $($_.Exception.Message)" }
    }

    if ($state.ProtectionStatus -ne 'On') {
        return [pscustomobject]@{ State = $state; Issue = 'BitLocker protection remains suspended after Resume-BitLocker.' }
    }

    Write-Host 'BitLocker protection resumed successfully.' -ForegroundColor Green
    return [pscustomobject]@{ State = $state; Issue = $null }
}

function Invoke-WinRERollback {
    param(
        [Parameter(Mandatory)] [int]$DiskNumber,
        [Parameter(Mandatory)] [char]$OsLetter,
        [Parameter(Mandatory)] [uint64]$OriginalOSSize,
        [Parameter(Mandatory)] [uint64]$OriginalRecoveryOffset,
        [Parameter(Mandatory)] [uint64]$OriginalRecoverySize,
        [Parameter(Mandatory)] [string]$BackupWimPath
    )

    Write-Step 'Attempting automatic rollback to the original WinRE layout'

    if (-not (Test-Path -LiteralPath $BackupWimPath)) {
        throw "Rollback cannot continue because the Winre.wim backup is missing: $BackupWimPath"
    }

    Invoke-ReAgentC -Arguments @('/disable') -AllowFailure | Out-Null

    $osPartition = Get-Partition -DriveLetter $OsLetter
    $partitionsAfterOS = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Offset -gt $osPartition.Offset } | Sort-Object Offset)

    if ($partitionsAfterOS.Count -gt 1) {
        throw 'Rollback found more than one partition after the Windows partition and will not guess which one to remove.'
    }

    if ($partitionsAfterOS.Count -eq 1) {
        $candidate = $partitionsAfterOS[0]
        $candidateType = "$($candidate.GptType)".Trim('{}').ToLowerInvariant()
        if ($candidateType -ne $RecoveryGptTypeBare) {
            throw "Rollback found an unexpected partition after Windows (partition $($candidate.PartitionNumber), type $($candidate.GptType))."
        }

        Write-Host ("Removing partial Recovery partition {0} before rollback." -f $candidate.PartitionNumber)
        Invoke-DiskPartScript -Commands @(
            "select disk $DiskNumber"
            "select partition $($candidate.PartitionNumber)"
            'delete partition override'
            'exit'
        )
        Start-Sleep -Milliseconds 750
    }

    $osPartition = Get-Partition -DriveLetter $OsLetter
    $supported = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber

    if (($OriginalOSSize -lt $supported.SizeMin) -or ($OriginalOSSize -gt $supported.SizeMax)) {
        throw ("Rollback cannot restore the original Windows partition size ({0}). Supported range is {1} to {2}." -f `
            (Format-Bytes $OriginalOSSize), (Format-Bytes ([uint64]$supported.SizeMin)), (Format-Bytes ([uint64]$supported.SizeMax)))
    }

    if ([uint64]$osPartition.Size -ne $OriginalOSSize) {
        Write-Host ("Restoring Windows partition size to {0}." -f (Format-Bytes $OriginalOSSize))
        Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $osPartition.PartitionNumber -Size $OriginalOSSize
    }

    Write-Host ("Recreating WinRE at original size {0}." -f (Format-Bytes $OriginalRecoverySize))
    $restoredRecovery = New-Partition `
        -DiskNumber $DiskNumber `
        -Offset $OriginalRecoveryOffset `
        -Size $OriginalRecoverySize `
        -GptType $RecoveryGptType `
        -AssignDriveLetter

    $restoredRecovery | Format-Volume `
        -FileSystem NTFS `
        -NewFileSystemLabel 'Windows RE tools' `
        -Confirm:$false | Out-Null

    $restoredRecovery = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $restoredRecovery.PartitionNumber
    if (-not $restoredRecovery.DriveLetter) {
        throw 'Rollback recreated the Recovery partition but did not receive a temporary drive letter.'
    }

    $rollbackLetter = [char]$restoredRecovery.DriveLetter
    $rollbackWinREDir = Join-Path ("{0}:\" -f $rollbackLetter) 'Recovery\WindowsRE'
    New-Item -ItemType Directory -Path $rollbackWinREDir -Force | Out-Null
    Copy-Item -LiteralPath $BackupWimPath -Destination (Join-Path $rollbackWinREDir 'Winre.wim') -Force

    $setResult = Invoke-ReAgentC -Arguments @('/setreimage', '/path', $rollbackWinREDir) -AllowFailure

    Invoke-DiskPartScript -Commands @(
        "select disk $DiskNumber"
        "select partition $($restoredRecovery.PartitionNumber)"
        "remove letter=$rollbackLetter noerr"
        'gpt attributes=0x8000000000000001'
        'exit'
    )

    $enableResult = Invoke-ReAgentC -Arguments @('/enable') -AllowFailure

    $finalRecovery = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $restoredRecovery.PartitionNumber
    $sizeDifference = [math]::Abs([int64]$finalRecovery.Size - [int64]$OriginalRecoverySize)
    $typeOk = "$($finalRecovery.GptType)".Trim('{}').ToLowerInvariant() -eq $RecoveryGptTypeBare

    if (($sizeDifference -gt 1MB) -or (-not $typeOk)) {
        throw 'Rollback recreated a Recovery partition, but its final size or GPT type does not match the original layout.'
    }

    Write-Host ''
    Write-Host 'AUTOMATIC ROLLBACK RESTORED THE ORIGINAL PARTITION SIZES' -ForegroundColor Green
    Write-Host ("Windows partition:   {0}" -f (Format-Bytes $OriginalOSSize))
    Write-Host ("WinRE partition:     {0}" -f (Format-Bytes $OriginalRecoverySize))
    Write-Host ("WinRE partition no.: {0}" -f $finalRecovery.PartitionNumber)

    if (($setResult.ExitCode -eq 0) -and ($enableResult.ExitCode -eq 0)) {
        Write-Host 'WinRE registration was also re-applied; post-reboot confirmation is still required.' -ForegroundColor Yellow
    } else {
        Write-Warning 'Partition sizes were restored, but WinRE registration still needs post-reboot confirmation/recovery.'
    }

    return [pscustomobject]@{
        LayoutRestored = $true
        RegistrationCommandSucceeded = (($setResult.ExitCode -eq 0) -and ($enableResult.ExitCode -eq 0))
        RecoveryPartitionNumber = $finalRecovery.PartitionNumber
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

    Write-Step 'Checking BitLocker protection after reboot'
    $bitLockerConfirmation = Ensure-BitLockerResumedForFinalConfirmation -DriveLetter $osLetter
    Write-BitLockerState -State $bitLockerConfirmation.State -Prefix 'BitLocker post-reboot'
    if ($null -ne $bitLockerConfirmation.Issue) {
        Write-Warning $bitLockerConfirmation.Issue
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
            $allPartitions = @(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)
            $nextAfterOS = @($allPartitions | Where-Object { $_.Offset -gt $osPartition.Offset } | Select-Object -First 1)
            $afterRecovery = @($allPartitions | Where-Object { $_.Offset -gt $registeredPartition.Offset })
            $sizeMB = [math]::Round($registeredPartition.Size / 1MB, 0)

            $registeredVolume = $null
            try {
                $registeredVolume = $registeredPartition | Get-Volume -ErrorAction Stop
            }
            catch {
            }

            $layoutIssues = @()

            $bitLockerFinal = $bitLockerConfirmation
            if ($null -ne $bitLockerFinal.Issue) {
                $layoutIssues += $bitLockerFinal.Issue
            }

            if ($registeredDisk -ne $disk.Number) {
                $layoutIssues += "WinRE is registered on disk $registeredDisk instead of Windows disk $($disk.Number)."
            }
            if ($registeredType -ne $RecoveryGptTypeBare) {
                $layoutIssues += "Partition $registeredPartitionNumber is not the Microsoft Recovery GPT type."
            }
            if (($nextAfterOS.Count -ne 1) -or ($nextAfterOS[0].PartitionNumber -ne $registeredPartitionNumber)) {
                $layoutIssues += 'The WinRE partition is not immediately after the Windows partition.'
            }
            if ($afterRecovery.Count -ne 0) {
                $layoutIssues += 'Another partition exists after the WinRE partition.'
            }
            if ($registeredPartition.DriveLetter) {
                $layoutIssues += "The WinRE partition still has drive letter $($registeredPartition.DriveLetter):."
            }
            if (-not $registeredPartition.IsHidden) {
                $layoutIssues += 'The WinRE partition is not marked hidden.'
            }
            if (-not $registeredPartition.NoDefaultDriveLetter) {
                $layoutIssues += 'The WinRE partition does not have the no-default-drive-letter attribute.'
            }
            if (($null -eq $registeredVolume) -or ("$($registeredVolume.FileSystem)" -ne 'NTFS')) {
                $layoutIssues += 'The WinRE partition filesystem could not be confirmed as NTFS.'
            }
            if (($sizeMB -lt 870) -or ($sizeMB -gt 1100)) {
                $layoutIssues += "The WinRE partition size ($sizeMB MB) is outside the expected 870-1100 MB range."
            }

            if ($layoutIssues.Count -eq 0) {
                Write-Host ''
                Write-Host 'FINAL DISK / WINRE STATE CONFIRMED' -ForegroundColor Green
                Write-Host 'WinRE status:          Enabled'
                Write-Host ("WinRE location:        disk {0}, partition {1}" -f $registeredDisk, $registeredPartitionNumber)
                Write-Host ("Recovery size:         {0} MB" -f $sizeMB)
                Write-Host 'Recovery filesystem:   NTFS'
                Write-Host 'Recovery drive letter: none'
                Write-Host 'Recovery attributes:   hidden + no-default-drive-letter'
                Write-Host 'Partition placement:   immediately after C: and last on disk'
                if ($bitLockerFinal.State.Available) {
                    if ($bitLockerFinal.State.IsEncrypted) {
                        Write-Host ("BitLocker protection:  {0}" -f $bitLockerFinal.State.ProtectionStatus)
                    } else {
                        Write-Host 'BitLocker protection:  not enabled on OS volume'
                    }
                }
                Write-Host ''
                Write-Host 'The post-reboot validation passed. The relayout operation is complete.' -ForegroundColor Green
                return
            }

            Write-Warning 'WinRE is enabled, but the final disk layout is not fully normalized:'
            foreach ($issue in $layoutIssues) {
                Write-Warning ("  - {0}" -f $issue)
            }
        }

        Write-Warning 'WinRE confirmation did not pass all final-state checks.'
        Write-Warning 'Recovery mode will attempt only WinRE metadata/registration repair; it will not resize partitions.'
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

    $recoveryOperationalMinimum = Round-Up -Value ([uint64]$sourceWim.Length + 200MB) -Multiple 1MB
    $recoveryRecommendedSize = Round-Up -Value ([uint64]$sourceWim.Length + 250MB) -Multiple 1MB

    if ($recoveryPartition.Size -lt $recoveryOperationalMinimum) {
        throw ("The Recovery partition is too small for Windows 11 WinRE. Winre.wim requires at least 200 MB free space in the Recovery partition. Required partition size: approximately {0} MB." -f [math]::Ceiling($recoveryOperationalMinimum / 1MB))
    }

    if ($recoveryPartition.Size -lt $recoveryRecommendedSize) {
        Write-Warning 'The Recovery partition leaves between 200 MB and 250 MB free above Winre.wim. It meets the Windows 11 minimum, but the recommended servicing headroom is tighter.'
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

    Write-Step 'Preparing the existing Recovery partition'

    $recoveryPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $recoveryPartition.PartitionNumber

    if (-not $recoveryPartition.DriveLetter) {
        Add-PartitionAccessPath `
            -DiskNumber $disk.Number `
            -PartitionNumber $recoveryPartition.PartitionNumber `
            -AssignDriveLetter `
            -ErrorAction Stop | Out-Null

        Start-Sleep -Milliseconds 500
        $recoveryPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $recoveryPartition.PartitionNumber
    }

    if (-not $recoveryPartition.DriveLetter) {
        throw 'Could not assign a temporary drive letter to the existing Recovery partition.'
    }

    $recoveryLetter = [char]$recoveryPartition.DriveLetter
    $recoveryRoot = ("{0}:\" -f $recoveryLetter)
    if (-not (Test-Path -LiteralPath $recoveryRoot)) {
        throw "Recovery partition drive letter $recoveryLetter`: is not accessible."
    }

    $recoveryWinREDir = Join-Path $recoveryRoot 'Recovery\WindowsRE'
    $recoveryWimPath = Join-Path $recoveryWinREDir 'Winre.wim'

    New-Item -ItemType Directory -Path $recoveryWinREDir -Force | Out-Null
    Copy-Item -LiteralPath $sourceWim.FullName -Destination $recoveryWimPath -Force -ErrorAction Stop

    $recoveryWim = Get-Item -LiteralPath $recoveryWimPath -Force -ErrorAction Stop
    if ($recoveryWim.Length -ne $sourceWim.Length) {
        throw 'Copied Winre.wim size on the Recovery partition does not match the source.'
    }

    Copy-Item -LiteralPath $sourceWim.FullName -Destination (Join-Path $repairBackupDir 'Winre.wim.repair-copy') -Force -ErrorAction Stop

    Write-Host ("Recovery Winre.wim:   {0}" -f $recoveryWim.FullName)
    Write-Host ("Recovery image size:  {0}" -f (Format-Bytes $recoveryWim.Length))

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

    if (-not (Test-Path -LiteralPath $recoveryWimPath)) {
        Copy-Item -LiteralPath (Join-Path $repairBackupDir 'Winre.wim.repair-copy') -Destination $recoveryWimPath -Force -ErrorAction Stop
    }

    Write-Step 'Registering WinRE on the Recovery partition'

    $setLog = Join-Path $repairBackupDir 'reagent-set.log'
    $setResult = Invoke-ReAgentC -Arguments @('/setreimage', '/path', $recoveryWinREDir, '/logpath', $setLog) -AllowFailure

    if ($setResult.ExitCode -ne 0) {
        throw "REAgentC /setreimage failed. Log retained at: $setLog"
    }

    Write-Step 'Finalizing the existing Recovery partition'

    Remove-PartitionAccessPath `
        -DiskNumber $disk.Number `
        -PartitionNumber $recoveryPartition.PartitionNumber `
        -AccessPath ("{0}:" -f $recoveryLetter) `
        -ErrorAction Stop | Out-Null

    Invoke-DiskPartScript -Commands @(
        "select disk $($disk.Number)"
        "select partition $($recoveryPartition.PartitionNumber)"
        "set id=$RecoveryGptTypeBare"
        'gpt attributes=0x8000000000000001'
        'exit'
    )

    Start-Sleep -Milliseconds 500
    $recoveryPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $recoveryPartition.PartitionNumber
    if ($recoveryPartition.DriveLetter) {
        throw "Recovery partition still has drive letter $($recoveryPartition.DriveLetter): after finalization."
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
    Write-Host 'WINRE RECOVERY APPLIED' -ForegroundColor Green
    Write-Host 'Status:              Enabled'
    Write-Host ("Location:            disk {0}, partition {1}" -f $finalDiskNumber, $finalPartitionNumber)
    Write-Host ("Recovery size:       {0}" -f (Format-Bytes $recoveryPartition.Size))
    Write-Host ("Recovery log/backup: {0}" -f $repairBackupDir)
    Write-Host ''
    Write-Host 'REQUIRED FINAL VALIDATION:' -ForegroundColor Yellow
    Write-Host '  1. Restart Windows.'
    Write-Host '  2. Run Move-WinRE-And-Extend.bat.'
    Write-Host '  3. Choose WinRE confirmation / recovery again.'
    Write-Host '  4. The operation is complete only when it reports:'
    Write-Host '     FINAL DISK / WINRE STATE CONFIRMED'
    Write-Host ''
    Write-Host 'Keep all WinRE backup folders until that post-reboot confirmation succeeds.' -ForegroundColor Yellow
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

$reAgentInfo = Invoke-ReAgentC -Arguments @('/info') -AllowFailure

if ($reAgentInfo.ExitCode -ne 0) {
    Write-Warning 'REAgentC /info failed, so the current WinRE state cannot be verified safely.'
    Write-Warning 'Do not run Execute until the WinRE state has been inspected.'
    Write-Host ''
    Write-Host 'No changes were made.' -ForegroundColor Yellow
    exit 2
}

$winreEnabled = $reAgentInfo.Output -match '(?im)Windows RE status:\s*Enabled'
$interruptedRelayout = $false
$interruptedWimPath = $null
$interruptedWimSize = $null

if (-not $winreEnabled) {
    $interruptedState = Get-InterruptedWinREState -DiskNumber $disk.Number -OsLetter $osLetter
    Write-InterruptedWinREGuidance -State $interruptedState -DiskNumber $disk.Number

    if (-not $interruptedState.UsableCandidate) {
        Write-Host ''
        Write-Host 'No changes were made.' -ForegroundColor Yellow
        exit 2
    }

    if ($interruptedState.CandidateMeetsMinimum) {
        Write-Host ''
        Write-Host 'No changes were made. Use option 3 instead of Execute.' -ForegroundColor Yellow
        exit 2
    }

    $interruptedRelayout = $true
    $interruptedWimPath = $interruptedState.SourceWimPath
    $interruptedWimSize = [uint64]$interruptedState.SourceWimSize
    $recoveryPartition = $interruptedState.RecoveryPartition
    $winre = [pscustomobject]@{
        DiskNumber      = $disk.Number
        PartitionNumber = $recoveryPartition.PartitionNumber
        RawInfo         = $reAgentInfo.Output
    }
}
else {
    $winre = Get-WinRELocation -InfoOutput $reAgentInfo.Output
    if ($null -eq $winre) {
        Write-Warning 'REAgentC reports WinRE as Enabled, but no WinRE partition location could be parsed.'
        Write-Warning 'The script will not guess a partition. Do not run Execute until the WinRE state has been inspected.'
        Write-Host ''
        Write-Host 'No changes were made.' -ForegroundColor Yellow
        exit 2
    }

    if ($winre.DiskNumber -ne $osPartition.DiskNumber) {
        throw "WinRE is on disk $($winre.DiskNumber), but Windows is on disk $($osPartition.DiskNumber). Refusing to continue."
    }

    $recoveryPartition = Get-Partition `
        -DiskNumber $winre.DiskNumber `
        -PartitionNumber $winre.PartitionNumber
}
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

# A completed previous run may legitimately have almost no unallocated space
# after WinRE. Redo mode supports that state by deleting/recreating WinRE and
# resizing C: either upward or downward to leave the newly selected size.
$bitLockerPreflight = Get-BitLockerState -DriveLetter $osLetter
Write-BitLockerState -State $bitLockerPreflight -Prefix 'BitLocker preflight'

$requestedRecoveryBytes = [uint64]$RecoverySizeMB * $MiB

if ($interruptedRelayout) {
    $interruptedMinimumRecoveryBytes = Round-Up -Value ($interruptedWimSize + 200MB) -Multiple 1MB
    if ($requestedRecoveryBytes -lt $interruptedMinimumRecoveryBytes) {
        Write-Warning ("Selected Recovery size ({0} MB) is too small for the retained Winre.wim. Select at least approximately {1} MB." -f $RecoverySizeMB, [math]::Ceiling($interruptedMinimumRecoveryBytes / 1MB))
        Write-Host 'No changes were made.' -ForegroundColor Yellow
        exit 2
    }
}

# Before any WinRE or BitLocker state is changed, make sure the OS volume has
# enough room for both the temporary WinRE staging copy created by /disable and
# our independent rollback backup. The current Recovery partition size is used
# as a conservative upper bound for Winre.wim, plus 256 MB working headroom.
$backupSpaceReserve = [uint64](2 * $recoveryPartition.Size + 256MB)
$backupSpacePreflight = Assert-FreeSpace `
    -DriveLetter $osLetter `
    -RequiredBytes $backupSpaceReserve `
    -Purpose 'temporary WinRE staging plus rollback backup'

$estimatedDelta = [int64]$recoveryPartition.Size + [int64]$tailFree - [int64]$requestedRecoveryBytes
$projectedOSSize = [int64]$osPartition.Size + $estimatedDelta

$osSupportedBefore = Get-PartitionSupportedSize `
    -DiskNumber $osPartition.DiskNumber `
    -PartitionNumber $osPartition.PartitionNumber

if ($projectedOSSize -lt [int64]$osSupportedBefore.SizeMin) {
    throw ("The selected Recovery size would require shrinking Windows below its supported minimum. Projected C: size: {0}; minimum supported: {1}." -f `
        (Format-Bytes ([uint64]$projectedOSSize)), (Format-Bytes ([uint64]$osSupportedBefore.SizeMin))
    )
}

$cChangeText = if ($estimatedDelta -gt 0) {
    "Increase by $(Format-Bytes ([uint64]$estimatedDelta))"
} elseif ($estimatedDelta -lt 0) {
    "Decrease by $(Format-Bytes ([uint64](-$estimatedDelta)))"
} else {
    'No material size change'
}

$meaningfulTailFree = $tailFree -ge 64MB
$downsizingOnly = (-not $meaningfulTailFree) -and ($estimatedDelta -gt 0)
$lowGain = ($estimatedDelta -gt 0) -and ($estimatedDelta -lt 256MB)

$operationMode = if ($interruptedRelayout) {
    'Interrupted WinRE recovery - recreate Recovery partition at a compliant size'
} elseif ($meaningfulTailFree) {
    'Reclaim unallocated space and recreate WinRE'
} elseif ($downsizingOnly) {
    'WinRE downsizing only - no meaningful unallocated space'
} elseif ($estimatedDelta -eq 0) {
    'WinRE recreation only - no C: capacity gain'
} else {
    'WinRE resize requires C: to shrink'
}

Write-Host ''
[pscustomobject]@{
    Disk                  = $disk.Number
    'Disk size'           = Format-Bytes $disk.Size
    'Windows partition'   = "$osLetter`: (partition $($osPartition.PartitionNumber))"
    'Windows size now'    = Format-Bytes $osPartition.Size
    'WinRE partition'     = $recoveryPartition.PartitionNumber
    'WinRE size now'      = Format-Bytes $recoveryPartition.Size
    'Free after WinRE'    = Format-Bytes $tailFree
    'Selected new WinRE'   = Format-Bytes $requestedRecoveryBytes
    'Operation mode'       = $operationMode
    'WinRE source'         = if ($interruptedRelayout) { $interruptedWimPath } else { 'Active WinRE via REAgentC' }
    'Known Winre.wim size' = if ($interruptedRelayout) { Format-Bytes $interruptedWimSize } else { '(determined during Execute)' }
    'OS free space'        = Format-Bytes $backupSpacePreflight.FreeBytes
    'Backup space reserve' = Format-Bytes $backupSpacePreflight.RequiredBytes
    'Backup space check'   = 'OK'
    'Estimated C: change'  = $cChangeText
    'Projected C: size'    = Format-Bytes ([uint64]$projectedOSSize)
} | Format-List

if ($downsizingOnly) {
    Write-Warning 'There is no meaningful unallocated space after WinRE.'
    Write-Warning 'Any C: gain comes only from recreating WinRE smaller than it is now.'
    Write-Warning ("Expected C: gain from WinRE downsizing: {0}." -f (Format-Bytes ([uint64]$estimatedDelta)))
}

if ($lowGain) {
    Write-Warning ("The expected C: capacity gain is small ({0}). Consider whether recreating WinRE is worth the risk for this amount of space." -f (Format-Bytes ([uint64]$estimatedDelta)))
}

if ((-not $meaningfulTailFree) -and ($estimatedDelta -le 0)) {
    Write-Warning 'There is no unallocated space to reclaim and this selection does not increase C: capacity.'
}

if ($interruptedRelayout) {
    Write-Warning 'WinRE is currently disabled. This plan uses the retained Winre.wim backup to recreate the existing Recovery partition.'
    Write-Warning 'Because the current Recovery partition is undersized, this repair requires a partition-table change rather than option 3.'
}

$bitLockerBlocksExecute = ($bitLockerPreflight.Available -and $bitLockerPreflight.IsEncrypted -and ($bitLockerPreflight.KeyProtectorCount -eq 0))
if ($bitLockerBlocksExecute) {
    Write-Warning 'Execute is currently blocked because the encrypted OS volume has no configured BitLocker key protectors.'
    Write-Warning 'Inspect and restore an appropriate BitLocker protector before attempting the relayout.'
}

if (-not $Execute) {
    if ($interruptedRelayout) {
        Write-Host ''
        Write-Host 'DRY RUN ONLY - no changes were made.' -ForegroundColor Yellow
        Write-Host ''
        if ($bitLockerBlocksExecute) {
            Write-Host 'NEXT STEP:' -ForegroundColor Yellow
            Write-Host '  Repair/restore the BitLocker key-protector configuration first.'
            Write-Host '  Execute will refuse to modify partitions until BitLocker can be protected again.'
        }
        else {
            Write-Host 'NEXT STEPS:' -ForegroundColor Yellow
            Write-Host '  1. Review the interrupted-recovery relayout above.'
            Write-Host '  2. Run Execute with the same Recovery size.'
            Write-Host '  3. Type RELAYOUT when prompted.'
            Write-Host '  4. Reboot, then use option 3 until final confirmation passes.'
        }
        exit 0
    }

    Write-Host @'

DRY RUN ONLY - no changes were made.

REQUIRED NEXT STEPS:
  1. Restart Windows.
  2. Run Move-WinRE-And-Extend.bat again.
  3. Choose Execute.
  4. Select the desired Recovery partition size again.
  5. Type RELAYOUT when prompted.

AFTER EXECUTE COMPLETES:
  1. Restart Windows again.
  2. Run Move-WinRE-And-Extend.bat.
  3. Choose WinRE confirmation / recovery.
  4. Do not consider the operation complete until that option reports that
     the final disk layout and WinRE state are confirmed.
'@ -ForegroundColor Yellow
    exit 0
}

if ($bitLockerBlocksExecute) {
    Write-Warning 'Execute is blocked before confirmation because BitLocker has no configured key protectors.'
    Write-Host 'No changes were made.' -ForegroundColor Yellow
    exit 2
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

Write-Step 'Preparing BitLocker for the partition operation'
$bitLockerExecutionState = Set-BitLockerKnownOneRebootSuspension -DriveLetter $osLetter

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path "$osLetter`:\" "WinRE-Relayout-Backup-$timestamp"
$destructiveStarted = $false
$originalOSSize = [uint64]$osPartition.Size
$originalRecoveryOffset = [uint64]$recoveryPartition.Offset
$originalRecoverySize = [uint64]$recoveryPartition.Size
$rollbackBackupWimPath = Join-Path $backupDir 'Winre.wim'

try {
    Write-Step 'Creating a local WinRE backup directory'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $reAgentXml = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
    if (Test-Path -LiteralPath $reAgentXml) {
        Copy-Item -LiteralPath $reAgentXml -Destination (Join-Path $backupDir 'ReAgent.xml.before') -Force
    }

    if ($interruptedRelayout) {
        Write-Step 'Using the retained WinRE image from the interrupted relayout'
        $winreWim = $interruptedWimPath
        $winreWimItem = Get-Item -LiteralPath $winreWim -Force -ErrorAction Stop
    }
    else {
        Write-Step 'Disabling WinRE'
        Invoke-ReAgentC -Arguments @('/disable') | Out-Null

        $winreWim = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
        try {
            $winreWimItem = Get-Item -LiteralPath $winreWim -Force -ErrorAction Stop
        }
        catch {
            Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
            throw "WinRE was disabled, but $winreWim could not be accessed. The old recovery partition has NOT been deleted."
        }
    }

    $exactBackupRequired = [uint64]$winreWimItem.Length + 128MB
    try {
        $exactBackupSpace = Assert-FreeSpace `
            -DriveLetter $osLetter `
            -RequiredBytes $exactBackupRequired `
            -Purpose 'Winre.wim rollback backup'
    }
    catch {
        if (-not $interruptedRelayout) {
            Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
        }
        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Host ("Free space before backup: {0}" -f (Format-Bytes $exactBackupSpace.FreeBytes))
    Write-Host ("Backup copy requirement:   {0}" -f (Format-Bytes $exactBackupSpace.RequiredBytes))

    try {
        Copy-Item -LiteralPath $winreWim -Destination (Join-Path $backupDir 'Winre.wim') -Force -ErrorAction Stop

        $backupWimItem = Get-Item -LiteralPath (Join-Path $backupDir 'Winre.wim') -Force -ErrorAction Stop
        if ($backupWimItem.Length -ne $winreWimItem.Length) {
            throw 'Copied Winre.wim size does not match the source.'
        }
    }
    catch {
        $backupFailure = $_.Exception.Message
        if (-not $interruptedRelayout) {
            Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
        }
        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        throw ("Winre.wim backup copy/verification failed before any partition change: {0}" -f $backupFailure)
    }
    # Honor the explicitly selected final partition size. Require enough room
    # for Winre.wim plus a small operational margin, but do not silently enlarge
    # the partition beyond the user's choice. Also report when the more generous
    # 250 MB servicing headroom is not available.
    $wimSize = [uint64]$winreWimItem.Length
    $minimumOperationalBytes = Round-Up -Value ($wimSize + 200MB) -Multiple 1MB
    $recommendedServicingBytes = Round-Up -Value ($wimSize + 250MB) -Multiple 1MB
    $targetRecoveryBytes = $requestedRecoveryBytes

    if ($targetRecoveryBytes -lt $minimumOperationalBytes) {
        throw ("Selected Recovery size ({0} MB) is too small for this Windows 11 Winre.wim. At least approximately {1} MB is required to leave the minimum 200 MB free space." -f `
            $RecoverySizeMB, [math]::Ceiling($minimumOperationalBytes / 1MB))
    }

    Write-Host ("Winre.wim size:       {0}" -f (Format-Bytes $wimSize))
    Write-Host ("Selected WinRE size:  {0}" -f (Format-Bytes $targetRecoveryBytes))
    Write-Host ("Windows 11 minimum:   {0}" -f (Format-Bytes $minimumOperationalBytes))

    if ($targetRecoveryBytes -lt $recommendedServicingBytes) {
        Write-Warning ("Selected size leaves between 200 MB and 250 MB free above Winre.wim. It meets the Windows 11 minimum, but recommended servicing headroom is tighter.")
    }
    Write-Host ("Backup directory:     {0}" -f $backupDir)

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

    Write-Step 'Resizing the Windows partition while reserving the selected WinRE size'

    # Refresh the OS partition after deleting WinRE. SizeMax now reaches the end
    # of the usable disk. Subtract the exact requested Recovery size; this may
    # enlarge C: (initial layout) or shrink it slightly (redo with larger WinRE).
    $osPartition = Get-Partition -DriveLetter $osLetter
    $supported = Get-PartitionSupportedSize `
        -DiskNumber $osPartition.DiskNumber `
        -PartitionNumber $osPartition.PartitionNumber

    if ($supported.SizeMax -le $targetRecoveryBytes) {
        throw 'Unexpected disk geometry: supported Windows SizeMax is smaller than the WinRE reservation.'
    }

    # Align C: down to a MiB boundary. This guarantees at least the selected
    # Recovery size remains and may leave a sub-MiB alignment tail at disk end.
    $targetOSSize = [uint64](
        [math]::Floor(
            (($supported.SizeMax - $targetRecoveryBytes) / [double]$MiB)
        ) * $MiB
    )

    if ($targetOSSize -lt $supported.SizeMin) {
        throw ("Windows cannot be shrunk enough to reserve {0} MB for WinRE. Minimum supported C: size is {1}." -f `
            $RecoverySizeMB, (Format-Bytes ([uint64]$supported.SizeMin))
        )
    }

    $currentOSSize = [uint64]$osPartition.Size
    Write-Host ("Windows size before:  {0}" -f (Format-Bytes $currentOSSize))
    Write-Host ("Windows size target:  {0}" -f (Format-Bytes $targetOSSize))

    if ($targetOSSize -gt $currentOSSize) {
        Write-Host ("Increase:             {0}" -f (Format-Bytes ([uint64]($targetOSSize - $currentOSSize))))
    } elseif ($targetOSSize -lt $currentOSSize) {
        Write-Host ("Decrease:             {0}" -f (Format-Bytes ([uint64]($currentOSSize - $targetOSSize))))
    } else {
        Write-Host 'Change:               none'
    }

    if ($targetOSSize -ne $currentOSSize) {
        Resize-Partition `
            -DiskNumber $osPartition.DiskNumber `
            -PartitionNumber $osPartition.PartitionNumber `
            -Size $targetOSSize
    }

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
    $finalEnabledNow = $finalInfo.Output -match '(?im)Windows RE status:\s*Enabled'

    if ($finalEnabledNow -and $finalMatch.Success) {
        if (
            ([int]$finalMatch.Groups['disk'].Value -ne $disk.Number) -or
            ([int]$finalMatch.Groups['partition'].Value -ne $finalRecovery.PartitionNumber)
        ) {
            throw 'WinRE is enabled, but REAgentC points to an unexpected disk/partition.'
        }
        Write-Host 'WinRE is already enabled and registered in the current session.' -ForegroundColor Green
    }
    else {
        Write-Warning 'REAgentC /enable returned success, but the current session does not yet report WinRE as Enabled at the new partition.'
        Write-Warning 'This is PENDING POST-REBOOT VALIDATION, not a partition-operation failure.'
        Write-Warning 'After restarting, WinRE confirmation / recovery will verify the state and repair registration if necessary.'
    }

    Write-Host ''
    Write-Host 'RELAYOUT COMPLETED - REBOOT AND CONFIRMATION STILL REQUIRED' -ForegroundColor Green
    Write-Host ("Windows partition is now: {0}" -f (Format-Bytes $finalOS.Size))
    Write-Host ("WinRE partition is now:   {0} (partition {1})" -f `
        (Format-Bytes $finalRecovery.Size), $finalRecovery.PartitionNumber)
    Write-Host ("WinRE backup retained at: {0}" -f $backupDir)
    if ($bitLockerExecutionState.Available -and $bitLockerExecutionState.IsEncrypted) {
        Write-Host 'BitLocker:                suspended for one reboot'
    }
    Write-Host ''
    Write-Host 'REQUIRED NEXT STEPS:' -ForegroundColor Yellow
    Write-Host '  1. Restart Windows.'
    Write-Host '  2. Run Move-WinRE-And-Extend.bat.'
    Write-Host '  3. Choose WinRE confirmation / recovery.'
    Write-Host '  4. Do not delete the backup directory until that option reports:'
    Write-Host '     FINAL DISK / WINRE STATE CONFIRMED'
    Write-Host ''
}
catch {
    $originalFailure = $_

    Write-Host ''
    Write-Host 'ERROR' -ForegroundColor Red
    Write-Host $originalFailure.Exception.Message -ForegroundColor Red

    $rollbackSucceeded = $false

    if ($destructiveStarted) {
        Write-Warning 'A partition-table change has already occurred.'
        Write-Warning "Do NOT delete the backup directory: $backupDir"

        if (Test-Path -LiteralPath $rollbackBackupWimPath) {
            try {
                $rollbackResult = Invoke-WinRERollback `
                    -DiskNumber $disk.Number `
                    -OsLetter $osLetter `
                    -OriginalOSSize $originalOSSize `
                    -OriginalRecoveryOffset $originalRecoveryOffset `
                    -OriginalRecoverySize $originalRecoverySize `
                    -BackupWimPath $rollbackBackupWimPath

                $rollbackSucceeded = $rollbackResult.LayoutRestored
            }
            catch {
                Write-Host ''
                Write-Host 'AUTOMATIC ROLLBACK FAILED' -ForegroundColor Red
                Write-Warning $_.Exception.Message
                Write-Warning 'Do not make further partition changes until the disk layout has been inspected.'
            }
        }
        else {
            Write-Warning 'Automatic rollback could not start because the Winre.wim backup is missing.'
        }

        if ($bitLockerExecutionState.Available -and $bitLockerExecutionState.IsEncrypted) {
            Write-Warning 'BitLocker protection was suspended for the operation.'
        }

        Write-Host ''
        if ($rollbackSucceeded) {
            Write-Warning 'The relayout failed, but the script restored the original Windows and WinRE partition sizes.'
        } else {
            Write-Warning 'The relayout failed and automatic restoration could not be fully verified.'
        }
        Write-Warning 'Restart Windows, then run WinRE confirmation / recovery to finalize BitLocker and WinRE state.'
    }
    else {
        Write-Warning 'No partition-table change had occurred before the failure.'
        Write-Warning 'Attempting to leave WinRE enabled if Windows can do so...'
        try {
            Invoke-ReAgentC -Arguments @('/enable') -AllowFailure | Out-Null
        }
        catch {
        }
    }

    throw $originalFailure
}