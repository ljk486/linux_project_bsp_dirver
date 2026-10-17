# Day16：RK3568 实板自编译、OTG 烧录与启动验收

日期：2026-10-16

板卡：野火 LubanCat 2，RK3568
主机：Windows + Ubuntu VM `liu@192.168.189.134`
SDK：`/home/liu/linux_driver/project/vendor/sdk`
串口：CH340，最终枚举为 `COM8`
串口参数：`1500000-8-N-1`，无硬件流控

> 本日目标：完成 U-Boot、Linux kernel、rootfs 构建，经 OTG 烧录到 eMMC，并通过串口登录验证启动结果。
>
> 重要边界：用户原计划是使用 Buildroot 生成 rootfs；本次 SDK 中没有 `buildroot/` 目录，实际走的是 SDK 自带 Ubuntu-lite 路线。Buildroot rootfs 尚未完成，不能把本次 Ubuntu rootfs 写成 Buildroot 结果。

---

## 1. 板级配置

最初检查了：

```text
device/rockchip/rk356x/BoardConfig-LubanCat-RK3568-debian-lite.mk
```

该配置中：

```make
RK_UBOOT_DEFCONFIG=rk3568
RK_KERNEL_DEFCONFIG=lubancat2_defconfig
RK_KERNEL_DTS=rk356x-lubancat-generic
RK_CFG_BUILDROOT=
RK_ROOTFS_SYSTEM=debian
```

检查 SDK 顶层目录后发现：

```text
build.sh
u-boot/
kernel/
debian/
ubuntu/
rkbin/
tools/
rkflash.sh
```

没有 SDK 自带的 `buildroot/` 目录，且 debian/ubuntu 目录都有完整的 rootfs 构建脚本。因此本次切换到：

```bash
cd /home/liu/linux_driver/project/vendor/sdk
ln -rfs \
  device/rockchip/rk356x/BoardConfig-LubanCat-RK3568-ubuntu-lite.mk \
  device/rockchip/.BoardConfig.mk
```

最终使用的配置关键项：

```make
RK_UBOOT_DEFCONFIG=rk3568
RK_KERNEL_DEFCONFIG=lubancat2_defconfig
RK_KERNEL_DTS=rk356x-lubancat-generic
RK_PARAMETER=parameter-ubuntu-fit.txt
RK_PACKAGE_FILE=rk356x-package-file-ubuntu
RK_ROOTFS_SYSTEM=ubuntu
RK_ROOTFS_TARGET=lite
RK_ROOTFS_TYPE=ext4
RK_EXTBOOT=true
```

这一步决定了：U-Boot 和 kernel 使用 LubanCat2 的配置，boot 分区使用 extboot，rootfs 使用 Ubuntu-lite。

---

## 2. 编译 U-Boot

执行：

```bash
./build.sh uboot
```

第一次失败原因：SDK 的脚本检查 `python2`，但 VM 中只有 Python 3：

```text
ERROR: No python2
```

处理：

```bash
sudo apt-get install -y python2
sudo ln -sf /usr/bin/python2 /usr/local/bin/python
```

然后重新执行：

```bash
./build.sh uboot
```

U-Boot 编译成功，主要产物：

```text
u-boot/u-boot.bin
u-boot/u-boot-dtb.bin
u-boot/uboot.img
u-boot/rk356x_spl_loader_v1.21.114.bin
```

U-Boot 配置中确认：

```text
CONFIG_DEFAULT_DEVICE_TREE="rk3568-evb"
CONFIG_BAUDRATE=1500000
CONFIG_DEBUG_UART_BASE=0xFE660000
CONFIG_DEBUG_UART_CLOCK=24000000
CONFIG_DEBUG_UART_SHIFT=2
```

说明：

- `uboot.img` 是后续写入 eMMC 的 U-Boot 镜像。
- `rk356x_spl_loader_v1.21.114.bin` 是 Rockchip 下载工具使用的 loader，包含 DDR 初始化和下载阶段需要的代码。
- loader 与 U-Boot 镜像是两个不同概念，不能因为 `uboot.img` 写入成功就说 loader 也更新成功。

---

## 3. 编译 Linux kernel

执行：

```bash
./build.sh kernel
```

实际使用：

```text
Defconfig: lubancat2_defconfig
DTS:       rk356x-lubancat-generic
ARCH:      arm64
```

中间因为 `python` 命令不存在而失败，补充 Python 2 软链接后重新执行。最终日志：

```text
Running build_kernel succeeded.
```

核心产物：

```text
kernel/arch/arm64/boot/Image
kernel/arch/arm64/boot/dts/rockchip/rk356x-lubancat-generic.dtb
```

实际大小：

```text
Image：26071048 bytes，约 25 MiB
DTB：145785 bytes
```

---

## 4. 制作 kerneldeb 和 extboot

extboot 构建脚本会把 kernel、DTB、extlinux、uEnv 和 kerneldeb 放入 boot 分区，因此先执行：

```bash
./build.sh kerneldeb
```

成功生成：

```text
linux-headers-4.19.232_4.19.232-24_arm64.deb
linux-image-4.19.232_4.19.232-24_arm64.deb
linux-image-4.19.232-dbg_4.19.232-24_arm64.deb
linux-libc-dev_4.19.232-24_arm64.deb
```

然后执行：

```bash
export PATH=/home/liu/linux_driver/project/vendor/sdk/u-boot/tools:$PATH
./build.sh extboot
```

第一次执行遇到：

```text
/bin/sh: 1: mkimage: not found
```

处理：把 U-Boot 的工具目录加入 PATH：

```bash
export PATH=/home/liu/linux_driver/project/vendor/sdk/u-boot/tools:$PATH
```

随后又发现 extboot 脚本无条件复制 kerneldeb，所以先完成 `kerneldeb` 后再重跑 extboot。最终：

```text
Running build_extboot succeeded.
```

生成：

```text
kernel/extboot.img
```

大小：

```text
134217728 bytes，128 MiB
```

boot 镜像包含：

```text
Image-4.19.232
rk-kernel.dtb
dtb/
dtb/overlay/
extlinux/extlinux.conf
uEnv/
boot.scr
kerneldeb/
```

`extlinux.conf` 的关键内容：

```text
label kernel-4.19.232
    kernel /Image-4.19.232
    devicetreedir /
    append root=/dev/mmcblk0p3 earlyprintk console=ttyFIQ0 \
        console=tty1 consoleblank=0 loglevel=7 rootwait rw rootfstype=ext4
```

---

## 5. 构建 rootfs

### 5.1 Debian 路线的结果

最初尝试过：

```bash
./build.sh debian
```

该路线使用 `debian/ubuntu-build-service` 和 live-build。运行时出现 live-build 版本参数不兼容：

```text
lb config: unrecognized option '--debootstrap-options'
lb config: unrecognized option '--updates'
```

因此没有继续使用这条路线。

### 5.2 Ubuntu-lite 路线

实际执行：

```bash
cd /home/liu/linux_driver/project/vendor/sdk/ubuntu
TARGET=lite ARCH=arm64 SOC=rk356x ./mk-base-ubuntu.sh
TARGET=lite ARCH=arm64 SOC=rk356x RELEASE=20.04 ./mk-ubuntu-rootfs.sh
./mk-image.sh
```

构建过程：

1. 下载 Ubuntu 20.04 arm64 base tarball。
2. 解压到 `ubuntu/binary/`。
3. 拷贝 `qemu-aarch64-static`。
4. 使用 qemu 在 x86 VM 中执行 arm64 chroot。
5. 更新 apt 索引并安装大量 Ubuntu 软件包。
6. 安装 LubanCat 平台包、Mali、RGA、camera engine 等 SDK 包。
7. 拷贝 overlay、systemd、串口登录配置。
8. 清理 apt 缓存。
9. 通过 `mkfs.ext4 -d` 创建 ext4 镜像。

最终生成：

```text
ubuntu/ubuntu-lite-rootfs.img
```

大小约：

```text
1487929344 bytes，约 1.4 GiB
```

镜像内的 `/etc/os-release`：

```text
NAME="Ubuntu"
VERSION="20.04.6 LTS (Focal Fossa)"
ID=ubuntu
VERSION_ID="20.04"
```

因此本次实际烧入的是 Ubuntu 20.04.6 lite，不是 Buildroot rootfs。

---

## 6. 打包 rockdev

将各个镜像链接/准备到：

```text
/home/liu/linux_driver/project/vendor/sdk/rockdev/
```

执行：

```bash
./mkfirmware.sh
```

最终五个关键文件：

| 文件 | 大小 | 来源 | 作用 |
|---|---:|---|---|
| `MiniLoaderAll.bin` | 481728 bytes | `u-boot/rk356x_spl_loader_v1.21.114.bin` | Rockchip loader |
| `parameter.txt` | 348 bytes | `parameter-ubuntu-fit.txt` | GPT 分区表参数 |
| `uboot.img` | 8388608 bytes | `u-boot/uboot.img` | eMMC U-Boot |
| `boot.img` | 134217728 bytes | `kernel/extboot.img` | kernel、DTB、extlinux、uEnv |
| `rootfs.img` | 1487929344 bytes | `ubuntu/ubuntu-lite-rootfs.img` | Ubuntu ext4 根文件系统 |

分区参数核心内容：

```text
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00004000@0x00004000(uboot),0x00040000@0x00008000(boot:bootable),-@0x00048000(rootfs:grow)
```

含义：

```text
mmcblk0p1：uboot，约 8 MiB
mmcblk0p2：boot，约 128 MiB
mmcblk0p3：rootfs，占用剩余空间
```

对 boot.img 和 rootfs.img 执行只读文件系统检查：

```bash
e2fsck -fn rockdev/boot.img
e2fsck -fn rockdev/rootfs.img
```

两者都返回 0。

---

## 7. OTG 烧录过程

板子进入 Rockchip Loader 模式后，VM 识别到：

```text
Vid=0x2207
Pid=0x350a
Mode=Loader
```

### 7.1 loader 命令

第一次执行：

```bash
upgrade_tool ul -noreset rockdev/MiniLoaderAll.bin
```

返回：

```text
Loading loader failed,err=-1!
```

这个命令失败，不能记录为 loader 烧录成功。

upgrade_tool 内部帮助字符串显示正确格式为：

```text
UL <Loader> [-noreset] [FLASH|EMMC|SPINOR|SPINAND]
```

所以正确格式应该是：

```bash
sudo tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool/upgrade_tool \
    UL rockdev/MiniLoaderAll.bin -noreset
```

这条修正后的 UL 命令在本次流程中没有重新执行。当前只能确认 loader 升级失败，不能声称板上 loader 被更新。

### 7.2 GPT 和分区镜像写入

写入分区表：

```bash
sudo upgrade_tool di -p rockdev/parameter.txt
```

返回：

```text
Write gpt ok.
```

写 U-Boot：

```bash
sudo upgrade_tool di -uboot rockdev/uboot.img
```

返回：

```text
Download image ok.
```

写 boot：

```bash
sudo upgrade_tool di -b rockdev/boot.img
```

返回：

```text
Download image ok.
```

写 rootfs：

```bash
sudo upgrade_tool di -rootfs rockdev/rootfs.img
```

进度到 100%，返回：

```text
Download image ok.
```

最后复位：

```bash
sudo upgrade_tool rd
```

返回：

```text
Reset Device OK.
```

因此烧录结果应准确记录为：

```text
GPT       成功
uboot     成功
boot      成功
rootfs    成功
loader    本次 UL 命令失败，未确认更新
```

---

## 8. 串口无输出的排查过程

最初串口没有输出，经历了以下排查：

1. Windows 识别到 CH340。
2. 曾经使用 COM7，后来重新枚举为 COM8。
3. 回环测试验证了 CH340、USB 线、驱动和串口参数。
4. 1500000、8N1、无流控下，板端只收到过 `FC`、`FC FE` 等不可读字节。
5. 最终发现板子 TX/RX 接反。

正确接线：

```text
板子 TXD -> CH340 RXD
板子 RXD -> CH340 TXD
板子 GND -> CH340 GND
```

修正接线后，在 COM8、1500000-8-N-1 下收到：

```text
lubancat login:
```

结论：

> 本次串口无反应的直接原因是 TX/RX 物理接反，不是已经证实的 kernel/rootfs 故障，也不是波特率错误。

板上三个按键是：

```text
ON/OFF
REC
MASKROM
```

之前把不存在的 RESET 键作为指导，是错误的。普通启动应通过正常断电/上电完成，不应把 REC 或 MASKROM 当普通复位使用。

---

## 9. 板端登录验收

串口登录后执行：

```bash
uname -a
cat /etc/os-release
cat /proc/cmdline
findmnt /
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
```

登录欢迎信息：

```text
Welcome to Ubuntu 20.04.6 LTS (GNU/Linux 4.19.232 aarch64)
```

kernel：

```text
Linux lubancat 4.19.232 #24 SMP Thu Oct 15 21:36:41 PDT 2026 aarch64
```

rootfs：

```text
/      /dev/mmcblk0p3 ext4   rw,relatime
```

eMMC 分区：

```text
mmcblk0       7.3G
├─mmcblk0p1     8M
├─mmcblk0p2   128M ext2
└─mmcblk0p3   7.2G ext4   /
mmcblk0boot0   4M
mmcblk0boot1   4M
```

`/proc/cmdline` 中出现：

```text
root=PARTUUID=614e0000-0000
console=tty1
rootwait
rootfstype=ext4
androidboot.fwver=...uboot-10/14/2026
```

这些结果共同证明：

1. rootfs 已从 eMMC 的 `mmcblk0p3` 挂载。
2. 新 GPT 分区布局已生效。
3. 运行中的 Linux 是本次编译的 4.19.232 kernel。
4. 运行中的 rootfs 是本次构建的 Ubuntu 20.04.6。
5. boot 分区使用了本次制作的 128 MiB extboot 镜像。
6. 板子已经从 eMMC 启动了本次写入的系统，而不是继续运行原二手系统。

补充检查：

```text
/lib/modules 和 /usr/lib/modules 没有找到模块文件
```

这不影响当前系统启动，但后续需要检查 boot 分区中的 kerneldeb，并决定是否安装 kernel image/headers 或补充模块。

---

## 10. 整体流程图

```text
确认 BoardConfig
    ↓
编译 U-Boot
    ↓
编译 Linux Image + DTB
    ↓
生成 kerneldeb
    ↓
生成 extboot.img
    ↓
构建 Ubuntu arm64 rootfs
    ↓
生成 rootfs.img
    ↓
准备 parameter.txt
    ↓
mkfirmware.sh 生成 rockdev 五件套
    ↓
板子进入 Rockchip Loader
    ↓
upgrade_tool 写 GPT
    ↓
upgrade_tool 写 uboot.img
    ↓
upgrade_tool 写 boot.img
    ↓
upgrade_tool 写 rootfs.img
    ↓
upgrade_tool rd
    ↓
Debug UART 1500000-8-N-1
    ↓
修正 TX/RX 接线
    ↓
串口登录
    ↓
验证 kernel、rootfs、eMMC 分区
```

---

## 11. 本日暴露的问题

### 问题 1：用户要求 Buildroot，但实际切换成 Ubuntu

原因：SDK 没有 buildroot 目录，且当前 BoardConfig 的 rootfs 体系是 Debian/Ubuntu。后续需要单独引入可用的 Buildroot 工程或确认项目是否正式改为 Ubuntu rootfs。

### 问题 2：loader 命令失败

原因：第一次执行 UL 时参数顺序错误：

```bash
ul -noreset <loader>
```

正确格式：

```bash
UL <loader> -noreset
```

当前板子能够启动，说明现有 loader + 新 U-Boot 链路实际可用，不应仅因为旧命令失败就盲目刷写。若后续要更新 loader，必须重新进入 MaskROM/Loader 并单独验证 UL 返回结果。

### 问题 3：串口无输出

原因：TX/RX 接反。

修正后输出正常。这个问题说明硬件调试的第一步必须验证：

```text
串口设备枚举
→ 回环测试
→ TX/RX/GND 接线
→ 电平
→ 波特率
→ 再判断启动链
```

---

## 12. 产物与证据

构建和烧录记录：

```text
D:/linux_driver/project/reports/2026-10-16-first-flash-status.md
```

串口登录日志：

```text
D:/linux_driver/project/logs/serial-login-20261016-160501.log
```

板端验收日志：

```text
D:/linux_driver/project/logs/serial-verify-20261016-160547.log
```

镜像文件系统检查：

```text
D:/linux_driver/project/logs/image-check-20261016.txt
```

本日核心结论：

> 我们完成了从 SDK 板级配置、U-Boot 编译、Linux 编译、Ubuntu rootfs 构建、extboot 打包、OTG 写入 eMMC 到串口登录验收的完整最小闭环。当前板子已运行自编译 kernel 和自构建 rootfs；Buildroot rootfs 和 kernel 模块安装仍是后续工作。

---

## 13. 下一步

1. 核实 boot 分区中的 kerneldeb，处理 `/lib/modules` 缺失问题。
2. 通过 `modprobe`、V4L2、I2C、GPIO、网口、USB 做板端功能验收。
3. 决定是否补写 loader；当前系统已能启动，暂不盲刷。
4. 按原要求补齐 Buildroot rootfs 方案，或明确记录 Ubuntu rootfs 为项目基线。
5. 整理本次串口日志，进入 Week2 Day8/Day9 的实板启动链与 initcall/rootfs/VFS 分析。
