# Studio Display XDR：Windows / NVIDIA HDR 修复工具

这是一个便携式、无安装依赖、可完整回退的社区工具，用于处理以下特定问题：

- Apple Studio Display XDR 连接到 Windows PC 的 NVIDIA 显卡；
- 5K 120Hz 已经能够正常输出；
- 较新的 NVIDIA 驱动却把显示器识别为 `unknown` 或通用非即插即用显示器；
- Windows 因此显示“不支持 HDR”，无法启用真正的 HDR。

本工具不会修改显示器固件、EDID、驱动文件、分辨率或显示时序。它只在用户选定的 NVIDIA GPU 设备配置键中设置一个 NVIDIA 驱动开关：

```text
名称：DISABLE_NATIVE_DISPLAYID2X_SUPPORT
类型：REG_DWORD
数值：1
```

这个开关使 NVIDIA 驱动绕过发生兼容性问题的原生 DisplayID 2.x 读取路径，回退到传统 EDID 能力描述。它是社区 workaround，不是 NVIDIA 或 Apple 官方修复。

## 适用范围

已在以下配置完成“修改前—修改后—恢复能力”的本机验证：

- Windows 11 25H2，Build 26200.9457
- NVIDIA GeForce RTX 5090
- NVIDIA 616.92
- 5120 × 2880 @ 120Hz
- HDR / ST 2084 PQ / BT.2020 / 2000 nit

它可能适用于其他 NVIDIA GPU 和驱动版本，但不能保证所有电脑、线材、扩展卡或连接拓扑都成功。它不解决以下问题：

- 线材或转接器本身无法传输 5K120；
- 显卡或连接方式不支持所需的 DSC/带宽；
- Apple Studio Display XDR 以外的显示器问题；
- 非 NVIDIA 显卡；
- macOS 或 Linux。

该设置按 GPU 生效，可能影响同一张显卡连接的其他显示器。修改后应检查所有显示器的 HDR、刷新率、VRR、音频和唤醒行为。

## 快速使用

1. 解压整个 ZIP 到本地文件夹。不要直接在 ZIP 内运行。
2. 双击 `01-Status.cmd`，确认工具识别到了正确的 NVIDIA GPU。
3. 保存正在进行的工作，并确保黑屏时有其他显示器、远程访问或安全模式恢复手段。
4. 双击 `02-Apply.cmd`，接受 Windows UAC 管理员提示。
5. 如果有多张 NVIDIA GPU，选择物理连接 Studio Display XDR 的那一张。
6. 核对路径后输入大写 `APPLY`。
7. 工具会先备份原始值，再写入 DWORD 1，并读取验证。
8. 使用 Windows 的“重新启动”。不要用拔插线材、重启显卡设备或关机后再开机代替。
9. 重启后检查 Windows HDR、5K120、实际 HDR 视频/游戏，以及其他显示器。
10. 可双击 `04-Diagnose.cmd` 保存一份诊断结果。

脚本不会自动重启，也不会安装常驻服务、计划任务、启动项或联网下载任何内容。

## 一键恢复

只有使用本工具成功应用后，它才会为对应 GPU 创建 `backups\active-XXXX.json`。恢复时：

1. 双击 `03-Restore.cmd`；
2. 接受 UAC；
3. 选择原来修改的 GPU；
4. 输入大写 `RESTORE`；
5. 工具核对 GPU 身份、注册表路径、当前值和备份；
6. 如果原始值不存在，只删除本工具添加的那个值；如果原来已有 DWORD，则恢复原值；
7. 完整重新启动 Windows。

工具不会导入或覆盖整个 NVIDIA 注册表设备键。已恢复的备份会移到 `backups\restored` 留作审计。

如果工具发现该值已经是 1，但当前这份工具没有对应备份，它不会伪造“原始状态”，也不会声称能够自动恢复。请使用最初应用修改时生成的备份。

## 命令行

只读状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\XdrHdrTool.ps1 -Mode Status
```

导出 DxDiag 和结构化诊断：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\XdrHdrTool.ps1 -Mode Diagnose
```

管理员 PowerShell 中应用到指定 GPU 键：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\XdrHdrTool.ps1 -Mode Apply -GpuKey 0000 -Confirm APPLY
```

管理员 PowerShell 中恢复：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\XdrHdrTool.ps1 -Mode Restore -GpuKey 0000 -Confirm RESTORE
```

`0000` 仅为示例。必须以 `Status` 在目标电脑上显示的实际键号为准。

## 如何确认真的恢复了 HDR

不要仅以“10 位输出”、颜色变鲜艳或注册表写入成功作为判断依据。至少检查：

- 当前模式是 5120 × 2880 @ 120Hz；
- Windows 显示设置提供并启用了 HDR；
- 诊断显示 `HDR Support: Supported`；
- `Active Color Mode` 是 HDR；
- 色彩空间是 PQ / BT.2020，而不是 Gamma 2.2 / Rec.709；
- 显示器重新识别为 `Studio XDR / APPAE42`；
- 播放已知 HDR 内容时高光与局部调光正常；
- 重启、睡眠唤醒和重新连接后仍然有效。

## 驱动更新与安全提醒

- 普通驱动升级可能保留此值；清洁安装、DDU 或设备重装可能删除它或更换四位键号。
- 每次驱动更新后先运行 `01-Status.cmd`，再检查实际显示状态。
- NVIDIA 正式修复后，应先使用本工具恢复原始状态，重启，然后测试是否仍然正常。
- `diagnostics\...\dxdiag.txt` 可能包含机器名和设备标识，只应私下保存或脱敏后分享。
- 备份与具体电脑和 GPU 身份绑定，不要把自己的备份当成通用恢复文件发给别人。
- 如果屏幕黑屏，优先使用另一台显示器或安全模式运行恢复；不要删除整个 `0000`/`0001` 设备键。

PowerShell 脚本未进行商业代码签名。CMD 启动器只为当前 PowerShell 进程使用 `ExecutionPolicy Bypass`，不会永久修改系统执行策略。源代码完全可读，建议在运行前自行检查。

驱动开关的源码依据、故障前后证据和工作机制见 `TECHNICAL.md`。

## 文件说明

- `01-Status.cmd`：只读查看 GPU、驱动与当前开关状态
- `02-Apply.cmd`：UAC 提权、备份、应用和验证
- `03-Restore.cmd`：依据本机备份恢复并验证
- `04-Diagnose.cmd`：保存 DxDiag 与结构化显示状态
- `XdrHdrTool.ps1`：完整可读源代码
- `TECHNICAL.md`：修改原理、源码依据和实测证据
- `backups`：首次应用后自动创建，不应公开分享
- `diagnostics`：运行诊断后自动创建，原始 DxDiag 应保密

## 许可证与免责声明

代码采用 MIT License。该工具按原样提供，使用者自行承担风险。它属于未获 NVIDIA 或 Apple 背书的社区兼容性处理方案。
