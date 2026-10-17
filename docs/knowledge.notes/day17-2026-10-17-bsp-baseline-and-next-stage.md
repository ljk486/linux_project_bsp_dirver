# Day17：BSP baseline 收尾与后续阶段边界

日期：2026-10-17
板卡：野火 LubanCat 2，RK3568
当前系统：Ubuntu 20.04.6，Linux 4.19.232
串口：COM9，1500000-8-N-1

## 1. 今日完成

### 1.1 kernel modules

通过 SSH 检查 VM 中的：

```text
/home/liu/linux_driver/project/vendor/sdk/linux-image-4.19.232_4.19.232-24_arm64.deb
```

确认：

- 包版本：4.19.232-24
- 架构：arm64
- 包内有 55 个 `.ko`
- 包内有 `modules.dep`、`modules.alias`、`modules.order` 等索引

通过 COM9 登录板端后确认安装前：

```text
uname -r = 4.19.232
linux-image-4.19.232 未安装
/lib/modules 不存在
```

从 boot 分区安装：

```bash
dpkg -i /mnt/boot/kerneldeb/linux-image-4.19.232_4.19.232-24_arm64.deb
depmod -a 4.19.232
```

安装后：

```text
Status: install ok installed
/lib/modules/4.19.232 存在
55 个 .ko
modinfo tun 成功
modprobe tun 成功
```

### 1.2 rootfs 扩容

安装 kernel image 后发现 rootfs 原始 ext4 文件系统只有约 1.3 GiB，而 `mmcblk0p3` 分区约 7.2 GiB，导致根分区 100% 满。

在线执行：

```bash
resize2fs /dev/mmcblk0p3
```

结果：

```text
/dev/root  7.1G  1.3G  5.5G  19% /
```

没有删除文件，也没有重新烧录镜像。

### 1.3 外设只读 smoke test

当前仅做枚举和日志检查，没有进行有风险的硬件写操作：

- `eth0` 驱动已 probe，支持 10/100/1000M，但未接网线，`Link detected: no`
- USB root hub 正常；没有插外部 USB 设备
- I2C：`/dev/i2c-0`、`/dev/i2c-6`
- GPIO：`gpiochip0` 到 `gpiochip5`
- DRM：`/dev/dri/card0`、`/dev/dri/renderD128`，HDMI 未连接
- V4L2：当前没有 `/dev/video*` 和 `/dev/media*`

本项目只涉及 Camera，因此网口、USB、HDMI 等功能验证暂时跳过，不把它们标记为项目阻塞项。

## 2. 按 BSP_PLAN.md 修正阶段边界

前一轮曾把 Camera bring-up 提前到当前步骤，这是计划顺序错误。

`BSP_PLAN.md` 的实际边界是：

```text
Day8-Day14：完成 BSP/Linux baseline 与 bsp-v1.0
第三周：低功耗 PM
第四周：DRM/KMS 与 HDMI
BSP、低功耗、DRM 完成且 Camera 型号确定后：进入 Linux 驱动与 V4L2 Camera 阶段
```

因此当前不做：

- 不修改 Camera sensor DTS
- 不启用 Camera overlay
- 不刷 Camera 专用 DTB/DTBO
- 不把当前没有 `/dev/video*` 直接记为故障
- 不提前宣称 Camera 已移植

当前只保留 Camera 所需配置已编译的事实：

```text
CONFIG_MEDIA_SUPPORT=y
CONFIG_MEDIA_CONTROLLER=y
CONFIG_VIDEO_V4L2=y
CONFIG_VIDEO_ROCKCHIP_CIF=y
CONFIG_VIDEO_ROCKCHIP_ISP=y
CONFIG_VIDEO_ROCKCHIP_ISP_VERSION_V21=y
CONFIG_PHY_ROCKCHIP_CSI2_DPHY=y
```

当前 kernel 配置中还启用了多个 sensor 驱动，例如 IMX415、OV5647、OV5648、OV8858 等，但这只说明编译配置存在，不能代替真实 Camera 硬件验证。

## 3. 下一阶段主线

接下来回到 BSP_PLAN.md 的 Day8-Day14：

1. Day8：从完整上电日志分析 BootROM/Loader/U-Boot/Linux/rootfs/PID1 链路，并落盘。
2. Day9：整理 `start_kernel()`、`rest_init()`、`kernel_init()`、initcall、rootfs、VFS 与当前系统的对应关系。
3. Day10：验证 TF/eMMC 回退和 Kernel/DTB 独立替换，记录地址、大小和启动命令。
4. Day11：设计并执行错误 kernel/DTB/rootfs 参数与恢复路径测试。
5. Day12-Day13：在不破坏 Camera 配置的前提下做裁剪、启动稳定性和资源对比。
6. Day14：clean build、回退测试、整理配置/patch/日志，形成 `bsp-v1.0`。

只有 `bsp-v1.0` 通过后，才进入第三周 PM 和第四周 DRM；Camera bring-up 按计划放到这些阶段完成后，并以具体 Camera 型号和硬件连接为前提。

## 4. Git 记录策略

项目目录已初始化 Git，远端目标为：

```text
https://github.com/ljk486/linux_project_bsp_dirver.git
```

提交规则：

- 每个里程碑一个 focused commit
- 提交命令、配置、日志、报告和学习笔记
- 不提交 SDK 压缩包、镜像、`.deb` 和串口原始二进制
- 硬件结论必须关联串口日志或板端命令输出
- 未实际完成的内容保持 `PENDING-HARDWARE` 或明确的待办状态
