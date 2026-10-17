# Day 07（2026-09-29）：map_memory 三宏 + __create_page_tables 全函数收官

> 源码：`arch/arm64/kernel/head.S`（Rockchip 4.19，虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`）。
> 本日完成：`__create_page_tables` 全部路径（含边角分支）+ `map_memory`/`compute_indices`/`populate_entries` 三宏 + 跨表场景推演。
> 对应原计划 Day2 的 `__create_page_tables` 部分；`__cpu_setup`、`__primary_switch` 留明日，届时整合 Day2 总笔记并统一考核。

## 一、map_memory 三宏（实际执行的建表路径）

### populate_entries（head.S:192）——循环填表项

```asm
.macro populate_entries, tbl, rtbl, index, eindex, flags, inc, tmp1
.Lpe\@:	phys_to_pte \tmp1, \rtbl       // tmp1 = rtbl
	orr	\tmp1, \tmp1, \flags          // tmp1 = rtbl | flags
	str	\tmp1, [\tbl, \index, lsl #3] // tbl[index] = tmp1
	add	\rtbl, \rtbl, \inc            // 目标地址递增(4096或2MB)
	add	\index, \index, #1            // 下标递增
	cmp	\index, \eindex
	b.ls	.Lpe\@                        // 填到eindex为止
	.endm
```

- `create_table_entry` 的循环版，一次填 `[istart, iend]` 一段
- `flags` 决定类型：`PMD_TYPE_TABLE`(0b11)=目录项；`\flags`(属性位,类型01)=叶子映射项
- `.Lpe\@`：`\@` 是宏展开计数器，避免多次展开标号重名

### compute_indices（head.S:224）——算起止下标

```asm
lsr  iend, vend, shift;  and iend, iend, ptrs-1   // 终点格子号
lsr  istart, vstart, shift; and istart, & 511     // 起点格子号
sub  count, iend, istart                          // 本级填几项
// 开头三行 iend += (count-1)*ptrs：下层跨多张表时把iend缩放成全局下标
```

istart/iend = **映射区间在该层覆盖到的格子编号范围**，即 populate_entries 的循环边界。

### map_memory（head.S:262）——四级流水

```text
L0  compute(shift=39) + populate(TABLE, 步长4096)   ← 目录项→L1页
L1  compute(shift=30) + populate(TABLE, 步长4096)   ← 目录项→L2页 (LEVELS>3)
L2  compute(shift=21) + populate(TABLE, 步长4096)   ← 目录项→L3页 (LEVELS>2)
L3  compute(shift=21) + bic(phys对齐2MB) + populate(flags, 步长2MB) ← 真映射
```

13 参数：6 输入(tbl/vstart/vend/flags/phys/pgds) + 7 工作寄存器(rtbl/istart/iend/tmp/count/sv)。汇编宏无局部变量，中间状态全靠调用方给寄存器。

## 二、跨表场景（多分支树）

例：L0填[1,2]、L1填[0,1]×2表、L3填[0,0]×4表：

```text
L0[1]→L1-A[0]→L2-A[0]→L3-A[0]=phys+0MB
L0[1]→L1-A[1]→L2-B[0]→L3-B[0]=phys+2MB
L0[2]→L1-B[0]→L2-C[0]→L3-C[0]=phys+4MB
L0[2]→L1-B[1]→L2-D[0]→L3-D[0]=phys+6MB
```

- 4条根到叶路径，映射8MB，消耗11张表页=44KB（多级页表按需生长的真实开销）
- **跨表机制**：下层多张表物理连续(每张4KB)，`tbl[512]` 即下一张表`[0]`；compute_indices 的 count缩放让 iend 变成跨表全局下标——即注释 "entries span multiple tables"
- **表页分配**：populate 每填一项 rtbl+=4096，上层填N项=下层自动拥有N张连续表页

## 三、__create_page_tables 全函数六段（head.S:282~404）

```text
① mov x28, lr                      保存返回地址
② inval_cache(idmap_pg_dir~swapper_pg_end)   防旧脏行覆盖新表
③ 清零循环(64B/轮) + x7=SWAPPER_MM_MMUFLAGS  全零=invalid
④ 建idmap树:
   adrp x0,x3 → clz检查物理地址高度 → b.ge 1f(你的配置恒跳)
   #if(VA_BITS<48): create_table_entry加EXTRA级 (你的配置不编译)
   #else: pgds=1<<(48-39)=512 存idmap_ptrs_per_pgd
   1: ldr_l x4 → map_memory(vstart==phys==__idmap_text_start物理地址)
⑤ 建swapper树: vstart=KIMAGE_VADDR+TEXT_OFFSET(高虚拟), phys=_text
⑥ dmb sy + 二次inval(防投机加载) + ret
```

## 四、关键辨析（本日问答沉淀）

1. **__idmap_text_start 是物理还是虚拟**：符号链接值是虚拟地址，但 `adrp` PC相对寻址在 MMU 关闭时取到的是物理地址（源码注释 `__pa(...)` 直接标明）
2. **PC/adrp 前后关系**：MMU 开前 PC 是物理地址、adrp 取物理；开后 PC 是虚拟、adrp 取虚拟。地址类型由 PC 决定，不由 adrp 决定
3. **#else 分支生死**：PA≤48 的芯片(含RK3568)恒 b.ge 跳过=死代码；唯一活路=VA48+64K页+PA52 服务器芯片（4.19 Kconfig 只许该组合配 PA52）。"#else 单独不自洽（x4=8192>一页512项）"——需配合 T0SZ 缩小(多一级walk)才成立；PA52+4K页组合 Kconfig 选不出来，不是源码 bug
4. **判断分支能否删**：不看自己的 .config，要看内核支持的全部配置矩阵——"我的配置到不了"≠"死代码"
5. **L0[1] 的三种地址**：表本身(0x80000000) / 格子所在内存(基址+index×8=0x80000008) / 格里存的值((表+4096)|0b11)
6. **PTRS_PER_PGD 更正**：VA48+4K页下 = 1<<(48-39) = **512**（此前误记256）

## 五、调用关系（明日衔接）

```text
stext: ...→ bl __create_page_tables → bl __cpu_setup → b __primary_switch
__primary_switch(935): bl __enable_mmu(769) → br __primary_switched(411)
__enable_mmu 另一调用点: secondary_startup(716) — 副CPU各自开MMU, RK3568四核跑3次
```

create_table_entry 唯一调用点 head.S:361，被 `#if(VA_BITS<48)` 包裹，你的配置预处理期剔除；即使编入也是宏内联展开，vmlinux 无此符号。

## 六、待办（明日）

1. 学 `__cpu_setup`（TCR/MAIR/SCTLR 准备，proc.S:466）
2. 学 `__primary_switch` + `__enable_mmu`（TTBR0/1 装载、sctlr_el1 置 M 位、.idmap.text 保连续取指）
3. 整合 day04~day08 为"原计划 Day2"总笔记
4. 统一闭卷考核（建表5题 + 开MMU前后地址关系脱稿）
