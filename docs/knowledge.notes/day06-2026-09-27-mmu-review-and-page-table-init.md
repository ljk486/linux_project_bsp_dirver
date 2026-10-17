# Day 05（2026-09-27）：MMU 概念闭卷修正 + `__create_page_tables` 开篇

> 承接 Day04（2026-09-21 MMU 最小模型，断在第 12 问 Kernel Mapping）。
> 源码：虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel/arch/arm64/kernel/head.S`（Rockchip 4.19）。

## 一、闭卷第一轮：MMU 最小模型（6 题，初评 6/10，修正后通过）

| 题 | 我的答案 | 修正 |
|---|---|---|
| MMU vs 页表 | MMU 是执行翻译的硬件；页表是数据结构 ✅ | 页表方向：以**虚拟页号**为索引查出物理页框（虚拟→物理），不是"物理翻译到虚拟" |
| TLB vs Cache | TLB 缓存翻译结果；Cache 缓存指令/数据内容 ✅ | — |
| 页内偏移 | "规定好的" ❌ | 原因是**映射粒度是整页**：低 12 位根本不进页表，MMU 只翻译页号 |
| 多级页表 | 不理解 ❌ | 见下方例子 |
| 为何开 MMU 前要 idmap | "访问安全" ⚠️ | 不是安全问题，是**取指连续性**：开 MMU 瞬间下一条指令地址按虚拟解释，没有 虚拟==物理 映射则取指异常死机 |
| Kernel Mapping | "虚拟地址对应高位物理地址" ❌ | 与物理地址高低无关。是**同一物理内存的两扇窗**：低地址 idmap（虚拟=物理，过渡拐杖）+ 高地址 0xffff8000…（KIMAGE_VADDR，内核链接地址，C 代码正式用） |

### 多级页表省内存的例子（必背）

48 位 VA、4KB 页，一级大页表：页号 36 位 → 2^36 项 × 8B = **512GB**，比内存还大。
多级：第一级 1 个目录页（4KB/512 项），**用到哪段地址才分配下一级页表页**。进程只用 128 个 4MB 区域时 ≈ 128+1 页 ≈ **516KB**。
本质：一级表是必须铺满的数组，多级表是**按需生长的树**（第一级留空 = invalid = 不分配）。

### 为什么需要 MMU（Q8）

进程隔离、权限控制（PTE 的 R/W/X 位）、内存共享（两个虚拟页→同一物理页，DMA-BUF 零拷贝的地基）、简化布局（虚拟连续、物理散落）。

## 二、源码：`__create_page_tables` 开篇（head.S:290）

```asm
__create_page_tables:
	mov	x28, lr                 // 保存返回地址
	adrp	x0, idmap_pg_dir    // ┐
	adrp	x1, swapper_pg_end  // │ 计算两棵页表区域的起止
	sub	x1, x1, x0          // ┘
	bl	__inval_dcache_area     // ① 先把这段内存的脏 Cache 行全部无效化

	adrp	x0, idmap_pg_dir        // ② 清零循环
	adrp	x1, swapper_pg_end
	sub	x1, x1, x0
1:	stp	xzr, xzr, [x0], #16     // 存两个 64 位 0，x0 后自增 16
	stp	xzr, xzr, [x0], #16
	stp	xzr, xzr, [x0], #16
	stp	xzr, xzr, [x0], #16
	subs	x1, x1, #64
	b.ne	1b
```

三个关键对象：
- `idmap_pg_dir`：恒等映射页树的根
- `swapper_pg_dir`：内核映射页树的根（早期兼作进程 0 "swapper" 的页表，名字沿用）
- `swapper_pg_end`：只是区域**末尾**标记，用于算长度，不是页表根！

① 的原因：MMU 还没开，`stp` 直接写**物理内存**，但 Cache 开着。若旧内容挂在脏 Cache 行，之后逐出时会把旧数据**覆盖回刚写好的页表**。"MMU 关闭时改页表必须先管 Cache"——面试高频。

② 的原因：0 = invalid = 未映射，页表必须从全零开始，不能有残留。

## 三、闭卷第二轮：4 题验收（9/10）

1. `idmap_pg_dir` / `swapper_pg_dir` 各是哪棵树的根 ✅（注意别再写成 `swapper_pg_end`）
2. 先 inval Cache 防旧脏数据写回 ✅
3. `stp xzr, xzr, [x0], #16`：写 16 字节双零 + x0 后自增 16 ✅
4. 多级页表 = 先目录页、按需长出下级，不是一次建全 ✅

扣 1 分：第 1 题把 `swapper_pg_dir` 写成了 `swapper_pg_end`（后者只是清零范围的末尾标记）。

## 四、今日八股

1. 为什么 MMU 关闭阶段改页表前必须 invalidate Cache？（脏行回写覆盖新页表）
2. idmap 和 swapper 两棵页表各解决什么问题？开 MMU 后谁先失效？（idmap：过渡期取指连续；swapper：内核正式地址空间；进高地址映射后 idmap 不再需要）
3. 一级页表 512GB vs 多级 516KB 的数字怎么算出来的？
4. `stp xzr, xzr, [x0], #16` 的后自增（post-index）和前自增区别？

## 五、下一课

`create_table_entry` 宏：页表从"全零"到"有映射"——逐层填目录项、`__cpu_setup` 配 TTBR0/TTBR1 指向两棵树、`sctlr_el1` 置位开 MMU。
