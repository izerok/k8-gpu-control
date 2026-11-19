# K8 Tune — GPU 分档与散热联动控制

一个独立的 macOS 小工具，用于 **nullarc 780M** 黑苹果（测试机：KTHIN K8，Ryzen 7 H 255 / Radeon 780M `1002:1900`，macOS 26.6.2）。
提供**可视化档位调节**与**负载联动的自动降频**，用 GPU 频率上限来压低发热，让 BIOS/EC 把风扇降下来。

> 与 K8 装机仓库无耦合：本项目只依赖 nullarc 暴露的 `debug.phx_pm_*` 驱动 sysctl。

## 功能

- **六档 + 自定义**：静音 800 / 省电 1000 / 均衡 1200 / 性能 1600 / 满速 2600 MHz，滑杆可设 800–2600 任意值
- **实时状态**：当前 GFX 频率、驱动策略、频率上限、WindowServer CPU、系统负载
- **负载联动（可选）**：持续高负载 30 秒 → 每次降 200 MHz（下限 1200，避免"降频→更卡→继续降"）；持续空闲 60 秒 → 逐步回到所选档位上限
- **免密码**：GUI 只写状态文件，root 守护进程每 2 秒读取并应用 sysctl，无需每次输入管理员密码
- **开机持久**：守护进程 `RunAtLoad` + `KeepAlive`，重启后自动套用上次档位

## 关于"风扇管理"的边界

K8 的风扇由 **BIOS/EC 按固件温度控制**，macOS 侧没有 SMC 风扇键（`F0Ac`/`TC0P` 等均不存在），因此**无法直接设置转速或风扇曲线**。
本项目做的是**热管理**：限制 GPU 频率上限 → 降低 SoC 发热 → 固件自行降低风扇转速。这也是本机实测有效的路径
（`GFXCLK 2600 → 800` 后风扇明显下降）。

## 它改了什么

| sysctl | 含义 |
|---|---|
| `debug.phx_pm_mode` | `0` PMFW 默认 / `1` 驱动自动范围（本工具固定 1） |
| `debug.phx_pm_gfx_max` | GFX 频率上限，MHz（800–2600） |
| `debug.phx_pm_gfxclk` | 只读，当前 GFX 频率 |

`debug.*` 每次重启会重置，所以由守护进程在开机后重新应用。

## 构建

需要 Command Line Tools（无需 Xcode）：

```bash
cd app
./build.sh            # 产出 K8Tune.app（x86_64）
```

## 安装

在目标机（K8）上：

```bash
# 1) 安装特权守护进程
sudo daemon/install.sh

# 2) 安装 App（从构建机 scp 过来）
sudo ditto K8Tune.app /Applications/K8Tune.app
sudo chown -R root:wheel /Applications/K8Tune.app
sudo xattr -dr com.apple.quarantine /Applications/K8Tune.app

# 3) 打开
open -a /Applications/K8Tune.app
```

## 状态文件与日志

- 状态：`/Users/Shared/K8Tune/state.plist`（App 写、守护进程读）

  ```xml
  <dict>
      <key>profile</key><string>balanced</string>   <!-- silent/eco/balanced/performance/max/auto/custom -->
      <key>cap_mhz</key><integer>1200</integer>
      <key>auto</key><false/>
  </dict>
  ```

- 日志：`/var/log/k8tune.log`（每次档位变更一行）

## 已验证

- `debug.phx_pm_mode=1` + `debug.phx_pm_gfx_max=800` → `debug.phx_pm_gfxclk` 从 2600 即时降到 800
- 档位切换（max→performance→silent）在 2 秒内由守护进程应用
- 自动联动：高负载持续 30 秒后按 200 MHz 步进下降，静置 60 秒后回升

## 注意事项

- **不要用动态/航拍（Aerial）壁纸**：`NeptuneOneWallpaper` + `VTDecoderXPCService` 会持续解码视频，切换壁纸时接近卡死；请使用静态图片壁纸
- 频率下限设为 1200 是刻意的：800 MHz 下 WindowServer 合成会明显变卡
- 只适用于带 `debug.phx_pm_*` sysctl 的 nullarc 驱动（0.4.0+）
- 修改前建议记录默认值：`sysctl debug.phx_pm_mode debug.phx_pm_gfx_max`

## 许可

MIT

## 与其它开机脚本共存（重要）

如果机器上还有自定义的 `phxdisplay` 类守护进程（例如 nullarc 的显示/残影修复脚本），**不要让它在开机时写 `debug.phx_pm_*`**。
两个守护进程会在开机时互相覆盖频率上限，表现为"设置 1600 却被改回 800"。

正确分工：

```sh
# display / ghosting daemon: 只设置显示相关
sysctl -w debug.nvaccel_surface_gpu_on=0

# k8tuned: 独占 debug.phx_pm_mode / debug.phx_pm_gfx_max
```

本机已按此调整：`/usr/local/bin/phxdisplay.sh` 只保留 `surface_gpu_on=0`，频率由 `local.k8tune` 管理。
