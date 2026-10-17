# RK3568 Linux 启动链——面试脱稿版

> 从 U-Boot 跳入内核到 CPU 第一次进入用户态（EL0）执行 init 的完整链路。
> 面试时按这条线脱稿讲，每一步带"干了什么 + 为什么在这个位置"。
> 源码基准：Rockchip 4.19（arch/arm64/kernel/head.S + init/main.c + drivers/of/fdt.c + drivers/base/）。

## 一句话版

U-Boot 把 Image 和 DTB 加载到内存后跳入 `stext`，内核在物理地址上建两棵页表（恒等映射 + 内核高地址映射）并开启 MMU，跳到高虚拟地址执行 `start_kernel`；`start_kernel` 解析 DTB 建立 memblock 和 device_node 树、初始化内存/调度/中断子系统，最后调 `rest_init` 创建 PID 1（init）和 PID 2（kthreadd），自己变成 PID 0 idle；PID 1 跑 `do_initcalls` 注册全部驱动并 probe，挂载 rootfs，最后 `do_execve("/sbin/init")` 把自己从内核线程变成用户进程——CPU 从 EL1 进入 EL0，用户世界开始。

## 完整链路（脱稿讲这条线）

### 第一阶段：汇编入口（物理地址视角，MMU 关闭）

```text
U-Boot booti → stext (head.S:120)
```

**1. preserve_boot_args**——保存 U-Boot 传入的 x0~x3：x0 是 DTB 地址（后面存进 x21）、x2 也是 DTB、x1/x3 是 task ID/FDT 大小。存到栈上供后续用。

**2. el2_setup**——判断 CPU 进入内核时的异常级别（EL1 还是 EL2）。如果从 EL2 进入且不开 VHE：配置 EL2 的 CPTR_EL2/VBAR_EL2 等、处理协处理器陷阱权限，然后 `eret` 降到 EL1 运行内核（Linux 正常运行在 EL1）。如果开 VHE 则留在 EL2 用虚拟化寄存器别名。**返回值 w0 = 进入时的 EL（EL1 或 EL2），供后续保存**。

**3. set_cpu_boot_mode_flag**——把 w0（进入时的 EL）存进 `__boot_cpu_mode`（位于 `.mmuoff.data.write` 段，MMU 关闭时可物理写入）。运行时用它校验页表是否踩了这块内存。

**4. __create_page_tables**——建两棵页表树：
- **idmap_pg_dir**（恒等映射，VA==PA）：映射 `.idmap.text` 段（含 `__enable_mmu`/`__primary_switch`），保证开 MMU 瞬间 PC 数值不变、翻译结果也不变、取指无缝
- **swapper_pg_dir**（内核映射，VA=KIMAGE_VADDR 高地址→PA=内核物理基址）：映射整个内核镜像，是 C 代码的正式地址空间

建表流程：inval Cache（防旧脏行覆盖新表）→ 清零（0=invalid）→ `map_memory` 四级流水（L0→L1→L2 填目录项 PMD_TYPE_TABLE，L3 填叶子项 phys|SWAPPER_MM_MMUFLAGS）→ 填完再 inval（防投机加载的过时 Cache 行）。

**5. __cpu_setup**（proc.S:466）——配置 MMU 规则但不开启：
- 清 TLB → 开 FP/ASIMD → 填 MAIR_EL1（8 个内存属性槽：Device/Normal 等）→ 配 TCR_EL1（T0SZ/T1SZ=48/48 划分 TTBR0/TTBR1 范围）并立即写入 → 算好 SCTLR_EL1_SET（M 位=1 开 MMU、C 位=1 D-Cache、I 位=1 I-Cache）放进 **x0 返回但不写入 SCTLR**

**6. __primary_switch → __enable_mmu**（head.S:769）——开启 MMU：
- 检查 CPU 支持 4KB 页 → `TTBR0 ← idmap_pg_dir`、`TTBR1 ← swapper_pg_dir` → `isb` → `msr sctlr_el1, x0`（x0 = __cpu_setup 备好的 SCTLR_EL1_SET，M 位置 1）→ **MMU 从这一刻开启**
- `ic iallu` 清 I-Cache（旧物理视角取的指令全作废）
- **为什么不 fault**：`__enable_mmu` 这段代码在 `.idmap.text` 段 + idmap 树有 VA==PA 恒等映射 + TTBR0 指向 idmap 树 → 开 MMU 后 PC 数值不变、按虚拟解释、恒等映射翻译回同一物理地址 → 取指连续

之后 `br __primary_switched` 跳到高虚拟地址（0xffff8000…），走 TTBR1/swapper 树——**从此进入内核正式地址空间**。

### 第二阶段：过渡——建立 C 运行环境

```text
__primary_switched (head.S:411, 高虚拟地址执行)
```

七件事建立 C 运行环境：
1. **设内核栈**：`sp = init_thread_union + THREAD_SIZE`（栈在高地址往下长，task_struct 在 union 起始）
2. **sp_el0 ← init_task**：ARM64 借 sp_el0 存 current 的 task_struct 指针，`current` 宏读 sp_el0 一条 mrs 指令
3. **VBAR_EL1 ← vectors**：装异常向量表，此后中断/页错误/syscall 跳到内核 handler
4. **存 __fdt_pointer ← x21**：U-Boot 传来的 DTB 地址落全局变量，供 setup_arch 解析
5. **算 kimage_voffset**：`kimage_vaddr`（链接期写死的虚拟基址）− `__PHYS_OFFSET`（adrp 在物理 PC 下取的 RAM 基址）= VA↔PA 换算差，供 `__pa()`/`__va()` 用
6. **清 BSS**：C 全局变量要求初值 0，链接器不在镜像里存 0（省空间），内核自己清
7. **`b start_kernel`**：进入 C 代码主入口，不返回

### 第三阶段：start_kernel 五阶段

```text
start_kernel (init/main.c:557, 虚拟地址视角)
```

**阶段 1：准备**——`local_irq_disable`（关中断，中断依赖项还没就位）→ `boot_cpu_init`（标记 boot CPU 在线）→ `pr_notice(linux_banner)`（串口第一行输出，靠 earlycon）

**阶段 2：架构相关 setup_arch** ★
- `early_fixmap_init`：在 swapper 树里为 fixmap 区补建 L0→L1→L2 目录链（指向 .bss 预预留的 bm_pud/bm_pmd/bm_pte），之后改一个 PTE 就能映射
- `setup_machine_fdt(__fdt_pointer)`：`fixmap_remap_fdt` 把 DTB 映射到 FIX_FDT 槽位 → `memblock_reserve` 保护 DTB 物理内存 → `early_init_dt_scan` 三扫：
  - 扫根节点：model/compatible
  - 扫 memory 节点：reg → `memblock_add(base, size)`（板子 `<0 0 0 0x40000000>` → memblock_add(0, 1GB)）
  - 扫 chosen 节点：bootargs → `boot_command_line`（全局 char[2048]）
- `parse_early_param`：解析 bootargs 里的 earlycon=（★earlycon 在此激活：注册只写/轮询/无中断的极简串口驱动，经 fixmap 的 FIX_EARLYCON 直写 UART TX 寄存器）
- `arm64_memblock_init`：memblock 加工（截 PA 位、保留内核镜像/PID0 栈、记 memstart_addr）
- `unflatten_device_tree`：两遍扫描（dryrun 算大小 → memblock 一大块 → 游标切割）→ `populate_node` 五步（读名/切[结构体+名]/头插挂树/属性尾插且 name/value 直接引用 DTB 原文/回填快捷指针）→ device_node 树挂全局 of_root

**阶段 3：内存管理**——`build_all_zonelists`（zone 链表）→ `mm_init`（buddy/slab/vmalloc 就位，kmalloc 能用）

**阶段 4：调度与中断**——`sched_init`（调度器）→ `early_irq_init`/`init_IRQ`（GIC 接线）→ `tick_init`/`softirq_init`/`timekeeping_init`/`time_init` → `local_irq_enable`（★开中断，对称收口阶段 1 的 disable——开中断时刻 = 中断依赖项全部就位）

**阶段 5：VFS + rest_init**——`vfs_caches_init`（dentry/inode 缓存）→ `rest_init`（★最后一行）

### 第四阶段：rest_init——多线程时代开始

```text
rest_init (init/main.c:397)
```

**三件套**：
1. `kernel_thread(kernel_init)` → 创建 PID 1（先创建=占号，此时未运行）→ 钉在 boot CPU
2. `kernel_thread(kthreadd)` → 创建 PID 2（内核线程母亲，存全局 kthreadd_task）
3. `complete(&kthreadd_done)` → 放行 PID 1（它在 `kernel_init_freeable` 里 `wait_for_completion` 等 kthreadd 就位——PID 1 后续 do_initcalls 要创建内核线程，kthreadd 没就位就 OOPS）

→ `schedule_preempt_disabled()` ★**第一次真正的 schedule**——之前所有代码都是单线程串行，这一调调度器从就绪队列挑下一个任务（PID 1 或 2）切过去——**多线程时代从此开始**

→ `cpu_startup_entry → do_idle()` → PID 0 变 idle（永久空闲循环，WFI 等中断，永不退出）

### 第五阶段：PID 1 kernel_init——驱动注册 + rootfs + exec init

```text
kernel_init (init/main.c)
```

**5.1 kernel_init_freeable → do_basic_setup → do_initcalls**

`do_initcalls` 按级别 0→7 遍历所有 initcall 链接段（`.initcall0.init` ~ `.initcall7.init`）逐个调函数指针：

- `module_init(fn)` 宏编译期把 fn 的函数指针塞进 `.initcall6.init` 段（device 级，90% 驱动在这级）
- 八级层次 = 依赖拓扑序：i2c 总线（subsys 级 4）必须先于 sensor 驱动（device 级 6）

关键级别：
- **postcore 级（2）**：`of_platform_populate` 遍历 device_node 树，给有 compatible 的节点建 platform_device，`dev.of_node` 指回 device_node，`device_private_init` 分配 dev->p
- **fs 级（5）**：ext4 注册 + `populate_rootfs`（initramfs 的 cpio 解包进内存 rootfs）
- **device 级（6）**：★驱动注册

**5.2 驱动注册 → 匹配 → probe 全链路**（以你板子 UART 的 8250_dw.c 为例）

```text
module_platform_driver(dw8250_platform_driver)
  → module_init → do_initcall_level(6)调init函数
  → platform_driver_register → __platform_driver_register:
      设bus=platform_bus_type, probe=platform_drv_probe(包装函数)
  → driver_register → bus_add_driver:
      分配priv, 挂总线驱动链表, sysfs建目录
      drivers_autoprobe=1 → driver_attach ★

driver_attach → 遍历总线所有device → __driver_attach:
  driver_match_device → platform_match → of_driver_match_device
  (拿驱动of_match_table和device->of_node的compatible比对)
  "rockchip,rk3568-uart" 对上 → 返回1

匹配成功 → driver_probe_device → really_probe:
  device_links_check_suppliers (依赖检查/defer)
  dev->driver = drv ★绑定!
  pinctrl_bind_pins (引脚复用,Day4学的pinctrl-0生效)
  dma_configure
  bus->probe = platform_drv_probe:
    of_clk_set_defaults (DT时钟默认)
    dev_pm_domain_attach (PM域)
    drv->probe(dev) = dw8250_probe ★你的驱动代码!
  driver_bound → device加进klist_devices, 发uevent

probe失败返回-EPROBE_DEFER → deferred_probe_pending_list → supplier就位后重试
```

**5.3 prepare_namespace（块设备 rootfs 路径）**

如果 initramfs 里有 /init 且 exec 成功 → 不进 prepare_namespace（initramfs 在 populate_rootfs 里已解包进内存 rootfs）。
否则走 prepare_namespace：

- `wait_for_device_probe`（等所有 deferred probe 跑完）
- `name_to_dev_t(saved_root_name)`：root= 的字符串 → dev_t（PARTUUID 查块设备分区表）
- `mount_root`：`ksys_mount(ROOT_DEV, "/root", "ext4", ...)` 挂到 /root（先挂子目录、验证成功后 MS_MOVE 挪到 /——安全模式）
- `ksys_mount(".", "/", MS_MOVE)` + `ksys_chroot(".")`：切根，PID 1 的 / 变成 ext4

**5.4 run_init_process——"最后一跳"**

```text
run_init_process("/sbin/init")
  → do_execve:
    PID 1的task_struct保留(pid=1不变)
    mm从NULL变成新mm_struct(用户地址空间)
    PC从kernel_init变成用户程序入口(_start→main)
    从EL1切到EL0
  ★CPU第一次进EL0 → 用户世界开始
```

五级回退找 init：initramfs /init → bootargs init= → /sbin/init → /etc/init → /bin/init → /bin/sh，全失败 `panic("No working init found")`。

### PID 2 kthreadd

`for(;;)` 睡眠等 `kthread_create_list` 有请求 → 醒来 `create_kthread`（从 kthreadd 这个"干净母体" fork，继承 ignore_signals/cpu_all_mask/PF_NOFREEZE）→ 所有 `[kworker]`/`[ksoftirqd]`/… 内核线程的母亲。

### PID 0 idle

`cpu_startup_entry → do_idle()` 永久循环：没事 WFI 等中断，中断来了处理完继续等。永不退出。你 `top` 看到的 idle% 就是它。

## 面试高频追问点

1. **MMU 怎么开的？为什么不会 fault？** → `.idmap.text` + 恒等映射 + TTBR0 指向 idmap
2. **idmap 和 swapper 区别？** → VA==PA 过渡用 vs 高地址正式空间
3. **kimage_voffset 为什么不为 0？** → 一虚（链接期 VA）一实（运行时 PA）相减
4. **设备树从 DTB 到 device_node 树全过程？** → fixmap 映射 → 三扫 → unflatten 两遍扫描
5. **驱动 probe 链路？** → platform_driver_register → bus_add_driver → driver_attach → platform_match（of_driver_match_device 比对 compatible）→ really_probe → platform_drv_probe → drv->probe
6. **PID 0/1/2 怎么产生？** → rest_init 三件套
7. **为什么内核线程通过 kthreadd 中转？** → 干净母体（避免脏调用者的信号/cgroup/CPU 亲和性）
8. **initramfs vs 块设备 rootfs？** → cpio 解进内存 rootfs（不用 mount）vs mount 块设备到 /root 再 MS_MOVE
9. **do_execve 干了什么？** → mm 从 NULL 变有、EL1→EL0、最后一跳
10. **init 找不到会怎样？** → 五级回退全失败 panic
