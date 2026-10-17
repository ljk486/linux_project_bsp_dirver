# Day 01 SDK 清单与构建信息

## 当前状态

- 记录日期：2026-09-12
- 开发板目标：野火 LubanCat 2
- SoC：Rockchip RK3568
- SDK 远程路径：`/home/liu/linux_driver/project/vendor/sdk`
- SDK 状态：已解压，目录结构完整
- 实板状态：`PENDING-HARDWARE`，尚未完成实板启动验证
- GitHub同步：暂未执行，等待项目阶段性成果统一提交

## 已确认的 SDK 顶层结构

```text
sdk/
├── ubuntu/
├── debian/
├── u-boot/
├── kernel/
├── device/
├── rkbin/
├── prebuilts/
├── tools/
├── build.sh
├── mkfirmware.sh
└── rkflash.sh
```

说明：该 SDK 没有顶层 `buildroot/` 目录，是 Rockchip Ubuntu/Debian SDK 的组织方式。Buildroot相关内容需要通过目标配置和文档继续确认，不能仅因目录不存在就判断SDK缺失。

## 鲁班猫2配置位置

### 板级目标配置

```text
device/rockchip/.target_product/.others/BoardConfig-LubanCat2-buildroot.mk
device/rockchip/.target_product/.others/BoardConfig-LubanCat2-debian.mk
device/rockchip/.target_product/.others/BoardConfig-LubanCat2-ubuntu.mk
```

公共配置副本位于：

```text
device/rockchip/rk356x/.others/BoardConfig-LubanCat2-buildroot.mk
device/rockchip/rk356x/.others/BoardConfig-LubanCat2-debian.mk
device/rockchip/rk356x/.others/BoardConfig-LubanCat2-ubuntu.mk
```

普通 LubanCat 2 首先核对实际PCB版本，再选择对应的普通2配置，不直接使用2N、2H或V3配置。

### Linux Kernel 设备树

```text
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2.dts
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2-v1.dts
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2h.dts
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2n.dts
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2n-v2.dts
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2n-v3.dts
kernel/arch/arm64/boot/dts/rockchip/uEnv/uEnvLubanCat2-V3.txt
```

### U-Boot和构建入口

```text
u-boot/configs/
u-boot/arch/arm/
u-boot/board/
u-boot/drivers/
u-boot/common/
u-boot/cmd/
u-boot/make.sh
build.sh
device/rockchip/common/build.sh
mkfirmware.sh
rkflash.sh
```

顶层 `build.sh` 通过 `device/rockchip/.BoardConfig.mk` 选择板级配置；如果链接不存在，脚本会列出 `BoardConfig*.mk` 并要求选择目标。

## 远程工具链和主机信息

```text
aarch64-linux-gnu-gcc：Ubuntu 9.4.0-1ubuntu1~20.04.2 9.4.0
GNU Make：4.2.1
DTC：1.5.0
Python：3.8.10
```

```text
远程工程路径：/home/liu/linux_driver/project
文件系统：/dev/sda5
总容量：59G
已使用：9.7G
可用：46G
```

## 尚未确认的信息

- SDK发布包文件名、发布日期和SHA256
- 各子仓库的Git commit或版本标识
- `RK_UBOOT_DEFCONFIG`
- `RK_KERNEL_DEFCONFIG`
- `RK_KERNEL_DTS`
- 实际rootfs构建方式及配置位置
- 完整构建命令和首次构建日志
- 各镜像的实际输出路径、大小和SHA256
- 开发板实际PCB版本、内存和eMMC容量

## 远程只读确认结果（2026-09-12）

执行检查的远程SDK：

```text
/home/liu/linux_driver/project/vendor/sdk
```

结果：

| 检查项 | 结果 |
|---|---|
| `device/rockchip/common/mk-buildroot.sh` | 存在 |
| 顶层 `buildroot/`目录 | 未发现 |
| `rockchip_rk3568_defconfig` | 未发现 |
| 鲁班猫2专属 `app-build.sh` | 未发现 |
| `device/rockchip/common/build.sh` | 存在 |
| `build.sh` | 存在 |

`device/rockchip/common/build.sh`明确引用以下路径：

```text
buildroot/configs/${RK_CFG_BUILDROOT}_defconfig
buildroot/output/$RK_CFG_BUILDROOT/.config
buildroot/output/$RK_CFG_BUILDROOT/images/rootfs.$RK_ROOTFS_TYPE
```

因此当前压缩包很可能是：

1. Buildroot作为未同步的Repo子项目；或
2. 当前SDK下载包不完整；或
3. Buildroot需要由另外的离线包/恢复脚本补充。

当前不能直接运行完整构建并声称SDK完整。下一步应先阅读SDK发布说明和`.repo/manifest*`，确认是否有未同步的Buildroot项目或额外下载包。

`RK_BOARD_PRE_BUILD_SCRIPT=app-build.sh`由公共脚本在以下条件下执行：

```text
device/rockchip/$RK_TARGET_PRODUCT/app-build.sh 存在
```

当前`RK_TARGET_PRODUCT=rk356x`，`device/rockchip/rk356x/app-build.sh`未找到；因此该hook当前没有可执行文件，不能把它当成已验证的板级预构建步骤。

远程环境还确认：

```text
rg命令未安装，配置检索使用grep/find完成
磁盘剩余约39GB（59GB总容量，17GB已用）
```

## 今天的下一步

1. 阅读普通 LubanCat 2 的 `BoardConfig-LubanCat2-*.mk`，提取 `RK_*`变量。
2. 阅读 SDK 文档，确认目标选择和完整构建命令。
3. 执行零修改构建，并保存到 `logs/build-day01.log`。
4. 构建成功或失败后补全本文件的“尚未确认的信息”。

## 证据规则

- 当前文件是远程SDK检查记录，不代表实板已启动。
- 未执行的构建、烧录、Camera和DRM测试保持待验证状态。
- 厂商SDK、`.repo`、工具链和闭源二进制不直接上传公开GitHub；后续只提交自己的配置、补丁、脚本、日志摘要和文档。

## 配置追踪结果（2026-09-12）

### `RK_CFG_BUILDROOT` 的使用链

当前板级配置设置：

```bash
RK_CFG_BUILDROOT=rockchip_rk3568
```

`device/rockchip/common/build.sh`中的`build_buildroot()`会检查该变量，并调用：

```text
device/rockchip/common/mk-buildroot.sh <BoardConfig>
    -> 使用 RK_CFG_BUILDROOT
    -> 期望 Buildroot 配置：buildroot/configs/rockchip_rk3568_defconfig
    -> 输出目录：buildroot/output/rockchip_rk3568/
```

构建脚本还会在以下位置引用该变量：

```text
buildroot/output/$RK_CFG_BUILDROOT/.config
buildroot/output/$RK_CFG_BUILDROOT/images/rootfs.$RK_ROOTFS_TYPE
buildroot/configs/${RK_CFG_BUILDROOT}_defconfig
```

### Kernel设备树使用链

```bash
RK_KERNEL_DTS=rk3568-lubancat-2
```

`device/rockchip/common/build.sh`会根据`RK_ARCH=arm64`拼接：

```text
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2.dtb
```

Kernel构建目标使用：

```text
make ARCH=arm64 rk3568-lubancat-2.img -j$RK_JOBS
```

### U-Boot使用链

```bash
RK_UBOOT_DEFCONFIG=rk3568
```

公共构建脚本的`usageuboot()`会进入`u-boot/`并使用：

```text
make rk3568_defconfig
./make.sh <RK_TRUST/RK_SPL等打包参数>
```

具体的trust、SPL/DDR和镜像参数由同一份`BoardConfig`中的其他`RK_*`变量及`rkbin/`文件决定。

### 当前发现的SDK问题/风险

- SDK顶层当前没有可见的`buildroot/`目录，但`build.sh`和`device/rockchip/common/build.sh`明确引用`buildroot/`。
- 因此在第一次构建前必须确认：Buildroot是否是未同步的Repo子项目、是否位于其他目录，或当前SDK压缩包缺少该组件。
- 当前`find`只在`device/rockchip/rv1126_rv1109/`发现`app-build.sh`，没有发现鲁班猫2专属的`app-build.sh`；不能直接假设`RK_BOARD_PRE_BUILD_SCRIPT=app-build.sh`在当前目标中可执行。
- 远程虚拟机没有安装`rg`，本次配置检索使用`grep/find`完成。

建议下一步只做只读确认：

```bash
cd /home/liu/linux_driver/project/vendor/sdk
find . -maxdepth 3 -type d -iname '*buildroot*' -o -type f -name 'mk-buildroot.sh'
find . -type f -name 'rockchip_rk3568_defconfig'
grep -RIn 'RK_BOARD_PRE_BUILD_SCRIPT\|app-build.sh' device/rockchip/common device/rockchip/.target_product 2>/dev/null
```

## BoardConfig 文件类型与读取流程

`BoardConfig-LubanCat2-buildroot.mk`虽然扩展名是`.mk`，但本质是使用Shell语法编写的板级配置脚本，不是普通Makefile，也不是说明性txt文件。它通过`export RK_变量=值`向构建脚本提供板级决策。

典型内容：

```bash
#!/bin/bash
export RK_ARCH=arm64
export RK_UBOOT_DEFCONFIG=rk3568
export RK_KERNEL_DEFCONFIG=lubancat2_buildroot_defconfig
export RK_KERNEL_DTS=rk3568-lubancat-2
```

`build.sh`的读取流程：

```text
./build.sh lunch
    -> 选择 BoardConfig-LubanCat2-buildroot.mk
    -> 创建/更新 device/rockchip/.BoardConfig.mk 符号链接
    -> source device/rockchip/.BoardConfig.mk
    -> RK_*变量进入当前Shell构建环境
    -> 按变量编译U-Boot、Kernel、DTB、rootfs并打包
```

检查符号链接：

```bash
ls -l device/rockchip/.BoardConfig.mk
readlink -f device/rockchip/.BoardConfig.mk
```

手动验证变量加载：

```bash
source device/rockchip/.target_product/.others/BoardConfig-LubanCat2-buildroot.mk
echo "$RK_ARCH"
echo "$RK_UBOOT_DEFCONFIG"
echo "$RK_KERNEL_DEFCONFIG"
echo "$RK_KERNEL_DTS"
```

与Makefile的区别：

| 文件 | 实际作用 |
|---|---|
| `BoardConfig-LubanCat2-buildroot.mk` | Shell变量配置脚本 |
| `build.sh` | 顶层Shell构建脚本 |
| `device/rockchip/common/build.sh` | Rockchip公共构建逻辑 |
| `Makefile` | 子工程的Make构建规则 |
| `.config` | Kernel/U-Boot配置结果 |
| `.dts` | 设备树源码 |
| `.dtb` | 编译后的设备树二进制 |

这个文件提供构建决策，不直接编译源码；真正的构建动作由`build.sh`、子目录脚本和Makefile完成。

## LubanCat2 Buildroot 配置变量

来源文件：

```text
device/rockchip/.target_product/.others/BoardConfig-LubanCat2-buildroot.mk
```

| 变量 | 实际值 | 作用 |
|---|---|---|
| `RK_ARCH` | `arm64` | 目标CPU架构 |
| `RK_UBOOT_DEFCONFIG` | `rk3568` | U-Boot默认配置，通常对应`rk3568_defconfig` |
| `RK_UBOOT_FORMAT_TYPE` | `fit` | U-Boot镜像采用FIT相关格式 |
| `RK_KERNEL_DEFCONFIG` | `lubancat2_buildroot_defconfig` | Linux Kernel默认配置 |
| `RK_KERNEL_DEFCONFIG_FRAGMENT` | 空 | 未叠加额外Kernel配置片段 |
| `RK_KERNEL_DTS` | `rk3568-lubancat-2` | Kernel设备树目标，通常对应`rk3568-lubancat-2.dts` |
| `RK_BOOT_IMG` | `boot.img` | 启动镜像名称 |
| `RK_KERNEL_IMG` | `kernel/arch/arm64/boot/Image` | Kernel原始Image路径 |
| `RK_KERNEL_FIT_ITS` | `boot.its` | Kernel FIT镜像组合描述文件 |
| `RK_PARAMETER` | `parameter-buildroot-fit.txt` | GPT分区和启动参数配置 |
| `RK_CFG_BUILDROOT` | `rockchip_rk3568` | Buildroot目标配置名 |
| `RK_CFG_RECOVERY` | `rockchip_rk356x_recovery` | Recovery目标配置名 |
| `RK_RECOVERY_FIT_ITS` | `boot4recovery.its` | Recovery FIT镜像描述文件 |
| `RK_CFG_RAMBOOT` | 空 | 未启用Ramboot配置 |
| `RK_CFG_PCBA` | 空 | 未启用PCBA测试配置 |
| `RK_JOBS` | `24` | 默认并行编译任务数 |
| `RK_TARGET_PRODUCT` | `rk356x` | Rockchip目标平台族 |
| `RK_ROOTFS_TYPE` | `ext4` | rootfs文件系统格式 |
| `RK_DEBIAN_VERSION` | `buster` | Debian版本变量，当前Buildroot目标不作为主配置使用 |
| `RK_UBUNTU_VERSION` | `bionic` | Ubuntu版本变量，当前Buildroot目标不作为主配置使用 |
| `RK_YOCTO_MACHINE` | `rockchip-rk3568-evb` | Yocto machine默认值，当前Buildroot目标不作为主配置使用 |
| `RK_ROOTFS_IMG` | `rockdev/rootfs.ext4` | rootfs镜像输出路径 |
| `RK_RAMBOOT_TYPE` | 空 | 未设置Ramboot镜像类型 |
| `RK_OEM_FS_TYPE` | `ext2` | OEM分区文件系统格式 |
| `RK_USERDATA_FS_TYPE` | `ext2` | userdata分区文件系统格式 |
| `RK_OEM_DIR` | `oem_normal` | OEM分区内容目录 |
| `RK_USERDATA_DIR` | `userdata_normal` | userdata分区内容目录 |
| `RK_MISC` | `wipe_all-misc.img` | misc分区镜像 |
| `RK_DISTRO_MODULE` | 空 | 未启用额外发行版模块 |
| `RK_BOARD_PRE_BUILD_SCRIPT` | `app-build.sh` | 板级预构建脚本 |
| `RK_ROOTFS_SYSTEM` | `buildroot` | 默认rootfs系统类型 |

### 当前构建流结论

```text
RK_ARCH=arm64
    -> 使用RK3568 U-Boot配置
    -> 使用lubancat2_buildroot_defconfig
    -> 编译rk3568-lubancat-2.dts
    -> 生成Image并按boot.its组合boot.img
    -> 使用rockchip_rk3568构建Buildroot rootfs
    -> 生成rootfs.ext4
    -> 按parameter-buildroot-fit.txt进行GPT/镜像打包
```

### 需要后续确认

- `RK_UBOOT_DEFCONFIG=rk3568`实际调用的完整U-Boot命令和输出文件。
- `RK_CFG_BUILDROOT=rockchip_rk3568`对应的配置文件实际路径。
- `app-build.sh`实际路径和执行内容。
- `boot.its`如何引用Image、DTB和rootfs。
- `parameter-buildroot-fit.txt`的实际分区起始地址和大小。
- `RK_JOBS=24`是否适合当前虚拟机内存；若构建OOM，临时降低为4或8，不修改项目结论。
