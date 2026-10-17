# Day 02：Linux Kernel框架、Image/DTB构建与启动入口

记录日期：2026-09-14  
项目平台：野火鲁班猫2 / Rockchip RK3568  
当前内核：Rockchip厂商Linux 4.19.232

## 一、项目中的Kernel位置

源码根目录：

```text
/home/liu/linux_driver/project/vendor/sdk/kernel
```

鲁班猫2相关入口：

```text
Kernel配置模板：
kernel/arch/arm64/configs/lubancat2_buildroot_defconfig

板级设备树源码：
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2.dts

内核镜像：
kernel/arch/arm64/boot/Image

设备树产物：
kernel/arch/arm64/boot/dts/rockchip/rk3568-lubancat-2.dtb
```

实际构建关系：

```text
BoardConfig-LubanCat2-buildroot.mk
  -> RK_ARCH=arm64
  -> RK_KERNEL_DEFCONFIG=lubancat2_buildroot_defconfig
  -> RK_KERNEL_DTS=rk3568-lubancat-2
  -> build_kernel()
  -> kernel/Makefile + Kconfig/Kbuild
  -> vmlinux -> Image
  -> DTS/DTSI -> DTB
```

## 二、Linux Kernel总体框架

```text
用户空间
├── BusyBox/init
├── cam_capture
├── drm_display
└── media-ctl / v4l2-ctl
          │ 系统调用
          ▼
Linux Kernel
├── arch/arm64/   ARM64架构实现
├── init/         Kernel启动编排
├── kernel/       核心机制
├── mm/           通用内存管理
├── fs/           VFS和文件系统
├── block/        块设备I/O层
├── drivers/      设备模型与驱动
├── net/          网络协议栈
├── include/      内核接口与UAPI
└── scripts/      配置和构建工具
          │
          ▼
RK3568硬件
├── CPU/MMU/GIC/Timer
├── eMMC/TF/USB/Ethernet
├── MIPI CSI/RKCIF/RKISP
└── VOP2/HDMI
```

### 1. `arch/arm64/`

负责ARM64架构相关实现：Kernel早期启动、EL0-EL3、异常和系统调用入口、MMU、页表、TLB、Cache、上下文切换和多核启动。

项目联系：

```text
U-Boot跳转到Image
-> arch/arm64/kernel/head.S
-> 保存DTB地址
-> 配置EL1/EL2
-> 建立早期页表并启用MMU
-> start_kernel()
```

### 2. `init/`

负责通用启动编排，关键路径是：

```text
start_kernel()
-> rest_init()
-> kernel_init()
-> initcall与驱动初始化
-> 挂载rootfs
-> 执行用户空间PID 1
```

项目联系：分析启动耗时、驱动初始化顺序、rootfs和PID 1故障。

### 3. `kernel/`

负责进程、线程、调度、中断通用层、锁、等待队列、completion、workqueue、timer和内核线程等核心机制。

项目联系：

```text
Camera帧中断 -> 唤醒等待队列 -> DQBUF
采集线程 -> 有界队列 -> 显示/写盘线程
mutex/spinlock -> 保护stream状态和共享buffer队列
completion -> 等待硬件操作完成
workqueue -> 延后到可睡眠上下文处理
```

### 4. `mm/`与`arch/arm64/mm/`

`mm/`负责架构无关的内存管理策略：物理页、伙伴系统、SLUB、`kmalloc()`、`vmalloc()`、VMA、`mmap()`、缺页、回收和CMA。

`arch/arm64/mm/`负责将这些机制落实到ARM64的MMU、页表、TLB和Cache。

项目联系：

```text
CMA连续内存
-> Camera DMA buffer
-> videobuf2队列
-> mmap到用户空间
-> DMA-BUF导出
-> DRM GEM导入
-> VOP2扫描输出
```

### 5. `drivers/base/`与`drivers/of/`

`drivers/base/`实现Linux设备模型：bus、device、driver、class、kobject、sysfs、match和probe。

`drivers/of/`提供设备树解析和OF接口。

项目联系：

```text
DTB节点
-> device_node
-> platform_device或i2c_client
-> bus匹配driver
-> probe()
-> 初始化具体硬件
```

后续platform、I2C Camera、DRM、RKCIF/RKISP、MMC和网卡都建立在设备模型上。

### 6. Clock、Regulator、Reset与Pinctrl

相关目录：

```text
drivers/clk/
drivers/regulator/
drivers/reset/
drivers/pinctrl/
```

项目联系：设备树描述资源；驱动在probe和stream过程中获取时钟、电源、复位及引脚资源；runtime PM在空闲时关闭资源。

Camera典型顺序：

```text
regulator供电
-> MCLK开启
-> reset/pwdn GPIO
-> I2C寄存器配置
-> stream on
```

### 7. `drivers/mmc/`、`block/`与`fs/`

```text
rootfs上的ext4
-> VFS / fs/ext4
-> block层
-> mmcblk
-> MMC主控制器驱动
-> RK3568 eMMC/TF硬件
```

`fs/`还负责file、inode、dentry、super_block和`file_operations`。用户的`open/read/ioctl/poll/mmap`经过VFS分派到驱动回调。

项目联系：rootfs挂载、模块加载、`/dev/videoX`、`/dev/dri/card0`、`/proc`、`/sys`和debugfs。

### 8. `drivers/media/`

负责V4L2、Media Controller、sensor subdev、videobuf2及SoC Camera/ISP驱动。

项目链路：

```text
Camera sensor
-> V4L2 subdev
-> Media Controller
-> MIPI CSI/D-PHY
-> RKCIF/RKISP
-> videobuf2
-> /dev/videoX
```

### 9. `drivers/gpu/drm/`

负责DRM/KMS、connector、encoder、CRTC、plane、framebuffer、GEM、atomic modesetting及PRIME/DMA-BUF。

项目链路：

```text
libdrm
-> DRM/KMS
-> GEM/framebuffer
-> plane/CRTC
-> Rockchip VOP2
-> HDMI
```

最终与Camera组合：

```text
V4L2 DMA buffer -> DMA-BUF -> DRM GEM -> framebuffer -> HDMI
```

## 三、Image构建过程

### 1. 配置生成

```text
arch/arm64/configs/lubancat2_buildroot_defconfig
+ 顶层及各子目录Kconfig
-> scripts/kconfig/conf解析
-> kernel/.config
-> include/config/auto.conf
-> include/generated/autoconf.h
```

`.config`决定功能是内建`y`、模块`m`还是关闭。

### 2. 编译与链接

```text
Kernel C/汇编源码
-> ARM64交叉编译
-> 大量.o
-> 各目录built-in.a
-> Kernel链接脚本
-> vmlinux（ELF）
-> ARM64镜像处理
-> arch/arm64/boot/Image
```

`vmlinux`包含ELF头、section、符号和可选调试信息，适合GDB、`readelf`、`nm`和`objdump`。`Image`是供U-Boot加载的ARM64可启动镜像。

## 四、DTB构建过程

输入：

```text
rk3568-lubancat-2.dts
+ rk3568.dtsi等公共DTSI
+ dt-bindings头文件
```

构建：

```text
DTS/DTSI
-> C预处理器展开#include和宏
-> dtc编码节点、属性和字符串
-> rk3568-lubancat-2.dtb
```

DTB是Flattened Device Tree结构化二进制数据，不是机器指令。内部主要包含Header、Memory Reservation Block、Structure Block和Strings Block。

DTS适合人类阅读修改；DTB供U-Boot加载、Kernel解析。反编译DTB不会恢复源码注释和原始include结构。

### 厂商镜像包装

```text
Image + DTB + 可选ramdisk + boot.its
-> mkimage/FIT打包
-> boot.img
```

`Image`是Kernel本体，DTB是硬件描述，`boot.img`是可能组合多个启动对象的封装镜像。

## 五、Image启动流程

### 1. U-Boot交接

```text
U-Boot执行bootcmd
-> 从eMMC/TF/FIT加载Image
-> 加载DTB
-> 准备bootargs并写入/chosen/bootargs
-> x0 = DTB物理地址
-> MMU关闭、D-cache关闭
-> 跳转到Image入口
```

`bootcmd`告诉U-Boot如何启动Linux；`bootargs`告诉Linux本次如何配置console、rootfs、init和CMA等。

### 2. Image Header

真实源码：`arch/arm64/kernel/head.S`

```asm
_head:
        b       stext
        ...
        .ascii  "ARM\x64"
```

Image开头既包含CPU执行的跳转，也包含Bootloader读取的镜像头数据。CPU通过`b stext`进入真正的启动代码，`ARM\x64`是ARM64 Image魔数。

### 3. `stext`主线

```asm
ENTRY(stext)
        bl      preserve_boot_args
        bl      el2_setup
        adrp    x23, __PHYS_OFFSET
        and     x23, x23, MIN_KIMG_ALIGN - 1
        bl      set_cpu_boot_mode_flag
        bl      __create_page_tables
        bl      __cpu_setup
        b       __primary_switch
ENDPROC(stext)
```

职责：

```text
preserve_boot_args     保存Bootloader传入的x0-x3及DTB地址
el2_setup              整理EL1/EL2执行状态
set_cpu_boot_mode_flag 记录启动模式
__create_page_tables   创建早期页表
__cpu_setup            设置CPU/MMU相关寄存器
__primary_switch       启用MMU并切换到Kernel虚拟地址环境
```

### 4. 保存DTB指针

```asm
preserve_boot_args:
        mov     x21, x0
        adr_l   x0, boot_args
        stp     x21, x1, [x0]
        stp     x2, x3, [x0, #16]
        dmb     sy
        mov     x1, #0x20
        b       __inval_dcache_area
```

进入时`x0`是DTB物理地址；保存后`x21`长期持有DTB地址，原始`x0-x3`保存到32字节的`boot_args`区域。这里的`boot_args`是寄存器保存区，不是U-Boot的`bootargs`字符串。

### 5. 异常级别处理（待学习，不计入当前进度）

```text
从EL1进入 -> 设置EL1状态 -> ret

从EL2进入
├── 使用VHE -> 配置EL2并ret，继续在EL2
└── 不使用VHE -> 配置EL2/EL1并eret进入EL1
```

本节仅记录后续阅读入口。`el2_setup`源码尚未正式学习、复述和验收，因此不计入已掌握进度。`ret`与`eret`、VHE/非VHE分支等内容留到下一学习日结合真实源码讲解。

### 6. 尚未展开的启动主线

```text
__create_page_tables
-> __cpu_setup
-> __primary_switch
-> MMU开启
-> start_kernel()
-> setup_arch()与DTB解析
-> 内存、调度、中断、时间和VFS初始化
-> rest_init()
-> PID 0/PID 1/PID 2
-> do_initcalls()与驱动probe
-> 挂载rootfs
-> 执行用户空间init
```

这一段属于后续任务，当前不能记录为已经掌握。

## 六、今天已经掌握的关键结论

1. Linux Kernel由通用核心、ARM64架构实现、设备模型、驱动、内存、VFS和块设备等协作组成。
2. `mm/`提供通用内存策略，`arch/arm64/mm/`提供ARM64页表、MMU、TLB和Cache实现。
3. `vmlinux`是ELF，`Image`是由它生成并供U-Boot加载的ARM64启动镜像。
4. DTS/DTSI经过预处理和dtc生成DTB；DTB是数据，不是程序。
5. U-Boot把DTB物理地址放在`x0`并跳转到Image。
6. 已知道`head.S`将在进入通用C代码前完成异常级别、页表和CPU环境准备，但`el2_setup`及页表/MMU源码尚未学习。
7. V4L2、DRM、CMA、DMA-BUF和rootfs都能映射到明确的Kernel子系统。

## 七、后续任务

### 下一次：先完成`el2_setup`，再开始ARM64内存最小理论

第一部分先结合真实`head.S`学习：

- `CurrentEL`、EL1、EL2和VHE
- `mrs/msr`、`SCTLR_EL1/EL2`和`HCR_EL2`
- `ret`与`eret`
- EL1进入、EL2+VHE、EL2非VHE三条分支
- `set_cpu_boot_mode_flag`如何记录启动模式

通过闭卷验收后，第二部分再学习：

- 物理地址与虚拟地址
- 为什么需要虚拟内存
- 页、页表和多级页表
- MMU、TLB和Cache分别做什么
- Identity Mapping与Kernel Mapping

再结合真实源码阅读：

```text
arch/arm64/kernel/head.S::__create_page_tables
arch/arm64/mm/proc.S::__cpu_setup
arch/arm64/kernel/head.S::__primary_switch
arch/arm64/kernel/head.S::__enable_mmu
```

验收：解释MMU开启前后CPU地址访问如何变化，以及为什么需要临时恒等映射。

### 后续启动源码

```text
__primary_switched -> start_kernel()
start_kernel() -> setup_arch()
setup_arch() -> DTB早期扫描和unflatten
rest_init() -> PID 1和kthreadd
kernel_init() -> initcall、rootfs和用户空间init
```

### 启动主线完成后的专题顺序

```text
设备模型与设备树
-> 进程与调度
-> 内存管理
-> 中断与同步
-> VFS与字符设备
-> block/rootfs
-> Kernel/DTB实际编译和实板验证
-> BSP适配与裁剪
-> PM/DRM
-> V4L2 Camera
```

## 八、今日八股问题与回答

### 1. `sdk/kernel/`与`sdk/kernel/kernel/`有什么区别？

`sdk/kernel/`是完整Linux Kernel源码根目录；`sdk/kernel/kernel/`只是其中的核心机制目录，主要包含调度、进程、锁、中断通用层、workqueue和内核线程等代码。

### 2. `kernel/`、`mm/`、`drivers/`是否都是内核子系统？

它们是Linux源码的顶层功能目录，与子系统高度相关，但目录和子系统并非严格一一对应。`drivers/`包含I2C、USB、MMC、V4L2和DRM等多个子系统；内存管理则横跨`mm/`、`arch/arm64/mm/`和公共头文件。

### 3. `arch/arm64/`与`kernel/`如何分工？

`kernel/`实现架构无关的进程、调度、锁等通用机制；`arch/arm64/`实现ARM64专属的启动、异常入口、寄存器保存、上下文切换和系统调用入口。具体外设驱动主要位于`drivers/`。

### 4. `mm/`与`arch/arm64/mm/`如何分工？

`mm/`实现伙伴系统、SLUB、VMA、缺页、`kmalloc()`、`vmalloc()`和CMA等通用策略；`arch/arm64/mm/`负责ARM64页表、MMU、TLB和Cache等架构实现。

项目联系：Camera的CMA、DMA buffer、videobuf2和`mmap()`依赖通用内存管理，同时依赖ARM64地址转换与Cache一致性机制。

### 5. `drivers/base/`为什么是驱动框架基础？

它实现Linux Device Model的bus、device、driver、class、kobject、sysfs、match和probe。platform、I2C和USB等总线都建立在该模型上。典型链路是：device和driver注册，bus执行match，成功后调用具体驱动的`probe()`。

### 6. Kernel配置如何决定哪些驱动进入编译？

Kconfig定义配置项和依赖，defconfig提供板级起点，`conf`解析后生成`.config`及`auto.conf/autoconf.h`。Kbuild中的`obj-$(CONFIG_xxx)`决定目标文件是否编译；C代码中的`#ifdef CONFIG_xxx`决定文件内部代码是否生效。`y`表示内建，`m`表示模块，未设置表示关闭。

### 7. `vmlinux`与ARM64 `Image`是什么关系？

Kernel源码先生成目标文件和`built-in.a`，再链接为`vmlinux`。`vmlinux`是包含ELF结构、符号和可选调试信息的Kernel文件；ARM64流程再由它生成`arch/arm64/boot/Image`供U-Boot加载。开发板运行`Image`，符号调试通常使用`vmlinux`。

### 8. DTS、DTSI与DTB有什么区别？

DTS描述具体板卡；DTSI保存可复用的SoC或公共硬件描述；DTS/DTSI和dt-bindings经过预处理及`dtc`后生成DTB。DTB是Flattened Device Tree二进制数据，不是机器指令，由U-Boot加载、Kernel解析。

### 9. DTB与Image是什么关系？

Image包含Kernel程序，DTB包含硬件描述。U-Boot分别加载二者，把DTB物理地址放入ARM64的`x0`，再跳转到Image入口。Kernel代码随后通过`x0`找到并解析DTB。FIT可以把二者封装在同一镜像中，但逻辑上仍是独立对象。

### 10. DTS如何生成DTB？

板级DTS引用DTSI和dt-bindings，C预处理器先展开`#include`和宏，`dtc`再把节点、属性和字符串编码为DTB。这里的“编译”是结构化数据转换，不会生成CPU机器指令。

### 11. `bootcmd`与`bootargs`有什么区别？

`bootcmd`由U-Boot解释执行，负责加载Image/DTB并执行`booti`或`bootm`；`bootargs`由Linux解析，用于设置`console=`、`root=`、`rootfstype=`、`rootwait`、`init=`和`cma=`等启动参数。

一句话：`bootcmd`告诉U-Boot怎样启动Linux，`bootargs`告诉Linux本次怎样启动。

### 12. rootfs是什么？Buildroot与rootfs是什么关系？

rootfs是Linux用户空间的根文件系统`/`，包含程序、libc、配置、模块和PID 1。Buildroot是交叉构建用户空间并生成`rootfs.ext4`等镜像的工具，不是rootfs本身。

### 13. rootfs为什么依赖`fs/`、`block/`和存储驱动？

以eMMC上的ext4为例：VFS/ext4解析文件系统，block层处理块I/O，MMC block及控制器驱动访问eMMC，还依赖clock、reset、pinctrl和regulator。启动必需驱动通常要内建为`y`；若只存在于尚未挂载的rootfs模块中会形成循环依赖，除非由initramfs提前提供。

### 14. `head.S`为什么先于`start_kernel()`？

CPU刚进入Image时，C运行环境尚未完整建立。`head.S`需要处理Bootloader参数、异常级别、早期页表、MMU、栈和地址切换，随后才能进入通用C入口`start_kernel()`。

### 15. `start_kernel()`为什么是调度者？

Linux由多个子系统组成。`start_kernel()`按依赖顺序调用架构、内存、调度、中断、时间和VFS等初始化入口；具体实现分散在`arch/`、`mm/`、`kernel/`、`fs/`和`drivers/`。

### 16. V4L2和DRM分别位于哪些目录？

V4L2/Media主要位于`drivers/media/`、`include/media/`和`include/uapi/linux/videodev2.h`；DRM/KMS主要位于`drivers/gpu/drm/`、`include/drm/`和`include/uapi/drm/`。

最终项目链路：

```text
V4L2/videobuf2 Camera buffer
-> DMA-BUF
-> DRM PRIME/GEM
-> framebuffer/plane
-> VOP2/HDMI
```

### 17. ARM64启动时，U-Boot如何传递DTB？

U-Boot把DTB加载到内存，将物理地址放入`x0`，再跳转到Image入口。真实`head.S`中的`preserve_boot_args`把该地址复制到`x21`并保存原始`x0-x3`，供后续启动代码使用。

## 九、明日待答问题（不计入今日掌握）

以下内容必须在正式学习`el2_setup`并通过闭卷验收后填写：

1. `CurrentEL`表示什么？
2. 从EL1和EL2进入Kernel分别如何处理？
3. VHE为什么允许宿主Kernel留在EL2？
4. `ret`和`eret`有什么区别？
5. 为什么切换到EL1后仍可能记录`BOOT_CPU_MODE_EL2`？
6. `SPSR_EL2`、`ELR_EL2`和`VBAR_EL2`分别有什么作用？
7. `el2_setup`为什么位于建立早期页表之前？
