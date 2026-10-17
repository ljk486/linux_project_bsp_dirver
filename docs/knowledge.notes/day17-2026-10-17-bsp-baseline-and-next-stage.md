# Day17：BSP baseline 收尾、完整启动日志与后续阶段边界

日期：2026-10-17
板卡：野火 LubanCat 2，RK3568
主机：Windows + Ubuntu VM `liu@192.168.189.134`
当前系统：Ubuntu 20.04.6，Linux 4.19.232
串口：COM9，1500000-8-N-1

> 本日是按实际工程进度记录的工作日编号。它不强行等同于 `BSP_PLAN.md` 中的理论 Day8 或 Day9；本日完成了自编译系统 baseline 收尾、内核模块安装、rootfs 扩容、只读外设枚举和完整断电上电日志采集。

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

详细记录：`logs/kernel-modules-20261017.txt`

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

详细记录：`logs/peripheral-smoke-20261017.txt`

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

## 3. 完整断电上电启动日志

### 3.1 采集信息

在串口持续监听状态下，对板卡执行了明确的断电再上电，完整日志保存为：

```text
logs/serial-COM9-20261017-142847.log
```

原始字节文件本地保留但按 `.gitignore` 排除：

```text
logs/serial-COM9-20261017-142847.bin
```

串口参数：

```text
COM9
1500000 baud
8N1
无硬件流控
```

### 3.2 验收结论

本次完整捕获到：

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

### 3.3 DDR 与 SPL

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

### 3.4 BL31 与 U-Boot proper

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

### 3.5 U-Boot 加载 boot 分区

```text
Found U-Boot script /boot.scr
SCRIPT FAILED: continuing...

1: kernel-4.19.232
Retrieving file: /Image-4.19.232
append: root=/dev/mmcblk0p3 earlyprintk console=ttyFIQ0 console=tty1 consoleblank=0 loglevel=7 rootwait rw rootfstype=ext4 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 switolb=1 coherent_pool=1m
Starting kernel ...
```

说明：U-Boot 找到并执行了启动配置，随后加载 kernel。`SCRIPT FAILED: continuing...` 需要后续确认具体是 `boot.scr` 中某个可选命令失败，还是脚本返回值设计导致的提示；它没有阻止本次启动，不应直接当作 kernel 故障。

### 3.6 Linux 入口和命令行

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

### 3.7 存储和 rootfs

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

### 3.8 PID 1 和登录

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

## 4. 日志中的告警分类

### 4.1 不阻塞本次启动

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

### 4.2 需要记录但不是当前阻塞项

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

## 5. 实际阶段定位

按计划与实际完成情况区分：

```text
计划 Day8：核心实板启动验收已完成
计划 Day9：自编译系统 baseline 已完成主体，模块已安装并验证
实际工作日：Day17，完成 BSP baseline 收尾与启动证据补齐
当前下一步：进入计划 Day10 的独立替换和回退路径验证
```

准确结论：

> 当前处于 BSP Week2 的 Day9 后半段收尾状态。Day8 的完整启动日志证据已补齐，下一步进入 Day10：验证 Kernel、DTB、rootfs 的独立替换关系，并建立 TF/eMMC 回退路径。

## 6. 后续工作顺序

### 6.1 计划 Day10

1. 分析 `boot.scr` 的 `SCRIPT FAILED` 具体原因，但不先修改启动链。
2. 确认 Kernel、DTB、rootfs 的独立替换关系。
3. 记录镜像大小、加载地址和启动命令。
4. 优先建立 TF/eMMC 回退路径。
5. 在保留回退路径的前提下验证单独替换 kernel 或 DTB。

### 6.2 计划 Day11-Day14

```text
Day11：错误 kernel/DTB/rootfs 参数与恢复路径
Day12：裁剪系统、中断和并发验证
Day13：启动性能、内存和裁剪对比
Day14：clean build、回退测试、整理 bsp-v1.0
```

只有 `bsp-v1.0` 通过后，才进入：

```text
低功耗 PM
-> DRM/KMS
-> V4L2 Camera
```

## 7. Camera 阶段边界

Camera bring-up 按计划后置，当前不做：

- 不修改 Camera sensor DTS
- 不启用 Camera overlay
- 不刷 Camera 专用 DTB/DTBO
- 不把当前没有 `/dev/video*` 直接记为 Camera 故障
- 不提前宣称 Camera 已移植

只有在 BSP、低功耗、DRM 完成且 Camera 型号确定后，才进入：

```text
sensor I2C probe
-> sensor subdev
-> MIPI CSI-2 / D-PHY
-> RKCIF / RKISP
-> Media Controller
-> V4L2 video node
-> vb2 buffer
-> 实际出帧
```

## 8. Git 记录

项目已初始化 Git，远端为：

```text
https://github.com/ljk486/linux_project_bsp_dirver.git
```

已推送的首个提交：

```text
4e76aa6 docs: record RK3568 BSP baseline and module validation
```

本日启动日志分析提交已在本地创建：

```text
d76f02a docs: analyze complete RK3568 boot log
```

该提交此前因当前网络无法连接 GitHub 443，暂未推送。网络恢复后执行：

```bash
git -C D:/linux_driver/project push origin main
```

提交规则：

- 后续笔记按实际工作日从 Day17 继续编号
- 新文件统一使用 `day18-YYYY-MM-DD-主题.md`、`day19-YYYY-MM-DD-主题.md` 格式
- 每个阶段使用 focused commit
- 提交命令、配置、日志、报告和学习笔记
- 不提交 SDK 压缩包、镜像、`.deb` 和串口原始二进制
- 硬件结论必须关联串口日志或板端命令输出
- 未实际完成的内容保持 `PENDING-HARDWARE` 或明确待办状态
