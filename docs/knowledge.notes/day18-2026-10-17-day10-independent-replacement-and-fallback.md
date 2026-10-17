# Day18：Day10 独立替换关系、U-Boot 脚本与回退边界

日期：2026-10-17
板卡：野火 LubanCat 2，RK3568
主机：Windows + Ubuntu VM `liu@192.168.189.134`
当前系统：Ubuntu 20.04.6，Linux 4.19.232
串口：COM9，1500000-8-N-1

> 本日对应 `BSP_PLAN.md` 的计划 Day10。实际完成了启动脚本源码审计、完整串口日志对照、Kernel/DTB/rootfs 独立关系分析和内存地址计算。TF 卡/TFTP 回退与在回退介质上的替换启动仍未完成，保留为 `PENDING-HARDWARE`，没有覆盖当前可启动 eMMC。

## 1. 今日主结论

1. `SCRIPT FAILED: continuing...` 不是本次启动失败的证据。它来自 U-Boot `scan_dev_for_scripts` 的固定提示：脚本执行返回后无条件打印该字符串；随后 `scan_dev_for_extlinux` 继续读取 `extlinux/extlinux.conf`。
2. 完整串口日志证明 U-Boot 在 eMMC boot 分区中成功找到并读取 `boot.scr`、`Image-4.19.232` 和 `rk-kernel.dtb`，然后 Linux 成功启动到 systemd 和登录提示。
3. 当前启动路径中 Kernel、DTB 和 rootfs 由不同对象控制：
   - Kernel：boot 分区 `/Image-4.19.232`；
   - DTB：boot 分区 `/rk-kernel.dtb`；
   - rootfs：Kernel command line 中的 `/dev/mmcblk0p3`，对应 eMMC rootfs 分区。
4. 构建脚本明确把 `Image`、DTB、`boot.scr`、extlinux 配置和 kerneldeb 放入 128 MiB `extboot.img`；rootfs 则来自独立的 Ubuntu ext4 镜像。
5. 当前没有 TF/TFTP 回退的硬件证据，因此本日不执行 eMMC 上的独立替换、不刷写错误镜像、不盲目更新 loader。

## 2. 已读取的工程配置

当前 BoardConfig 符号链接：

```text
device/rockchip/.BoardConfig.mk
 -> device/rockchip/rk356x/BoardConfig-LubanCat-RK3568-ubuntu-lite.mk
```

关键值：

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

本日确认 `RK_PACKAGE_FILE` 是构建流程使用的包文件名；当前 SDK 的实际工作目录中没有找到同名的普通文件，不能把它写成已单独核验的 package-file 内容。已经核验并实际使用的分区参数文件是：

```text
device/rockchip/rk356x/parameter-ubuntu-fit.txt
```

其核心内容：

```text
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00004000@0x00004000(uboot),0x00040000@0x00008000(boot:bootable),-@0x00048000(rootfs:grow)
uuid:rootfs=614e0000-0000-4b53-8000-1d28000054a9
```

换算为分区关系：

```text
p1 uboot：0x4000 sectors，约 8 MiB
p2 boot：0x40000 sectors，约 128 MiB
p3 rootfs：从 0x48000 sectors 开始，占剩余空间
```

## 3. `SCRIPT FAILED` 的源码定位

U-Boot 源码：

```text
u-boot/include/config_distro_bootcmd.h
```

相关逻辑：

```c
"scan_dev_for_scripts="
    "for script in ${boot_scripts}; do "
        "if test -e ${devtype} "
                "${devnum}:${distro_bootpart} "
                "${prefix}${script}; then "
            "echo Found U-Boot script "
                "${prefix}${script}; "
            "run boot_a_script; "
            "echo SCRIPT FAILED: continuing...; "
        "fi; "
    "done\0"
```

`scan_dev_for_extlinux` 也有同样的固定提示：执行 `boot_extlinux` 后无条件打印 `SCRIPT FAILED: continuing...`。

因此这条字符串的准确含义不是“已经证明脚本失败”，而是“该扫描分支返回后继续尝试其他启动入口”。本次日志中它后面紧接着出现：

```text
Found /extlinux/extlinux.conf
Retrieving file: /extlinux/extlinux.conf
...
Retrieving file: /Image-4.19.232
...
Retrieving file: /rk-kernel.dtb
...
Starting kernel ...
```

所以本次硬件结论是：U-Boot 启动扫描继续执行并成功进入 Linux；不是 kernel 加载失败。

## 4. `boot.scr` 和 extlinux 的关系

`kernel/extboot/boot.scr` 是由：

```text
kernel/extboot/boot.cmd
```

通过：

```bash
mkimage -T script -C none -d boot.cmd boot.scr
```

生成的 U-Boot 脚本。

脚本先尝试：

```text
/uEnv/uEnv.txt
/initrd
/initrd-${uname_r}
/Image
/Image-${uname_r}
/rk-kernel.dtb
```

然后执行 I2C 检查、可选屏幕 EEPROM/overlay 处理，并尝试 `booti`。如果该脚本分支没有最终停留在 Linux，U-Boot 的 distro boot 会继续扫描 extlinux。

本次启动日志中的实际顺序是：

```text
Scanning mmc 0:2...
Found U-Boot script /boot.scr
3958 bytes read in 23 ms
## Executing script at 00c00000
SCRIPT FAILED: continuing...
Found /extlinux/extlinux.conf
...
Starting kernel ...
```

这里的 `0x00c00000` 是 `scriptaddr`。

## 5. 加载地址与大小

U-Boot RK3568 默认环境布局来自：

```text
u-boot/include/configs/rk3568_common.h
```

关键值：

```text
scriptaddr    = 0x00c00000
pxefile_addr_r= 0x00e00000
fdt_over_addr = 0x0a000000
env_addr_r    = 0x0a080000
fdt_addr_r    = 0x0a100000
kernel_addr_r = 0x00280000
ramdisk_addr_r= 0x0a200000
```

本次构建文件：

```text
Image-4.19.232：26071048 bytes
rk-kernel.dtb：145785 bytes
boot.scr：3958 bytes
extlinux/extlinux.conf：286 bytes
extboot.img：134217728 bytes，128 MiB
uboot.img：8388608 bytes，8 MiB
rootfs.img：1487929344 bytes，约 1.4 GiB（构建时原始大小）
```

按实际加载地址计算：

```text
Kernel 起始：0x00280000
Kernel 结束：0x01b5d008
DTB 起始：   0x0a100000
DTB 结束：   0x0a123979
```

串口日志进一步确认：

```text
26071048 bytes read in 806 ms
145785 bytes read in 8 ms
## Flattened Device Tree blob at 0x0a100000
Booting using the fdt blob at 0x0a100000
```

注意：extlinux 实际执行时 U-Boot 负责读取文件并选择地址；`extlinux.conf` 本身只声明 Kernel 文件路径、DTB 根目录和 rootfs 参数，不直接写死上述内存地址。

## 6. 独立替换矩阵

### 6.1 只替换 Kernel

变更对象：

```text
boot 分区中的 /Image-4.19.232
```

保持不变：

```text
/rk-kernel.dtb
rootfs 分区 /dev/mmcblk0p3
U-Boot、loader、GPT
```

验证重点：

```text
Linux version
编译编号/#号
uname -r
启动是否到 systemd/login
```

推荐方式：先在 TF boot 分区或 TFTP/RAM 中加载新 Image，使用原 eMMC rootfs；未建立回退前不覆盖 eMMC p2。

### 6.2 只替换 DTB

变更对象：

```text
boot 分区中的 /rk-kernel.dtb
```

保持不变：

```text
/Image-4.19.232
/dev/mmcblk0p3
U-Boot、loader、GPT
```

验证重点：

```text
Machine model
设备树启用/禁用节点对应的 probe 日志
串口、eMMC、rootfs 是否仍能启动
```

不要把 DTB 目录中的任意型号文件直接写入 `rk-kernel.dtb`。当前运行基线是 `rk356x-lubancat-generic.dtb`，必须先确认候选 DTB 的板级兼容性。

### 6.3 只替换 rootfs

变更对象：

```text
eMMC p3 或 TF 对应 rootfs 分区
```

保持不变：

```text
boot 分区、Image、DTB、U-Boot、loader、GPT
```

验证重点：

```text
root=...
VFS: Mounted root
Run /sbin/init
systemd[1]
登录提示
```

注意 rootfs 镜像的 ext4 文件系统大小和目标分区大小必须匹配；本项目曾通过板端 `resize2fs /dev/mmcblk0p3` 扩大文件系统，不能把“镜像能通过 e2fsck”误认为“已经安装到板端并启动”。

## 7. 回退策略

当前已证实：

```text
eMMC p1/p2/p3 启动成功
```

当前未证实：

```text
TF 卡能被 SPL/U-Boot 识别
TF 卡能加载 boot.scr/extlinux
TFTP 网络启动可用
U-Boot 环境持久化 bootcount/recovery 已配置
```

因此本日不执行：

```text
upgrade_tool di -b ...
upgrade_tool di -rootfs ...
修改 eMMC p2 中的 boot.img
修改 eMMC p3 中的 rootfs
补刷 loader
```

下一次硬件实验必须先满足：

1. 插入可用 TF 卡或准备可用 TFTP 网络。
2. 串口能在上电时捕获 U-Boot。
3. 在 U-Boot 中只读执行 `mmc list`、`mmc dev`、`part list mmc <n>`、`ls mmc <n>:1`/`ls mmc <n>:2`，确认介质和分区。
4. 先从 TF/TFTP 加载原始基线 Kernel、DTB，rootfs 仍使用 eMMC p3。
5. 基线启动成功后，才替换一个组件并记录启动日志。
6. 失败时断电，移除 TF/TFTP 介质，恢复从 eMMC 启动。

## 8. 本日学习要点

### 8.1 为什么 Kernel、DTB、rootfs 可以独立替换

三者在启动链中承担不同职责：

```text
Kernel：执行代码和内核内建配置
DTB：描述硬件资源、地址、中断、时钟、设备状态
rootfs：Linux 启动后的用户空间文件系统和 PID 1
```

Kernel 通过启动参数获得 rootfs 位置；DTB 由 U-Boot 传给 Kernel；rootfs 不包含 Kernel 的执行映像。因此只要接口保持兼容，就可以分别替换并分别验证。

### 8.2 物理地址、加载地址和虚拟地址不能混淆

本次 `0x00280000`、`0x0a100000` 是 U-Boot 将文件放入 DRAM 的加载地址；Linux 进入后会建立页表并使用虚拟地址访问内核映射。驱动不能因为看到一个设备物理地址就直接当作普通 C 指针解引用；设备寄存器要经过 `ioremap`，DMA 还要考虑设备可见的总线地址、缓存一致性和 CMA/预留内存。

### 8.3 Camera 为什么会关心 CMA

Camera 一帧 buffer 通常较大，且需要 DMA 连续或满足特定对齐/地址约束；V4L2 vb2、RKCIF、RKISP 和后续 DRM/DMA-BUF 可能共享这些 buffer。CMA 提供在启动时预留、运行时分配大块连续页的机制，但是否真正需要、大小多少，必须由分辨率、像素格式、buffer 数和硬件 DMA 约束计算并实测，不能只看到 Camera 配置就随意增大。

## 9. 已完成、未完成与证据

已完成：

```text
[已编译] extboot、Image、DTB、U-Boot
[已打包] 128 MiB boot 镜像和 Ubuntu rootfs 镜像
[已上板] eMMC GPT、U-Boot、boot、rootfs
[已测试] 完整断电上电到登录
[已分析] boot.scr、distro boot、extlinux、加载地址
```

证据：

```text
logs/serial-COM9-20261017-142847.log
logs/image-check-20261016.txt
reports/2026-10-16-first-flash-status.md
docs/knowledge.notes/day16-2026-10-16-real-board-build-flash.md
docs/knowledge.notes/day17-2026-10-17-bsp-baseline-and-next-stage.md
```

未完成，明确标记 `PENDING-HARDWARE`：

```text
TF 启动验证
TFTP 启动验证
TF/TFTP 上的 Kernel 独立替换
TF/TFTP 上的 DTB 独立替换
rootfs 独立替换后的启动验证
bootcount/recovery 回退验证
```

## 10. 下一步入口

下一次实际硬件操作从串口 U-Boot 命令开始，不先写 eMMC：

```text
mmc list
mmc dev 0
mmc info
part list mmc 0
mmc dev 1
mmc info
part list mmc 1
```

若发现 TF 设备，再继续：

```text
ls mmc <tf_dev>:1
ls mmc <tf_dev>:2
printenv scriptaddr kernel_addr_r fdt_addr_r ramdisk_addr_r boot_targets
```

之后先加载原始基线并记录返回值，再做单变量替换。当前不能把这些命令的结果写成已执行，因为本日没有进入 U-Boot 交互界面。

## 11. Git

本日新增本笔记，文件名遵循实际工作日连续规则：

```text
day18-2026-10-17-day10-independent-replacement-and-fallback.md
```

不提交：

```text
镜像、.deb、原始串口 .bin、VM 密码
```

后续应使用 focused commit：

```bash
git add docs/knowledge.notes/day18-2026-10-17-day10-independent-replacement-and-fallback.md
 git commit -m "docs: record day10 independent replacement boundary"
```

当前远端同步仍待网络恢复后执行：

```bash
git push origin main
```
