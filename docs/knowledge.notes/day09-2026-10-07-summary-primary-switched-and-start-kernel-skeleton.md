# Day 3 总笔记（原计划 Day3）：`__primary_switched` 过渡 + `start_kernel` 五阶段骨架

> 对应 7 天计划第 3 天：理论=栈、BSS、启动参数、初始化依赖；源码=`__primary_switched` 进入 `start_kernel()` 拆分阶段；验收=画汇编入口到 C 入口完整调用图。
> 源码基准：Rockchip 4.19（虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`），PA=48/VA_BITS=48/4KB页/4级页表。
> 承接 Day2：MMU 开启后从 `br __primary_switched` 开始（高虚拟地址视角）。

## 〇、全局定位

```text
[汇编阶段 物理地址视角] (Day2已学)
U-Boot booti → stext
  ├─ preserve_boot_args → el2_setup → set_cpu_boot_mode_flag
  ├─ __create_page_tables (建idmap+swapper)
  ├─ __cpu_setup (配TCR/MAIR/SCTLR值)
  └─ b __primary_switch
      └─ bl __enable_mmu (TTBR装载+开MMU)
          └─ br __primary_switched (跳高VA)  ← Day3从这里开始

[过渡阶段 进入高虚拟地址视角]
__primary_switched:
  ├─ 设sp内核栈
  ├─ sp_el0 ← init_task (current机制)
  ├─ vbar_el1 ← vectors (异常向量表)
  ├─ 存__fdt_pointer ← x21
  ├─ 算kimage_voffset
  ├─ 清BSS
  └─ b start_kernel

[C阶段]
start_kernel (init/main.c:557):
  ├─ 阶段1 准备: boot_cpu_init/banner/关中断
  ├─ 阶段2 setup_arch ★FDT解析/内存账本/cmdline
  ├─ 阶段3 mm_init ★分配器就位(kmalloc能用)
  ├─ 阶段4 调度+中断+开中断
  └─ 阶段5 VFS+rest_init ★fork出PID 1/2, 自己变idle (Day5展开)
```

## 一、`__primary_switched`（head.S:411~460）逐行

### 函数入口条件

源码注释："executed with the MMU enabled. x0 = __PHYS_OFFSET"。进来时 MMU 已开、PC 在高虚拟地址、x0=RAM物理基址。**这是从"纯汇编物理地址世界"切换到"C 虚拟地址世界"的过渡函数**。

### 第 1 段：建内核栈

```asm
	adrp	x4, init_thread_union      // x4 = union起始(低地址, task_struct处)
	add	sp, x4, #THREAD_SIZE       // sp = union+16KB = 栈顶(高地址)
```

**追问答疑①：init_thread_union / THREAD_SIZE / 栈布局**

- `init_thread_union` 是 PID 0 的 `union thread_union` 实例（`init/init_task.c`），16KB（THREAD_SIZE）
- union 定义（`sched.h:1674`）：
  ```c
  union thread_union {
      struct task_struct task;                  // 进程描述符, 占union起始(最低地址)
      struct thread_info thread_info;           // 4.19 arm64 嵌进task_struct, 不独立
      unsigned long stack[THREAD_SIZE/sizeof(long)]; // 栈数组, 名义占满整个16KB
  };
  ```
- **布局**：task_struct 在低地址固定不动，栈从高地址（union+THREAD_SIZE）**向下生长**（满递减栈, full-descending）。两者共用 16KB，中间空闲
- **溢出检测**：栈太深会踩进 task_struct——`start_kernel` 第一行 `set_task_stack_end_magic` 在交界处放魔数，每次调度回来检查，被踩即 panic
- `__primary_switched` 两行：第一条取 task_struct 那头（`adrp x4`），第二条把 sp 设到栈那头（`add sp, #THREAD_SIZE`）——一低一高，正是 union 两成员各自位置
- **为什么 union 共用起始不覆盖**：会覆盖，但**同一时刻只用一个区域**——栈往下长不碰 task_struct，直到溢出（这正是栈溢出检测能成立的前提）

### 第 2 段：sp_el0 ← init_task（current 机制）

```asm
	adr_l	x5, init_task
	msr	sp_el0, x5
```

**追问答疑②：task_struct / sp_el0 / current**

- `task_struct`：进程描述符，一个进程一个，几百字节。含 PID、状态、调度信息、`mm_struct*`、`files_struct*`、信号、寄存器保存区等。Linux 进程模型核心
- `sp_el0`：ARM64 系统寄存器之一。本意是 EL0 栈指针，Linux 借它**存当前进程的 task_struct 地址**（内核态用 sp_el1 作栈，sp_el0 空出来挪用）
- `current` 宏（`current.h:14`）：
  ```c
  static __always_inline struct task_struct *get_current(void) {
      unsigned long sp_el0;
      asm("mrs %0, sp_el0" : "=r"(sp_el0));
      return (struct task_struct *)sp_el0;
  }
  #define current get_current()
  ```
- **完整链路**：进程切换时调度器把新进程 task_struct 地址写进 sp_el0 → 之后 `current` 宏读 sp_el0 → 拿到当前进程 → 取 `current->pid`/`current->mm` 等。**ARM64 上读 current 是一条 mrs 指令，比 x86 通过 gs 段还快**
- 这一行 `msr sp_el0, x5` 把 PID 0 的 task_struct 装进去——**从此 current 能用了，C 代码靠 current 的前提就是这一步**

### 第 3 段：异常向量表

```asm
	adr_l	x8, vectors
	msr	vbar_el1, x8
	isb
```

装异常向量表基址到 VBAR_EL1。此后同步异常/IRQ/SError 跳到 vectors 对应槽位执行。在这之前 VBAR_EL1 是 U-Boot/BL31 留下的旧值——内核自己的异常处理（中断、页错误、syscall）全靠这一步生效。`isb` 保证写入对后续指令可见（异常随时来必须立刻生效）。

### 第 4 段：建栈帧

```asm
	stp	xzr, x30, [sp, #-16]!    // push {0, lr}, sp-=16
	mov	x29, sp                  // 帧指针
```

AAPCS64 函数序言——栈上压一个空帧（x29=0, x30=lr），x29 指向它，构成栈回溯链起点。

**追问答疑④：为什么建栈帧？最后又清 x29/x30 不冗余吗？**

- 第 4 段建栈帧：让**此刻栈结构合法**。在这之前 sp 指向栈顶末端无任何内容（空栈）。建帧后栈上有了第一格、x29 指向它，C 调用（`bl __pi_memset`）的函数序言会再压一层帧链到 x29 上——若 x29 起始是垃圾，栈回溯会追到非法地址
- 第 9 段清 x29/x30：在 `b start_kernel` 前清理战场，**标识"栈底、不返回"**。backtrace 算法沿 x29→上一帧回溯，遇到 x29=0 即停止；x30=0 告诉 backtrace"此函数无返回地址"（`b start_kernel` 不返回）
- **两者目的不同不冗余**：第 4 段为"中间 C 调用有合法栈帧"，第 9 段为"清理启动栈、告诉后续 backtrace 到此为止"

### 第 5 段：存 FDT 指针

```asm
	str_l	x21, __fdt_pointer, x5
```

x21 是 `preserve_boot_args` 保存的 U-Boot 传来的 FDT 指针，存进全局变量 `__fdt_pointer`，供 `setup_arch` 里 `setup_machine_fdt` 解析设备树。**U-Boot 和内核之间设备树交接的落地点**。

**追问答疑③：str_l 的 x5 干嘛的 / FDT 是什么**

- `str_l` 是宏（`assembler.h:265`），需三个参数：
  ```asm
  .macro str_l, src, sym, tmp
      adrp \tmp, \sym              // tmp = sym所在页基址
      str  \src, [\tmp, :lo12:\sym] // *(tmp + sym低12位) = src
  .endm
  ```
  x5 是 `tmp` 工具人——`adrp` 取地址需要个临时寄存器，调用方不在乎它最后的值。这就是 `str_l` 比 `str` 多一个参数的原因
- **FDT/DTB/DTS 关系**：
  - DTS（Device Tree Source）= 文本源码（`.dts`板级 + `.dtsi`公共部分，人写）
  - DTB（Device Tree Blob）= dtc 编译 DTS 的二进制产物（`.dtb`）
  - FDT（Flattened Device Tree）= DTB 的别名，强调扁平结构。内核 `fdt_*` 函数处理的就是 DTB
  - `__fdt_pointer` 存的是 DTB 在内存中的地址（一个指针），指向那块二进制数据

**追问答疑⑤：DTB 加载方式**

- DTB 由 dtc 编译期生成（`make dtbs`），U-Boot 不"压缩"只"搬运"：开机时 `fatload` 把现成 `.dtb` 文件读到内存、把地址告诉内核
- U-Boot 可选地 `fdt_fixup`（修改几个字段如 chosen/bootargs/bootcount），不是从无到有生成
- 加载方式：① 打包进 boot 镜像由 bootcmd 自动 fatload ② 在 U-Boot 命令行手动 `fatload`/`tftpboot` 到任意地址再 `booti` 指定（调试常用）
- ARM64 boot protocol：booti 把 DTB 地址塞进 x2 寄存器 → preserve_boot_args 存 x21 → __primary_switched 存 __fdt_pointer → setup_arch 解析

### 第 6 段：算 kimage_voffset（Day2 已深挖）

```asm
	ldr_l	x4, kimage_vaddr
	sub	x4, x4, x0
	str_l	x4, kimage_voffset, x5
```

虚拟基址 − 物理基址 = VA↔PA 换算差。Day2 已透，此处不重复。

### 第 7 段：清 BSS

```asm
	adr_l	x0, __bss_start
	mov	x1, xzr
	adr_l	x2, __bss_stop
	sub	x2, x2, x0
	bl	__pi_memset               // memset(0, 0, len)
	dsb	ishst                     // 内共享写屏障: 清零对页表遍历器可见
```

BSS 是"未初始化全局变量"区，C 标准要求初值 0。链接器不在镜像里存 0（省空间），启动时内核自己清。`dsb ishst` 保证清零对 PTW 可见，否则 PTW 读 BSS 变量可能拿到旧垃圾。

### 第 8 段：KASLR（你配置不走）

```asm
#ifdef CONFIG_RANDOMIZE_BASE
	tst	x23, ~(MIN_KIMG_ALIGN - 1)
	b.ne	0f
	mov	x0, x21
	bl	kaslr_early_init          // 解析FDT的kaslr-seed
	cbz	x0, 0f
	orr	x23, x23, x0
	ldp	x29, x30, [sp], #16
	ret	                           // 返回__primary_switch走重建表路径
0:
#endif
```

Day2 已讲：解析 FDT 拿随机种子，若有偏移则 `ret` 回 `__primary_switch` 重建页表；无偏移继续往下。你的配置整段不编译。

### 第 9 段：进 C 世界

```asm
	add	sp, sp, #16              // 退掉第4段压的栈帧
	mov	x29, #0                   // 帧指针清零(标识栈底)
	mov	x30, #0                   // lr清零(标识不返回)
	b	start_kernel              // ★进入C代码主入口, 不返回
```

清理栈帧、清帧指针和 lr（backtrace 到此停止）、`b start_kernel` 跳进 C 代码主入口。

## 二、`start_kernel`（init/main.c:557）五阶段骨架

**不展开单阶段内部实现**（setup_arch 在 Day4、rest_init 在 Day5、initcall 在 Day6、rootfs 在 Day7）。本日只到"每阶段干什么 + 为什么这个顺序"的粒度。

### 阶段 1：启动准备

```c
set_task_stack_end_magic(&init_task)  // 栈溢出哨兵(对应第1段union布局)
smp_setup_processor_id()              // 记下boot CPU的ID
cgroup_init_early()
local_irq_disable()                   // ★关中断(对称收口在阶段4末尾)
early_boot_irqs_disabled = true
boot_cpu_init()                       // 标记boot CPU为online
page_address_init()
pr_notice("%s", linux_banner)         // 串口第一行Linux banner
```

**为什么开头就关中断**：中断处理依赖的机制（描述符/调度器/软中断）全没初始化，此时来一个中断就崩。**关中断→开中断**这对括号中间夹的正是"所有中断依赖项就位"的过程。

### 阶段 2：架构相关（★Day4 展开）

```c
setup_arch(&command_line)   // arch/arm64/kernel/setup.c
```

四类事（今天只到粒度，不展开）：
- `setup_machine_fdt(__fdt_pointer)`：解析 DTB 认识硬件（CPU 几个/内存多大在哪/外设清单）
- memblock 建立：DTB 的 memory 节点 → 早期内存账本
- boot_command_line 解析：bootargs
- early fixmap：早期固定映射（解析过程本身要访问内存/IO，先得有最小映射）

**为什么排第二**：它认识硬件（尤其内存账本），后面一切初始化都要分配内存——不知道有多少内存、哪些能用什么都干不了。必须排在 mm_init 之前，因为 mm_init 建页表需要的内存信息就来自 setup_arch 扫出的 memblock。

### 阶段 3：内存管理初始化

```c
build_all_zonelists(NULL)   // 物理内存划zone(NORMAL/DMA/highmem)+分配链表
page_alloc_init()
mm_init()                   // ★buddy/slab/vmalloc从此kmalloc能用
```

**mm_init 之后解锁的能力**：kmalloc、kmem_cache_alloc、vmalloc、page_alloc——所有"动态分配内存"的 API。

**为什么排第三**：调度器、中断、VFS 每一个都要 kmalloc（中断描述符/调度队列/dentry cache）。顺序就是依赖序：先有账本（阶段2）→ 再有分配器（阶段3）→ 才轮到用分配器的人（阶段4、5）。

### 阶段 4：调度与中断 + 开中断收口

```c
sched_init()               // 调度器(runqueue/调度类)
preempt_disable()          // 禁抢占(直到cpu_idle)
workqueue_init_early()
rcu_init()
context_tracking_init()
early_irq_init()           // 中断描述符数组
init_IRQ()                 // 架构中断控制器(GIC)接线
tick_init()
init_timers()
hrtimers_init()
softirq_init()
timekeeping_init()         // 系统时钟
time_init()                // 架构时钟(读DTB时钟频率——用阶段2成果)
...
local_irq_enable()         // ★开中断(对称收口阶段1的disable)
```

**为什么这样排列**：

- **关中断/开中断是 start_kernel 最紧的顺序约束**。开中断的时刻 = 中断依赖项全部就位的时刻
- 调度器排在中断前：timer 中断会触发 `scheduler_tick`，调度器没就位 timer 中断就是炸弹
- `time_init` 读 DTB 时钟频率——没它 timer 不知道多久滴答一次，所以在 tick 之后、开中断之前

### 阶段 5：VFS / rest_init（★Day5 展开）

```c
vfs_caches_init()          // dentry/inode缓存
buffer_init()              // 块设备缓冲
...
rest_init()                // ★start_kernel最后一行
```

**`rest_init` 干的事**（今天只记骨架，Day5 展开）：

```c
rest_init():
    kernel_thread(kernel_init, ...)    // PID 1(将来exec成init/用户空间)
    pid = kernel_thread(kthreaddr, ...) // PID 2(内核线程守护者)
    cpu_startup_entry(CPUHP_ONLINE)    // 自己变PID 0 idle(永久空闲循环)
```

**为什么这样收尾**：start_kernel 是一条线程跑完的（启动 CPU 这条执行流，PID 0）。一个线程不能既当 idle 又当 init，所以最后 fork 出 PID 1/2 分工，自己降级为 idle。**从这里开始内核进入"多线程时代"**——之前所有代码都是单线程串行的。

## 三、五阶段顺序总纲（画图时标注的依赖箭头）

```text
阶段1 准备(关中断/标记boot CPU/打banner)
  ↓ 关中断保护后面所有初始化
阶段2 setup_arch(认识硬件+内存账本+bootargs)
  ↓ mm_init 要内存信息
阶段3 内存(分配器就位)
  ↓ 调度/中断/VFS 全要 kmalloc
阶段4 调度+中断(就位后开中断)
  ↓ VFS/workqueue 要调度和中断
阶段5 VFS+rest_init(fork出PID 1/2, 自己变idle)
```

一句话记忆链：**关中断 → 认硬件 → 建分配器 → 建调度/中断后开中断 → 分家（PID 0/1/2）**。

## 四、闭卷考核标准答案

**Q1 `__primary_switched` 建立了 C 环境的哪几样东西？**
六样：① 内核栈 sp=init_thread_union+THREAD_SIZE（C 函数靠栈传参/局部变量）② sp_el0←init_task（current 机制基础）③ VBAR_EL1←vectors（异常向量表）④ __fdt_pointer←x21（设备树落变量）⑤ kimage_voffset（VA↔PA 换算基准）⑥ 清 BSS（C 全局变量初值要求）。做完这六样才有资格 `b start_kernel`。

**Q2 从 stext 到 start_kernel，每步各解决什么问题？**
preserve_boot_args 保存启动参数（FDT→x21）；el2_setup 处理异常级别；set_cpu_boot_mode_flag 记录 EL；__create_page_tables 建两棵页表；__cpu_setup 配 TCR/MAIR 备 SCTLR 值；__enable_mmu 装 TTBR+开 MMU；__primary_switched 建 C 环境（栈/current/向量表/FDT/voffset/BSS）；b start_kernel 进 C 主入口。

**Q3 start_kernel 五阶段各自做什么、为什么是这个顺序？**
① 准备（关中断保护后续）→ ② setup_arch（认硬件+内存账本+bootargs，是分配器的前提）→ ③ mm_init（分配器就位，是后续所有 kmalloc 的前提）→ ④ 调度+中断+开中断（关/开中断是最紧约束，开中断时刻=中断依赖项全部就位）→ ⑤ VFS+rest_init（fork 出 PID 1/2，自己变 PID 0 idle，进入多线程时代）。依赖链：硬件账本→分配器→调度/中断→VFS。

**Q4 关中断/开中断夹在 start_kernel 哪两处？为什么？**
开头 `local_irq_disable`（阶段1），阶段4 末尾 `local_irq_enable`。中间夹着的是所有中断依赖项的就位过程：中断描述符、GIC 接线、调度器、软中断、timer、时钟——这些没就位就来一个中断直接崩。开中断时刻 = 它们全部就位的时刻。

**Q5（验收）画汇编入口到 C 入口完整调用图。**
见本笔记第〇节"全局定位"的 ASCII 图——从 U-Boot booti → stext 八步 → __primary_switched 七步 → start_kernel 五阶段 → rest_init。重点标注：① 物理地址视角 vs 虚拟地址视角的分界（br __primary_switched）② 关/开中断的括号（阶段1~阶段4 末）③ rest_init 的三分家（PID 0/1/2）。

## 五、本日踩坑/易混点

1. `init_thread_union` 是 union 不是 struct，task_struct 和 stack **共用** 16KB（不是各占 16KB）。THREAD_SIZE 是 union 总大小，栈可用空间 = THREAD_SIZE − sizeof(task_struct)
2. 栈向下生长（满递减），task_struct 在低地址不动，栈从高地址往低逼近——栈溢出踩 task_struct 是 union 共用起始的"特性"（栈溢出检测能成立的前提）
3. `sp_el0` 不是"用作栈"——它被 Linux 借用存 current 的 task_struct 指针。内核态用 sp_el1 作栈
4. `str_l` 比 `str` 多一个 tmp 参数：adrp 取地址需要临时寄存器，调用方提供一个可破坏的
5. 第 4 段建栈帧 vs 第 9 段清 x29/x30 不冗余：前者为"中间 C 调用有合法栈帧"，后者为"清理启动栈、告诉 backtrace 到此为止"
6. FDT=DTB（同义，DTB 是文件后缀，FDT 是内核源码里的命名），DTS 是源码文本。U-Boot 不"压缩"DTB，只搬运
7. 五阶段顺序本质是依赖序：硬件账本→分配器→调度/中断→VFS。任何一阶段往前挪都会因前置未就绪而崩

## 六、明日（Day4）

`setup_arch` 深入：`setup_machine_fdt` 解析 DTB 的具体过程（节点/属性/memory 节点→memblock/chosen 节点→bootargs/pinctrl 等），对照鲁班猫2 的 `rk3568-lubancat-2.dts`。
