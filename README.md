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
   - removes the temporary drive letter and applies the Microsoft Recovery GPT partition type and attributes;
   - only then re-enables WinRE;
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

The Recovery partition size is user-selectable from **870 MB to 1100 MB**, with **1024 MB** as the default. The selected value is used as the final partition size. During execution the script verifies that the selected size can physically hold the current `Winre.wim` plus a small operational margin. If it cannot, the script stops instead of silently creating a larger partition. If the selected size leaves less than 250 MB above the WIM, the script warns that future servicing headroom is tighter but still honors the selected size.

### `Move-WinRE-And-Extend.bat`

Convenience launcher for Windows users. It:

- locates the PowerShell script in the same directory;
- self-elevates to Administrator;
- launches PowerShell with `-ExecutionPolicy Bypass`;
- provides a menu for:
  - **Dry run**
  - **Execute**
  - **WinRE confirmation / recovery**
  - **Unblock PowerShell script**
  - **Exit**

The BAT launcher's Execute option intentionally does **not** pass `-Force`; the PowerShell script still requires the user to type `RELAYOUT`.

## Supported layout

This utility is deliberately narrow. It supports both the original blocked-space layout:

```text
... [ Windows partition ] [ active WinRE partition ] [ unallocated space ]
```

and re-running a completed layout:

```text
... [ Windows partition ] [ active WinRE partition ]
```

where the Windows and WinRE partitions are on the same GPT disk and WinRE is the last existing partition.

On a completed layout, choosing a smaller WinRE partition grows `C:` by the difference. Choosing a larger WinRE partition shrinks `C:` by the required amount, provided Windows reports that the requested shrink is supported. The existing WinRE partition is then recreated at the exact selected size.

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

Choose **Dry run** first. The launcher asks for a Recovery partition size between **870 and 1100 MB** (press Enter for 1024 MB). Nothing is modified.

Review the detected disk, partition numbers, current sizes, free space, selected Recovery size, and estimated `C:` change. For an already-completed layout, this may be a small increase or decrease depending on the new WinRE size.

The required workflow is:

1. Run **Dry run**.
2. If the proposed layout is correct, **restart Windows**.
3. Run `Move-WinRE-And-Extend.bat` again and choose **Execute**.
4. Select the desired Recovery size again and type:

   ```text
   RELAYOUT
   ```

5. When Execute completes successfully, **restart Windows again**.
6. Run `Move-WinRE-And-Extend.bat` again and choose **WinRE confirmation / recovery**.
7. The operation is considered complete only when the post-reboot check reports:

   ```text
   FINAL DISK / WINRE STATE CONFIRMED
   ```

Keep the generated WinRE backup directories until that final confirmation succeeds.

### WinRE confirmation / recovery

Use this mode after an interrupted or partially successful relayout when the Windows partition is already extended and an existing Microsoft Recovery GPT partition remains on the OS disk.

From the BAT launcher choose **WinRE confirmation / recovery**, or run:

```powershell
.\Move-WinRE-And-Extend.ps1 -WinRERecovery
```

The mode first checks the current WinRE status and validates the final disk state: WinRE must be enabled on the expected Recovery GPT partition, the partition must be NTFS, hidden, have no default drive letter, be immediately after the Windows partition, be the last partition on the disk, and be within the expected **870–1100 MB** size range. When all checks pass it reports **FINAL DISK / WINRE STATE CONFIRMED** and makes no changes.

If recovery is required, it displays the detected OS disk, Recovery partition, WinRE image source and sizes, then requires the user to type:

```text
RECOVER
```

before changing WinRE configuration.

This mode is deliberately non-destructive with respect to disk geometry. It does **not**:

- delete partitions;
- create partitions;
- shrink partitions;
- extend or resize partitions.

Recovery mode can:

- find the existing Microsoft Recovery GPT partition on the Windows disk;
- find `Winre.wim` in `C:\Windows\System32\Recovery` or the newest `C:\WinRE-Relayout-Backup-*\Winre.wim`;
- normalize the existing Recovery partition GUID/attributes and remove a temporary drive letter;
- stage a known-good `Winre.wim` in the Windows recovery staging directory;
- back up and clear stale `ReAgent.xml` / `ReAgent_Merged.xml` metadata;
- register the staged image;
- run `reagentc /enable`;
- verify that WinRE is enabled on the expected disk and partition;
- retain detailed REAgentC logs when recovery fails.

If more than one Microsoft Recovery partition exists, the mode stops instead of guessing which partition should be used.

### PowerShell directly

Open Windows PowerShell or Terminal **as Administrator**.

Dry-run:

```powershell
.\Move-WinRE-And-Extend.ps1
```

WinRE confirmation/recovery:

```powershell
.\Move-WinRE-And-Extend.ps1 -WinRERecovery
```

Execute with explicit confirmation:

```powershell
.\Move-WinRE-And-Extend.ps1 -Execute
```

Choose a different Recovery size, for example 1100 MB:

```powershell
.\Move-WinRE-And-Extend.ps1 -Execute -RecoverySizeMB 1100
```

Valid values are **870–1100 MB**. Values outside that range are rejected by PowerShell parameter validation.

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

## Windows PowerShell 5.1 compatibility

The PowerShell script intentionally uses ASCII-only source text for console-facing content. This avoids mojibake such as `â€”` when a GitHub-downloaded UTF-8 script without a BOM is executed by Windows PowerShell 5.1 through the BAT launcher.

## Design goal

The project is intentionally small and auditable. It uses Windows' built-in partitioning, Storage, BitLocker, and REAgentC tooling instead of bundling a third-party partition manager.

The objective is not to be a general-purpose partition editor. It is to safely automate one specific Windows 11 maintenance task:

> reclaim unallocated space blocked by the WinRE partition while leaving a valid WinRE partition at the end of the OS disk.
