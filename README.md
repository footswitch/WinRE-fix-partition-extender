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
- detects the OS volume's full BitLocker state (encryption status and protection status);
- when the OS volume is BitLocker-encrypted, establishes a known **one-reboot suspension** immediately before partition changes;
- if BitLocker was already suspended, briefly resumes it and then re-suspends with `-RebootCount 1` so the expected resume point is known;
- the post-reboot confirmation verifies BitLocker protection is back **On**; if it is still suspended, the confirmation mode attempts `Resume-BitLocker` and will not declare final success until protection is restored;
- preflights free space on the OS volume before changing WinRE or BitLocker state;
- conservatively reserves room for both the temporary `Winre.wim` staging copy created by `reagentc /disable` and the independent rollback backup;
- after WinRE is disabled and the actual `Winre.wim` size is known, performs a second exact free-space check before copying the rollback backup;
- verifies the copied `Winre.wim` file size matches the staged source before any Recovery partition is deleted;
- backs up `Winre.wim` before deleting the old Recovery partition;
- records the original Windows partition size, WinRE offset, and WinRE size before destructive work;
- if a relayout fails after WinRE has been deleted, attempts to restore the original Windows partition size and recreate WinRE at its original offset and original size from the backup;
- requires an explicit `RELAYOUT` confirmation before destructive work unless `-Force` is deliberately supplied;
- verifies the recreated WinRE partition and REAgentC configuration afterward.

The Recovery partition size is user-selectable from **870 MB to 1100 MB**, with **1024 MB** as the default. The selected value is used as the final partition size, but Windows 11 also requires the Recovery partition to leave at least **200 MB free** above the current `Winre.wim`. The script therefore rejects a selected size that cannot satisfy `Winre.wim size + 200 MB`; it never silently enlarges the partition. Microsoft recommends **250 MB free** for servicing, so a selection that leaves 200-249 MB free is accepted with a warning. For example, a 765 MB WIM requires a Recovery partition of approximately 965 MB or larger, so 870 MB is not sufficient for that image.

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

When there is no meaningful unallocated space after WinRE, the script explicitly identifies the operation as **WinRE downsizing only**. In that case all capacity gained by `C:` comes from making WinRE smaller. If the expected gain is below **256 MB**, the dry run and Execute preflight warn that the benefit is small relative to the risk of recreating the Recovery partition. If the selected size produces no `C:` gain, the script says so explicitly.

## Not supported

The script intentionally stops rather than attempting to handle:

- MBR disks;
- dynamic disks;
- WinRE located on another disk;
- another partition between Windows and WinRE;
- an existing partition after WinRE.

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

5. When Execute finishes the partition changes, **restart Windows again**. An immediate same-session `reagentc /info` may still report WinRE as Disabled even when `reagentc /enable` returned success; this is treated as pending post-reboot validation rather than a partition-operation failure.
6. Run `Move-WinRE-And-Extend.bat` again and choose **WinRE confirmation / recovery**.
7. The operation is considered complete only when the post-reboot check reports:

   ```text
   FINAL DISK / WINRE STATE CONFIRMED
   ```

Keep the generated WinRE backup directories until that final confirmation succeeds.

### Backup free-space preflight

The rollback backup is stored on the Windows volume, normally under:

```text
C:\WinRE-Relayout-Backup-YYYYMMDD-HHMMSS
```

Before any WinRE or BitLocker state is changed, the script performs a conservative capacity check on the OS volume. It reserves approximately:

```text
2 x current WinRE partition size + 256 MB
```

This covers both the temporary WinRE staging copy that `reagentc /disable` may place under `C:\Windows\System32\Recovery` and the separate rollback copy retained by this utility.

The dry run displays:

- current OS-volume free space;
- the conservative backup/staging reserve;
- whether the backup-space check passed.

After `reagentc /disable` exposes the actual `Winre.wim`, the script checks again using the real WIM size. Before copying the rollback backup it requires:

```text
actual Winre.wim size + 128 MB
```

of remaining free space. If that second check fails, the script attempts to re-enable WinRE, removes the incomplete backup directory, and stops before deleting or resizing any partition.

After copying the backup, the script also verifies that the backup file length matches the source WIM before destructive work begins.

### Automatic rollback after a failed relayout

Before deleting WinRE, Execute records:

- the original Windows partition size;
- the original WinRE partition offset;
- the original WinRE partition size;
- a backup copy of `Winre.wim`.

If an error occurs after the partition table has already been changed, the script attempts an automatic rollback. It removes any partially-created Recovery partition, restores the Windows partition to its original size, recreates WinRE at the original offset and original size, restores `Winre.wim`, reapplies the Recovery GPT attributes, and attempts to register/enable WinRE again.

A rollback is deliberately conservative. If the current layout no longer allows the original Windows size to be restored, if an unexpected partition exists after Windows, or if the WinRE backup is unavailable, rollback stops rather than guessing.

Even after a successful automatic rollback, restart Windows and run **WinRE confirmation / recovery**. The operation is not considered finalized until disk layout, WinRE, and BitLocker all pass the post-reboot confirmation.

### Interrupted-state detection

Dry run and Execute first check whether REAgentC currently reports WinRE as enabled. If WinRE is disabled, the script does not throw a raw location-parsing error and does not start another relayout.

Instead, it performs a non-destructive interrupted-state inspection of the Windows disk:

- counts Microsoft Recovery GPT partitions;
- reports whether a staged `Winre.wim` is present;
- reports whether a retained `WinRE-Relayout-Backup-*` image is available;
- when exactly one Recovery partition exists, checks whether it is immediately after `C:` and is the last partition on disk.

If that single Recovery candidate matches the expected final placement **and is large enough for the retained Winre.wim plus the Windows 11 minimum 200 MB free space**, the script directs the user to **WinRE confirmation / recovery** (option 3) and exits without making changes.

If the single Recovery candidate is correctly placed but too small for the retained Winre.wim, Dry run can instead evaluate an **interrupted WinRE recovery relayout**. That path reuses the retained Winre.wim backup and can recreate the existing Recovery partition at a compliant selected size. It still requires the same explicit `RELAYOUT` confirmation and rollback protections as normal Execute. If BitLocker is encrypted but has no configured key protectors, Execute is blocked before confirmation until the BitLocker protector configuration is repaired.

If there is no Recovery partition, more than one candidate, no usable Winre.wim source, or unexpected partition geometry, the script stops cleanly and does not attempt partition changes. Option 3 remains non-destructive and does not create or resize partitions.

Safety/precondition stops return exit code `2`. The BAT launcher treats that code generically as **recovery or safety attention required**, because it can represent an interrupted WinRE state, BitLocker readiness failure, or another precondition that deliberately blocks Execute before partition changes.

### WinRE confirmation / recovery

Use this mode after an interrupted or partially successful relayout when the Windows partition is already extended and an existing Microsoft Recovery GPT partition remains on the OS disk.

From the BAT launcher choose **WinRE confirmation / recovery**, or run:

```powershell
.\Move-WinRE-And-Extend.ps1 -WinRERecovery
```

The mode first checks the current WinRE status and validates the final disk state: WinRE must be enabled on the expected Recovery GPT partition, the partition must be NTFS, hidden, have no default drive letter, be immediately after the Windows partition, be the last partition on the disk, and be within the expected **870–1100 MB** size range. If the OS volume is BitLocker-encrypted, protection must also be **On**; if it is still suspended, the mode attempts to resume it. When all checks pass it reports **FINAL DISK / WINRE STATE CONFIRMED**.

Recovery metadata finalization now applies Microsoft's documented `0x8000000000000001` GPT attributes and also sets `NoDefaultDriveLetter=True` through the Windows Storage provider. Execute, recovery mode, and rollback then re-read the partition and fail if the Microsoft Recovery GPT type, no-current-drive-letter state, or `NoDefaultDriveLetter` invariant is missing. This closes a case where DiskPart returned success but the no-default-drive-letter state was not actually present.

If **the only** failed final-state check is `NoDefaultDriveLetter=False` while WinRE registration, filesystem, size, placement, hidden state, and BitLocker are already correct, option 3 uses a metadata-only `RECOVER` path. It normalizes and verifies the Recovery partition metadata without copying `Winre.wim`, clearing REAgentC metadata, or re-registering WinRE.

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
- temporarily mount the existing Recovery partition when needed;
- copy and verify a known-good `Winre.wim` directly under that Recovery partition's `Recovery\WindowsRE` directory;
- back up and clear stale `ReAgent.xml` / `ReAgent_Merged.xml` metadata;
- register the image directly from the Recovery partition rather than from the BitLocker-protected OS volume;
- remove the temporary access path and normalize the Recovery GPT GUID/attributes;
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

The script now distinguishes between **encryption state** and **protection state**. This matters because a BitLocker volume can remain fully encrypted while `ProtectionStatus` is `Off`, which means its key protectors are suspended rather than the volume being decrypted.

Dry run reports:

- volume status, such as `FullyEncrypted`;
- protection status, `On` or `Off`;
- lock status;
- encryption percentage;
- configured key-protector count and protector types when available.

If an encrypted OS volume has no configured key protectors, Execute refuses to modify partitions. Post-reboot confirmation also reports that condition explicitly instead of repeatedly attempting `Resume-BitLocker`.

Execute first verifies that an encrypted OS volume can be returned to protected state. If protection is currently `Off`, the script attempts `Resume-BitLocker` **before** it asks for `RELAYOUT`. If that resume fails, Execute reports **BITLOCKER READINESS FAILED**, returns exit code `2`, and stops before the confirmation and before any disk-layout change.

Only after BitLocker readiness passes and the user confirms `RELAYOUT` is the encrypted OS volume placed into a known one-reboot BitLocker suspension using:

```powershell
Suspend-BitLocker -MountPoint 'C:' -RebootCount 1
```

If protection was already suspended before Execute, the readiness phase resumes it and verifies that protection is `On`. If the user then confirms the operation, the script establishes the controlled one-reboot suspension. This avoids carrying an unknown or indefinite suspension forward from an earlier interrupted attempt; if the user cancels after readiness succeeds, BitLocker remains protected.

If BitLocker readiness fails, the script prints non-secret diagnostics: key-protector **types and IDs** plus TPM availability/readiness when `Get-Tpm` is available. It deliberately does not print the 48-digit recovery password.

When readiness fails in the specific recoverable state where the OS volume is encrypted and suspended, a **RecoveryPassword** protector is still present, no TPM-based protector exists, and the TPM is present/ready/enabled/activated/not locked out, interactive Execute may offer an explicit `ADDTPM` repair. That repair adds a TPM-only protector while retaining the RecoveryPassword protector, then retries `Resume-BitLocker`. If resume still fails, the script removes only the TPM protector created by that repair attempt. `-Force` never performs this protector-topology repair automatically. Windows policy remains authoritative: if TPM-only startup protection is not allowed, the protector add fails and Execute stops before `RELAYOUT`.

After the required restart, **WinRE confirmation / recovery** checks BitLocker again. If the OS volume remains encrypted but protection is still `Off`, it attempts `Resume-BitLocker`. Final confirmation does not pass while an encrypted OS volume remains suspended.

Microsoft documents that suspending BitLocker does not decrypt the volume; it temporarily makes the volume encryption key available, and `-RebootCount 1` schedules protection to resume after the next restart.

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
