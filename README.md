# WinRE Fix Partition Extender

A small Windows 11 utility for a common partition-layout problem:

```text
[ EFI ] [ MSR ] [ Windows C: ] [ WinRE / Recovery ] [ Unallocated space ]
```

Windows Disk Management can only extend a partition into unallocated space that is immediately to its right. If the Windows Recovery Environment (WinRE) partition sits between `C:` and the free space, Disk Management cannot extend `C:`, and it cannot move the Recovery partition.

This project automates the safer Windows-native alternative: **recreate WinRE at the end of the disk, then extend the Windows partition into the newly contiguous space.**

## What it does

For the supported layout, the PowerShell script:

1. Detects the Windows OS partition and its physical disk.
2. Reads the active WinRE location from `reagentc /info`.
3. Verifies that:
   - the disk is GPT;
   - WinRE is on the same disk as Windows;
   - WinRE is immediately after the Windows partition;
   - WinRE is the last existing partition;
   - unallocated space exists after WinRE.
4. Checks BitLocker protection when the BitLocker PowerShell cmdlets are available.
5. Runs as a **dry-run by default** and shows the detected layout and estimated increase for `C:`.
6. When execution is explicitly requested:
   - disables WinRE;
   - verifies and backs up `Winre.wim`;
   - deletes the existing Recovery partition;
   - extends the Windows partition while reserving space for a new WinRE partition;
   - creates and formats a new Recovery partition at the end of the disk;
   - copies and registers `Winre.wim`;
   - applies the Microsoft Recovery GPT partition type and attributes;
   - re-enables WinRE;
   - verifies the final WinRE registration and partition type.

The intended transformation is:

```text
Before:
[ EFI ] [ MSR ] [       C:       ] [ WinRE ] [      Unallocated      ]

After:
[ EFI ] [ MSR ] [                 larger C:                 ] [ WinRE ]
```

No third-party partition-moving driver or boot environment is required.

## Files

### `Move-WinRE-And-Extend.ps1`

The main PowerShell implementation.

Safety characteristics:

- dry-run unless `-Execute` is supplied;
- does not assume Disk 0;
- GPT-only;
- refuses unsupported partition geometry rather than guessing;
- refuses to proceed when BitLocker protection is detected as enabled;
- backs up `Winre.wim` before deleting the old Recovery partition;
- requires an explicit `RELAYOUT` confirmation before destructive work unless `-Force` is deliberately supplied;
- verifies the recreated WinRE partition and REAgentC configuration afterward.

The default requested Recovery size is **1024 MB**. During execution the script checks the actual `Winre.wim` size and increases the reservation when necessary to preserve servicing headroom.

### `Move-WinRE-And-Extend.bat`

Convenience launcher for Windows users. It:

- locates the PowerShell script in the same directory;
- self-elevates to Administrator;
- launches PowerShell with `-ExecutionPolicy Bypass`;
- provides a menu for:
  - **Dry run**
  - **Execute**
  - **Unblock PowerShell script**
  - **Exit**

The BAT launcher's Execute option intentionally does **not** pass `-Force`; the PowerShell script still requires the user to type `RELAYOUT`.

## Supported layout

This utility is deliberately narrow. It is intended for:

```text
... [ Windows partition ] [ active WinRE partition ] [ unallocated space ]
```

where the Windows and WinRE partitions are on the same GPT disk and WinRE is the last existing partition.

## Not supported

The script intentionally stops rather than attempting to handle:

- MBR disks;
- dynamic disks;
- WinRE located on another disk;
- another partition between Windows and WinRE;
- an existing partition after WinRE;
- layouts with no meaningful unallocated space after WinRE.

Those cases need individual inspection.

## Usage

### Recommended: BAT launcher

Keep both files in the same folder and run:

```text
Move-WinRE-And-Extend.bat
```

Choose **Dry run** first. Nothing is modified.

Review the detected disk, partition numbers, current sizes, free space, requested Recovery size, and estimated `C:` increase.

If everything is correct, run the launcher again and choose **Execute**. The PowerShell script will run its checks again and require:

```text
RELAYOUT
```

before destructive changes begin.

### PowerShell directly

Open Windows PowerShell or Terminal **as Administrator**.

Dry-run:

```powershell
.\Move-WinRE-And-Extend.ps1
```

Execute with explicit confirmation:

```powershell
.\Move-WinRE-And-Extend.ps1 -Execute
```

Choose a different Recovery size, for example 1536 MB:

```powershell
.\Move-WinRE-And-Extend.ps1 -Execute -RecoverySizeMB 1536
```

An unattended mode exists:

```powershell
.\Move-WinRE-And-Extend.ps1 -Execute -Force
```

Use `-Force` only after validating the same machine/layout with a dry-run.

## BitLocker

If BitLocker protection is active on the Windows volume, the script stops rather than suspending it automatically.

A typical temporary suspension is:

```powershell
Suspend-BitLocker -MountPoint 'C:' -RebootCount 1
```

Then rerun the utility.

## Recovery backup

Before deleting the old Recovery partition, the script disables WinRE and verifies that Windows has made `Winre.wim` available.

It creates a timestamped backup directory on the Windows volume:

```text
C:\WinRE-Relayout-Backup-YYYYMMDD-HHMMSS
```

The directory contains a copy of `Winre.wim` and, when present, the pre-change `ReAgent.xml`.

Keep this backup until the machine has rebooted successfully and:

```cmd
reagentc /info
```

shows WinRE as enabled at the new Recovery partition.

## Important warning

This utility modifies the system disk partition table. A power failure, storage failure, unexpected disk layout, or software defect during a partitioning operation can make a machine unbootable or cause data loss.

**Have a current backup before using `-Execute`.**

The dry-run exists specifically so the detected geometry can be reviewed before any destructive action occurs.

## Design goal

The project is intentionally small and auditable. It uses Windows' built-in partitioning, Storage, BitLocker, and REAgentC tooling instead of bundling a third-party partition manager.

The objective is not to be a general-purpose partition editor. It is to safely automate one specific Windows 11 maintenance task:

> reclaim unallocated space blocked by the WinRE partition while leaving a valid WinRE partition at the end of the OS disk.
