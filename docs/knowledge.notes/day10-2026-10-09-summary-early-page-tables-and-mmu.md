# Day 2 总笔记（原计划 Day2）：早期页表与 MMU 开启——从 `__create_page_tables` 到 `start_kernel` 门前

> 整合 day04~day08 学习内容（2026-09-21 ~ 09-30），对应 7 天计划第 2 天：
> 理论=物理/虚拟地址、MMU、页表、TLB、Cache；源码=`__create_page_tables`/`__cpu_setup`/`__primary_switch`；
> 验收=解释早期映射与启用 MMU 前后地址关系。
> 源码基准：Rockchip 4.19（虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`），配置 PA=48 / VA_BITS=48 / 4KB页 / 4级页表。
> 各日明细见 day04~day07 分笔记；本文是提炼版 + 统一闭卷标准答案。

## 〇、全局调用链（本日覆盖范围）

```text
stext (head.S:120)
├─ preserve_boot_args        (Day3已学)
├─ el2_setup                 (Day3已学)
├─ set_cpu_boot_mode_flag    (Day4)
├─ __create_page_tables      ★ 建两棵页表 (head.S:290)
├─ __cpu_setup               ★ 配MMU规则+备SCTLR值 (proc.S:466)
└─ b __primary_switch        ★ (head.S:935)
    └─ bl __enable_mmu       ★ TTBR装载+开MMU (head.S:769)
        └─ br __primary_switched → b start_kernel  (第3天内容)
```

## 一、理论：MMU 最小模型（12 问要点）

- **物理地址**：CPU 送到内存控制器的真实地址；**虚拟地址**：指令中使用的地址，MMU 按页表翻译成物理地址
- **页表**：内存中的翻译数据结构（PTE=物理页框+权限+属性）；**MMU**：执行翻译的硬件。TLB 缓存"翻译结果"，Cache 缓存"内容"
- **多级页表省内存**：48位VA+4KB页一级表需 2^36×8B=512GB；4级树"用到才分配下一级"，进程只用128个4MB区域时≈516KB。数组 vs 按需生长的树
- **页内偏移不翻译**：映射粒度是整页，低12位不进页表
- 48VA/4KB/4级索引布局：`[63:48]保留 | [47:39]L0 | [38:30]L1 | [29:21]L2 | [20:12]L3 | [11:0]偏移`，每级9位512项
- **为什么开MMU前必须建好页表**：`msr sctlr_el1`置M位后下一条指令地址立即按虚拟解释，无映射则取指异常——不是安全问题，是取指连续性

## 二、`__create_page_tables`（head.S:290~404）六段

```text
① mov x28, lr                         保存返回地址
② inval_cache(idmap_pg_dir~swapper_pg_end)   防旧脏Cache行回写覆盖新表
③ 清零循环(4×stp xzr=64B/轮) + x7=SWAPPER_MM_MMUFLAGS   0=invalid
④ 建idmap树: adrp x0/x3 → clz检查物理地址高度(b.ge 1f, PA≤48恒跳)
   #if(VA_BITS<48): create_table_entry 加EXTRA级 | #else: pgds=512存idmap_ptrs_per_pgd
   1: ldr_l x4 → map_memory(vstart==phys==__idmap_text_start物理地址)
⑤ 建swapper树: vstart=KIMAGE_VADDR+TEXT_OFFSET(高VA)+x23(KASLR), phys=_text
⑥ dmb sy + 二次inval(防投机加载Cache行) + ret x28
```

- **两次inval的区别**：开头防"旧脏行覆盖刚写的表"；结尾防"填表期间CPU投机预取的行已过时"
- **idmap**：VA==PA恒等映射，护送开MMU瞬间的取指；**swapper**：内核正式高地址空间
- `#else` 分支唯一活路 = VA48+64K页+PA52 服务器芯片（4.19 Kconfig 仅允许该组合配PA52）；PA≤48芯片恒跳过。"我的配置到不了"≠可删——要看内核支持的全部配置矩阵

## 三、建表三宏（实际执行路径）

**populate_entries（:192）**：循环填 `[istart,iend]`。`tbl[index] = rtbl|flags`，rtbl按inc递增(目录4096/叶子2MB)。`.Lpe\@`的`\@`=展开计数器防标号重名。

**compute_indices（:224）**：`istart=(vstart>>shift)&511, iend=(vend>>shift)&511, count=差`。开头`iend+=(count-1)*ptrs`是跨表缩放。

**map_memory（:262）**：四级流水，13参数（6输入+7工作寄存器）：

```text
L0 compute(39)+populate(TABLE,步长4096)  目录→L1页
L1 compute(30)+populate(TABLE,步长4096)  目录→L2页 (LEVELS>3)
L2 compute(21)+populate(TABLE,步长4096)  目录→L3页 (LEVELS>2)
L3 compute(21)+bic(phys对齐2MB)+populate(flags,步长2MB)  ★真映射
```

**目录项 vs 叶子项**：前者值=下一级表页地址|0b11(PMD_TYPE_TABLE)；后者值=真实物理地址|属性位(SWAPPER_MM_MMUFLAGS,类型01)。前三层搭骨架，L3才产生VA→PA映射。

**create_table_entry（:165）**：单格目录项原型（你的配置不编译）。8行=算下一级页地址(+4096)、拼类型位、`(virt>>shift)&(ptrs-1)`算下标、`str [tbl,index,lsl#3]`写入、游标前进。`&511`等价`%512`（2的幂-1掩码，与门1周期vs除法几十周期）。`lsl#3`=×8因为PTE占8字节。

**跨表**：上层填N项→下层N张表页连续排布（rtbl每项+4096自动"分配"）；`tbl[512]`即下一张表`[0]`；compute_indices的count缩放让iend变跨表全局下标。例：L0填[1,2]、L1填[0,1]→4张L2、4张L3、4条根到叶路径、11张表页44KB映射8MB。

## 四、`__cpu_setup`（proc.S:466）——准备MMU规则，不开MMU

```text
tlbi vmalle1 + dsb        清TLB防旧翻译
cpacr_el1 = 3<<20         开FP/ASIMD
MAIR_EL1 填8个属性槽      槽0=0x00(Device nGnRnE) 槽4=0xff(Normal写回)...
TCR_EL1 立即写入          T0SZ/T1SZ=48/48划分TTBR0/TTBR1范围、TG=4KB、IPS=48
  └ tcr_set_idmap_t0sz    若idmap扩过范围同步改T0SZ(与__create_page_tables的#else配套)
SCTLR_EL1_SET→x0返回      含M位(MMU)|C位(DCache)|I位(ICache)等, 不写入!
```

**MAIR与PTE的配合**：PTE bit[5:2]=AttrIndx(3位下标)→查MAIR 8槽之一得Cache属性。`PTE_ATTRINDX(MT_NORMAL)=4<<2=0x10`指向槽4(0xff可缓存)；ioremap映射寄存器用AttrIndx=0指向槽0(Device不缓存)——**寄存器不能当普通内存访问的硬件根源**。`MAIR(attr,mt)=(attr)<<(mt*8)`就是算槽位偏移。

## 五、`__primary_switch` + `__enable_mmu`——开MMU

**__enable_mmu（:769）**：
```text
查ID_AA64MMFR0_EL1支持4KB页 → TTBR0←idmap_pg_dir, TTBR1←swapper_pg_dir
→ isb → msr sctlr_el1, x0(x0=__cpu_setup备好的SCTLR_EL1_SET, M=1) ★MMU开
→ ic iallu清I-Cache(旧物理视角指令作废)
```
`phys_to_ttbr`：48位PA下=mov；52位PA需折叠（TTBR的orr,lsr#46 / PTE的orr,lsr#36，把bit[51:48]折进保留位；占用页内偏移位→52PA仅支持64K页）。

**__primary_switch（:935）**：非KASLR路径仅3行：`bl __enable_mmu` → `ldr x8,=__primary_switched; adrp x0,__PHYS_OFFSET; br x8`。KASLR路径会关MMU→重建页表→重开MMU（第二次`__create_page_tables`带随机偏移x23）。

**为什么开MMU不fault（三件套）**：`__primary_switch`/`__enable_mmu`在`.idmap.text`段 + idmap树建了VA==PA恒等映射 + TTBR0指向idmap树。`msr`置M位后PC数值不变、按虚拟解释、恒等映射翻译回同一物理地址→取指连续。之后`br x8`跳高VA走TTBR1→swapper树。

## 六、开MMU前后地址关系（本日最深一环）

**PC视角**：MMU关=物理；开瞬间起=虚拟。**adrp规则**：`结果=运行时PC+链接期固定偏移`——PC是什么类型结果就是什么类型。普通内核代码（高VA执行）取虚拟；`.idmap.text`代码（开MMU后仍在物理地址执行，idmap保证可取指）取物理。

**`__PHYS_OFFSET = KERNEL_START - TEXT_OFFSET`（宏，无内存）**：
```text
x0 = 运行时PC + [(_text-0x80000) - 本指令链接VA]
   = (RAM_BASE+0x80000+指令位置) - (0x80000+指令位置) = RAM_BASE ★精确抵消
```
宏里`-TEXT_OFFSET`就是为了抵消加载时的`+TEXT_OFFSET`。RK3568 DRAM基址=0，故x0=0x0。
**为什么绕**：CPU无"RAM基址寄存器"，镜像信息全是链接期写死，运行时唯一信息源是PC；adrp是唯一能提取PC信息的工具（PIC标准手法，同族：`__boot_cpu_mode`的adr_l、U-Boot relocation）。

**kimage_voffset = 虚拟基址 − 物理基址**（mmu.c:58，EXPORT_SYMBOL）：
```text
kimage_vaddr变量(.idmap.text段, 存链接期算的_text-TEXT_OFFSET虚拟数值, 如0xffff800010000000)
x0 = adrp在物理PC下取的RAM_BASE(如0x0)
kimage_voffset = 0xffff800010000000 - 0 = 0xffff800010000000 (≠0! 一虚一实)
__pa(va)=va-voffset; __va(pa)=pa+voffset
验证: __pa(_text)=0xffff800010080000-voffset=0x80000=RAM_BASE+TEXT_OFFSET ✓
```
三者辨析：`__PHYS_OFFSET`宏无内存（adrp只算地址不读内存）；`kimage_vaddr`是真变量（.quad占8字节）；`kimage_voffset`是真变量（全内核VA/PA换算基准，驱动virt_to_phys走到它）。

## 七、周边概念

- **KASLR**：每次启动随机偏移x23（非烧录时）。改三样：①重建页表(vstart+x23) ②`__relocate_kernel`修镜像内链接期写死的绝对地址 ③更新kimage_voffset。双建表原因：解析FDT(C代码,需MMU+C环境)拿偏移→被迫先建零偏移基线表
- **链接期**=ld按vmlinux.lds.S给符号定地址（区别于建表期）；`vmlinux.lds.S:114: . = KIMAGE_VADDR + TEXT_OFFSET; _text = .`；`KIMAGE_VADDR=MODULES_END`(memory.h:64常量链)
- **TEXT_OFFSET=0x80000**（arch/arm64/Makefile写死，约束4KB对齐/≤2MB）：Image文件开头相对RAM基址(2MB对齐后)的偏移。写在Image header的text_offset字段——U-Boot/链接器/内核启动汇编三方契约
- **booti**（u-boot/cmd/booti.c）：读Image头(magic 0x644d5241)→`dst=ALIGN(RAM,2M)+text_offset`→`memmove`搬正→设x0/x1/x2跳转。正常开机由bootcmd环境变量自动串fatload+booti；调试时手动敲
- **SCTLR_EL1_SET**（sysreg.h:506）：M(1<<0)MMU | C(1<<2)DCache | I(1<<12)ICache | SPAN | ... 按位或的预设值
- **TTBR0/TTBR1分工**：VA高16位=0走TTBR0(低半段/用户,此刻idmap)，=0xffff走TTBR1(高半段/内核swapper)；TCR的T0SZ/T1SZ定分界

## 八、闭卷考核标准答案

**Q1 `create_table_entry`的④⑤⑥在算什么？为什么and代替mod？**
算"本级的表项下标"：`lsr`把virt中属于本级的9位索引段移到最低位，`sub`把512变成511=0x1FF（9个1的掩码），`and`截取低9位得到0~511下标。`x & (2^n-1) ≡ x mod 2^n`，与运算1个时钟周期、除法几十个周期，512是2的幂所以可用。

**Q2 map_memory前三级和最后一级写的descriptor区别？**
前三级（L0/L1/L2）写目录项：值=下一级页表页地址 | PMD_TYPE_TABLE(0b11)，只搭骨架不产生映射。最后一级（L3）写映射项：值=真实物理地址 | SWAPPER_MM_MMUFLAGS（类型01，含有效位+读写权限+AttrIndx=4），这一刻才建立VA→PA映射，步长2MB递增phys。

**Q3 下一级页表页哪里来？为什么不用分配？**
链接脚本在.bss连续预留页表区域，populate_entries每填一项rtbl+=PAGE_SIZE——上层填N项=下层自动获得N张连续表页。启动早期没有内存分配器（buddy/slab都未初始化），只能用这种"位置即分配"的静态布局约定。

**Q4 填完页表为什么再inval一次Cache？和开头那次区别？**
开头：防旧数据脏行——MMU关闭下stp直接写物理内存，旧内容若挂在Cache脏行，之后逐出会把旧数据覆盖回刚写的页表。结尾：防投机加载——填表过程中CPU投机预取把页表内存以旧视角拉进Cache，开MMU后读到过时行。同一块内存、两个时刻、两种风险，所以两次。结尾前有dmb sy保证写入全局可见。

**Q5 一个L0表项覆盖多大虚拟范围？**
PGDIR_SIZE = 1<<39 = 512GB（L0索引用VA[47:39]，一项罩住下面三层全部512×512×512×4KB）。48位VA共256项有效（PTRS_PER_PGD=512但高半段只用低半的256组合）。idmap侧因要罩48位物理空间用满512项。

**Q6（总验收）解释早期映射与启用MMU前后地址关系。**
标准答案：内核入口在物理地址执行（MMU关闭，U-Boot的booti按TEXT_OFFSET约定把Image放在RAM_BASE+0x80000后跳入）。`__create_page_tables`建两棵树：idmap（VA==PA，护送开MMU瞬间）+swapper（KIMAGE_VADDR高VA→内核物理）。`__cpu_setup`配TCR/MAIR、备SCTLR值。`__enable_mmu`装TTBR0←idmap/TTBR1←swapper后`msr sctlr_el1`置M位——从这条指令之后PC按虚拟解释；因这段代码在.idmap.text且有恒等映射，翻译回同一物理地址，取指无缝。`br __primary_switched`跳高VA走TTBR1进入内核正式地址空间，此后C代码全在高VA运行；kimage_voffset（虚拟基址−物理基址）记录换算差供__pa/__va使用。idmap树使命在进高VA后结束。

## 九、本日踩坑记录（易混点）

1. `__PHYS_OFFSET`是宏不是变量，adrp只算地址从不读内存
2. `.idmap.text`代码开MMU后仍在物理PC执行（idmap保证可取指）→ adrp取物理；"MMU开后adrp取虚拟"仅适用于高VA执行的普通内核代码
3. kimage_voffset≠0：被减两边一虚（链接期数值）一实（运行时物理）
4. RK3568 DRAM基址=0x0（不是通用示例的0x40000000）
5. PTRS_PER_PGD(VA48)=512不是256
6. booti会memmove兜底搬正Image位置；但Image头magic校验失败直接拒启
7. #if分支能否删要看全配置矩阵，不能只看自己的.config

## 九·补、温习追问沉淀（2026-10-09）

### Q7 idmap 和 kernel map 的"有效位"是不是都等于物理地址？

校准用词：此处的"有效位"指**虚拟地址低 48 位的位模式**（不是 PTE 的 bit[0] 有效位）。答案：**只有 idmap 成立；kernel map 不成立**。

```text
idmap:        VA低48位 == PA  (逐位相同, 这是恒等映射的定义)
  例: VA=0x0000000004000000  PA=0x0000000004000000  ← 翻译等于没翻译

kernel map:   VA低48位 != PA  (差 kimage_voffset)
  例: VA=0xffff800010080000  PA=0x000000000080000
      差值 0xffff800010000000 = kimage_voffset (Day2末尾算过)
```

两棵树叶子层的 PTE 属性位确实**逐位相同**（都用 `SWAPPER_MM_MMUFLAGS`），但 VA 地址本身的位模式不同：
- idmap：VA==PA（低半段，高 16 位=0x0000，走 TTBR0）
- kernel map：VA 在高半段（高 16 位=0xffff，走 TTBR1），与 PA 数值无关、纯靠页表翻译关联

如果 kernel map 的 VA 也等于 PA，内核就不需要两棵树了——正是为了让内核跑在高地址（隔离用户/内核空间）才有第二棵非恒等映射。

### Q8 L1 填 2 项时，L2 是不是只写第一页？

**不是——两张 L2 表都会被填，靠 `compute_indices` 的 count 缩放 + populate 连续 index 写入**。漏 `mov tbl, sv` 那两行只负责把 tbl 设到"本层第一张表"，跨到第二张不是它管的。

关键在 `compute_indices` 开头三行：

```asm
lsr  iend, vend, shift; and iend, iend, ptrs-1    // iend = 单表内下标
mov  istart, ptrs; mul istart, istart, count
add  iend, iend, istart                            // ★iend += (count-1)*ptrs 跨表缩放
```

L1 层填 2 项时 `count` 输出=2，传给 L2 层。L2 的 `compute_indices` 把 iend 缩放成"跨 2 张表的全局下标"：

```text
L1: istart=1, iend=2 → count输出=2
    L1[1]=L2表A地址|0b11, L1[2]=L2表B地址|0b11

L2: count输入=2(来自上层)
    compute_indices 不带缩放时 iend=511(半张表范围)
    带缩放: iend = 511 + (2-1)*512 = 1023   ← 全局下标!
    populate 循环 index=0..1023:
      index 0~511   → 写tbl[0..511]    = L2表A (地址=tbl+index*8)
      index 512~1023 → 写tbl[512..1023] = L2表B (地址=tbl+4096+...)
```

`str tmp, [tbl, index, lsl #3]` 寻址是纯算术（tbl+index×8），index=512 时字节偏移 4096——正好落到物理上紧跟的第一张表之后的第二张表 `[0]`。**两张 L2 表物理连续，index 连续增长就自然跨过去，不需要 tbl 推进多次**。

`mov tbl, sv; mov sv, rtbl` 这两行只把 tbl 设到本层第一张表（供 populate 基址用），跨到第二张表是 populate 的 index 越界天然完成的。两层配合：tbl 给起点、count 缩放给终点、物理连续兜底。

### Q9 vstart 和 kimage_voffset 的先后顺序

**vstart 编译期定死，kimage_voffset 运行时算出**。

```text
编译期(链接器跑 vmlinux.lds.S):
  KIMAGE_VADDR = MODULES_END = 一串VA常量推出来    ← 已定
  _text = KIMAGE_VADDR + TEXT_OFFSET               ← 已定
  vstart 的"理论值" = KIMAGE_VADDR + TEXT_OFFSET    ← 已定
  (此刻没有物理基址, voffset 算不出)

启动早期(__create_page_tables 建swapper):
  mov_q x5, KIMAGE_VADDR + TEXT_OFFSET    // 用编译期定死的值
  add   x5, x5, x23                       // +KASLR偏移(默认0)
  → vstart 用来建表, 此刻不需要 voffset

__primary_switched (开完MMU后):
  adrp x0, __PHYS_OFFSET                  // 运行时第一次知道物理基址PA
  ldr_l x4, kimage_vaddr                  // = KIMAGE_VADDR(链接期值)
  sub  x4, x4, x0                         // ★ kimage_voffset = VA - PA (此刻才算出)
```

**为什么是这个顺序**：同一份 Image 烧到不同板子（DRAM 起始 0x0 / 0x40000000 / 别的）都一样能跑——镜像里所有符号的虚拟地址在编译期定死（KIMAGE_VADDR），但物理地址取决于"板子把 Image 放在哪个 RAM 起始处"。所以：

- vstart = 虚拟地址，编译期定死（KIMAGE_VADDR）
- voffset = 虚拟基址 − 物理基址，要等运行时用 PC 算出 RAM_BASE 才能定

voffset 本质是"链接期写死的虚拟基址"和"运行时才知道的物理基址"的差——直到 `__primary_switched` 才解出来。在那之前内核不需要 voffset 也能工作（建表用 KIMAGE_VADDR 编译期值；MMU 开后访问符号靠 PC 相对寻址不查 voffset）。voffset 是给后续 C 代码的 `__pa()`/`__va()` 准备的换算工具，启动早期汇编不需要。

KASLR 时 x23 在运行时被 `kaslr_early_init` 改成随机值，vstart 变运行时值——但即便如此，voffset 依然在 vstart（带偏移）确定后才算，先后顺序不变。

一句话：**vstart 是镜像里写死的"应该长这样"，voffset 是运行时量出"实际放在哪"后的差值**。先有目标位置（vstart），再算从物理到目标的换算系数（voffset）。

## 十、明日（第3天）

`__primary_switched`逐行（设栈/向量表/存FDT/清BSS）→ `start_kernel()`拆分 → 验收：画汇编入口到C入口完整调用图。
