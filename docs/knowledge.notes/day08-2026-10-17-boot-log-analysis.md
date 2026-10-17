# Day8：RK3568 自编译系统完整上电启动日志分析

日期：2026-10-17
板卡：EmbedFire LubanCat 2，RK3568
串口：COM9，1500000-8-N-1，无硬件流控
启动介质：eMMC
日志：`logs/serial-COM9-20261017-142847.log`
原始字节：`logs/serial-COM9-20261017-142847.bin`（本地保留，默认不提交）

## 1. 验收结论

本次在串口持续监听状态下，对板卡执行了明确的断电再上电，完整捕获到：

```text
DDR 初始化
-> U-Boot SPL
-> BL31/ARM Trusted Firmware
-> U-Boot proper
-> extlinux 读取 kernel 配置
-> 加载 Image 和 DTB
-> Linux 4.19.232
-> eMMC 分区识别
-> ext4 rootfs 挂载
-> /sbin/init
-> systemd
-> lubancat login:
```

因此以下链路已在实板上验证：

- DDR/Loader 能初始化 2 GiB LPDDR4X
- SPL 能从 MMC 启动
- BL31 能接管并跳转到 U-Boot
- U-Boot 能识别 LubanCat 设备树和 eMMC
- U-Boot 能从 boot 分区加载 `Image-4.19.232`
- Linux 能识别 `mmcblk0` 和 `p1/p2/p3`
- Linux 能挂载 `/dev/mmcblk0p3` 为 ext4 根文件系统
- systemd 能作为 PID 1 启动
- 系统能到达串口登录提示

## 2. 启动阶段证据

### 2.1 DDR 与 SPL

日志中的 DDR 固件和内存训练信息：

```text
DDR 2d653b3476 typ 24/01/20-15:04:19,fwver: v1.21
LPDDR4X, 324MHz
Size=2048MB
change to: 1560MHz(final freq)
```

SPL 阶段：

```text
U-Boot SPL board init
U-Boot SPL 2017.09-g606f72bd97a-240527 #lxh (May 30 2024 - 16:08:15), fwver: v1.14
Trying to boot from MMC2
spl: mmc init failed with error: -123
Trying to boot from MMC1
```

解释：SPL 先尝试 MMC2，失败后回退到 MMC1，最终继续启动。这不是本次启动失败；后续需要结合板卡启动介质和存储映射进一步确认 MMC2/MMC1 的含义。

### 2.2 BL31 与 U-Boot proper

```text
Jumping to U-Boot(0x00a00000) via ARM Trusted Firmware(0x00040000)
INFO: Entry point address = 0xa00000

U-Boot 2017.09 (Oct 14 2026 - 23:36:40 -0700)
Model: Rockchip RK3568 Evaluation Board
DRAM: 2 GiB
Model: EmbedFire LubanCat
```

这里可以确认：

```text
SPL/loader -> BL31 -> U-Boot proper
```

`/proc/cmdline` 中同时带有：

```text
androidboot.fwver=ddr-v1.21-2d653b3476,spl-v1.14,bl31-v1.44,bl32-v2.12,uboot-10/14/2026
```

这与本次构建的 U-Boot 时间吻合，支持运行的是本次写入的新 U-Boot。loader 本身之前的 `UL` 命令失败，因此不能声称 loader 被重新刷写；本次只能确认已有 loader 链路可正常启动。

### 2.3 U-Boot 加载 boot 分区

```text
Found U-Boot script /boot.scr
SCRIPT FAILED: continuing...

1: kernel-4.19.232
Retrieving file: /Image-4.19.232
append: root=/dev/mmcblk0p3 earlyprintk console=ttyFIQ0 console=tty1 ... rootfstype=ext4
Starting kernel ...
```

说明：U-Boot 找到并执行了启动配置，随后加载 kernel。`SCRIPT FAILED: continuing...` 需要后续确认具体是 `boot.scr` 中某个可选命令失败，还是脚本返回值设计导致的提示；它没有阻止本次启动，不应直接当作 kernel 故障。

### 2.4 Linux 入口和命令行

```text
Linux version 4.19.232 (liu@ubuntu) ... #24 SMP Thu Oct 15 21:36:41 PDT 2026
aarch64
Machine model: EmbedFire LubanCat
```

内核命令行：

```text
root=PARTUUID=614e0000-0000
console=tty1
consoleblank=0
loglevel=7
rootwait
rw
rootfstype=ext4
earlycon=uart8250,mmio32,0xfe660000
```

这说明 U-Boot 已向 Linux 传递：

- 根文件系统由 PARTUUID 选择
- 根文件系统类型为 ext4
- 等待根设备出现
- 早期串口为 RK3568 调试 UART
- 启动日志级别为 7

### 2.5 存储和 rootfs

```text
mmc0: new HS200 MMC card at address 0001
mmcblk0: mmc0:0001 05S000 7.31 GiB
mmcblk0boot0: ... 4.00 MiB
mmcblk0boot1: ... 4.00 MiB
mmcblk0: p1 p2 p3
```

根文件系统挂载：

```text
EXT4-fs (mmcblk0p3): recovery complete
EXT4-fs (mmcblk0p3): mounted filesystem with ordered data mode
VFS: Mounted root (ext4 filesystem) on device 179:3.
```

这与板端验收结果一致：

```text
/dev/mmcblk0p3 -> /
```

### 2.6 PID 1 和登录

```text
Run /sbin/init as init process
systemd[1]: System time before build time, advancing clock.
EXT4-fs (mmcblk0p3): re-mounted.
Ubuntu 20.04 LTS GNU/Linux lubancat ttyFIQ0
lubancat login:
```

启动链的用户空间部分是：

```text
kernel_init
-> /sbin/init
-> systemd(PID 1)
-> ttyFIQ0 登录服务
-> lubancat login:
```

## 3. 日志中的告警分类

### 不阻塞本次启动

```text
spl: mmc init failed with error: -123
```

SPL 随后切换 MMC1 并继续启动。

```text
SCRIPT FAILED: continuing...
```

U-Boot 继续执行并成功加载 kernel，需要后续单独分析 boot.scr。

```text
systemd[1]: Failed to find module 'autofs4'
```

当前 rootfs 没有对应模块，但不影响根文件系统和 systemd 启动。kernel modules 已在后续步骤安装，仍需确认该模块是否由当前配置生成。

```text
platform regulatory.0: Direct firmware load for regulatory.db failed
```

无线 regulatory 数据库缺失；当前项目暂不做无线功能验收。

```text
configfs-gadget ... failed to start rockchip: -22
```

USB gadget 没有配置 function；当前项目暂不做 USB 功能验收。

### 需要记录但不是当前阻塞项

```text
dw-apb-uart ... probe of fe650000.serial failed with error -22
```

```text
rockchip-drm ... failed to show loader logo
```

```text
rk817-codec ... parse device tree property error -19
```

```text
mpp_rkvenc/mpp_rkvdec ... failed to find power_model node
```

这些告警没有阻止当前系统进入 rootfs 和登录。由于当前阶段重点是 BSP 启动链，暂不为它们盲目修改设备树。

## 4. 当前阶段判断

```text
Day8：核心实板启动验收已完成
Day9：自编译系统 baseline 已完成主体，模块已安装并验证
Day10：Kernel/DTB 独立替换、TF/eMMC 回退尚未完成
Day11-Day14：尚未完成
Camera：按计划后置，不在当前阶段 bring-up
```

当前准确定位：

> BSP Week2，Day9 后半段，Day8 启动日志证据已补齐，下一步进入 Day10 的独立替换和回退路径验证。

## 5. 下一步

1. 保留本次完整串口日志作为 Day8 证据。
2. 分析 `boot.scr` 的 `SCRIPT FAILED` 具体原因，但不先改动启动链。
3. 进入 Day10：确认 Kernel、DTB、rootfs 的独立替换关系，优先建立 TF/eMMC 回退路径。
4. 之后再做 Day11 的故障注入和恢复验证。
5. 完成 Day14 后形成 `bsp-v1.0`，再进入 PM、DRM，最后进入 Camera 阶段。
