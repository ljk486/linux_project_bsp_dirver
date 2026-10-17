# Day 4 复习笔记：setup_arch 与设备树解析（学习者视角）

> 7 天计划第 4 天。理论：DTS/DTSI/DTB、节点属性、内存保留、bootargs；源码：setup_arch / setup_machine_fdt / FDT 扫描，对照鲁班猫 2；验收：解释 memory、chosen 与 DTB 展开。
> 本文是我经过多轮追问深挖后、整理出来的"复习用"版本——只保留理解后的结论 + 必要代码 + 易混点，原始问答在第十一节。

## 0. 学习轨迹：我曾经的错误理解（复习时先看这个，防止重蹈覆辙）

这轮深挖里我被纠正过的认识，每一条都是当时真实的想法：

1. **"DTB 四段在 DTS 里是根节点形式"** → 错。四段是文件包装层，header/strings 由 dtc 自动生成，DTS 只写树内容
2. **"MMU 要先找到 fixmap 的根在哪"** → 错。MMU 从不"找"，它只是按 VA 位段无脑查表；路径是 early_fixmap_init 用 .bss 预留的 bm 三表提前铺好的
3. **"unflatten 给 device_node 分配的内存在 fixmap"** → 错。fixmap 只有几页装不下几十 KB 的树；分配走 memblock_virt_alloc（线性映射区）。DTB 原文在 fixmap、树在 memblock——两样东西两个地方
4. **"np->sibling = dad->child 这行赋值决定 np 排前面"** → 错。赋值只保旧头不丢；顺序由 `dad->child = np` 那行决定——链表顺序由"谁被 dad->child 指着"定义，两行合起来才是头插
5. **"device_node 和 property 是一个东西"** → 错。节点管"我是谁、挂哪"（树形），属性管"我有什么参数"（键值对链），一对多
6. **"of_node_init 挂全局哈希表 allnodes"** → 这是 AI 讲错被我追问出来的：4.19 没有 allnodes（老内核才有），只有 of_root 树入口
7. **"populate_properties 会拷贝属性值"** → 错。name/value 直接引用 DTB 原文——这就是 DTB 被 reserve+只读保护的根源
8. **（Day2 温习）"L1 填 2 项时 L2 只写第一页"** → 错。count 缩放让 iend 变跨表全局下标，populate 的 index 越过 512 天然落到物理紧邻的第二张表
9. **（Day2 温习）"两棵树的有效位都等于物理地址"** → 只有 idmap 成立（VA==PA）；kernel map 差 kimage_voffset

## 0.5 一张图串起本日全部

```text
__fdt_pointer(DTB物理地址, Day3 __primary_switched存的)
  ↓ setup_arch (arch/arm64/kernel/setup.c:258)
  │  early_fixmap_init()       ┐ 给fixmap区铺路: 补swapper树里fixmap的
  │  early_ioremap_init()      ┘ L0→L1→L2目录链,指向.bss预留的bm_pud/pmd/pte
  │  setup_machine_fdt(__fdt_pointer)
  │    ├ fixmap_remap_fdt:     DTB映到FIX_FDT(先映2MB→读totalsize→补映→只读保护)
  │    ├ memblock_reserve:     保留DTB占的物理内存(防被buddy踩)
  │    └ early_init_dt_scan    ★三扫★
  │       ├ 扫根:              model/compatible
  │       ├ 扫memory:          reg→base/size→memblock_add(0, 1GB)
  │       └ 扫chosen:          bootargs→boot_command_line
  │  parse_early_param()        解析earlycon=等(★earlycon在此激活串口)
  │  cpu_uninstall_idmap()      卸TTBR0的idmap(使命完成)
  │  arm64_memblock_init()     memblock加工:截PA/保留镜像/PID0栈/记memstart_addr
  │  paging_init()             (划到第10天)
  │  unflatten_device_tree()   ★DTB→device_node树(挂到全局of_root)
  │  bootmem_init()            zone初始化(过渡到Day3 mm_init)
  │  psci_dt_init/smp_init_cpus PSCI+从DTB读cpu节点枚举多核
  ↓ 返回start_kernel进阶段3(内存管理)
```

## 1. DTB 是什么、四段布局、和 DTS 的关系

### 1.1 DTS / DTB / FDT 三者

| 名字 | 形态 | 阶段 |
|---|---|---|
| DTS / DTSI | 文本源码 | 人写、git 管 |
| DTB | 二进制 | `make dtbs` 由 dtc 编译产物 |
| FDT | DTB 别名 | 内核/U-Boot 里叫法，强调"扁平" |

**U-Boot 不"压缩"DTB，只搬运**：开机时 `fatload` 把 `.dtb` 文件从存储读到内存、`booti` 把地址传给内核（DTB 地址进 x2 → preserve_boot_args 存 x21 → __primary_switched 存 __fdt_pointer）。U-Boot 可选 `fdt_fixup` 改几个字段（往 chosen 写 bootargs 等），不生成 DTB。

### 1.2 DTB 文件四段

```text
┌─────────────────────┐
│ fdt_header (40B)    │  magic=0xd00dfeed + totalsize + 各段偏移
├─────────────────────┤
│ memory reserve map  │  /memreserve/语法写入(几乎不用)
├─────────────────────┤
│ structure block     │  ★节点树本体: 深度优先token流
├─────────────────────┤
│ strings block       │  属性名去重池(可省一半体积)
└─────────────────────┘
```

**structure block** = "拍平的树"。DTS 花括号嵌套序列化成线性 token：

```text
FDT_BEGIN_NODE("/") → FDT_PROP("model","LubanCat-2") →
FDT_BEGIN_NODE("chosen") → FDT_PROP("bootargs",...) → FDT_END_NODE →
FDT_BEGIN_NODE("memory@0") → FDT_PROP("reg",...) → FDT_END_NODE →
FDT_END_NODE → FDT_END
```

解析器靠 BEGIN/END 配对（括号匹配）还原树——"Flattened" = 树拍成线性流，对比 Open Firmware 早期实时树对象。

**strings block**：属性名（`reg`/`compatible` 出现几百次）去重存池；structure block 里 FDT_PROP 不存名字只存 nameoff（池内偏移）。节点名不进池（出现少，直接存 BEGIN_NODE 后）。

**四段在 DTS 里的对应**：header/strings 无对应（dtc 自动生成）；structure 对应整棵 DTS 树；reserve map 对应 `/memreserve/`（极少用）。**写 DTS 只管节点和属性，编译器管包装**。

### 1.3 一个关键澄清：reserved-memory 节点 ≠ reserve map 段

两者都最终汇进 `memblock.reserved`，但路径不同：

| 来源 | 路径 | 典型 |
|---|---|---|
| `/memreserve/ 0x110000 0xf0000` | DTB reserve map 段 → early_init_dt_scan 读到就 reserve | 老 OF 风格，几乎不用 |
| `reserved-memory { ramoops { reg=...; }; }` | structure block 当普通节点扫 → `fdt_init_reserved_mem` 调 `memblock_reserve` | 现代写法，板子用的 |

**CMA** = reserved-memory 的 `compatible="shared-dma-pool"` 特例——Camera DMA 要连续物理内存的根本原因（第 10 天/Day7 V4L2 接上）。

## 2. DTS 节点字段怎么读怎么改（对照 rk3568-lubancat-2）

### 2.1 文件组织

```text
rk3568.dtsi              SoC公共(默认全disabled,各板按需开)
rk3568-lubancat-2.dtsi   板级公共(chosen/bootargs/reserved-memory)
rk3568-lubancat-2.dts    板级入口(#include上面两个,开启本板用的外设)
```

### 2.2 编辑手法：&引用覆盖

```dts
// SoC文件里默认关:
uart2: serial@fe660000 { ... status = "disabled"; };

// 板级文件里覆盖打开:
&i2c1 {
    status = "okay";
    pinctrl-0 = <&i2c1m0_xfer>;   // 改引脚走线方案
};
```

`&label` 引用已存在节点，追加或覆盖属性；编译后合成一个节点。**这就是改 DTS 最常见的操作**。

### 2.3 字段读法（uart2 节点实例）

```dts
uart2: serial@fe660000 {
    compatible = "rockchip,rk3568-uart", "snps,dw-apb-uart";
    reg = <0x0 0xfe660000 0x0 0x100>;
    interrupts = <GIC_SPI 118 IRQ_TYPE_LEVEL_HIGH>;
    clocks = <&cru SCLK_UART2>, <&cru PCLK_UART2>;
    pinctrl-0 = <&uart2m0_xfer>;
    status = "disabled";
};
```

| 字段 | 怎么读 | 改不改 |
|---|---|---|
| `compatible` | 驱动匹配名牌，多字符串先厂商后通用IP（Rockchip 买 dw-apb-uart IP，所以两个） | 不改 |
| `reg` | `<addr_hi addr_lo size_hi size_lo>`，由父节点 `#address-cells=2/#size-cells=2` 分组；= 0xfe660000 起 256B | 不改（硬件定死） |
| `interrupts` | `<GIC_SPI 118 LEVEL_HIGH>`，由中断父 `#interrupt-cells=3` 定：类型+硬件号+触发方式 | 不改 |
| `pinctrl-0` | 引脚复用组，m0/m1 是两组物理走线方案，按原理图接哪组选哪组 | 常改（适配） |
| `status` | `"disabled"`→`"okay"` 开关 | 常改 |

### 2.4 修改生效流程

```text
改 dts → make dtbs → 新 dtb → 烧写/替换 → 重启
验证: cat /proc/device-tree/serial@fe660000/status
```

## 3. setup_machine_fdt + 三扫

### 3.1 fixmap 是什么（背景）

启动早期 buddy 没就绪，普通 ioremap（要 vmalloc 区+alloc_pages）走不通。fixmap = **虚拟地址区里编译期固定的预留槽**，把"找虚拟地址"省掉（`__fix_to_virt(idx)` 编译期算死），只剩改 PTE。

- 三住户：`FIX_FDT`=DTB、`FIX_EARLYCON`=UART 寄存器、`FIX_BTMAPS`=7 个 early_ioremap 临时 slot
- 两类：永久（FIX_FDT/EARLYCON 一直挂着）vs 临时（FIX_BTMAPS 领用/归还）

### 3.2 early_fixmap_init 补目录链

swapper 树（Day2 建的）只映了内核镜像，fixmap 区的目录是空的。`early_fixmap_init` 用 .bss 预预留的三张表（`bm_pud/bm_pmd/bm_pte`）补好：

```text
swapper树L0格 → bm_pud(.bss) → bm_pmd(.bss) → bm_pte叶子 ← 具体使用者填
```

之后改一个 PTE 就能立即映射。

### 3.3 fixmap_remap_fdt 的"鸡生蛋"解法

```text
先映第一个2MB块(肯定够放头部) → 读totalsize → 跨块再补映 → 重映射只读保护
```

不映射就读不了 size，不映射够大就读不到后面——先映 2MB 兜底。

### 3.4 early_init_dt_scan 三扫

```c
early_init_dt_scan_nodes():
    of_scan_flat_dt(early_init_dt_scan_root, NULL);          // 根: model/compatible
    of_scan_flat_dt(early_init_dt_scan_memory, NULL);        // memory→memblock_add ★
    of_scan_flat_dt(early_init_dt_scan_chosen, boot_command_line); // chosen→bootargs
```

**of_scan_flat_dt** 是深度优先遍历器：循环调 fdt_next_node（token 游标）对每个节点回调。回调返回 0="继续扫"，非 0="停止"。

**early_init_dt_scan_memory 怎么把 memory 节点变 memblock**：

```c
只处理 device_type="memory" 的节点
读 reg 按 cells 分组解析 base/size
early_init_dt_add_memory_arch(base, size) → memblock_add(base, size)
// 板子 reg=<0 0 0 0x40000000> → memblock_add(0, 1GB)
// 返回0(继续扫),因为要收集所有memory节点
```

## 4. unflatten_device_tree（追问最密集区）

### 4.1 为什么还要展开

三扫期间只是**回调式扫描**——每次找节点都要全树扫一遍，太慢。unflatten 后建出 device_node 树，之后 `of_find_node_by_path`/`of_find_compatible_node`/`of_property_read_u32` 按指针直达。**Day6 驱动 probe 的 of_device_id 匹配就依赖这棵树**。

### 4.2 两遍扫描

```c
第一遍: unflatten_dt_nodes(blob, mem=NULL)   dryrun只统计总字节
       → dt_alloc(size) 一次从memblock拿一大块
第二遍: unflatten_dt_nodes(blob, &mem)        真建,游标递增切割
最后:  reverse_nodes 反转每层child链
```

**不是每节点调一次分配器**——只碰一次 memblock，其余纯指针算术切割。

### 4.3 unflatten_dt_nodes 主循环

```c
struct device_node *nps[FDT_MAX_DEPTH];   // 每深度记"最近节点"
for (offset=0; offset>=0; offset=fdt_next_node(blob, offset, &depth))
    populate_node(blob, offset, &mem, nps[depth], &nps[depth+1], dryrun);
    //                              ↑父=浅一层最近  ↑把我记在这层
```

**父子关系全靠 nps[]**——新节点的父亲 = 浅一层的最近节点。五圈实例（/ → chosen → memory@0 → serial → uart_clk）：

```text
第1圈("/",depth=0):    父=NULL → *nodepp="/" → of_root
第2圈(chosen,depth=1): 父=nps[1]="/"  → 头插进"/"的孩子链
第3圈(memory,depth=1): 父=nps[1]="/"  → 头插,排到chosen前
第4圈(serial,depth=1): 父=nps[1]="/"  → 头插,排最前
第5圈(uart_clk,d=2):   父=nps[2]="serial"(第4圈记的!) → 头插进serial孩子链
```

### 4.4 populate_node 五步

```text
① fdt_get_name         读节点名,allocl=长度+1(含\0)
② unflatten_dt_alloc   一次切两段:[struct device_node | 名字字符串]
                       np->full_name = (char*)np + sizeof(*np) 指针算术划界
                       memcpy从DTB拷名字
                       of_node_init: kobject_init + fwnode.ops
③ 头插挂树(三行):
   np->parent = dad;
   np->sibling = dad->child;   // (a)np的下一个兄弟=旧链头
   dad->child = np;            // (b)★顺序由这行定:np成链头,旧头挤到第二
                               // 链表顺序由"谁被dad->child指着"定义:
                               // (a)保旧头不丢,(b)定新头,两行合起来=头插O(1)
④ populate_properties: 遍历属性token
   每属性切一块struct property(尾插保DTB顺序,与节点头插相反)
   pp->name/pp->value ★直接引用DTB原文不拷贝★ ← DTB要reserve+只读保护的根源
⑤ 回填快捷指针:
   np->name  = of_get_property(np,"name",NULL)       // "memory"(@前部分)
   np->type  = of_get_property(np,"device_type",NULL)
   作用: 最常用查询缓存成O(1)字段(空间换时间)
```

### 4.5 关键区分

| | device_node | property |
|---|---|---|
| 角色 | 节点（DTS 一个 `{}`） | 属性（DTS 一行 `xxx=yyy`） |
| 关系 | parent/child/sibling 树 | 链表挂在 np->properties |
| name | "memory@0"→full_name / "memory"→name 快捷 | "reg" |
| value | 无 | 直接引用 DTB 字节 |

一对多：一个 device_node 串多串 property。

### 4.6 内存位置

- DTB 原文：fixmap 的 FIX_FDT（只读保护，property 引用它的字节）
- 展开的 device_node 树：memblock 分配的线性映射内存（几十 KB 几百节点）
- **两样东西两个地方**

### 4.7 of_root

全局 device_node* 变量，指向展开后的根节点——唯一官方入口，所有 of_find_* 从它出发。child/sibling 是成员指针（"房间里的指路牌"），不是全局变量（"墙上总门牌"只有 of_root；of_chosen/of_aliases 例外）。4.19 没有 allnodes 哈希表（老内核才有）。

## 5. chosen/bootargs 完整链路

```text
① DTB chosen写死(板子dtsi兜底):
   chosen { bootargs = "earlycon=... console=ttyFIQ0 root=PARTUUID=614e0000-0000 rw"; }
② U-Boot fdt fixup: 若env有bootargs → fdt_setprop改写DTB chosen(优先级更高) ★
③ early_init_dt_scan_chosen: 读bootargs → strlcpy进boot_command_line(全局char[2048])
④ setup_arch: *cmdline_p = boot_command_line
⑤ start_kernel: parse_early_param(earlycon/loglevel/init/nokaslr)
                parse_args(root/console/rw)
三个CONFIG: CMDLINE_FORCE(强制)/EXTEND(拼接)/默认(DTB/U-Boot值直接用,本板)
实操改参数: U-Boot setenv bootargs 'xxx'; saveenv; boot —— 免重编DTB
```

## 6. earlycon（启动早期串口打印）

**不是串口驱动**。真正的 uart 驱动 Day6 initcall 才 probe；earlycon 是只写/轮询/无中断的极简通道：

```text
bootargs的earlycon=uart8250,mmio32,0xfe660000
  → parse_early_param → setup_earlycon
  → 注册只实现write/poll_put_char的极简驱动
  → pr_info → printk → earlycon->write → 经FIX_EARLYCON直写UART TX
  → 轮询TX FIFO空再写下一字节
启动日志"console [ttyFIQ0] enabled" = 正式驱动probe后接管的切换时刻
若bootargs无earlycon → banner等早期打印全丢(调板无输出先查这个)
```

## 7. 周边

- **static keys**：零开销开关，关闭=nop、开启=patch 成跳转；jump_label_init patch 初值。用于 tracepoint
- **boot_command_line**：全局 char[2048]（init/main.c:133），赋值链见第 5 节
- **DAIF**：start_kernel 开头 local_irq_disable 只动 PSTATE.I；A/F 的 mask 来自 el2_setup `msr daifset,0xf`。local_daif_restore 解除 A/F 但保持 I 关——时机=earlycon 就绪
- **early_ioremap**：fixmap 的 FIX_BTMAPS 7 个 slot 领用/归还；普通 ioremap 要 buddy 走不通
- **memblock 两本账**：memory（可用，scan_memory 登记）+ reserved（保留，DTB/镜像/栈/ramoops）。memblock_virt_alloc 从 memory−reserved 切、返回线性映射虚拟地址。buddy 就绪后退役。unflatten 的 `mem` 游标只是大块内存内的指针，不是 memblock 本身

## 8. 闭卷标准答案

**Q1 DTB 四段？structure 为什么叫扁平？**
fdt_header(magic 0xd00dfeed+偏移)/reserve map/structure block(节点树 token 流)/strings block(属性名去重池)。DTS 花括号嵌套序列化成 FDT_BEGIN_NODE/PROP/END 线性 token，解析器靠 BEGIN/END 配对还原树——树拍成线性，故称 Flattened。

**Q2 reg/interrupts/compatible/status/pinctrl？怎么读怎么改？**
reg=寄存器地址+长度（按父 cells 分组，驱动 ioremap 用）；interrupts=中断接法（按中断父 cells：类型+号+触发）；compatible=驱动匹配名牌（多字符串先厂商后通用 IP）；status=okay/disabled 开关（SoC 默认关、板级 & 覆盖打开）；pinctrl=引脚复用组（m0/m1 走线按原理图选）。改法：板级 `&label { 属性=新值; }` → make dtbs → 烧写 → cat /proc/device-tree 验证。

**Q3 memory 节点怎么变内存账本？**
early_init_dt_scan_memory 过滤 device_type="memory" → 读 reg 按 cells 解析 base/size → early_init_dt_add_memory_arch → memblock_add。板子 `<0 0 0 0x40000000>` → memblock_add(0,1GB)。之后 arm64_memblock_init 加工（截 PA/保留镜像/栈/记 memstart_addr），paging_init/bootmem_init 从这本账工作。

**Q4 chosen 作用？bootargs 链路？**
chosen 不是真实设备，是 U-Boot↔内核启动参数信箱。链路：DTB chosen 写死（兜底）→ U-Boot fdt fixup 用 env 改写（优先级更高）→ early_init_dt_scan_chosen 读出写 boot_command_line → parse_early_param/parse_args 解析。改参数：U-Boot setenv bootargs 免重编 DTB。

**Q5（验收）DTB 展开用途？展开前后区别？**
展开=unflatten_device_tree 把扁平 token 流变成内存里 parent/child/sibling 指针连接的 device_node 树（of_root 为全局入口）。前：of_scan_flat_dt 全树遍历（慢，仅早期够用）；后：of_find_node_by_path/compatible、of_property_read_u32 按指针直达——之后驱动 probe/设备模型/sysfs 全依赖。两遍扫描（dryrun 算大小→memblock 一大块→游标切割），populate_node 五步（读名/切[结构体+名]/头插挂树/populate_properties 尾插属性且 name/value 引用 DTB 原文/回填快捷指针），最后 reverse_nodes 反转回 DTS 顺序。

**Q6 earlycon 为什么能在串口驱动加载前打印？**
earlycon 是只写/轮询/无中断的极简通道：parse_early_param 处理 bootargs 的 earlycon= → 注册只实现 write 的驱动 → printk 经 fixmap 的 FIX_EARLYCON 直写 UART TX、轮询 FIFO。不依赖 uart 驱动 probe、不用中断/DMA。正式驱动 probe 后接管（日志 "console [ttyFIQ0] enabled"）。

## 9. 踩坑 / 易混点

1. DTB 四段是"文件包装层"，DTS 只写树内容——header/strings 由 dtc 自动生成
2. reserved-memory 节点 ≠ reserve map 段：前者普通节点（structure block 路），后者 `/memreserve/` 写入；都汇进 memblock.reserved
3. property 的 name/value **不拷贝**，直接引用 DTB 原文——所以 DTB 物理内存被 reserve+只读保护，是"活体数据"
4. 4.19 无 of_allnodes 全局哈希表（老内核才有）；of_root 是唯一官方树入口
5. 节点头插（快，顺序反，需 reverse）vs 属性尾插（保序）——选择原因不同
6. np->full_name="memory@0"（建节点时拷贝），np->name="memory"（属性链查出的快捷指针）——来源与含义不同
7. unflatten 分配在 memblock 线性映射区，**不在 fixmap**；DTB 原文才在 fixmap
8. memblock_virt_alloc 返回虚拟地址（线性映射），memblock 本身管物理账
9. earlycon 与 console=ttyFIQ0 是两套：前者启动早期、后者正式驱动接管后
10. fixmap walk 路径：TTBR1→swapper L0→bm_pud→bm_pmd→bm_pte→目标物理页；前三级 early_fixmap_init 搭、叶子具体使用者填

## 10. 明日（Day5）

rest_init 深入：kernel_thread 创建 PID 1/2、PID 0 变 idle、kernel_init → initcalls → rootfs。验收：解释 PID 0/1/2 如何产生。


## 十一、追问实录（Q&A 合并版——同一知识点的多轮追问已合并整理）

> 本节把 Day4 全部追问按知识点归并：每个知识点下列"我的问题 → 答案要点"，同主题的连续追问合并为一条链。讲解时展示的关键代码在第十二节。

### A. DTB 格式与设备树概念

**Q：设备树就是 FDT 吗？还是 U-Boot 把设备树压缩成 FDT？**
不是"压缩"是"编译"。DTS（文本源码，人写）—dtc编译→ DTB（二进制，机器读）；FDT 是 DTB 的别名（Flattened，强调扁平结构），内核 `fdt_*` 函数处理的就是 DTB。U-Boot 不生成只搬运（可选 fdt_fixup 改几个字段）。

**Q：fdt_header / reserve map / structure block / strings block 在 DTS 里都是以根节点形式表现吗？**
都不是。这四段是 DTB 的"文件包装层"：header 和 strings 由 dtc 自动生成（DTS 无对应）；structure block 是整棵 DTS 树的序列化；reserve map 对应 `/memreserve/` 语法（极少用）。`reserved-memory` 节点是普通节点走 structure block，内核扫到后调 memblock_reserve——与 reserve map 是两条都通向 memblock.reserved 的路径。写 DTS 只关心节点和属性，四段布局编译器自动管。

**Q：structure block 是什么？"深度优先序列化成 token"什么意思？**
DTS 的花括号嵌套没法用二进制表示，改用 token 指令流：`FDT_BEGIN_NODE("/")` → `FDT_PROP(name=len+data)` → `FDT_BEGIN_NODE("chosen")` → ... → `FDT_END_NODE`×N → `FDT_END`。解析器读 token 时按"进入节点→处理属性→进子节点→回浮"顺序，靠 BEGIN/END 配对（括号匹配）还原树。"Flattened"=树拍平成线性流（对比 Open Firmware 早期的实时树对象）。

**Q：strings block 是什么？**
属性名（`model`/`reg` 出现几百次）的去重字符串池。structure block 里的 FDT_PROP 不存属性名本身，只存 nameoff（池内偏移），体积砍半以上。节点名不进池（直接存 BEGIN_NODE 后，出现次数少没必要去重）。

**Q：DTB/DTS 就是设备树吗？**
都是。DTS=源码形态、DTB=二进制形态，泛称"设备树"——类比 .c 和 ELF 都叫"程序"。

**Q：DTB 可以打包进 boot 自动加载，也可以自己手动加载到内存某区域？**
对。① boot 分区独立文件由 bootcmd 自动 fatload（正常开机）；② U-Boot 命令行手动 fatload/tftpboot 到任意地址再 booti 指定（调试常用，tftp 拉新 dtb 免插卡）。

### B. of_scan_flat_dt 遍历机制

**Q："深度优先遍历器对每个节点调回调、边还原树边调回调"没理解？**
of_scan_flat_dt 内部就是 `while ((node = fdt_next_node(...)) >= 0) callback(node, uname, depth, data);`。以 `/`→chosen→memory@0 为例：step1 回调("/",depth=0)、step2 回调("chosen",depth=1)、step3 回调("memory@0",depth=1)……解析器不先建完整树对象，**读到哪里就回调到哪里**，token 流用完即走。`early_init_dt_scan_memory` 回调里第一行 `strcmp(type,"memory")` 不匹配就 return——1000 个节点只有 memory 节点真正被处理。

**Q：根节点就是根下一层面的属性吗？**
根节点是 DTS 里 `/ { ... }` 的整体；"根节点的属性"指直接写在 `/` 里的（model/compatible）。根节点 ≠ 根的属性。

### C. setup_machine_fdt 与三扫

**Q：setup_machine_fdt 干了什么？为 fdt 注册页表、扫描、导出参数吗？**
三件事都对，但页表不是它自己写——它调 `fixmap_remap_fdt` 完成映射（铺路的是前面的 `early_fixmap_init`/`early_ioremap_init`）。完整：①fixmap 映射 DTB ②memblock_reserve 保护 ③early_init_dt_scan 扫描导出（memory→memblock、chosen→boot_command_line、根节点 model）④只读重映射 ⑤打印 Machine model。

**Q：early_fixmap_init 和 early_ioremap_init 分别完成了什么？**
early_fixmap_init：在 swapper 树里为 FIXADDR 区补建 L0→L1→L2 目录链（指向 .bss 预预留的 bm_pud/bm_pmd/bm_pte），之后"改一个 PTE 就能映射"。early_ioremap_init：初始化 FIX_BTMAPS 的 7 个临时 slot 的占用管理。

**Q：early_init_dt_scan_memory 在哪出现的？干什么？返回什么？**
在 early_init_dt_scan_nodes() 里被 of_scan_flat_dt 调用（三扫之一）。干什么：过滤 device_type="memory" 节点 → 读 reg → 按 cells 分组解析 base/size → `early_init_dt_add_memory_arch(base,size)` 进 memblock。返回 0 = "继续扫"（要收集所有 memory 节点所以处理完也返回 0）；非 0 = "停止遍历"。

### D. fixmap 专题（温习+深挖）

**Q：fixmap 是什么？**
虚拟地址区里编译期固定的预留槽段（FIXADDR_START~TOP）。普通 ioremap 要 buddy（vmalloc 区+vmap_area+alloc_pages），启动早期没分配器走不通；fixmap 把"找虚拟地址"省掉（`__fix_to_virt(idx)` 编译期算死），只剩"改 PTE"，且 PTE 所在页表页也是预预留的——全程零分配。两类槽位：永久（FIX_FDT/FIX_EARLYCON 一直挂着）vs 临时（FIX_BTMAPS 领用归还）。

**Q：MMU 怎么找到 fixmap 虚拟地址的根目录对应物理地址？**
MMU 不"找"，它只是无脑按 VA 位段查表。路径：TTBR1(swapper) → L0 格（early_fixmap_init 填 = bm_pud 物理|TABLE）→ bm_pud → bm_pmd → bm_pte 的 PTE（fixmap_remap_fdt 填 = DTB 物理页|属性）。前三级 early_fixmap_init 用 .bss 预留表搭好，叶子由具体使用者填——"查一张已经铺好的路"。

**Q：DTB 是被映射到 fixmap 了是吗？**
对，FIX_FDT 槽位。fixmap_remap_fdt 的鸡生蛋解法值得记：先映射 2MB 块（够放 DTB 头）→ 读 totalsize → 跨块再补映射。扫完后以 PAGE_KERNEL_RO 重映射为只读保护。

**Q：early_ioremap 机制？**
fixmap 的 FIX_BTMAPS 7 个 slot 领用/归还：early_ioremap(addr,size) = 领 slot → 改 PTE 指向 addr → 返回虚拟地址；用完 early_iounmap 清 PTE 归还。与普通 ioremap 区别就在"不分配"。

### E. earlycon 串口打印

**Q：pr_info("Machine model") 的串口打印调用了串口驱动吗？驱动初始化在哪步完成的？**
不是串口驱动（那要 Day6 initcall 才 probe），是 **earlycon**——只写/轮询/无中断的极简通道。初始化链：bootargs 的 `earlycon=uart8250,mmio32,0xfe660000` → setup_arch 里 parse_early_param → setup_earlycon → 注册只实现 write/poll_put_char 的驱动 → printk 经 FIX_EARLYCON 槽位直写 UART TX 寄存器、轮询 FIFO。启动日志 "console [ttyFIQ0] enabled" = 正式驱动 probe 后接管的切换时刻。若 bootargs 无 earlycon，banner 等早期打印全丢（调板无输出先查这个）。

### F. static keys 与 DAIF

**Q：static keys 是什么？**
零开销运行时开关。关闭时代码是 1 条 nop、开启时内核把指令原地 patch 成跳转（code patching）。jump_label_init 把初始状态 patch 好。用于 tracepoint/调试开关。

**Q：local_daif_restore 前面哪一步开启了异常屏蔽？**
不是 start_kernel 开头的 local_irq_disable（那只动 PSTATE.I）。A(SError)/F(Fiq) 的 mask 来自更早的 el2_setup `msr daifset, 0xf`（CPU 上电就全 mask，U-Boot 延续）。local_daif_restore(DAIF_PROCCTX_NOIRQ) 解除 A/F 但保持 I 关——时机=earlycon 就绪、"终于能打印 SError 了"的最早时刻。

### G. boot_command_line 链路

**Q：boot_command_line 是什么？在哪定义？在哪赋值？**
内核命令行的全局 char[2048]（init/main.c:133）。赋值链：① DTB chosen 节点写死 bootargs（兜底）② U-Boot fdt fixup 用 env 的 bootargs 改写 DTB（优先级更高）③ early_init_dt_scan_chosen 读出 strlcpy 进 boot_command_line ④ setup_arch `*cmdline_p = boot_command_line` ⑤ start_kernel 的 parse_early_param/parse_args 解析。U-Boot 实操改参数：`setenv bootargs 'xxx'; saveenv; boot`——免重编 DTB。

### H. unflatten_device_tree 专题（追问最密集，按层合并）

**Q：unflatten_device_tree 干什么？**
把扁平 DTB 展开成内存里的 device_node 树（parent/child/sibling 指针连接），挂到全局 of_root。之前只能 of_scan_flat_dt 全树扫（慢）；之后 of_find_node_by_path/of_find_compatible_node/of_property_read_u32 按指针直达——之后所有驱动 probe、设备模型匹配都依赖这棵树。

**Q：__unflatten_device_tree 怎么做到每个节点分配一个 device_node？**
两遍扫描：第一遍 dryrun（mem 传 NULL）只统计总字节数 → dt_alloc（=memblock_virt_alloc）一次拿一大块 → 第二遍真建，unflatten_dt_alloc 游标递增切割。不是每节点调一次分配器——只碰一次 memblock，其余纯指针算术。

**Q：unflatten_dt_nodes 还是没看懂，结合具体 DTB 讲。**
主循环就三件套：`for (offset=0; offset>=0; offset=fdt_next_node(blob,offset,&depth)) populate_node(blob,offset,&mem,nps[depth],&nps[depth+1],dryrun);`。nps[depth] 记"每深度最近节点"，新节点的父亲=浅一层最近节点——**父子关系全靠这个数组建立**。五圈实例（/ → chosen → memory@0 → serial → uart_clk）：第 1 圈根写进 of_root；第 3 圈 memory 头插到 chosen 前；第 5 圈 uart_clk 的父=第 4 圈刚记的 serial。循环完 reverse_nodes 反转每层链。

**Q：populate_node 具体怎么运行？**
五步：① fdt_get_name 读节点名 ② unflatten_dt_alloc 切 [sizeof(device_node)+名字长度] 一块（一次分配两样东西放同段内存，`np->full_name=(char*)np+sizeof(*np)` 指针算术划界）+ of_node_init ③ 头插挂树三行 ④ populate_properties 遍历属性（每属性切一块 struct property，name/value **直接引用 DTB 原文不拷贝**，尾插保持顺序）⑤ 回填快捷指针 np->name/np->type（把最常用查询缓存成 O(1) 字段）。

**Q："一次切两段：结构体+名字字符串空间"——名字字符串空间是什么？**
一次分配的内存里装两样：前段是结构体、后段放节点名字符串（"memory@0\0" 9 字节）。full_name 指向后段。好处：省一次分配、名字与结构体内存相邻 cache 友好。

**Q：of_node_init 干了什么？什么叫全局哈希表 allnodes？**
4.19 真实源码就两件事：kobject_init（为 sysfs 导出 /sys/firmware/devicetree 做准备）+ fwnode.ops 挂 DT 操作表（ACPI/DT 统一抽象）。**纠错**：4.19 没有 allnodes 哈希表——那是老内核的；4.19 是 of_root 树 + for_each_of_allnodes 宏（从 of_root 遍历）。

**Q：np 是什么？**
node pointer，populate_node 的局部变量 struct device_node*，指向正在新建的节点结构体。内核设备树代码的通用缩写（同理 pp=property pointer）。

**Q：sibling 是结构体指针数组吗？为什么 np->sibling = dad->child 后 np 在旧头前面？**
不是数组，是单个指针（指向"我的下一个兄弟"）。顺序不取决于赋值那行，而取决于 `dad->child = np`（b 行）——链表顺序由"谁被 dad->child 指着"定义：(a) `np->sibling=旧头` 保旧头不丢，(b) `dad->child=np` 让 np 成链头，两行合起来=头插。改写成尾插（旧头->sibling=np）就排后面。头插原因：O(1) 不用遍历链尾；代价是顺序反，最后 reverse_nodes 反转。

**Q：只有 of_root 是全局指针吗？child/sibling 里存的不是全局指针吗？**
of_root 是全局变量（唯一官方树入口，of_find_* 都从它出发）。child/sibling 是结构体成员指针——对象在共享内存里但你没变量名访问，必须先拿到某个节点指针才能顺着摸。类比：of_root 是墙上的总门牌，child/sibling 是房间里的指路牌。（of_chosen/of_aliases 是高频快捷全局，例外。）

**Q：early_init_dt_alloc_memory_arch 给 device_node/property 分配的虚拟地址是 fixmap 里的吗？device_node 和 property 是一个东西吗？**
不是 fixmap——它转调 memblock_virt_alloc：从 memblock 拿物理页、返回**线性映射区**虚拟地址。DTB 原文在 fixmap/FIX_FDT，展开的树在 memblock 线性映射内存——两样东西两个地方（树几十 KB 也塞不进 fixmap 那几页）。device_node 和 property 不是同一个东西：前者管"我是谁、挂哪"（树形关系），后者管"我有什么参数"（键值对），一对多——一个节点的 properties 链上挂多串 property。

**Q：回填快捷指针是什么意思？有什么作用？**
np->name/np->type 本来要走 properties 链 strcmp 查（O(n)），回填就是查一次把结果（value 指针）缓存成结构体字段，之后 O(1) 解引用。空间换时间的查询缓存。注意与 full_name 区别：full_name="memory@0"（建节点时拷贝），name="memory"（属性链查出的 @ 前部分）。

**Q：populate_properties 里 name/value 引用 DTB 原文是什么意思？**
pp->name 直接指向 DTB strings block 里的字符串、pp->value 直接指向 DTB 里的值字节——**不拷贝**。这就是 DTB 物理内存被 memblock_reserve + 只读重映射保护的原因：它是 device_node 树的"活体数据"，被写坏=整棵树内容全坏。

**Q：memblock 是什么？unflatten 里的 mem 就是 memblock 吗？和 scan_memory 填的是一个东西吗？**
memblock 是启动早期临时内存管理器，管两本账：memory（可用，scan_memory 登记的）+ reserved（保留，DTB/镜像/栈/ramoops）。mem 不是 memblock——它只是大块内存里的游标指针（局部变量）。关系：memblock 先分配一大块（memblock_virt_alloc），mem 指向开头，后续切割不再碰 memblock。scan_memory 是"填账"、memblock_virt_alloc 是"取账"——同一个 memblock。buddy 就绪后 memblock 退役。

**Q：头插法是什么？为什么兄弟顺序和 DTB 相反？**
头插=新节点插链表头部。处理顺序 chosen→memory→serial，每来一个都插最前，链变成 serial→memory→chosen（反序）。不尾插因为尾插要遍历到链尾 O(n)、头插 O(1)——几百节点全部头插再一次性 reverse_nodes 反转，比每个尾插快。属性用尾插（保 DTB 顺序）——节点和属性选择相反。

### I. 内存保留

**Q：memblock_reserve 和 reserved-memory 节点什么关系？/memreserve/ 呢？**
两个独立机制汇进同一本账 memblock.reserved：① memblock_reserve(addr,size) 代码主动调（保护 DTB 自己、内核镜像、PID0 栈、initramfs）② reserved-memory 节点（DTS 写节点，内核 fdt_init_reserved_mem 扫到后调 memblock_reserve——板子的 ramoops@110000 就是）。/memreserve/ 是 DTS 语法直接进 DTB reserve map 段的老 OF 风格，几乎不用。效果：mm_init 建 buddy 时"memblock.memory − reserved = 可用页"，保留区永不进空闲池。CMA=reserved-memory 的 shared-dma-pool 特例（Camera DMA 要连续物理内存的根本原因）。

### J. 页表温习（Day2 回顾）

**Q：idmap 和 kernel map 的有效位都和物理地址一样吗？（有效位指 VA 低 48 位）**
只有 idmap 成立：VA==PA 逐位相同（翻译等于没翻译）。kernel map 不成立：VA=0xffff8000... 高半段，与 PA 差 kimage_voffset（0xffff800010000000 级别的固定差）。两棵树叶子 PTE 属性位倒是逐位相同（同一个 SWAPPER_MM_MMUFLAGS）。如果 kernel map VA 也等于 PA 就不需要两棵树了——高地址隔离用户/内核才是第二棵树的目的。

**Q：L1 填 2 项时 L2 只写第一页吗？（因为 mov tbl,sv 推进后 tbl 是下一级第一页）**
不漏——两张 L2 都会写。关键在 compute_indices 开头 `iend += (count-1)*ptrs` 缩放：L1 填 2 项 → count=2 传给 L2 → L2 的 iend 被缩放成跨 2 张表的全局下标（1023）→ populate 循环 index 0~1023，index=512 时字节偏移 4096 正好落到物理紧邻的第二张表 [0]。mov tbl,sv 只管把 tbl 设到本层第一张表（起点），跨表靠 index 连续增长天然完成（终点靠 count 缩放、物理连续兜底）。

**Q：先定 vstart 还是先算 voffset？**
vstart 编译期定死（KIMAGE_VADDR+TEXT_OFFSET 写在链接脚本里），voffset 运行时才算（__primary_switched 里 adrp 取到 RAM_BASE 后 VA−PA）。顺序本质：镜像虚拟基址链接期写死、物理基址运行时才知道（同一份 Image 烧不同板都行）。启动早期汇编不需要 voffset（建表用编译期值、访问符号用 PC 相对寻址），voffset 是给 C 代码 __pa/__va 准备的。

## 十二、追问讲解源码实录（问答时展示的代码+注释版）

> 本节收录 Day4 学习过程中追问环节展示过的代码——按追问顺序排列，带讲解注释，复习时直接读这节回忆"为什么"。

### 11.1 fixmap 是什么（温习追问）

`enum fixed_addresses`（arch/arm64/include/asm/fixmap.h:36）——fixmap 区按枚举切成固定槽：

```c
enum fixed_addresses {
    FIX_HOLE,                       // 占位
    FIX_FDT_END, FIX_FDT,           // ★DTB的固定映射窗口(2MB+MAX_FDT_SIZE)
    FIX_EARLYCON_MEM_BASE,          // ★earlycon的UART寄存器映射(串口打印用的!)
    FIX_TEXT_POKE0,                 // 运行时改指令(static keys用的)

    __end_of_permanent_fixed_addresses,   // 永久映射项到此
    FIX_BTMAP_END, FIX_BTMAP_BEGIN,       // ★early_ioremap的临时slot区(7个slot×64页)
    FIX_PTE, FIX_PMD, FIX_PUD, FIX_PGD,   // 建页表本身用的临时页
};
// 两类用法: 永久(FIX_FDT/EARLYCON一直挂着) vs 临时(BTMAPS领用→iounmap归还)
```

`early_fixmap_init`（arch/arm64/mm/mmu.c:843）——补目录链，把 fixmap 区接进 swapper 树：

```c
void __init early_fixmap_init(void)
{
    unsigned long addr = FIXADDR_START;

    pgdp = pgd_offset_k(addr);              // 按FIXADDR_START的VA[47:39]定位swapper树里的L0格
    // 该格原来是0(invalid)——Day2的map_memory只映了内核镜像,fixmap区是空的
    if (pgd_none(pgd))
        __pgd_populate(pgdp, __pa_symbol(bm_pud), PUD_TYPE_TABLE);  // ★L0格→指向bm_pud
    pudp = fixmap_pud(addr);                 // 到bm_pud表里定位fixmap的L1下标

    if (pud_none(READ_ONCE(*pudp)))
        __pud_populate(pudp, __pa_symbol(bm_pmd), PMD_TYPE_TABLE);  // ★L1格→指向bm_pmd
    pmdp = fixmap_pmd(addr);

    __pmd_populate(pmdp, __pa_symbol(bm_pte), PMD_TYPE_TABLE);      // ★L2格→指向bm_pte
    // 补完PGD→PUD→PMD路径,之后"改一个PTE就能立即映射"——叶子留给具体使用者填
}
```

bm 三张表的定义（mmu.c:68）——.bss 预预留、不需要分配的页表页：

```c
static pte_t bm_pte[PTRS_PER_PTE] __page_aligned_bss;   // L3叶子表,512项,一整页
static pmd_t bm_pmd[PTRS_PER_PMD] __page_aligned_bss;   // L2表
static pud_t bm_pud[PTRS_PER_PUD] __page_aligned_bss;   // L1表
// __page_aligned_bss: 各占一页、页对齐,内核镜像自带 → 启动早期能用的根本
```

**MMU 访问 FIX_FDT 的完整 walk（追问"MMU怎么找到fixmap的根"）**：

```text
TTBR1 = swapper_pg_dir
  └─ swapper树L0格  ← early_fixmap_init填的 = bm_pud物理地址|TABLE
       └─ bm_pud[L1格] ← 同上填的 = bm_pmd物理地址|TABLE
            └─ bm_pmd[L2格] ← 同上填的 = bm_pte物理地址|TABLE
                 └─ bm_pte[PTE格] ← fixmap_remap_fdt填的!★ = DTB物理页|属性
                       → 翻译完成,落到DTB
分工: early_fixmap_init搭前三级(.bss预留表), 具体使用者填最后一片叶子
```

### 11.2 fixmap_remap_fdt（追问"DTB是被映射到fixmap了吗"）

arch/arm64/mm/mmu.c:916：

```c
void *__init fixmap_remap_fdt(phys_addr_t dt_phys, int *size, pgprot_t prot)
{
    const u64 dt_virt_base = __fix_to_virt(FIX_FDT);   // ① DTB专属虚拟地址(编译期算死)
    ...
    if (!dt_phys || dt_phys % MIN_FDT_ALIGN)           // ② 物理地址8字节对齐检查
        return NULL;

    offset = dt_phys % SWAPPER_BLOCK_SIZE;             // ③ DTB在2MB块内的偏移
    dt_virt = (void *)dt_virt_base + offset;

    /* ④ 先映射第一个2MB块——为了能读DTB头部的totalsize字段 */
    create_mapping_noalloc(round_down(dt_phys, SWAPPER_BLOCK_SIZE),
                    dt_virt_base, SWAPPER_BLOCK_SIZE, prot);
    // ↑ noalloc=只改PTE不分配页表页(中间层已由early_fixmap_init搭好)

    if (fdt_magic(dt_virt) != FDT_MAGIC)               // ⑤ 读magic验证(0xd00dfeed)
        return NULL;

    *size = fdt_totalsize(dt_virt);                    // ⑥ 读头部totalsize
    if (*size > MAX_FDT_SIZE)                          //    超2MB上限拒绝
        return NULL;

    /* ⑦ DTB跨多个2MB块时补映射(鸡生蛋:不映射读不了头,先映2MB肯定够放头) */
    if (offset + *size > SWAPPER_BLOCK_SIZE)
        create_mapping_noalloc(..., round_up(offset + *size, SWAPPER_BLOCK_SIZE), prot);

    return dt_virt;
}
// 调用方(setup_machine_fdt): 先以PAGE_KERNEL映射(扫描用),
// 扫完再以PAGE_KERNEL_RO重映射为只读(保护DTB不被后续写坏)
```

### 11.3 early_init_dt_scan_memory（追问"干了什么返回什么"）

drivers/of/fdt.c:1121——`of_scan_flat_dt` 的回调，每扫一个节点调一次：

```c
int __init early_init_dt_scan_memory(unsigned long node, const char *uname, int depth, void *data)
{
    // 1. 过滤:只处理 device_type="memory" 的节点,其他节点直接return
    const char *type = of_get_flat_dt_prop(node, "device_type", NULL);
    if (type == NULL || strcmp(type, "memory") != 0)
        return 0;

    // 2. 读reg属性(优先linux,usable-memory,没有就读reg)
    reg = of_get_flat_dt_prop(node, "reg", &l);

    // 3. 循环解析reg里的每一对(base,size)
    while ((endp - reg) >= (dt_root_addr_cells + dt_root_size_cells)) {
        u64 base, size;
        base = dt_mem_next_cell(dt_root_addr_cells, &reg);  // 取2个cell拼成64位地址
        size = dt_mem_next_cell(dt_root_size_cells, &reg);  // 取2个cell拼成64位长度
        if (size == 0) continue;

        early_init_dt_add_memory_arch(base, size);   // ★加进memblock.memory
    }
    return 0;   // ★返回0="继续扫下一个节点";非0="找到目标停止遍历"
                // memory要收集所有节点,处理完也返回0
}
// 对应板子 reg=<0 0 0 0x40000000> → base=0, size=1GB → memblock_add(0, 1GB)
```

### 11.4 unflatten_dt_nodes（追问"结合具体DTB讲一遍"）

drivers/of/fdt.c:456——展开主循环。用这棵 DTB 演示：

```dts
/ { chosen { }; memory@0 { }; serial@fe660000 { uart_clk { }; }; };
// token流(深度优先): BEGIN"/" BEGIN"chosen" END BEGIN"memory@0" END
//                     BEGIN"serial" BEGIN"uart_clk" END END END
```

```c
static int unflatten_dt_nodes(const void *blob, void *mem,
                              struct device_node *dad, struct device_node **nodepp)
{
    struct device_node *nps[FDT_MAX_DEPTH];   // ★每深度记"最近一个该深度的节点"
    void *base = mem;
    bool dryrun = !base;                       // mem传NULL = 第一遍只统计不建

    for (offset = 0; offset >= 0; offset = fdt_next_node(blob, offset, &depth)) {
        //                    ↑token游标:每调一次走到下一个节点,报出深度

        populate_node(blob, offset, &mem, nps[depth], &nps[depth+1], dryrun);
        //                      ↑内存游标   ↑我的父亲=浅一层最近节点  ↑把我记在这层
        if (!dryrun && nodepp && !*nodepp)
            *nodepp = nps[depth+1];            // 第一个建的就是根 → 写进of_root
    }
    ...
    // 循环结束后 reverse_nodes 每层反转child链(头插导致顺序反了)
}
```

五圈演算（nps[] 的变化）：

```text
第1圈("/",depth=0):     父=nps[0]=NULL → 不挂链,*nodepp="/" → of_root
第2圈("chosen",depth=1): 父=nps[1]="/"(第1圈记的) → 头插进"/"的孩子链
第3圈("memory",depth=1): 父=nps[1]="/" → 头插,排到chosen前面
第4圈("serial",depth=1): 父=nps[1]="/" → 头插,排最前
第5圈("uart_clk",depth=2): 父=nps[2]="serial"(第4圈记的!) → 头插进serial的孩子链
父子关系全靠nps[]建立,无需回溯
```

### 11.5 populate_node（追问"具体怎么运行、每步怎么做"）

drivers/of/fdt.c:373——"给一个DTB节点建一个device_node并挂进树"的工人：

```c
static bool populate_node(const void *blob, int offset, void **mem,
                          struct device_node *dad, struct device_node **pnp, bool dryrun)
{
    struct device_node *np;
    // ① 拿节点名
    pathp = fdt_get_name(blob, offset, &l);   // 从DTB token读出"memory@0", l=长度
    allocl = ++l;                              // +1 = 字符串结尾'\0'的字节

    // ② 分配并填充: 一次切两段(结构体+名字)同块连续内存
    np = unflatten_dt_alloc(mem, sizeof(struct device_node) + allocl, ...);
    //                                   ↑结构体本身        ↑名字字符串空间
    if (!dryrun) {
        of_node_init(np);                      // kobject_init + fwnode.ops(见11.7)
        np->full_name = fn = ((char *)np) + sizeof(*np);
        //              ↑指针算术划界: 结构体结尾处 = 字符串起始处
        memcpy(fn, pathp, l);                  // "memory@0\0"从DTB拷进那块空间

    // ③ 头插挂树(三行)
        if (dad != NULL) {
            np->parent = dad;          // 我的父亲
            np->sibling = dad->child;  // (a)np的下一个兄弟 = 旧链头
            dad->child = np;           // (b)★顺序由这行决定: np成为链头,旧头被挤到第二
        }                              // 链表顺序由"谁被dad->child指着"定义:
                                         // (a)保旧头不丢,(b)定新头,两行合起来=头插(O(1)无需遍历)
    }

    // ④ 处理属性
    populate_properties(blob, offset, mem, np, pathp, dryrun);

    // ⑤ 回填快捷指针
    if (!dryrun) {
        np->name = of_get_property(np, "name", NULL);          // "memory"(@前)
        np->type = of_get_property(np, "device_type", NULL);   // 查一次的结果缓存成字段
    }                                                        // O(n)走链变O(1)解引用

    *pnp = np;      // 输出:新节点交给调用方(记进nps[depth+1])
    return true;
}
```

populate_properties 的属性循环（fdt.c:285）：

```c
for (cur = fdt_first_property_offset(blob, offset);
     cur >= 0;
     cur = fdt_next_property_offset(blob, cur)) {     // ① 遍历该节点的所有属性token

    val = fdt_getprop_by_offset(blob, cur, &pname, &sz);  // 拿属性名(查strings block)+值+长度

    pp = unflatten_dt_alloc(mem, sizeof(struct property), ...);  // ② 每属性切一块
    if (dryrun) continue;

    pp->name   = (char *)pname;    // ③ ★不拷贝!直接引用DTB原文(strings block里的字符串)
    pp->length = sz;
    pp->value  = (__be32 *)val;    //    ★值也直接引用DTB里的字节
    *pprev     = pp;               // ④ 尾插(保持DTB顺序——属性尾插,节点才是头插)
    pprev      = &pp->next;
}
// 这就是DTB物理内存被memblock_reserve+只读重映射保护的原因:
// property的name/value是"活体引用",DTB被写坏=整棵device_node树的内容全坏
```

unflatten_dt_alloc 游标切割（fdt.c:260）：

```c
static void *unflatten_dt_alloc(void **mem, unsigned long size, unsigned long align)
{
    *mem = PTR_ALIGN(*mem, align);   // 对齐
    res = *mem;                       // 从当前游标切
    *mem += size;                     // 游标前进
    return res;
    // 不是每节点调一次memblock——全部节点共享一大块memblock内存,指针递增切割
}
```

### 11.6 struct device_node / property 对照（追问"是一个东西吗"）

```c
struct device_node {              // 节点: 对应DTS里的一个{}, 管"我是谁、挂哪"
    const char *name;             //   "memory"(快捷指针,@前部分)
    const char *full_name;        //   "memory@0"(建节点时拷贝的完整名)
    struct property *properties;  //   ★属性链表头
    struct device_node *parent, *child, *sibling;  // 左孩子右兄弟
    struct kobject kobj;          //   sysfs导出用
};

struct property {                 // 属性: 对应DTS节点里一行 xxx = yyy, 管"我有什么参数"
    char *name;                   //   "reg"
    int length;                   //   值长度(16字节)
    void *value;                  //   值数据(直接引用DTB原文!)
    struct property *next;        //   链表(尾插保持DTB顺序)
};
// 一个device_node + 一串property(一对多); of_property_read_u32 就是
// 沿np->properties链找到name匹配的property、从value里读数
```

### 11.7 of_node_init（追问"干了什么、allnodes是什么"——含纠错）

include/linux/of.h:108（4.19 真实源码）：

```c
static inline void of_node_init(struct device_node *node)
{
#if defined(CONFIG_OF_KOBJ)
    kobject_init(&node->kobj, &of_node_ktype);   // ① 初始化kobject(sysfs设备模型基类)
#endif                                            //   之后能导出到 /sys/firmware/devicetree/
    node->fwnode.ops = &of_fwnode_ops;            // ② 挂fwnode操作表(ACPI/DT统一抽象)
}
// ★纠错记录: 4.19没有"挂进全局哈希表allnodes"这回事——那是4.x之前的老内核;
//   4.19是of_root树 + for_each_of_allnodes宏(从of_root遍历,不是哈希表)
```

### 11.8 early_init_dt_alloc_memory_arch（追问"分配的是fixmap吗"）

drivers/of/fdt.c:1330：

```c
static void * __init early_init_dt_alloc_memory_arch(u64 size, u64 align)
{
    return memblock_virt_alloc(size, align);
    // ★memblock不是fixmap! 从memblock管理的物理内存切,返回线性映射区虚拟地址
    // (PAGE_OFFSET+物理偏移)。"virt"=返回的是虚拟地址(memblock本身管物理账)
    // 它是适配层: __unflatten_device_tree设计为"分配策略由调用方注入"(dt_alloc函数指针)
}
```

device_node 树在内存里的位置（两样东西两个地方）：

```text
DTB原文(blob)  → fixmap的FIX_FDT槽位     (只读保护,property引用它的字节)
展开的device_node树 → memblock分配的线性映射内存 (长期常驻,几百节点几十KB)
```

### 11.9 early_init_dt_scan_chosen（chosen/bootargs 链路追问）

drivers/of/fdt.c:1191：

```c
int __init early_init_dt_scan_chosen(unsigned long node, const char *uname, int depth, void *data)
{
    char *cmdline = data;   // data就是boot_command_line(全局char[2048], init/main.c:133)

    // 过滤: 只处理depth=1且名字叫"chosen"的节点
    if (depth != 1 || !cmdline ||
        (strcmp(uname, "chosen") != 0 && strcmp(uname, "chosen@0") != 0))
        return 0;

    early_init_dt_check_for_initrd(node);    // 顺便扫initrd位置

    // 处理CONFIG_CMDLINE_FORCE/EXTEND(内核可配置强制覆盖/扩展)
    if (overwrite_incoming_cmdline || !cmdline[0])
        strlcpy(cmdline, config_cmdline, COMMAND_LINE_SIZE);

    // ★读chosen节点的bootargs属性
    if (read_dt_cmdline)
        p = of_get_flat_dt_prop(node, "bootargs", &l);

    if (p != NULL && l > 0) {
        if (concat_cmdline)
            strlcat(cmdline, p, ...);   // EXTEND模式: 拼接
        else
            strlcpy(cmdline, p, ...);   // 默认: 覆盖
    }
}
// 完整链路: DTB chosen写死(兜底) → U-Boot fdt fixup用env改写(优先级更高)
//         → 此处读出 → boot_command_line → parse_early_param/parse_args解析
```

### 11.10 __unflatten_device_tree 两遍扫描（追问"怎么做到每个节点分配一个"）

drivers/of/fdt.c:536：

```c
void *__unflatten_device_tree(const void *blob, struct device_node *dad,
                              struct device_node **mynodes,
                              void *(*dt_alloc)(u64 size, u64 align), bool detached)
{
    // 第一遍: dryrun——只数不建,算出整棵树展开需要多少字节
    size = unflatten_dt_nodes(blob, NULL, dad, NULL);   // mem传NULL=dryrun
    // 返回值 = mem游标累计推进量 = 总字节数

    // 分配一大块连续内存
    mem = dt_alloc(size, 4);       // = early_init_dt_alloc_memory_arch → memblock_virt_alloc

    // 第二遍: 真建——每个节点回调populate_node,从mem里游标递增切割
    unflatten_dt_nodes(blob, &mem, dad, mynodes);       // mynodes = &of_root
    // 整个展开只碰一次memblock,其余全是指针算术——启动早期又快又省
}
```

### 11.11 setup_machine_fdt 主体（Day4 主课展示版）

arch/arm64/kernel/setup.c:192：

```c
static void __init setup_machine_fdt(phys_addr_t dt_phys)
{
    int size;
    void *dt_virt = fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL);  // ① 映射DTB到FIX_FDT
    if (dt_virt)
        memblock_reserve(dt_phys, size);              // ② 保留DTB物理内存(防被分配踩坏)

    if (!dt_virt || !early_init_dt_scan(dt_virt)) {   // ③ 扫描(magic校验失败则停机)
        pr_crit("Error: invalid device tree blob ...");
        while (true) cpu_relax();
    }

    fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL_RO); // ④ 重映射为只读(保护)

    name = of_flat_dt_get_machine_name();             // ⑤ 读根节点model
    pr_info("Machine model: %s\n", name);             //   串口"Machine model: EmbedFire LubanCat-2"
}
```

early_init_dt_scan（fdt.c:1364）：

```c
bool __init early_init_dt_scan(void *params)
{
    status = early_init_dt_verify(params);    // ① 校验DTB(magic+版本+大小)
    if (!status) return false;
    early_init_dt_scan_nodes();               // ② 三扫:
    //   扫根节点(model/compatible/bootargs/initrd)
    //   扫memory节点 → memblock_add ★
    //   扫chosen节点 → boot_command_line ★
    return true;
}
```
