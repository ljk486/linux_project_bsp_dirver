# 鲁班猫2 RK3568 BSP、低功耗与 DRM 四周计划

## 目标与节奏

前三阶段完成并理解以下可复现启动链：

```text
BootROM -> TPL/SPL -> BL31 -> U-Boot -> Linux + DTB -> Buildroot -> init

扩展链路：Linux PM -> suspend/resume；DRM/KMS -> VOP2 -> HDMI。Camera 阶段再将 V4L2 DMA-BUF 接入 DRM。
```

项目定位是基于 Rockchip/野火 BSP 进行复现、分析、裁剪、定制和可靠性改造，不宣称“从零移植 RK3568”。每天约 6 小时：工程 3.5 小时、源码与理论 1.5 小时、日志/提交/闭卷口述 1 小时。

每天必须形成闭环：阅读指定源码入口 -> 画调用流 -> 完成工程任务 -> 保存日志和 diff -> 写一页理论笔记 -> 脱稿讲解 5 分钟。

## 第一周：板卡到货前的离线工作

### 第1天：原厂 SDK 基线与 U-Boot 架构

工程：下载普通鲁班猫2对应的完整 SDK、镜像、原理图、TRM 和构建文档；记录压缩包 SHA256、仓库 commit、工具链及组件版本；不改源码，用官方 defconfig 完整构建；保存命令、日志、耗时、磁盘占用和产物哈希。

源码：顶层 `Makefile`、`Kconfig`、板级 defconfig，以及 `arch/arm/`、`board/`、`drivers/`、`common/`、`cmd/`、`include/`。

理论：U-Boot proper、SPL、TPL、BL31、DTB、Kconfig、Kbuild、Driver Model；区分上游、Rockchip、野火配置及二进制 blob。

闭卷问题：为什么 RK3568 不只运行一个 `u-boot.bin`？defconfig 与 `.config` 有何区别？为什么编译 SDK 不等于从零移植？

产物：`docs/knowledge/day01-uboot-architecture.md`、SDK 目录图、原始构建日志。验收：完整可烧录镜像成功生成，实板项标记 `PENDING-HARDWARE`。

### 第2天：分组件构建与镜像组成

工程：分别构建 U-Boot、Kernel Image、DTB、modules 和 Buildroot；定位所有板级配置；跟踪顶层构建脚本；加入本地 U-Boot/Kernel 版本后缀并增量重建。

源码：U-Boot linker script、map 文件、`System.map`、镜像打包规则和厂商构建脚本。

理论：预处理、编译、链接、objcopy、打包；ELF section、BSS、链接地址、加载地址、运行地址和 relocation 信息；`u-boot`、`u-boot.bin`、`u-boot.dtb`、`u-boot.itb` 的区别。

闭卷问题：为什么编译成功仍可能在 banner 前失败？链接地址与运行地址有何区别？DDR/BL31 为什么可能是 blob？

产物：`docs/knowledge/day02-uboot-build.md`、构建调用图和产物生成图。验收：一个组件可独立修改和构建。

### 第3天：RK3568 启动链与存储布局

工程：定位分区表、打包配置、`bootcmd`、`bootargs`、Kernel/DTB 加载地址和 rootfs 参数；把 IDBLoader、U-Boot、BL31/trust、boot、rootfs 映射到实际存储位置。

源码：RK3568 启动文档、SPL 入口、板级初始化路径、实际启动脚本。

理论：BootROM 启动介质选择；DDR 初始化、TPL/SPL、BL31、U-Boot 职责；早期栈、BSS 清零、global data、relocation、console、存储和 environment。

闭卷问题：DRAM 可用前运行什么？U-Boot 为什么 relocation？执行 `booti` 时传给 Linux 什么？

产物：`docs/knowledge/day03-rk3568-boot-flow.md`、启动阶段/镜像/地址表。验收：讲清谁从哪里加载谁、放到哪里、传递什么。

### 第4天：主备启动与环境变量

工程：确定 environment 存储及持久化机制；定义 `primary/recovery`；设置 `bootlimit=3`，实现 `bootcount/altbootcmd`；设计用户空间成功确认与计数清零；完成编译验证。

理论：默认与持久化 environment、CRC、import/export；`bootcmd`、`bootargs`、bootcount；断电窗口、重试上限、成功确认；Kernel command line、initramfs、块设备 rootfs、PID 1。

闭卷问题：environment 如何形成 Kernel command line？environment 损坏如何处理？为什么应由 Linux 确认启动成功？

产物：`docs/knowledge/day04-uboot-environment.md`、状态图和故障测试表。验收：脚本可解析和构建，运行结果仍标记待实板验证。

### 第5天：设备树与 U-Boot Driver Model

工程：整理 DTS include 关系；定位 UART、eMMC、TF、Ethernet、I2C、GPIO、MIPI CSI；跟踪一个节点的 `compatible -> match -> driver -> probe`；加入无害标识并反编译 DTB 验证。

源码：`struct udevice`、`struct driver`、`U_BOOT_DRIVER`、uclass、`device_bind()`、`device_probe()`及一个真实 UART/MMC 驱动。

理论：bind/probe、uclass、父子设备、platform/private data、pre-relocation 设备；U-Boot 与 Linux 使用 DT 的异同。

闭卷问题：串口为何可能需要 pre-relocation 标志？bind 与 probe 有何区别？DT 节点如何匹配 MMC 驱动？

产物：`docs/knowledge/day05-uboot-dm.md`、DTS 继承图和真实调用链。验收：从板级节点找到实际 probe。

### 第6天：U-Boot/Linux/Buildroot 移植与裁剪

工程：保存 baseline 配置；只裁剪用途明确的功能；必须保留串口、eMMC、TF、网口、USB、I2C、GPIO、V4L2/media、RKCIF、RKISP；加入系统信息采集工具；比较产物大小。

源码：板级 defconfig、DTS/DTSI、Rockchip Kconfig、板级源码、Kernel `start_kernel()`和`rest_init()`主路径。

理论：板级移植涉及 SoC、DDR、pinmux、PMIC、clock/reset、存储、console、DT、环境和打包；Kconfig 的 `select/depends on`；initcall 与 probe 时机。

闭卷问题：更换 RK3568 底板需要改什么？哪些信息没有原理图不能猜？如何证明裁剪安全？

产物：`docs/knowledge/day06-port-trim.md`、配置 diff、裁剪理由和大小表。验收：裁剪镜像成功构建，每个删除项可解释。

### 第7天：离线集成与 U-Boot 综合复盘

工程：集成 U-Boot、Kernel、DTB、rootfs 为 `bsp-rc1`；从干净目录重建；拆分可审查 patch；准备部署、回退和实板测试命令。

理论复盘：BootROM 到 Linux handoff、SPL/TPL/BL31、relocation/global data、Driver Model、environment、DT、加载地址、bootargs、镜像打包。

产物：`docs/interview/uboot-qa.md`，至少 15 道用自己的语言回答且关联工程证据的问题。验收：脱稿讲解 U-Boot 10 分钟，板子到货即可部署。

## 第二周：实板集成与 Linux 架构

<!-- BSP_TOTAL_REVIEW_ANCHOR: BSP阶段(第14天 bsp-v1.0)结束后，除既定考核外，追加一轮"安全启动专题总拷打"：
     安全启动(secure boot)、ATF/TF-A(BL1/BL2/BL31/BL32职责)、TrustZone(安全世界/普通世界、SMC调用)、
     Hypervisor/EL2/VHE、OP-TEE。要求结合本项目实际讲解：RK3568启动链中BL31所在环节、
    rkbin trust镜像、设备树中的安全相关节点、EL2与el2_setup源码的呼应。
     产出追加进 docs/interview/linux-bsp-qa.md。来源：2026-09-30用户面经反馈。-->

### 第8天：原厂基线与 Linux 启动架构

工程：核对型号、PCB、RAM、eMMC；启动原厂镜像并保存完整串口日志；记录 model、Kernel、cmdline、存储和网络；验证 TF、Loader、MaskROM；备份 environment 和 DTB。

源码：ARM64 boot protocol、入口汇编高层流程、`start_kernel()`及串口日志对应位置。

理论：EL0-EL3、DT 指针、MMU 切换；架构、内存、调度器、IRQ、时钟、VFS、driver core、initcall、rootfs、PID 1 的顺序。

闭卷问题：进入 Linux 前 U-Boot 必须准备什么？`start_kernel()`做什么？MMU 何时及为何启用？

产物：`docs/knowledge/day08-linux-architecture.md`和注释启动日志。验收：原厂系统正常且恢复路径可靠。

### 第9天：自编译系统、initcall、rootfs 与 VFS

工程：从 TF 启动未裁剪的自编译镜像；确认自定义版本；测试 rootfs、网口、USB、TF、eMMC、SSH；先解决 baseline 问题。

源码：`rest_init()`、`kernel_init()`、initcall 宏、rootfs 挂载路径、`struct file`、inode、dentry、file_operations。

理论：PID 0/PID 1、内核线程、initcall 等级、init 回退；VFS 对象；内建驱动与模块初始化。

闭卷问题：执行不了 PID 1 会怎样？四个 VFS 对象有何区别？内建驱动何时初始化？

产物：`docs/knowledge/day09-init-vfs.md`。验收：自编译 baseline 完整启动。

### 第10天：快速部署与内存地址模型

工程：验证 U-Boot、Kernel、DTB 独立替换；配置 TFTP；记录地址、大小和启动命令；保留 TF/eMMC 回退。

理论：物理/虚拟/总线 DMA/链接/加载地址；页表、线性映射、reserved-memory、CMA；镜像区域重叠风险；`kmalloc`、`vmalloc`、页分配和 coherent DMA。

闭卷问题：驱动为何不能随意解引用物理地址？几类内存分配有何区别？Camera 为什么可能需要 CMA？

产物：`docs/knowledge/day10-memory-addressing.md`和内存布局图。验收：Kernel/DTB 修改可在 15 分钟内验证。

### 第11天：回退测试、进程与失败行为

工程：验证 primary、成功确认、错误 Kernel/DTB/rootfs 参数、三次失败进入 recovery、断电后 bootcount 持久化。

源码：`task_struct`、进程状态、调度入口概览、panic 配置和实际故障日志。

理论：进程/线程、上下文切换、内核线程、oops/panic/watchdog/reset，以及 U-Boot 如何在下次重启判断 Linux 失败。

闭卷问题：上下文切换保存什么？oops 与 panic 区别？U-Boot 不解析 Linux 日志如何判断失败？

产物：`docs/knowledge/day11-process-failure.md`及故障日志。验收：至少三种故障可重复且能恢复登录。

### 第12天：裁剪验证、中断与并发

工程：启动裁剪系统；测试串口、eMMC、TF、网口、USB、SSH、I2C、GPIO；确认 Camera 配置保留；执行 3 次冷启动、10 次重启。

源码：IRQ 文档及 spinlock、mutex、completion、wait queue、workqueue、threaded IRQ 定义。

理论：hard IRQ、softirq、threaded IRQ、workqueue、进程/原子上下文；睡眠规则、竞态、死锁和锁顺序。

闭卷问题：硬中断为何不能睡眠？何时用 threaded IRQ？completion 与 mutex 各解决什么问题？

产物：`docs/knowledge/day12-interrupt-locking.md`和上下文/锁矩阵。验收：裁剪系统稳定且保留后续驱动依赖。

### 第13天：性能、内存分配与裁剪原理

工程：用固定标志测量启动时间；比较 U-Boot、Kernel、modules、rootfs、整包大小；记录内存/服务；完成一份“现象->假设->证据->根因->修复->回归”报告。

理论：buddy、SLUB、页分配、`kmalloc`、`vmalloc`、GFP flags；删除功能、改为模块、关闭用户服务的区别；裁剪对依赖和启动顺序的影响。

闭卷问题：`vmalloc` 为何通常不能直接 DMA？`GFP_ATOMIC`牺牲什么？更小的 Kernel 为何可能启动失败？

产物：`docs/knowledge/day13-memory-trimming.md`和实测对比。验收：每个数字可由日志或命令复核。

### 第14天：BSP v1.0 与 Linux 移植综合复盘

工程：clean build；重复 TF 启动和回退测试；整理配置、patch、日志、哈希、图和报告；区分厂商功能与自己的改动；创建 `bsp-v1.0` tag。

理论：掌握 Linux 移植清单，包括架构/SoC、clock/reset、中断控制器、timer、pinctrl、PMIC/regulator、内存、存储、console、网络、DT、rootfs、module、firmware 和验证；能够分层排查无日志、Kernel 卡死、panic、无 rootfs、无 probe、deferred probe 和用户服务失败。

产物：`docs/interview/linux-bsp-qa.md`，至少 20 道回答及一次 15 分钟模拟面试。验收：另一台 Ubuntu 可依 README 构建，板卡可启动、回退并复现实测。

## 必须执行的测试

- 原厂 SDK 零修改 clean build及自编译镜像启动。
- 裁剪镜像 3 次冷启动、10 次热重启。
- primary 正常启动及 Kernel、DTB、rootfs 故障注入。
- 三次失败后进入 recovery，成功后清零 bootcount。
- 串口、eMMC、TF、Ethernet、USB、SSH、I2C、GPIO 检查。
- 在相同条件下比较配置、大小和启动耗时。
- 保留 V4L2、Media Controller、RKCIF、RKISP 供下一阶段使用。
- 低功耗阶段执行50次suspend/resume，记录唤醒原因和关键设备恢复。
- DRM阶段执行30分钟page flip、20次HDMI热插拔和20次显示中休眠唤醒。

## 第三周：Linux低功耗专题

### 第15天：PM架构与基线

- 检查Kernel配置、DTS中的OPP、clock、power-domain、regulator和wakeup属性。
- 阅读PM core、runtime PM与system sleep的关系。
- 保存CPU频率、idle state、clock、regulator、wakeup_sources状态。
- 产物：`docs/knowledge/day15-pm-architecture.md`和PM基线报告。

### 第16天：CPUFreq与CPUIdle

- 枚举CPU policy、OPP、governor和idle states。
- 在空闲、固定负载下比较`schedutil`、`performance`、`powersave`。
- 记录频率、idle驻留、温度、CPU占用和任务耗时。
- 产物：`reports/pm/cpufreq-cpuidle.md`。

### 第17天：Clock、Regulator与Power Domain

- 使用debugfs保存`clk_summary`、regulator和genpd状态。
- 对比外设使用中、空闲和关闭后的资源状态。
- 学习clock gate、regulator引用、genpd和设备树关系。
- 产物：`docs/knowledge/day17-clock-regulator-genpd.md`。

### 第18天：Runtime PM跟踪

- 选择一个已有runtime PM支持的安全设备。
- 跟踪`pm_runtime_get/put`、usage count、autosuspend和runtime回调。
- 验证空闲进入suspended、再次访问恢复。
- 产物：runtime PM调用时序图和trace日志。

### 第19天：System Suspend/Resume

- 以RTC或板载按键作为主唤醒源，验证`suspend-to-RAM`。
- 记录suspend/resume耗时、唤醒源和失败日志。
- 完成20次休眠唤醒。
- 产物：`reports/pm/suspend-resume.md`。

### 第20天：PM改造

- 依据证据选择一项改造：修复runtime PM引用不平衡、未关闭clock、错误wakeup source或autosuspend延迟。
- 保存修改前后状态、trace和回归结果。
- 不报告未经功率计验证的瓦数或功耗百分比。

### 第21天：PM发布

- 完成50次suspend/resume以及网络、存储、显示恢复测试。
- 整理patch、报告和15道PM面试题。
- 创建`pm-v1.0`标签。

## 第四周：DRM/KMS与HDMI显示

目标链路：

```text
libdrm -> DRM ioctl/atomic -> framebuffer/GEM -> plane -> CRTC
       -> encoder -> connector -> VOP2 -> HDMI PHY -> 显示器
```

### 第22天：DRM架构与拓扑

- 确认DRM、Rockchip DRM、VOP2、HDMI和PHY配置及DTS节点。
- 使用`modetest -c -p -e`导出connector、encoder、CRTC、plane、format和property。
- 学习DRM对象模型及板级硬件映射。
- 产物：`docs/knowledge/day22-drm-architecture.md`。

### 第23天：最小KMS显示程序

- 用C/libdrm打开设备，枚举资源，选择mode/CRTC。
- 创建dumb buffer，mmap填色，创建framebuffer并显示。
- 实现错误路径资源释放。
- 接口：`drm_display --card /dev/dri/card0 --connector auto --mode 1920x1080@60 --duration 30`。

### 第24天：双缓冲与Page Flip

- 实现两个buffer、page-flip event、`poll()`事件循环和有序退出。
- 统计vblank/page-flip间隔、CPU占用和丢失事件。
- 产物：page flip时序和30分钟压力日志。

### 第25天：Atomic Modesetting

- 枚举connector、CRTC、plane属性，构造atomic request。
- 先执行`TEST_ONLY`，再正式commit；支持`NONBLOCK`事件。
- 增加`--atomic --buffers 2`参数。
- 产物：atomic对象/property映射和失败参数测试。

### 第26天：格式、stride、GEM与DMA-BUF

- 测试至少两种分辨率和一种RGB格式，记录pitch、offset和modifier。
- 理解dumb buffer、GEM handle、PRIME fd和DMA-BUF的生命周期。
- 建立后续V4L2共同格式和stride兼容矩阵。
- 产物：`docs/knowledge/day26-gem-dmabuf.md`。

### 第27天：热插拔与PM联动

- 测试HDMI断开/重连、无EDID、无可用CRTC。
- 在显示活动时执行suspend/resume，比较clock和runtime PM状态。
- 验证DRM资源可安全重建。
- 产物：`reports/drm/hotplug-pm.md`。

### 第28天：DRM发布

- 执行clean build、30分钟page flip、20次热插拔和20次休眠唤醒。
- 检查GEM/framebuffer、fd、RSS和退出清理。
- 整理README、报告和20道DRM面试题。
- 创建`drm-v1.0`标签。

## 后续阶段边界：Linux驱动与V4L2 Camera

暂不展开逐日计划，待BSP、低功耗、DRM完成且Camera型号确定后再细化。预定内容：字符设备、platform/I2C、GPIO/IRQ、DMA、runtime PM、vivid、V4L2用户态、sensor subdev、Media Controller、videobuf2、真实Camera，以及`VIDIOC_EXPBUF -> DMA-BUF -> DRM PRIME/GEM -> atomic plane`闭环。

## 可选加分项：Kernel LTS升级

该项仅在`bsp-v1.0`、真实V4L2 Camera和必要测试完成后启动，不影响11月投递主线。

执行优先级：

```text
厂商Linux 4.19完整项目
    -> Rockchip develop-6.1 BSP迁移/评估
    -> 时间和岗位需求允许时，再评估主线Linux 6.6
```

6.1阶段重点：迁移鲁班猫2DTS和defconfig，验证启动、串口、eMMC/TF、网口、USB、DRM/HDMI、PM，并分析RKCIF/RKISP和Camera支持差异。

6.6阶段默认定位为可行性评估，不预设完整多媒体支持。输出已工作外设、缺失驱动、厂商补丁依赖、内核API变化、Camera/ISP阻塞点、迁移成本和风险。

验收至少满足其一：

- 6.1 LTS能够稳定启动并完成关键外设回归；或
- 6.6能够启动到用户空间，并形成有源码和日志依据的BSP差距报告。

简历表述必须与实测一致：只完成启动时不能写成“完成完整BSP升级”，Camera未跑通时不能写成“完成Camera迁移”。

## 理论验收门槛

- 10 分钟画出并解释 RK3568 从复位到 PID 1。
- 指出控制每个阶段的镜像、配置和源码入口。
- 解释 U-Boot relocation、Driver Model、environment、DT 和 Linux handoff。
- 解释 `start_kernel()`、initcall、rootfs、PID 1、VFS、内存、中断上下文、常用锁和 Linux Driver Model。
- 每个核心回答至少引用一项自己的日志、配置 diff 或 patch。
- 面对未知故障时给出分层排查方案，不直接猜单一原因。

## 规则

- TF 和恢复链路验证前，不覆盖唯一可工作的 eMMC 系统。
- 原厂 baseline 保持不动，修改放在自己的分支。
- 每项结论必须有原始日志、diff、命令或测量依据。
- 两周内不通读全部 U-Boot/Kernel，不迁移主线版本。
- 第14天后进入低功耗与DRM阶段；第28天后进入Linux驱动和V4L2，非关键BSP扩展进入待办。

## 每日首次对话协议

每天第一次继续本项目时，助手必须先读取：

```text
D:\linux_driver\project\docs\BSP_PLAN.md
D:\linux_driver\project\docs\day01-sdk-inventory.md
D:\linux_driver\project\docs\knowledge.notes\ 中最近更新的学习笔记
D:\linux_driver\project\reports\ 和 logs\ 中最近的验收结果（存在时）
```

读取后先报告当前阶段、已通过验收、待验证事项和当天唯一主目标，再开始源码讲解或工程操作。必须区分“已讲解、已理解、已编译、已上板、已测试”，不得将前一状态自动视为后一状态。

每天结束时，将实际掌握内容、工程产物、未解决问题和下一次入口写入当日笔记。日程可根据真实进度顺延，但主线和验收标准不因赶进度而省略。

## 加分项提醒门槛

以下内容不是最低可投递版本的硬门槛，但时间充足时属于高价值加分项，必须在对应节点主动提醒：

1. `bsp-v1.0`通过后：提醒执行CPUFreq、CPUIdle、clock/regulator、runtime PM与suspend/resume低功耗专题。
2. DRM驱动和HDMI基线正常后：提醒完成libdrm、page flip、Atomic KMS及热插拔/休眠恢复。
3. 真实Camera稳定出帧后：提醒实现`VIDIOC_EXPBUF -> DMA-BUF -> DRM PRIME/GEM -> atomic plane`，并核对format、stride、offset、modifier、同步和buffer所有权。
4. 厂商4.19主项目完成后：提醒优先评估Rockchip 6.1 BSP；只有时间和岗位需求允许时再评估主线6.6。

只有Camera和DRM共享同一底层DMA buffer、途中没有CPU复制或额外转换buffer时，才称为“零拷贝”。使用RGA转换时表述为硬件转换/低CPU拷贝；使用CPU转换时不得表述为零拷贝。

## Linux内核子系统固定学习模式

学习`kernel/`、`mm/`、VFS、设备模型、中断同步、block/rootfs、PM、DRM和V4L2时，统一采用以下七步，不默认具备Linux内核课程基础：

1. **问题与概念**：先说明子系统解决什么问题，用生活化或最小程序例子解释首次出现的术语。
2. **框架与边界**：画出该子系统与用户态、架构层、设备驱动及其他子系统的关系，区分通用代码和`arch/arm64/`实现。
3. **核心对象**：只选择必须掌握的结构体、状态和生命周期，不一次罗列整个目录。
4. **真实源码主链**：读取当前Rockchip Linux 4.19.232源码，展示实际路径、行号和原始代码，逐句说明调用者、参数、返回值、上下文及下一跳。
5. **项目映射**：说明该机制在鲁班猫2BSP、低功耗、DRM或V4L2 Camera中的实际位置和用途。
6. **实验与故障**：安排一个最小实验和至少一个失败场景，保存命令、日志、diff及结论。
7. **闭卷验收**：用自己的话画调用链、回答面试题，并解释资源从哪里取得、何时使用、失败如何回滚、最终在哪里释放。

第一轮只要求“核心理论 + 关键结构体 + 一条代表性调用链 + 项目实验”。不以读完目录中所有`.c`文件为目标；调度器、内存回收、VFS和协议栈的高级算法按项目或面试需求进行第二轮深入。

推荐顺序固定为：

```text
Kernel启动主线
-> 设备模型与设备树
-> 进程、线程与调度框架
-> 内存管理
-> 中断与同步
-> VFS与字符设备
-> block与rootfs
-> DMA/CMA与runtime PM
-> DRM/KMS
-> V4L2/Media/videobuf2
```
