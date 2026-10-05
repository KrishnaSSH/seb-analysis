# Test-SebVirtualMachine.ps1

Checks if this pc looks like a vm, the same way Safe Exam Browser does it (`SafeExamBrowser.Monitoring/VirtualMachineDetector.cs`).

## Requirements

- Windows with PowerShell 5.1 or 7
- Run it as the normal user, not as admin. Check 5 reads the user registry.

## How to run

Open PowerShell in this folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-SebVirtualMachine.ps1
```

To also run the check from the SEB dll (check 7):

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-SebVirtualMachine.ps1 -SebPath "C:\Program Files\SafeExamBrowser\Application"
```

If Windows blocks the file, unblock it first:

```powershell
Unblock-File .\Test-SebVirtualMachine.ps1
```

## Checks

If any check says vm, the result is vm. SEB works the same way.

| # | Check | What it looks at |
|---|---|---|
| 1 | No system hardware | No memory, sensors, cache, fans or voltage probes in WMI |
| 2 | Virtual device | PnP device ids from VirtualBox, VMware, QEMU or Hyper-V |
| 3 | Virtual MAC | MAC starts with `525400` (QEMU), `080027` (VirtualBox) or is all zeros |
| 4 | Virtual CPU | CPU name has `kvm` in it |
| 5 | Registry | Cached make and model in `HKCU\...\TaskFlow\DeviceCache` |
| 6 | Virtual system | BIOS, manufacturer and model names |
| 7 | SEB dll | Check inside `seb_x64.dll`, only with `-SebPath` |

## Output

Each check prints `OK`, `VM` or `SKIPPED` and what it found. At the end you get:

- `Result: IS VM` with exit code 1
- `Result: IS NOT VM` with exit code 0

## Bugs copied from SEB

These are kept on purpose so the result is the same as SEB:

- The `Q35 +` check never matches because it compares against a lowercase string.
- If no network adapter has a DNS host name, the MAC becomes all zeros and counts as vm.
- If WMI fails in check 1, it counts as vm.
