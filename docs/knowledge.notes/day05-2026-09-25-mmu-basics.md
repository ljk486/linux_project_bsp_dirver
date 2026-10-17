# Day 04（2026-09-21）：__boot_cpu_mode 收尾 + 物理地址/虚拟地址/MMU 最小模型

> 从 Codex 迁移的当日完整对话记录。当日主目标：`set_cpu_boot_mode_flag` 与 `__boot_cpu_mode` 闭卷收尾，
> 随后进入物理地址、虚拟地址、MMU 概念最小模型；`__create_page_tables` 留待下一课。

## 本日要点速览

- `set_cpu_boot_mode_flag` 把进入 Kernel 时的 EL（w0）写入 `__boot_cpu_mode[0]`，后 4 字节 `.long BOOT_CPU_MODE_EL1` 是错位标记，用于运行时校验页表写入是否踩内存
- 写入后 `dmb sy` 保证 Store 先于后续 Cache invalidate 对所有 CPU 可见；`ic iallu` + `dsb nsh` 清取指缓存
- `__boot_cpu_mode` 位于 `.mmuoff.data.write` section（`head.S:662`），MMU 关闭阶段可用物理视角写入
- MMU 最小模型 12 问：物理/虚拟地址、页、页表、多级页表、MMU 与页表的关系、TLB vs Cache、为何启动前 MMU 关闭、Identity Mapping（idmap）、Kernel Mapping（对话在第 12 问处中断，下次从 Kernel Mapping 继续）

# Codex 对话记录：2026-09-21（MMU 学习日）


---

## [07:42] user

继续今天的学习，今天的任务是什么


---

## [07:43] assistant

我先按项目协议读取总计划、SDK清单、最近两份笔记及最新日志，确认上次学习的验收边界，然后给出今天唯一主目标并开始。

---

## [07:44] assistant

当前状态：

- 已通过：Kernel框架、Image/DTB关系、U-Boot到Image入口、`preserve_boot_args`、`el2_setup`
- 仅理解源码，尚未编译、上板或测试
- 未开始：`set_cpu_boot_mode_flag`、页表、MMU、TLB、Cache

## 今天唯一主目标

> 理解ARM64启动时如何建立早期地址映射并开启MMU。

今天分四段：

### 1. `set_cpu_boot_mode_flag`收尾

学习真实源码：

```asm
set_cpu_boot_mode_flag:
        adr_l   x1, __boot_cpu_mode
        cmp     w0, #BOOT_CPU_MODE_EL2
        b.ne    1f
        add     x1, x1, #4
1:      str     w0, [x1]
        dmb     sy
        dc      ivac, x1
        ret
```

需要理解：

- `el2_setup`通过`w0`返回初始启动EL。
- `__boot_cpu_mode`为什么保存两个位置。
- `dmb sy`与Cache维护的作用。
- 为什么MMU开启前写入、开启后读取需要考虑Cache一致性。

### 2. 补齐内存理论基础

从零学习：

```text
物理地址
虚拟地址
页与页框
页表和页表项
多级页表
MMU
TLB
Cache
```

需要分清：

```text
MMU：虚拟地址到物理地址的翻译
TLB：缓存地址翻译结果
Cache：缓存内存中的指令和数据
```

### 3. 两种早期映射

理解为什么Kernel启动时同时需要：

```text
Identity Mapping：
虚拟地址 == 物理地址
用于开启MMU瞬间保证当前代码仍可执行

Kernel Mapping：
Kernel高虚拟地址 -> 实际物理内存
用于进入Linux正式虚拟地址空间
```

核心问题：

> 开启MMU的那一刻，CPU下一条指令为什么不会“找不到”？

### 4. 结合真实源码

依次阅读：

```text
arch/arm64/kernel/head.S::__create_page_tables
arch/arm64/mm/proc.S::__cpu_setup
arch/arm64/kernel/head.S::__primary_switch
arch/arm64/kernel/head.S::__enable_mmu
```

最终形成：

```text
创建早期页表
-> 设置内存属性和地址转换控制
-> 设置页表基址
-> 开启MMU
-> 切换到Kernel虚拟地址
-> 准备进入start_kernel()
```

## 今日验收

闭卷回答：

1. 物理地址和虚拟地址有什么区别？
2. MMU、TLB、Cache分别做什么？
3. 为什么使用多级页表？
4. Identity Mapping是什么？
5. 为什么开启MMU前必须准备恒等映射？
6. Kernel Mapping解决什么问题？
7. `__create_page_tables`和`__cpu_setup`分别负责什么？
8. MMU开启瞬间，CPU如何连续执行下一条指令？

今天先从`set_cpu_boot_mode_flag`开始，然后进入物理地址与虚拟地址。编译和实板测试仍不属于今天任务。

---

## [07:48] user

开始今天的学习，第一个学什么


---

## [07:49] assistant

第一个学习：

> **`set_cpu_boot_mode_flag`如何保存`el2_setup`的结果，以及为什么要做内存屏障和Cache维护。**

它是`el2_setup`与页表/MMU之间的连接点。

## 1. 调用位置

真实源码：

```text
kernel/arch/arm64/kernel/head.S
```

`stext`中的顺序：

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

`el2_setup`返回时：

```text
w0 = BOOT_CPU_MODE_EL1
或者
w0 = BOOT_CPU_MODE_EL2
```

然后调用：

```asm
bl set_cpu_boot_mode_flag
```

## 2. 完整源码

```asm
/*
 * Sets the __boot_cpu_mode flag depending on the CPU boot mode passed
 * in w0. See arch/arm64/include/asm/virt.h for more info.
 */
set_cpu_boot_mode_flag:
        adr_l   x1, __boot_cpu_mode
        cmp     w0, #BOOT_CPU_MODE_EL2
        b.ne    1f
        add     x1, x1, #4
1:      str     w0, [x1]
        dmb     sy
        dc      ivac, x1
        ret
ENDPROC(set_cpu_boot_mode_flag)
```

## 3. 取得保存区域地址

```asm
adr_l x1, __boot_cpu_mode
```

`adr_l`是Linux ARM64汇编宏，用于将符号的完整地址放入寄存器。

执行后：

```text
x1 = &__boot_cpu_mode
```

`__boot_cpu_mode`不是CPU寄存器，而是Kernel内存中的全局数据区域。

后续Kernel通过它判断启动CPU最初来自EL1还是EL2。

## 4. 为什么EL2要偏移4字节？

```asm
cmp     w0, #BOOT_CPU_MODE_EL2
b.ne    1f
add     x1, x1, #4
```

逻辑：

```c
x1 = &__boot_cpu_mode;

if (w0 == BOOT_CPU_MODE_EL2)
    x1 += 4;
```

因此保存布局类似：

```text
__boot_cpu_mode + 0：EL1启动记录
__boot_cpu_mode + 4：EL2启动记录
```

每个记录是32位，因为使用：

```asm
w0
str w0
```

而不是64位的`x0`。

这种布局可以让Kernel后续检查：

- Boot CPU以哪个EL进入。
- 其他CPU启动时模式是否一致。
- 是否具备可用EL2。
- 是否可能支持KVM。

## 5. 写入启动模式

```asm
str w0, [x1]
```

`str`是Store Register。

含义：

```text
将w0中的32位值
写到x1指向的内存
```

如果从EL1进入：

```text
[__boot_cpu_mode + 0] = BOOT_CPU_MODE_EL1
```

如果从EL2进入：

```text
[__boot_cpu_mode + 4] = BOOT_CPU_MODE_EL2
```

## 6. 为什么需要`dmb sy`？

```asm
dmb sy
```

`dmb`是Data Memory Barrier。

它保证：

> 这条屏障之前的内存访问，在全系统可观察顺序上先于屏障之后的相关内存访问。

这里是确保：

```asm
str w0, [x1]
```

的写入在后续Cache维护之前完成。

`sy`表示Full System作用域。

不能简单理解成：

```text
dmb = 把Cache数据全部写入内存
```

它主要保证内存操作顺序，并不等同于清空Cache。

## 7. 为什么需要Cache维护？

```asm
dc ivac, x1
```

含义：

```text
Data Cache Invalidate by Virtual Address to Point of Coherency
```

大致作用是对`x1`所在Cache line执行失效处理，避免后续使用不同地址映射读取时看到旧值。

源码注释：

```asm
// Invalidate potentially stale cache line
```

当前仍处于MMU正式启用前后的特殊转换阶段：

```text
现在通过早期地址访问并写入
-> 稍后开启MMU
-> 通过Kernel虚拟地址读取
```

同一个物理内存可能在启动切换前后通过不同地址访问。

如果Cache中保留了旧映射对应的陈旧Cache line，后续Kernel可能读不到刚写入的启动模式。

所以这里执行：

```text
先写入启动模式
-> dmb保证顺序
-> Cache line失效
-> MMU开启后重新读取正确内容
```

第一轮不需要深入PoC、Cache别名和一致性协议，先理解：

> MMU开启前后地址表示会变化，因此必须避免旧Cache内容污染后续读取。

## 8. 返回

```asm
ret
```

返回`stext`，随后执行：

```asm
bl __create_page_tables
```

完整关系：

```text
el2_setup
-> w0返回初始启动EL
-> set_cpu_boot_mode_flag
-> 保存到__boot_cpu_mode
-> 做内存顺序和Cache维护
-> __create_page_tables
```

## 当前需要记住

```text
el2_setup：
判断并整理异常级别，返回启动模式

set_cpu_boot_mode_flag：
把启动模式保存到Kernel全局区域，确保MMU切换后仍能正确读取
```

### 小测

1. 为什么保存的是“进入Kernel时的EL”，而不是函数结束后的EL？
2. `dmb sy`和`dc ivac`分别解决什么问题？
3. 为什么EL2记录写在`__boot_cpu_mode + 4`？

回答这三题后，我们进入物理地址和虚拟地址。

---

## [08:51] user

1.不知道2.dmb是让dmb前的内存存读都完成后才能再次对内存读存操作。dcivac不知道是为了什么3.是由段的排布决定的


---

## [08:52] assistant

你的第2题已经抓到一半；第3题“由排布决定”太泛。为了准确说明为什么偏移4字节，我先读取`__boot_cpu_mode`的真实定义和后续使用位置，再结合源码纠正三题。

---

## [08:53] assistant

真实定义确认了：`__boot_cpu_mode`是两个`u32`元素，初始值故意一格写EL2、一格写EL1。接下来根据这个设计解释你的答案。

---

## [08:54] assistant

## 1. 为什么保存“进入Kernel时的EL”？

因为Linux需要知道：

```text
启动时是否获得了EL2能力
```

这会影响后续虚拟化能力判断。

真实定义在：

```text
arch/arm64/include/asm/virt.h
```

```c
extern u32 __boot_cpu_mode[2];
```

后续判断：

```c
return (__boot_cpu_mode[0] == BOOT_CPU_MODE_EL2 &&
        __boot_cpu_mode[1] == BOOT_CPU_MODE_EL2);
```

也就是说，Kernel会检查两个槽位是否都变成EL2，以判断启动CPU是否以一致的EL2模式进入。

如果只记录`el2_setup`结束后的当前级别：

```text
从EL2进入，非VHE
-> 最终切到EL1
-> 记录成EL1
```

Kernel就会丢失“启动时曾经获得EL2”的信息，无法正确判断虚拟化能力。

所以记录的是：

```text
Kernel入口时的CPU模式
```

而不是：

```text
el2_setup返回时的当前位置
```

## 2. `dmb sy`与`dc ivac`

你的`dmb`理解方向正确，但“全部完成后才能再次操作”稍显绝对。

### `dmb sy`

```asm
dmb sy
```

保证屏障前的内存访问，在全系统观察顺序上先于屏障后的内存访问。

这里确保：

```asm
str w0, [x1]
```

先于随后的Cache维护生效。

可以理解为：

```text
先确认“写启动模式”这件事排在前面
再执行针对该地址的Cache操作
```

它主要保证**内存访问顺序**，并不等于清空所有Cache。

### `dc ivac, x1`

```asm
dc ivac, x1
```

是对`x1`所在的Data Cache line执行：

```text
Invalidate by Virtual Address to Point of Coherency
```

这里的目的来自源码注释：

```asm
// Invalidate potentially stale cache line
```

当前还处于MMU开启前后的特殊启动阶段。相同物理内存之后可能通过Kernel虚拟地址读取。

如果Cache中保存着该位置的旧副本，MMU开启后可能读到陈旧值。因此：

```text
写入启动模式
-> dmb保证顺序
-> 失效可能陈旧的Cache line
-> 后续重新从一致位置取得正确数据
```

当前先记：

```text
dmb sy：保证写入与后续Cache操作的顺序
dc ivac：使这个地址对应的旧Data Cache line失效
```

Cache一致性的精确细节会在今天的MMU/Cache部分继续学。

## 3. 为什么EL2偏移4字节？

不是普通“段排布”决定的，而是这个数据结构的明确设计。

真实C声明：

```c
extern u32 __boot_cpu_mode[2];
```

真实汇编初始值：

```asm
ENTRY(__boot_cpu_mode)
        .long   BOOT_CPU_MODE_EL2
        .long   BOOT_CPU_MODE_EL1
```

内存布局：

```text
__boot_cpu_mode + 0：u32槽位0，初始EL2
__boot_cpu_mode + 4：u32槽位1，初始EL1
```

代码：

```asm
cmp     w0, #BOOT_CPU_MODE_EL2
b.ne    1f
add     x1, x1, #4
1:      str     w0, [x1]
```

结果如下：

### 从EL1启动

不加4，写槽位0：

```text
初始：[EL2, EL1]
写后：[EL1, EL1]
```

### 从EL2启动

加4，写槽位1：

```text
初始：[EL2, EL1]
写后：[EL2, EL2]
```

这样后续Kernel可以判断：

```text
[EL1, EL1]：从EL1启动
[EL2, EL2]：从EL2启动
两个值不同：CPU启动模式不一致或尚未正确记录
```

所以偏移4字节是因为：

```text
数组元素类型是u32
每个元素4字节
EL2结果写入第二个元素
```

## 修正后的三个答案

1. 保存入口EL，是为了保留Kernel是否从EL2获得虚拟化能力的信息，不能被后续切换到EL1覆盖。
2. `dmb sy`保证内存操作顺序；`dc ivac`使对应地址可能陈旧的Data Cache line失效。
3. `__boot_cpu_mode`是`u32[2]`，第二个元素相对首地址偏移4字节；特殊初始值和选择性写入让两个元素最终一致，从而编码EL1或EL2启动状态。

这三题现在可以算通过。下一步进入物理地址、虚拟地址和MMU。

---

## [09:03] user

```cpp
ENTRY(__boot_cpu_mode)
        .long   BOOT_CPU_MODE_EL2
        .long   BOOT_CPU_MODE_EL1
```

这个会放到image的.data段里吗还是硕是一个新的段，\_\_boot\_cpu\_mode的地址是链接的时候被赋予的还是自己定义的，这个地址是真实的物理地址还是虚拟地址


---

## [09:03] assistant

这个问题必须结合链接脚本确认：`__boot_cpu_mode`前后用了哪个section宏、该section在`vmlinux.lds.S`中放到哪里，以及`adr_l`在MMU关闭时如何取得可用地址。我先读取真实定义上下文和链接脚本映射。

---

## [09:05] assistant

源码已明确它不在普通`.data`，而是在专门的`.mmuoff.data.write`输入section。还需要确认链接脚本将这个输入section合并到哪个输出section，我再读取对应规则和`adr_l`宏。

---

## [09:06] assistant

## 1. 它不在普通`.data`，而是专门的Section

真实源码在`head.S:662`：

```asm
.pushsection ".mmuoff.data.write", "aw"
```

含义：

- `.pushsection`：临时切换到指定Section，并记住此前Section。
- `.mmuoff.data.write`：Section名称。
- `a`：alloc，运行时需要装入内存。
- `w`：writable，可写。
- 后面的`.popsection`恢复此前Section。

因此：

```asm
ENTRY(__boot_cpu_mode)
        .long BOOT_CPU_MODE_EL2
        .long BOOT_CPU_MODE_EL1
```

属于：

```text
.mmuoff.data.write
```

而不是普通`.data`，也不是`.bss`。

链接脚本中有独立的输出Section：

```text
arch/arm64/kernel/vmlinux.lds.S:220
```

```ld
.mmuoff.data.write : ALIGN(SZ_2K) {
        __mmuoff_data_start = .;
        *(.mmuoff.data.write)
}

.mmuoff.data.read : {
        *(.mmuoff.data.read)
        __mmuoff_data_end = .;
}
```

作用是把所有目标文件中的：

```text
.mmuoff.data.write
```

输入Section集中放入最终`vmlinux`的同名输出Section。

它会随Kernel镜像装入内存，因此也属于Image携带的数据。

## 2. 为什么单独建立这个Section？

源码注释已经说明：

```asm
/*
 * These values are written with the MMU off, but read with the MMU on.
 * Writers will invalidate the corresponding address...
 * The linker script ensures sufficient alignment...
 */
```

这类变量有特殊生命周期：

```text
MMU关闭时写入
-> MMU开启
-> 通过Kernel虚拟地址读取
```

因此需要：

- 可写
- 被加载到内存
- 有明确对齐
- 与其他Section隔离，避免Cache维护误伤其他数据

链接脚本要求：

```ld
ALIGN(SZ_2K)
```

因为启动代码执行Cache line失效时，可能影响一个Cache Writeback Granule范围。对齐可以避免这个范围覆盖相邻Section的重要数据。

## 3. 为什么不放`.bss`？

源码给出了原因：

```asm
/*
 * This is not in .bss, because we set it sufficiently early that the
 * boot-time zeroing of .bss would clobber it.
 */
```

`.bss`用于未显式初始化的全局变量。Kernel启动时会将其清零。

如果`__boot_cpu_mode`放在`.bss`：

```text
el2_setup后写入启动模式
-> 后续Kernel清零.bss
-> 启动模式被覆盖
```

所以它必须放在带初始内容的可写Section中。

## 4. `__boot_cpu_mode`地址如何产生？

```asm
ENTRY(__boot_cpu_mode)
```

本质上定义一个汇编符号，近似：

```asm
.global __boot_cpu_mode
__boot_cpu_mode:
```

它自身没有手工写死地址。

链接时，链接器根据：

```text
vmlinux.lds.S
+ 各Section大小
+ Section顺序
+ 对齐要求
```

给`__boot_cpu_mode`分配最终的**链接虚拟地址VMA**。

关系是：

```text
head.S定义符号及所属Section
-> 汇编器生成head.o及重定位信息
-> vmlinux.lds.S排列Section
-> 链接器确定__boot_cpu_mode的最终链接地址
```

因此答案是：

> 地址由链接器按照链接脚本计算，不是源码手动指定。

## 5. 这个地址是物理地址还是虚拟地址？

必须分阶段回答。

### 链接视角

链接器赋给`__boot_cpu_mode`的是Kernel的**虚拟链接地址**。

链接脚本从：

```ld
. = KIMAGE_VADDR + TEXT_OFFSET;
```

开始组织Kernel，因此符号表中的地址属于Kernel高虚拟地址空间。

可以在生成`vmlinux`后查看：

```bash
nm vmlinux | grep __boot_cpu_mode
```

看到的是虚拟链接地址。

### MMU关闭时的运行视角

代码：

```asm
adr_l x1, __boot_cpu_mode
```

宏的真实实现：

```asm
.macro adr_l, dst, sym
        adrp    \dst, \sym
        add     \dst, \dst, :lo12:\sym
.endm
```

`adrp + add`采用PC相对寻址。链接器把“目标符号相对当前指令的距离”编码进指令。

Image被整体加载到物理内存时：

```text
代码和__boot_cpu_mode一起移动
-> 二者相对距离不变
```

所以MMU关闭时执行这段PC相对指令，得到的是当前物理加载布局中：

```text
__boot_cpu_mode实际所在的物理地址
```

它可以直接用于：

```asm
str w0, [x1]
```

### MMU开启后

Kernel建立正式映射后，C代码通过符号：

```c
__boot_cpu_mode[0]
```

访问的是Kernel虚拟地址。

MMU再把该虚拟地址翻译到同一块物理内存。

所以同一个变量：

```text
链接时：拥有Kernel虚拟链接地址
MMU关闭时：早期汇编通过PC相对寻址得到可用物理位置
MMU开启后：通过Kernel虚拟地址访问
```

## 6. 它在内存中的布局

源码：

```asm
ENTRY(__boot_cpu_mode)
        .long   BOOT_CPU_MODE_EL2
        .long   BOOT_CPU_MODE_EL1
```

`.long`在这里各生成4字节：

```text
__boot_cpu_mode + 0：BOOT_CPU_MODE_EL2
__boot_cpu_mode + 4：BOOT_CPU_MODE_EL1
```

对应C声明：

```c
extern u32 __boot_cpu_mode[2];
```

所以它是：

```text
两个u32组成的8字节数组
```

## 完整关系

```text
head.S
.pushsection ".mmuoff.data.write"
__boot_cpu_mode:
    .long EL2
    .long EL1
        |
        v
汇编为head.o中的.mmuoff.data.write输入Section
        |
        v
vmlinux.lds.S收集并按2KB对齐
        |
        v
链接器分配Kernel虚拟链接地址
        |
        v
生成vmlinux，再生成Image
        |
        v
U-Boot把整个Image加载到物理内存
        |
        v
MMU关闭：adr_l通过PC相对地址定位物理位置
        |
        v
MMU开启：Kernel通过虚拟地址映射到同一物理位置
```

一句话回答：

> `__boot_cpu_mode`位于专门的`.mmuoff.data.write`可写Section中；符号的虚拟地址由链接器依据`vmlinux.lds.S`分配。MMU关闭时，启动汇编利用PC相对寻址得到其当前物理加载位置；MMU开启后，Kernel通过正式虚拟地址访问同一块物理内存。

---

## [09:15] user

明白了，进入物理地址、虚拟地址和MMU的学习


---

## [09:16] assistant

先建立最小模型，今天不直接读页表源码。理解下面这些概念后，再进入`__create_page_tables`。

## 1. 物理地址是什么？

物理地址是CPU最终送到内存控制器或设备总线上的地址。

例如RK3568有一段DRAM，假设某个数据实际位于：

```text
物理地址 0x00200000
```

这里表示真实物理内存中的位置。

但是，现代程序通常不会直接使用物理地址，而是使用虚拟地址。

## 2. 虚拟地址是什么？

虚拟地址是CPU执行程序时，指令中看到和使用的地址。

例如Kernel代码访问：

```text
虚拟地址 0xffff800000200000
```

MMU可以把它翻译为：

```text
物理地址 0x00200000
```

关系：

```text
CPU产生虚拟地址
-> MMU查页表
-> 得到物理地址
-> 访问DRAM
```

同一物理页可以映射到不同虚拟地址：

```text
虚拟地址A ─┐
           ├-> 同一个物理页
虚拟地址B ─┘
```

不同进程也可以使用相同虚拟地址，但映射到不同物理内存：

```text
进程A：0x400000 -> 物理页A
进程B：0x400000 -> 物理页B
```

这提供了进程隔离。

## 3. 为什么需要虚拟地址？

### 进程隔离

每个进程拥有自己的虚拟地址空间，一个进程不能随意访问另一个进程的物理内存。

### 简化程序布局

程序可以假设自己有连续地址：

```text
代码段
数据段
堆
共享库
栈
```

底层物理页不要求连续。

### 权限控制

页表项可以设置：

```text
可读
可写
可执行
用户可访问
仅Kernel可访问
```

例如：

```text
Kernel代码：可读、可执行、不可写
Kernel数据：可读、可写、不可执行
用户页：EL0可访问
```

### 内存共享

多个进程或设备可以共享同一物理页。

这与后续DMA-BUF直接相关：

```text
Camera和DRM共享同一物理buffer
-> 各自在自己的地址空间或设备地址空间访问
```

## 4. 页是什么？

MMU通常不是按每个字节建立映射，而是按固定大小的“页”映射。

假设使用4KB页：

```text
一页 = 4096字节 = 0x1000
```

虚拟地址可以拆成：

```text
虚拟页号 + 页内偏移
```

例如：

```text
虚拟地址：0x12345678
页内偏移：低12位，即0x678
虚拟页号：剩余高位
```

因为：

```text
4KB = 2^12
```

MMU通过页表把虚拟页号翻译为物理页框号，页内偏移保持不变：

```text
虚拟页号 -> 物理页框号
页内偏移 -> 原样保留
```

## 5. 页表是什么？

页表是保存在内存中的地址翻译数据结构。

页表项PTE记录：

```text
物理页地址
是否有效
读写权限
执行权限
用户/Kernel权限
内存类型
Cache属性
访问状态
```

简化：

```text
虚拟页0x12345
-> PTE
-> 物理页0xABC
-> 权限RW、不可执行
```

CPU访问虚拟地址时：

```text
取虚拟页号
-> 查页表
-> 检查有效位和权限
-> 组合物理页框号与页内偏移
-> 得到物理地址
```

## 6. 为什么使用多级页表？

如果为整个64位虚拟地址空间一次性准备一张巨大线性页表，会浪费大量内存。

多级页表类似分级目录：

```text
PGD
-> PUD
-> PMD
-> PTE
-> 物理页
```

只有实际用到的地址范围，才分配下一级页表。

类比：

```text
国家
-> 省
-> 市
-> 街道
-> 门牌号
```

查找稍复杂，但极大节省页表内存。

ARM64在4KB页配置下通常使用多级索引。当前先不记每级位数，读实际配置时再计算。

## 7. MMU是什么？

MMU是CPU内部的Memory Management Unit。

职责：

- 根据页表翻译虚拟地址
- 检查访问权限
- 检查内存属性
- 触发地址翻译异常或权限异常

MMU不是页表本身：

```text
页表：内存中的数据结构
MMU：读取并执行页表规则的硬件
```

Linux负责创建和修改页表，CPU的MMU负责实际翻译。

## 8. TLB是什么？

如果CPU每次访问内存都逐级读取页表，会非常慢。

TLB缓存最近的地址翻译结果：

```text
虚拟页 -> 物理页 + 权限
```

访问过程：

```text
CPU产生虚拟地址
-> 查询TLB
   ├── 命中：直接得到物理页
   └── 未命中：硬件遍历页表，再写入TLB
```

页表修改后，旧TLB项可能仍然存在，因此Kernel需要执行TLB失效操作。

```text
TLB缓存“地址翻译”
```

## 9. Cache是什么？

Cache缓存的是内存中的实际内容：

```text
指令
数据
```

例如：

```text
L1 I-Cache：缓存指令
L1 D-Cache：缓存数据
L2 Cache：更大的共享/私有缓存
```

与TLB区别：

```text
TLB：缓存虚拟地址到物理地址的翻译
Cache：缓存物理内存中的指令或数据内容
```

一次访问可以理解为：

```text
虚拟地址
-> TLB/MMU得到物理地址
-> Cache查找这个地址的数据
-> 未命中再访问DRAM
```

## 10. 为什么Kernel启动前MMU是关闭的？

U-Boot跳入Kernel时：

```text
MMU = off
```

这时CPU执行指令使用的地址基本按物理地址解释。

Kernel即将切换到自己设计的虚拟地址空间，但在开启MMU前必须先准备页表。

否则：

```text
打开MMU
-> CPU开始把下一条指令地址当作虚拟地址
-> 页表里没有映射
-> 立即取指异常
```

## 11. Identity Mapping是什么？

恒等映射：

```text
虚拟地址 == 物理地址
```

例如：

```text
虚拟0x00200000 -> 物理0x00200000
```

为什么启动时需要？

MMU开启前，CPU正在某个物理地址执行代码。开启MMU后，下一条指令地址立即按虚拟地址解释。

如果这个地址有恒等映射：

```text
开启MMU前PC = 0x00200000，按物理地址解释
开启MMU后PC = 0x00200004，按虚拟地址解释
页表把虚拟0x00200004映射到物理0x00200004
```

CPU可以连续执行，不会在开启MMU瞬间丢失当前代码。

这套临时页表通常称为：

```text
idmap
```

## 12. Kernel Mapping是什么？

Linux最终不希望一直运行在低物理地址对应的恒等映射中，而是运行在Kernel高虚拟地址。

例如概念上：

```text
Kernel虚拟高地址
-> Kernel实际物理加载地址
```

所以早期需要两种映射：

```text
Identity Mapping
    保证MMU开启瞬间当前代码连续执行

Kernel Mapping
    让Kernel切换到正式高虚拟地址继续运行
```

流程：

```text
MMU关闭，按物理地址运行
-> 创建idmap和Kernel映射
-> 使用idmap安全开启MMU
-> 跳转到Kernel高虚拟地址
-> 使用正式Kernel映射
```

## 13. 对应即将阅读的源码

```text
__create_page_tables
    创建idmap与Kernel早期页表

__cpu_setup
    配置MAIR、TCR等内存属性和地址翻译控制

__primary_switch
    安装页表基址并调用MMU启用路径

__enable_mmu
    设置TTBR和SCTLR，正式开启MMU

__primary_switched
    在Kernel虚拟地址环境中继续执行
```

## 14. 项目联系

### BSP启动

加载地址、Image位置或页表范围错误，Kernel可能在开启MMU前后直接卡死，甚至没有串口输出。

### Camera DMA

后续需要区分：

```text
CPU虚拟地址
物理地址
DMA地址
IOMMU地址
```

不能把驱动中的指针直接当作设备DMA地址。

### CMA与DMA-BUF

```text
CMA分配满足设备要求的物理内存
CPU通过虚拟地址访问
Camera通过DMA地址写入
DRM通过DMA-BUF共享并扫描输出
```

## 本节小测

1. MMU与页表有什么区别？
2. TLB和Cache缓存的内容分别是什么？
3. 页内偏移为什么不需要翻译？
4. 多级页表为什么比一张巨大线性页表节省内存？
5. 为什么开启MMU前需要Identity Mapping？
6. Identity Mapping和Kernel Mapping分别解决什么问题？

回答后，我们再读取真实的`__create_page_tables`源码。