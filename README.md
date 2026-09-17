# Studio Display XDR HDR Tool for Windows and NVIDIA

English | [简体中文](README.zh-CN.md)

A portable, dependency-free, reversible community workaround for a specific NVIDIA driver regression affecting Apple Studio Display XDR on Windows.

The affected state typically looks like this:

- 5120 × 2880 at 120 Hz still works;
- the display becomes `unknown` or Generic Non-PnP;
- Windows reports HDR as unsupported;
- the live color space falls back from PQ/BT.2020 to gamma 2.2/Rec.709.

The tool does not patch a driver, flash firmware, override EDID, or change display timings. It backs up and sets one NVIDIA per-GPU configuration value:

```text
DISABLE_NATIVE_DISPLAYID2X_SUPPORT = 1 (REG_DWORD)
```

This makes the driver bypass its Native DisplayID 2.x path and use the traditional EDID capability path. It is a community workaround, not an NVIDIA- or Apple-supported fix.

## Tested configuration

- Windows 11 25H2, build 26200.9457
- GeForce RTX 5090
- NVIDIA 616.92
- Studio Display XDR at 5120 × 2880, 120 Hz, HDR, ST 2084 PQ, BT.2020, 2000 nits

Other GPUs and drivers may work, but are not guaranteed. The physical connection must already support 5K120. This tool does not fix insufficient bandwidth, DSC, cable, adapter, Thunderbolt, or non-NVIDIA issues.

The setting applies to the selected GPU and may affect other displays connected to it. Verify HDR, refresh rate, VRR, audio, sleep/wake, and reconnect behavior on every display.

## Quick start

1. Extract the complete ZIP to a local folder. Do not run it inside the ZIP.
2. Double-click `01-Status.cmd` and review the detected NVIDIA GPU device keys.
3. Save your work and make sure you have a recovery path if the only display goes black.
4. Double-click `02-Apply.cmd` and accept the Windows UAC prompt.
5. If multiple NVIDIA device keys exist, select the GPU physically connected to Studio Display XDR.
6. Review the target and type uppercase `APPLY`.
7. The tool records the original state, writes DWORD 1, and reads it back for verification.
8. Choose Windows Restart. Do not substitute cable reconnect, GPU device restart, or shutdown followed by power-on.
9. Verify 5K120, Windows HDR, real HDR playback, and every other display.
10. Optionally run `04-Diagnose.cmd` to save structured evidence.

The tool never restarts automatically and creates no service, startup entry, scheduled task, or network connection.

## Restore

Double-click `03-Restore.cmd`, accept UAC, select the original GPU, and type uppercase `RESTORE`. The tool verifies the GPU identity, path, current DWORD 1, and machine-specific backup before restoring. If the original value was absent, it deletes only the value it added. It never imports or overwrites the whole NVIDIA device key. Restart Windows afterward.

If the value was already 1 before this copy of the tool was used, the tool will not fabricate an original-state backup. Restore with the backup created by the tool that originally applied the setting.

## Command line

```powershell
# Read-only status
.\XdrHdrTool.ps1 -Mode Status

# Save DxDiag and structured display diagnostics
.\XdrHdrTool.ps1 -Mode Diagnose

# Run these two from an elevated PowerShell; 0000 is only an example
.\XdrHdrTool.ps1 -Mode Apply -GpuKey 0000 -Confirm APPLY
.\XdrHdrTool.ps1 -Mode Restore -GpuKey 0000 -Confirm RESTORE
```

## Verify real HDR

Do not treat 10-bit output, vivid color, or a successful registry write as sufficient proof. Check that the display is 5120 × 2880 at 120 Hz, Windows HDR is enabled, live HDR capability is supported, Active Color Mode is HDR, the color space is PQ/BT.2020, the display identity is Studio XDR/APPAE42, known HDR content behaves correctly, and the result survives restart and sleep/wake.

## Safety and privacy

- A normal driver update may preserve the value; clean install, DDU, or device reinstall may remove it or change the numbered device key.
- When NVIDIA fixes the regression, restore the original state, restart, and test without the workaround.
- Raw `diagnostics/.../dxdiag.txt` can contain machine and device identifiers. Keep it private or redact it before sharing.
- Backups are machine- and GPU-specific. Never distribute them as generic restore files.
- If the screen goes black, use another display or Safe Mode to restore. Never delete the entire `0000`/`0001` key.

The PowerShell source is unsigned. The launchers use `ExecutionPolicy Bypass` only for their child PowerShell process and do not permanently change system policy. Review the readable source before running it.

See `TECHNICAL.md` for driver-source references, before/after evidence, and the working mechanism.

MIT licensed. Provided as-is, without NVIDIA or Apple endorsement.
