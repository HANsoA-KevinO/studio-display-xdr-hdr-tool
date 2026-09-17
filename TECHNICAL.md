# Technical notes

## What changes

The tool writes one value to the selected NVIDIA display adapter's device software key:

```text
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\
{4d36e968-e325-11ce-bfc1-08002be10318}\<four-digit GPU key>

DISABLE_NATIVE_DISPLAYID2X_SUPPORT = 1 (REG_DWORD)
```

The four-digit key is discovered on each machine. The tool never assumes it is `0000` and refuses clearly non-present NVIDIA device keys. With multiple present NVIDIA GPUs, the user must select the GPU physically connected to Studio Display XDR.

No display firmware, EDID bytes, timing, DSC parameter, driver binary, INF, Windows HDR API state, service, or scheduled task is changed.

## Source evidence

NVIDIA's public open GPU kernel-module source defines the exact configuration name and maps it to `bDisableNativeDisplayId2xSupport`:

- Configuration definition and database field: https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/displayport/inc/dp_regkeydatabase.h
- Configuration database load and caching: https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/displayport/src/dp_evoadapter.cpp
- Connector policy and DisplayID/EDID paths: https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/displayport/src/dp_connectorimpl.cpp

Microsoft documents device software registry keys as a driver configuration location:

- https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/nf-wdm-ioopendeviceregistrykey

The public NVIDIA source establishes the name and intended control path. The Windows display driver remains proprietary; the Windows behavior is therefore also validated empirically by strict before/after capture rather than claimed solely from the Linux/open-kernel source.

## Controlled Windows evidence

Test system:

- Windows 11 25H2, build 26200.9457
- GeForce RTX 5090
- Studio Display XDR over an external DisplayPort path

Observed states:

| State | Identity | Active mode | HDR capability | Active color mode | Color space | Luminance |
|---|---|---|---|---|---|---|
| 591.86, no value | Studio XDR / APPAE42 | 5120×2880 120Hz | Supported | HDR | PQ / BT.2020 | 0–2000 nit |
| 616.92, no value | unknown / no ID | 5120×2880 120Hz | Not Supported | WCG | Gamma 2.2 / Rec.709 | 0.5–270 nit |
| 616.92, DWORD 1, full restart | Studio XDR / APPAE42 | 5120×2880 120Hz | Supported | HDR | PQ / BT.2020 | 0–2000 nit |

The resolution and refresh rate stayed at 5K120 while the live identity and HDR capabilities failed. Windows MonitorDataStore still retained `HDREnabled=1` for APPAE42 during the broken state. This separates the regression from insufficient link bandwidth and from a user-disabled HDR preference.

The result supports this working explanation: the newer driver can transport the 5K120 stream but mishandles the display's capability selection or merge through its Native DisplayID 2.x path. Disabling that path allows the traditional EDID description to supply the HDR identity and metadata again. NVIDIA and Apple have not confirmed the exact defect.

## Why a full restart is required

NVIDIA's display configuration is initialized and cached at driver startup. A cable reconnect or device restart may not rebuild all cached state. The tested transition became effective after a full Windows Restart.

## Restore model

Before applying, the tool records whether the value exists, its type, its data, the GPU identity, driver state, INF, and exact registry path. Restore proceeds only when:

- the selected GPU identity matches the backup;
- the exact registry path matches;
- the current value is DWORD 1;
- the backup belongs to this value and schema.

If the original value was absent, restore deletes only this value. If it was an existing DWORD, restore writes its original data. Other original registry types are never overwritten by Apply.

## Limits

This setting is per GPU, not per monitor. A display that advertises important capabilities only through Native DisplayID 2.x could lose those capabilities while the workaround is active. Test every display connected to the selected GPU. A future driver may fix the underlying defect, change the switch, or stop reading it.

