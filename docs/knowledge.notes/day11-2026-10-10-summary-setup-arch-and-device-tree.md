# Day 4 总笔记（原计划 Day4）：setup_arch 与设备树解析——从 DTB 到 device_node 树

> 对应 7 天计划第 4 天：理论=DTS/DTSI/DTB、节点属性、内存保留、bootargs；源码=`setup_arch()`、`setup_machine_fdt()` 和 FDT 扫描，对照鲁班猫2 DTS；验收=解释 memory、chosen 与 DTB 展开的用途。
> 源码基准：Rockchip 4.19（虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`）。
> 承接 Day3：`__primary_switched` 把 FDT 指针存进 `__fdt_pointer`，`start_kernel` 阶段 2 调 `setup_arch`——从这里开始。
> `paging_init` 按用户决定划到第二周第 10 天（内存地址模型），不在本日范围。

## 〇、全局链路（本日主线一张图）

```text
__fdt_pointer (DTB物理地址, Day3存的)
  ↓ setup_arch (arch/arm64/kernel/setup.c:258)
  │  ├─ early_fixmap_init()      补swapper树里fixmap区的目录链(指向.bss预留的bm_pud/pmd/pte)
  │  ├─ early_ioremap_init()     初始化early_ioremap的slot管理
  │  ├─ setup_machine_fdt(__fdt_pointer)   ★
  │  │    ├─ fixmap_remap_fdt: DTB映射到FIX_FDT槽位(先映2MB→读totalsize→补映)
  │  │    ├─ memblock_reserve(DTB自身)
  │  │    ├─ early_init_dt_scan: 三扫(根节点/memory→memblock/chosen→boot_command_line)
  │  │    └─ 重映射只读 + 打印"Machine model: EmbedFire LubanCat-2"
  │  ├─ parse_early_param()      解析earlycon=等early参数(earlycon在此激活!)
  │  ├─ cpu_uninstall_idmap()    卸载TTBR0的idmap(使命完成)
  │  ├─ arm64_memblock_init()    memblock加工:截PA位/保留内核镜像/PID0栈/记录memstart_addr
  │  ├─ paging_init()            (划到Day10)
  │  ├─ unflatten_device_tree()  ★DTB→device_node树(挂到全局of_root)
  │  ├─ bootmem_init()           zone初始化(过渡到Day3学的mm_init)
  │  └─ psci_dt_init/smp_init_cpus  PSCI + 从DTB读cpu节点枚举多核
  ↓ 返回 start_kernel 进阶段3(内存管理)
```

## 一、DTB 文件格式（Flattened 的含义）

四段式布局：

```text
┌─────────────────────┐
│ fdt_header (40字节) │  magic=0xd00dfeed, totalsize, 各段偏移
├─────────────────────┤
│ memory reserve map  │  保留区列表(每项16字节addr+size), /memreserve/语法写入
├─────────────────────┤
│ structure block     │  ★节点树本体: 深度优先token流
├─────────────────────┤
│ strings block       │  属性名字符串池(去重, property只存池内偏移)
└─────────────────────┘
```

- **structure block**：DTS 的花括号嵌套序列化成 `FDT_BEGIN_NODE/FDT_PROP/FDT_END_NODE/FDT_END` 线性 token 流，解析器靠 BEGIN/END 配对还原树。"Flattened"=树拍平成线性流
- **strings block**：`device_type`/`reg` 等属性名全树重复几百次，去重存池、property 里只存 nameoff。节点名不进池（次数少，直接存 BEGIN_NODE 后）
- **四段在 DTS 里的对应**：header/strings 无对应（dtc 自动生成）；structure 对应整棵 DTS 树；reserve map 对应 `/memreserve/`（极少用）。`reserved-memory` 节点是普通节点走 structure block，内核扫到后调 memblock_reserve——与 reserve map 是两条都通向 memblock.reserved 的不同路径

## 二、DTS 节点字段精读（对照 rk3568-lubancat-2 真实源码）

### 文件组织与编辑手法

```text
rk3568.dtsi              SoC公共(所有RK3568板共用), 设备默认 status="disabled"
rk3568-lubancat-2.dtsi   板级公共(chosen/bootargs/reserved-memory/fiq-debugger)
rk3568-lubancat-2.dts    板级入口(#include上面两个, 开启本板用的外设)
编辑手法: &label { status = "okay"; };   ← 引用已有节点追加/覆盖属性
         dtsi默认disabled → dts里开okay → 编译合成一个节点
生效流程: 改dts → make dtbs → 新dtb → 烧写/替换 → 重启
验证:     cat /proc/device-tree/节点/属性
```

### uart2 节点逐字段（rk3568.dtsi:3078）

```dts
uart2: serial@fe660000 {
    compatible = "rockchip,rk3568-uart", "snps,dw-apb-uart";  // 驱动匹配名牌(先厂商后通用IP)
    reg = <0x0 0xfe660000 0x0 0x100>;      // 寄存器:地址0xfe660000 长度256B(#address-cells=2,#size-cells=2)
    interrupts = <GIC_SPI 118 IRQ_TYPE_LEVEL_HIGH>;  // GIC的118号SPI,电平高触发(#interrupt-cells=3)
    clocks = <&cru SCLK_UART2>, <&cru PCLK_UART2>;   // 引用cru时钟控制器
    dmas = <&dmac0 4>, <&dmac0 5>;                   // DMA通道
    pinctrl-0 = <&uart2m0_xfer>;                     // 引脚复用选m0组(引脚走线方案)
    status = "disabled";                             // SoC文件默认关,板级开
};
```

- `reg` 读写法：父节点 cells 决定分组；驱动 probe 时 `platform_get_resource`+`ioremap` 用它
- `interrupts`：`request_irq` 时翻译成软件中断号
- pinctrl（rk3568-pinctrl.dtsi:2251）：`<0 RK_PD0 1 &pcfg_pull_up>` = bank0/D0引脚/复用功能1/上拉；m0/m1 两组物理走线，原理图接哪组选哪组
- compatible 双字符串：先试厂商特定驱动，不匹配退通用 IP 驱动（dw-apb-uart）
- gpio0 节点展示控制器双角色：`gpio-controller`+#gpio-cells（别人引用我）+ 自身 reg/interrupts

## 三、setup_machine_fdt 与 FDT 扫描

### fixmap 基础（温习+深化）

- fixmap = 虚拟地址区里编译期固定的预留槽（`enum fixed_addresses`：FIX_FDT/FIX_EARLYCON_MEM_BASE/FIX_BTMAPS 7个slot/FIX_PTE等），虚拟地址 `__fix_to_virt(idx)` 编译期算死，**不查空闲不分配**
- `early_fixmap_init`（mmu.c:843）：把 swapper 树里 fixmap 区的 L0→L1→L2 目录链接到 **.bss 预预留的 bm_pud/bm_pmd/bm_pte 三张表**（`__page_aligned_bss` 静态数组，`__pa_symbol` 转物理地址填入）。之后"改一个 PTE 就能映射"
- MMU 访问 FIX_FDT 的完整 walk：`TTBR1(swapper) → L0项(early_fixmap_init填) → bm_pud → bm_pmd → bm_pte里的PTE(fixmap_remap_fdt填) → DTB物理页`
- 三住户：FIX_FDT=DTB原文 / FIX_EARLYCON=UART寄存器(0xfe660000) / FIX_BTMAPS=early_ioremap临时slot。共同点：启动早期、buddy未就绪、虚拟地址固定、只改PTE不分配

### fixmap_remap_fdt（mmu.c:916）

```text
① dt_virt_base = __fix_to_virt(FIX_FDT)    编译期固定虚拟地址
② 8字节对齐检查
③ 先映射第一个2MB块 → 读DTB头totalsize(鸡生蛋:不映射读不了头,先映2MB肯定够放头)
④ fdt_magic验证(0xd00dfeed) + MAX_FDT_SIZE上限
⑤ 跨块则补映射
返回dt_virt; 调用方扫完后再以PAGE_KERNEL_RO重映射为只读(保护)
create_mapping_noalloc: 只改PTE不分配页表页——"noalloc"是启动早期能用的精髓
```

### early_init_dt_scan 三扫（drivers/of/fdt.c）

```c
early_init_dt_scan_nodes():
    of_scan_flat_dt(early_init_dt_scan_root, NULL);          // 根: model/compatible
    of_scan_flat_dt(early_init_dt_scan_memory, NULL);        // memory→memblock_add
    of_scan_flat_dt(early_init_dt_scan_chosen, boot_command_line); // chosen→bootargs
```

- `of_scan_flat_dt` = 深度优先遍历器：循环调 `fdt_next_node`(token游标) 对每个节点回调；**边读token边回调，不先建树**（区别于unflatten）
- 回调返回0=继续扫，非0=停止；memory扫描收所有节点所以处理完也返回0

### early_init_dt_scan_memory（fdt.c:1121）

```c
只处理 device_type="memory" 的节点(其余return 0)
读reg属性(优先linux,usable-memory)
循环: base=取2个cell拼64位, size=取2个cell
     early_init_dt_add_memory_arch(base, size)  → memblock_add
对应板子: reg=<0 0 0 0x40000000> → memblock_add(0, 1GB)
```

## 四、unflatten_device_tree——DTB 展开（追问最密集区）

### 两遍扫描架构

```c
__unflatten_device_tree(blob, NULL, &of_root, early_init_dt_alloc_memory_arch, false):
    第一遍: unflatten_dt_nodes(blob, mem=NULL, ...)   dryrun只统计总字节数
    mem = dt_alloc(size, 4)                            memblock_virt_alloc一大块
    第二遍: unflatten_dt_nodes(blob, &mem, ...)        真建,游标递增切割
    最后: reverse_nodes 每层child链反转回DTS顺序
```

**分配策略**：不是每节点调分配器——一次 memblock 拿一大块，`unflatten_dt_alloc`（游标对齐→切→游标前进）纯指针算术切割。

### unflatten_dt_nodes 主循环（fdt.c:456）

```c
struct device_node *nps[FDT_MAX_DEPTH];   // 每深度记"最近节点"
for (offset=0; offset>=0; offset=fdt_next_node(blob, offset, &depth))
    populate_node(blob, offset, &mem, nps[depth], &nps[depth+1], dryrun);
    //                              ↑我的父亲=浅一层最近节点  ↑把我记在这层
```

**父子关系全靠 nps[] 建立**，无需回溯。五圈实例（`/`→chosen→memory@0→serial→uart_clk）见教学记录：第1圈根写进 of_root；第3圈 memory 头插到 chosen 前；第5圈 uart_clk 的父=第4圈刚记的 serial。

### populate_node 五步（fdt.c:373）

```text
① fdt_get_name(blob, offset, &l)          读节点名, allocl=l+1(含\0)
② unflatten_dt_alloc(sizeof(device_node)+allocl)
   一次切两段: [结构体|名字字符串]同块连续内存
   np->full_name = (char*)np + sizeof(*np)  指针算术划界
   memcpy从DTB拷名字
   of_node_init(np): 4.19就两件事——kobject_init(为sysfs导出准备) + fwnode.ops挂DT操作表
③ 头插挂树(三行):
   np->parent = dad;
   np->sibling = dad->child;   // (a)np的下一个兄弟=旧链头
   dad->child = np;            // (b)★顺序由这行决定:np成为链头,旧头被挤到第二
   链表顺序由"谁被dad->child指着"定义——(a)保旧头不丢,(b)定新头,两行合起来=头插
   头插原因: O(1)无需遍历链尾; 代价=顺序反,故最后reverse_nodes反转
④ populate_properties: 遍历该节点属性token
   每属性切一块struct property(尾插保持DTB顺序,与节点头插相反)
   pp->name/pp->value 直接引用DTB原文(不拷贝!)——所以DTB被reserve+只读保护
   (老版本DTB缺name属性时从节点名截@前缀人工补一个)
⑤ 回填快捷指针:
   np->name  = of_get_property(np, "name", NULL)        // "memory"(@前)
   np->type  = of_get_property(np, "device_type", NULL)
   作用: 最常用查询缓存成字段, O(n)走链变O(1)解引用; 空间换时间
```

### struct device_node vs struct property（of.h:51/31）

```c
struct device_node {                 // 节点: 树形关系+属性链头
    const char *name, *type, *full_name;   // name="memory", full_name="memory@0"
    struct property *properties;           // 属性链表头
    struct device_node *parent, *child, *sibling;  // 左孩子右兄弟
    struct kobject kobj;                   // sysfs导出
    struct fwnode_handle fwnode;           // ACPI/DT统一抽象
};
struct property {                    // 属性: 键值对(DTS里一行 xxx=yyy)
    char *name;  int length;  void *value;  struct property *next;
};
一个device_node管"我是谁挂哪", 一串property管"我有什么参数", 一对多
```

### of_root 与内存位置

- `of_root` 是**全局 device_node* 变量**（drivers/of/base.c），指向展开后的根——唯一官方入口，所有 `of_find_*` API 从它出发。child/sibling 是结构体成员指针（"房间里的指路牌"），不是全局变量（"墙上的总门牌"只有of_root；of_chosen/of_aliases 是高频快捷全局，属例外）
- 分配的内存**不是fixmap**：`early_init_dt_alloc_memory_arch → memblock_virt_alloc` 从 memblock 拿物理页、返回**线性映射区**虚拟地址（PAGE_OFFSET+偏移）。DTB原文在fixmap/FIX_FDT，展开的树在memblock线性映射内存——两个东西两个地方
- 展开后访问方式升级：扁平期只能 of_scan_flat_dt 全树扫（慢）；树后 `of_find_node_by_path/of_find_compatible_node/of_property_read_u32` 直接走指针——**Day6 驱动 probe 的 of_device_id 匹配就依赖这棵树**

## 五、chosen/bootargs 完整链路

```text
① DTB chosen节点写死(板子dtsi): bootargs="earlycon=uart8250,mmio32,0xfe660000 console=ttyFIQ0 root=PARTUUID=614e0000-0000 rw rootwait"
② U-Boot fdt fixup: 若env有bootargs → fdt_setprop改写DTB chosen的bootargs(覆盖写死的) ★U-Boot env优先级更高
③ early_init_dt_scan_chosen(fdt.c:1191): 读bootargs → strlcpy进boot_command_line(全局char[2048], init/main.c:133)
④ setup_arch: *cmdline_p = boot_command_line
⑤ start_kernel: setup_command_line→saved_command_line/static_command_line
   parse_early_param → earlycon=/loglevel=/init=/nokaslr
   parse_args → root=/console=/rw
三个CONFIG: CMDLINE_FORCE(编译期强制) / CMDLINE_EXTEND(拼接) / 默认(DTB/U-Boot值直接用,本板情形)
实操改参数: U-Boot命令行 setenv bootargs 'xxx'; saveenv; boot —— 免重编DTB
```

## 六、earlycon 串口打印机制（追问高频点）

**不是串口驱动**。真正的 uart 驱动 Day6 initcall 阶段才 probe；earlycon 是只写/轮询/无中断的极简通道：

```text
bootargs的 earlycon=uart8250,mmio32,0xfe660000
  → parse_early_param(setup_arch内) → setup_earlycon
  → 注册只实现write/poll_put_char的极简驱动
  → pr_info → printk → earlycon->write → 经FIX_EARLYCON槽位直写UART TX寄存器
  → 轮询TX FIFO空再写下一字节
启动日志"console [ttyFIQ0] enabled" = 正式驱动probe后接管earlycon的切换时刻
若bootargs无earlycon → banner等早期打印全部丢失(调板无输出先查这个)
```

## 七、周边追问沉淀

- **static keys**：零开销运行时开关。关闭时代码是1条nop、开启时内核把指令原地patch成跳转（code patching）；jump_label_init 把初始状态patch好。用于tracepoint/调试开关
- **boot_command_line**：全局 char[2048]（init/main.c:133）；赋值三步链见第五节
- **DAIF 解疑**：start_kernel 开头 local_irq_disable 只动 PSTATE.I；A(SError)/F(Fiq) 的屏蔽来自更早的 el2_setup `msr daifset,0xf`（CPU上电就全mask）。`local_daif_restore(DAIF_PROCCTX_NOIRQ)` 解除A/F但保持I关——时机=earlycon就绪"终于能打印SError了"的最早时刻
- **early_ioremap**：fixmap 的 FIX_BTMAPS 7个slot 领用/归还；普通 ioremap 要 buddy（vmalloc区+vmap_area+alloc_pages），启动早期走不通
- **memblock 两本账**：memory（可用，scan_memory登记）+ reserved（保留，DTB/镜像/栈/ramoops）。`memblock_virt_alloc` 从 memory−reserved 里切、返回线性映射虚拟地址。buddy 就绪后退役。unflatten 的 `mem` 游标只是大块内存内的指针，不是 memblock 本身
- **内存保留双轨**：memblock_reserve（代码主动调）与 reserved-memory 节点（DTS→fdt_init_reserved_mem→memblock_reserve）最终都汇进 memblock.reserved；/memreserve/ 是老OF风格遗留。CMA=reserved-memory 的 shared-dma-pool 特例（Camera DMA 要连续物理内存的原因，第10天/Day7 V4L2 都会接上）

## 八、闭卷考核标准答案

**Q1 DTB 的四段是什么？structure block 为什么叫"扁平"？**
fdt_header(magic 0xd00dfeed+各段偏移)/memory reserve map(保留表)/structure block(节点树token流)/strings block(属性名去重池)。DTS 的花括号嵌套被序列化成 FDT_BEGIN_NODE/FDT_PROP/FDT_END_NODE 线性 token 流，解析器靠 BEGIN/END 配对还原树——树被"拍平"成线性序列，故称 Flattened。

**Q2 reg/interrupts/compatible/status/pinctrl 各是什么？怎么读怎么改？**
reg=寄存器地址+长度（按父节点#address-cells/#size-cells 分组，`<0 0xfe660000 0 0x100>`=0xfe660000 起 256B，驱动 ioremap 用）；interrupts=中断接法（按中断父节点#interrupt-cells，`<GIC_SPI 118 LEVEL_HIGH>`=GIC 118号 SPI）；compatible=驱动匹配名牌（多字符串先厂商后通用IP，probe 时对照驱动 of_device_id 表）；status=okay/disabled 开关（SoC 文件默认关、板级 &引用覆盖打开）；pinctrl=引脚复用组（m0/m1 走线方案按原理图选）。改法：板级 dts 里 `&label { 属性=新值; }` 覆盖 → make dtbs → 烧写 → cat /proc/device-tree 验证。

**Q3 memory 节点怎么变成内核的内存账本？**
early_init_dt_scan_memory 过滤 device_type="memory" 节点 → 读 reg 按 addr/size cells 分组解析 base/size → early_init_dt_add_memory_arch → memblock_add(base,size)。板子 `reg=<0 0 0 0x40000000>` → memblock_add(0,1GB)。之后 arm64_memblock_init 加工（截 PA 位、保留内核镜像/PID0 栈、记 memstart_addr），paging_init/bootmem_init 都从这本账工作。

**Q4 chosen 节点的作用？bootargs 完整链路？**
chosen 不是真实设备，是 U-Boot↔内核的启动参数信箱。链路：DTB chosen 写死 bootargs（兜底）→ U-Boot fdt fixup 用 env bootargs 改写（优先级更高）→ early_init_dt_scan_chosen 读出写进全局 boot_command_line → setup_arch 交 cmdline_p → parse_early_param（earlycon 等）/parse_args（root 等）解析。改参数实操：U-Boot setenv bootargs 即可免重编 DTB。

**Q5（验收）DTB 展开的用途？展开前后区别？**
展开=unflatten_device_tree 把扁平 token 流变成内存里 parent/child/sibling 指针连接的 struct device_node 树（of_root 为全局入口）。前：只能 of_scan_flat_dt 全树遍历回调（每次全扫，仅早期够用）；后：of_find_node_by_path/of_find_compatible_node/of_property_read_u32 按指针直达——之后所有驱动 probe、设备模型匹配、/proc/device-tree、sysfs 导出全依赖这棵树。两遍扫描（dryrun 算总大小→memblock 一大块→游标切割），populate_node 五步（读名/切[结构体+名]/头插挂树/populate_properties 尾插属性链且 name/value 直接引用 DTB 原文/回填 name/type 快捷指针），最后 reverse_nodes 反转回 DTS 顺序。

**Q6 earlycon 为什么能在串口驱动加载前打印？**
earlycon 是只写/轮询/无中断的极简通道：parse_early_param 处理 bootargs 的 earlycon=uart8250,mmio32,0xfe660000 → 注册只实现 write 的驱动 → printk 经 fixmap 的 FIX_EARLYCON 槽位直写 UART TX 寄存器、轮询 FIFO。不依赖 uart 驱动 probe、不用中断/DMA。正式驱动 probe 后接管（日志 "console [ttyFIQ0] enabled"）。

## 九、本日踩坑/易混点

1. DTB 四段是"文件包装层"，DTS 只写树内容——header/strings 由 dtc 自动生成
2. reserved-memory 节点 ≠ DTB reserve map 段：前者是普通节点（structure block 路），后者来自 /memreserve/ 语法；都汇进 memblock.reserved
3. property 的 name/value **不拷贝**，直接引用 DTB 原文——所以 DTB 物理内存被 reserve+只读，是"活体数据"
4. 4.19 无 of_allnodes 全局哈希表（老内核才有）；of_root 是唯一官方树入口（of_chosen/of_aliases 例外）
5. 节点头插（快，顺序反，需 reverse）vs 属性尾插（保序）——选择原因不同
6. np->full_name="memory@0"（建节点时拷贝），np->name="memory"（属性链查出的快捷指针）——来源与含义都不同
7. unflatten 分配在 memblock 线性映射区，不在 fixmap；DTB 原文才在 fixmap
8. memblock_virt_alloc 返回虚拟地址（线性映射），memblock 本身管物理账
9. earlycon 与 console=ttyFIQ0 是两套：前者启动早期、后者正式驱动接管后
10. fixmap walk 路径：TTBR1→swapper L0→bm_pud→bm_pmd→bm_pte→目标物理页；前三级 early_fixmap_init 搭、叶子具体使用者填

## 十、明日（Day5）

`rest_init` 深入：`kernel_thread(kernel_init)`/`kthreadd` 创建、PID 0 变 idle、`kernel_init` → `kernel_init_freeable` → do_initcalls（接 Day6）→ prepare_namespace → run_init_process（接 Day7）。验收：解释 PID 0/1/2 如何产生。


> 追问实录（Q&A 合并版）与追问讲解代码实录见 `day04-review-learner-notes.md` 第 11/12 节。
