# Day 6 复习笔记：initcall 机制与驱动 probe 链路（学习者视角）

> 7 天计划第 6 天。理论：设备/驱动/总线、initcall、probe 及延迟探测；源码：kernel_init_freeable()、do_basic_setup()、do_initcalls()，追一个真实驱动注册入口；验收：区分初始化函数执行、驱动注册、匹配与 probe。
> 源码基准：Rockchip 4.19（虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`）。
> 承接 Day5：kernel_init → kernel_init_freeable → do_basic_setup → do_initcalls。

## 0. 学习轨迹：我曾经的错误理解

1. **"module_init 是在调用驱动初始化函数"** → 错。`module_init` 编译期展开成"把函数指针塞进特殊链接段"，不调用任何东西；真正调用是启动时 `do_initcalls` 遍历链接段逐个调
2. **"驱动的 probe 是 driver_register 直接调的"** → 错。中间隔着 5 层：`bus_add_driver`→`driver_attach`→`__driver_attach`→`driver_match_device`（先匹配）→`driver_probe_device`→`really_probe`→`bus->probe`（=platform_drv_probe 包装函数）→`drv->probe`（=你写的 dw8250_probe）
3. **"probe 时调的是我写的 dw8250_probe"** → 半对。`really_probe` 调的是 `bus->probe`（= `platform_drv_probe`），不是直接调你的 probe；`platform_drv_probe` 在调你的 probe 前先做 DT 时钟默认设置 + PM 域挂载（platform 总线给所有驱动的统一预处理）
4. **"驱动注册完就自动匹配设备了"** → 对，但要知道是 `bus_add_driver` 里 `drivers_autoprobe=1` 时立刻调 `driver_attach` 触发的，不是"自动魔法"

## 0.5 全局一张图

```text
编译期:
  module_platform_driver(dw8250_platform_driver)
    → module_init(dw8250_platform_driver_init)
      → 函数指针塞进 .initcall6.init 链接段

启动时:
  kernel_init(PID 1)
    → kernel_init_freeable
      → do_basic_setup (main.c:1212)
        ├─ driver_init()        设备模型初始化: 建/sys/devices/bus/class目录
        └─ do_initcalls()       ★按级别0→7遍历所有initcall段
            → do_initcall_level(6) 遍历.initcall6.init段
              → do_one_initcall(dw8250_platform_driver_init)
                → platform_driver_register(&dw8250_platform_driver)  ★注册开始

注册+匹配+probe全链路(4→7环节):
  platform_driver_register
    → __platform_driver_register: 设bus=platform_bus_type, probe=platform_drv_probe(包装)
    → driver_register: 查重
    → bus_add_driver: 分配priv, 挂总线驱动链表, sysfs建目录
      → driver_attach(drv)                           ★环节5: 遍历总线所有device
        → __driver_attach(dev, drv):
            driver_match_device → platform_match → of_driver_match_device
            (拿device_node的compatible和驱动of_match_table比对) ← Day4的device_node树!
            匹配成功 → driver_probe_device            ★环节6
        → really_probe(dev, drv):
            device_links_check_suppliers (依赖检查/defer)
            dev->driver = drv                        ★★★绑定!
            pinctrl_bind_pins (引脚复用生效, Day4的pinctrl-0)
            dma_configure
            driver_sysfs_add
            bus->probe = platform_drv_probe:         ★环节7
              of_clk_set_defaults (DT时钟默认)
              dev_pm_domain_attach (PM域)
              drv->probe(dev) = dw8250_probe(pdev)   ★★★你的驱动代码!
            driver_bound(dev)
              device加进driver的klist_devices, 发uevent
```

## 1. initcall 机制：链接段 + 宏自动收集

### 1.1 驱动的写法（你以后写 Camera 驱动就这么写）

```c
static int __init my_camera_init(void)
{
    return platform_driver_register(&my_camera_driver);
}
module_init(my_camera_init);   // ★这一行
```

### 1.2 module_init 宏展开（init.h:221）

```c
// module.h:89 内建时:
#define module_init(x)  __initcall(x);
    → __define_initcall(x, 6)
        → ___define_initcall(x, 6, .initcall6)
            → static initcall_t __initcall_my_camera_init6 __used
                __attribute__((__section__(".initcall6.init"))) = my_camera_init;
                //   ↑函数指针变量              ↑塞进.initcall6.init链接段
```

**本质**：`module_init` 不调用函数，编译期把函数指针塞进特殊命名的链接段。全内核几百个驱动的函数指针自动排列在段里，`do_initcalls` 遍历段逐个调。**不用在 main.c 手写一行调用**。

### 1.3 八级层次（数字越小越早）

```text
级别  宏名                链接段                  典型
0     pure_initcall       .initcall0.init        纯初始化(无依赖)
1     core_initcall       .initcall1.init        子系统核心(irq/时钟)
2     postcore_initcall   .initcall2.init
3     arch_initcall       .initcall3.init
4     subsys_initcall     .initcall4.init        i2c/spi总线
5     fs_initcall         .initcall5.init        文件系统
6     device_initcall     .initcall6.init        ★90%驱动在这级
      = module_init(内建时)
7     late_initcall       .initcall7.init        最后执行
```

**为什么分级**：依赖拓扑序。i2c 总线（subsys 级 4）必须先就位，挂在 i2c 上的 sensor 驱动（device 级 6）才能 probe——probe 时要找 i2c adapter，没注册就失败。

### 1.4 do_initcalls 执行（main.c:1189）

```c
static void __init do_initcalls(void)
{
    for (level = 0; level < ARRAY_SIZE(initcall_levels) - 1; level++)
        do_initcall_level(level);
}

static void __init do_initcall_level(int level)
{
    parse_args(initcall_level_names[level], ...);   // 先解析该级别的cmdline参数
    for (fn = initcall_levels[level]; fn < initcall_levels[level+1]; fn++)
        do_one_initcall(initcall_from_entry(fn));   // ★逐个调函数指针
}
```

`initcall_levels[]`（main.c:965）是链接段地址数组：`__initcall0_start`~`__initcall_end`。

## 2. 设备/驱动/总线三角关系

```text
          bus_type (platform_bus_type, 虚拟总线)
         /                          \
    device                          driver
    (pdev, 有of_node=               (pdrv, 有of_match_table=
     Day4的device_node)              驱动里的compatible表)
         \                          /
          platform_match() ← 把两边配对
                ↓ 匹配成功
            driver->probe(pdev)  ← 真正初始化
```

- **bus**：platform 总线是虚拟总线（不对应物理总线），给 SoC IP（uart/i2c/spi/gpio）统一挂载
- **device**：由 DTB 解析（Day4 unflatten → of_platform_populate 把 device_node 转成 platform_device 挂上总线）
- **driver**：`platform_driver_register` 注册到总线
- **match**：总线提供 `platform_match` 把 device 和 driver 配对
- **probe**：配对成功后调驱动 probe——从这一刻起驱动"认领"了设备

## 3. 真实驱动：8250_dw.c（你板子的 UART）

### 3.1 驱动结构体

```c
// drivers/tty/serial/8250/8250_dw.c
static const struct of_device_id dw8250_of_match[] = {
    { .compatible = "snps,dw-apb-uart" },       // ★和DTS的uart2第二个compatible匹配
    { .compatible = "rockchip,rk3568-uart" },    // ★第一个compatible
    ...
};
// 就是你Day4学的device_node树里的compatible字段!

static struct platform_driver dw8250_platform_driver = {
    .driver = {
        .name = "dw-apb-uart",
        .of_match_table = dw8250_of_match,       // ★匹配表挂这里
    },
    .probe = dw8250_probe,                        // ★匹配成功后调的函数
    .remove = dw8250_remove,
};

module_platform_driver(dw8250_platform_driver);  // ★注册+module_init二合一
```

### 3.2 module_platform_driver 宏展开

```c
#define module_platform_driver(__platform_driver) \
module_driver(__platform_driver, platform_driver_register, platform_driver_unregister)

#define module_driver(__driver, __register, ...) \
static int __init __driver##_init(void) \
{ return __register(&(__driver)); }              // → platform_driver_register(&dw8250_platform_driver)
module_init(__driver##_init);                     // → 塞进.initcall6.init段

// 等价于:
static int __init dw8250_platform_driver_init(void) {
    return platform_driver_register(&dw8250_platform_driver);
}
module_init(dw8250_platform_driver_init);
```

## 4. 注册→匹配→probe 全链路（环节 4~7 逐层源码）

### 环节 4：platform_driver_register → driver_register → bus_add_driver

```c
// platform.c:648
int __platform_driver_register(struct platform_driver *drv, struct module *owner)
{
    drv->driver.bus = &platform_bus_type;          // ★挂到platform虚拟总线
    drv->driver.probe = platform_drv_probe;        // ★设总线层probe(包装函数,不是你的probe)
    // 你的dw8250_probe在drv->probe字段,由platform_drv_probe转发调用
    return driver_register(&drv->driver);
}

// driver.c:146
int driver_register(struct device_driver *drv)
{
    other = driver_find(drv->name, drv->bus);     // 查重:同名不能注册两次
    ret = bus_add_driver(drv);                     // ★核心
}

// bus.c:618
int bus_add_driver(struct device_driver *drv)
{
    priv = kzalloc(sizeof(*priv), GFP_KERNEL);    // 分配driver私有数据
    klist_init(&priv->klist_devices, NULL, NULL);  // "已绑定设备"链表(空)
    kobject_init_and_add(..., "%s", drv->name);    // sysfs建 /sys/bus/platform/drivers/dw-apb-uart
    klist_add_tail(&priv->knode_bus, &bus->p->klist_drivers);  // ★挂进总线的驱动链表

    if (drv->bus->p->drivers_autoprobe) {
        error = driver_attach(drv);                // ★★★ 触发匹配+probe!
    }
    module_add_driver(drv->owner, drv);            // sysfs模块符号链接
}
```

### 环节 5：driver_attach → 遍历设备 → platform_match

```c
// dd.c:1038
int driver_attach(struct device_driver *drv)
{
    return bus_for_each_dev(drv->bus, NULL, drv, __driver_attach);
    //                ↑遍历platform总线上所有已注册的device,每个调__driver_attach
}

// dd.c:978
static int __driver_attach(struct device *dev, void *data)
{
    struct device_driver *drv = data;

    ret = driver_match_device(drv, dev);   // ★调总线的match
    if (ret == 0) return 0;                // 不匹配→跳过
    if (ret == -EPROBE_DEFER) {
        driver_deferred_probe_add(dev);    // ★延迟探测→挂pending列表
        return 0;
    } // ret > 0 → 匹配成功
    driver_probe_device(drv, dev);         // → 真正probe
}

// base.h:122 — driver_match_device调的是bus->match
static inline int driver_match_device(struct device_driver *drv, struct device *dev)
{
    return drv->bus->match ? drv->bus->match(dev, drv) : 1;
    //                 ↑platform_bus_type.match = platform_match
}

// platform.c:988 — 四种匹配方式
static int platform_match(struct device *dev, struct device_driver *drv)
{
    if (pdev->driver_override)
        return !strcmp(pdev->driver_override, drv->name);    // ① 强制指定

    if (of_driver_match_device(dev, drv))                     // ② ★DT匹配(你板子主要走这条)
        return 1;    // 拿驱动的of_match_table和device的of_node(Day4的device_node!)的compatible比对

    if (acpi_driver_match_device(dev, drv))                   // ③ ACPI匹配(PC/服务器)
        return 1;

    if (pdrv->id_table)
        return platform_match_id(pdrv->id_table, pdev) != NULL;  // ④ ID表(老式)

    return (strcmp(pdev->name, drv->name) == 0);             // ⑤ 名字兜底
}
```

**DT 匹配链**：`of_driver_match_device` → 拿驱动的 `of_match_table` 和 device 的 `of_node->properties` 里 `compatible` 比对——**这就是 Day4 学的 device_node 树在这里被用上的瞬间**。

### 环节 6：driver_probe_device → really_probe

```c
// dd.c:653
int driver_probe_device(struct device_driver *drv, struct device *dev)
{
    pr_debug("matched device %s with driver %s\n", ...);
    ret = really_probe(dev, drv);     // ★
}

// dd.c:452
static int really_probe(struct device *dev, struct device_driver *drv)
{
    // ① 依赖检查
    ret = device_links_check_suppliers(dev);
    if (ret == -EPROBE_DEFER)
        driver_deferred_probe_add_trigger(dev, ...);  // supplier没就绪→延迟

    // ② ★★★ 绑定!
    dev->driver = drv;                  // 从此device知道"我的驱动是谁"

    // ③ 引脚复用(Day4的pinctrl-0在这里生效)
    ret = pinctrl_bind_pins(dev);

    // ④ DMA配置
    ret = dma_configure(dev);

    // ⑤ sysfs
    driver_sysfs_add(dev);

    // ⑥ ★调probe函数
    if (dev->bus->probe) {
        ret = dev->bus->probe(dev);       // platform_bus_type.probe = platform_drv_probe
    } else if (drv->probe) {
        ret = drv->probe(dev);            // (非platform总线走这条)
    }

    // ⑦ probe成功
    driver_bound(dev);                    // ★device加进driver的klist_devices, 发uevent

probe_failed:                              // probe失败路径
    dev->driver = NULL;                   // 解绑
    devres_release_all(dev);              // 释放probe中分配的资源
    ...
}
```

### 环节 7：platform_drv_probe → 你的 dw8250_probe

```c
// platform.c:587 — platform总线的probe包装函数
static int platform_drv_probe(struct device *_dev)
{
    struct platform_driver *drv = to_platform_driver(_dev->driver);
    struct platform_device *dev = to_platform_device(_dev);

    ret = of_clk_set_defaults(_dev->of_node, false);   // ① 从DT设置默认时钟
    ret = dev_pm_domain_attach(_dev, true);             // ② 挂PM域
    if (drv->probe) {
        ret = drv->probe(dev);                         // ③ ★调你写的 dw8250_probe!
    }
    ...
}
```

**两层 probe 的意义**：`really_probe` 调 `bus->probe`（=`platform_drv_probe`），不是直接调你的 `dw8250_probe`。`platform_drv_probe` 在调你的 probe 前先做 DT 时钟默认设置 + PM 域挂载——**platform 总线给所有 platform 驱动的统一预处理**，你写驱动时不用自己处理这些。

### driver_bound（绑定完成）

```c
// really_probe 最后:
driver_bound(dev);
    klist_add_tail(&dev->p->knode_driver, &dev->driver->p->klist_devices);
    //         ★device加进driver的"已绑定设备"链表
    //         (ls /sys/bus/platform/drivers/dw-apb-uart/ 能看到uart2设备链接)
    blocking_notifier_call_chain(..., BUS_NOTIFY_BOUND_DRIVER, dev);
    //         ★发uevent → 用户态udevd知道"绑定完成"
```

## 5. deferred probe（延迟探测）

**场景**：驱动 A 的 probe 需要 GPIO，但 GPIO 控制器（驱动 B）还没 probe。

```text
A先probe → gpiod_get拿不到 → 返回-EPROBE_DEFER → 内核把A挂deferred_probe_pending_list
→ B probe成功 → 把pending列表全部重试 → A再次probe拿到GPIO → 成功
```

源码注释（dd.c:39）原文：

```text
An SDHCI driver may first need a GPIO line from an i2c GPIO controller
before it can be initialized. If a required resource is not available yet,
a driver can request probing to be deferred by returning -EPROBE_DEFER
from its probe hook.
```

**`dmesg` 里 "probe deferred, retrying later" 不是 bug，是正常依赖等待**。

## 5.5 补：device_node → platform_device → device_private（Day4→Day6 的空白地带）

Day4 学了 unflatten 把 DTB 展开成 device_node 树（挂 of_root）；Day6 学了 driver_attach 遍历总线 device 做 match→probe。中间"device_node 怎么变成挂在总线上的 platform_device"这一步在这补完。

### 三步在不同位置

```text
① unflatten_device_tree (Day4, setup_arch里)
   → DTB扁平token → device_node树(挂of_root)
   → 此刻只有"硬件描述节点",没有platform_device,没有device_private

② of_platform_default_populate_init (postcore initcall, 级2)
   → of_platform_default_populate → of_platform_populate
   → 遍历device_node树,给有compatible的节点创建platform_device
   → 每个platform_device的dev.of_node指回device_node

③ of_device_add → device_add → device_private_init (core.c)
   → 分配device_private(dev->p), 把device挂进设备层次结构+注册到bus
   → 此刻device才"活"了,可以被driver_attach遍历匹配
```

### 为什么放在 postcore 级（2）

必须在 driver 级（6）的驱动注册之前把 device 挂上总线——否则 `driver_attach` 遍历总线时没有 device 可匹配。postcore < device，正好。

### of_platform_populate（platform.c:476）

```c
int of_platform_populate(struct device_node *root, ...)
{
    root = root ? : of_find_node_by_path("/");   // 从of_root出发
    for_each_child_of_node(root, child) {         // 遍历根的直接子节点
        of_platform_bus_create(child, matches, lookup, parent, true);
        //                ↑递归: 给每个有compatible的节点建platform_device
    }
}
```

### of_platform_bus_create（platform.c:354）——对每个 device_node

```c
static int of_platform_bus_create(struct device_node *bus, ...)
{
    // ① 检查有没有compatible,没有就跳过(纯描述性节点不建device)
    if (strict && (!of_get_property(bus, "compatible", NULL)))
        return 0;

    // ② 跳过被标记为"不创建device"的节点
    if (of_match_node(of_skipped_node_table, bus))
        return 0;

    // ③ ★创建platform_device
    dev = of_platform_device_create_pdata(bus, bus_id, platform_data, parent);

    // ④ 递归处理子节点
    for_each_child_of_node(bus, child)
        of_platform_bus_create(child, ...);
}
```

### of_platform_device_create_pdata（platform.c:173）——真正创建

```c
static struct platform_device *of_platform_device_create_pdata(
    struct device_node *np, const char *bus_id, void *platform_data, struct device *parent)
{
    struct platform_device *dev;

    // ① ★检查节点status(disabled的跳过! Day4学的status="okay"在这里生效)
    if (!of_device_is_available(np) ||
        of_node_test_and_set_flag(np, OF_POPULATED))
        return NULL;
    // of_device_is_available读status属性: "disabled"→不建device
    // → 所以你DTS里没开的设备不会出现在/sys/bus/platform/devices/

    // ② ★从device_node分配platform_device
    dev = of_device_alloc(np, bus_id, parent);
    // of_device_alloc内部:
    //   dev = platform_device_alloc("", -1);   分配struct platform_device
    //   dev->dev.of_node = np;                ★★关联! device的of_node指回device_node
    //   dev->dev.parent = parent;
    //   dev->dev.fwnode = &np->fwnode;
    // 这就是Day6 platform_match里of_driver_match_device能拿到
    // device_node的compatible的原因: device->of_node在这里被设上

    // ③ 设DMA mask/bus
    dev->dev.coherent_dma_mask = DMA_BIT_MASK(32);
    dev->dev.bus = &platform_bus_type;          // ★挂到platform虚拟总线
    of_msi_configure(&dev->dev, dev->dev.of_node);
    of_reserved_mem_device_init_by_idx(...);    // 关联reserved-memory(Day4学过的)

    // ④ ★把device加进设备层次结构(内部调device_add→device_private_init)
    if (of_device_add(dev) != 0) {
        platform_device_put(dev);
        goto err_clear_flag;
    }

    return dev;
}
```

**关键关联**：`dev->dev.of_node = np`——platform_device 的 of_node 指针指回 Day4 学的 device_node。Day6 `platform_match`→`of_driver_match_device` 就是通过这个指针拿到 device_node 的 compatible 和 driver 的 of_match_table 比对。

### device_private_init（core.c:2478）

`of_device_add` 内部调 `device_add`，后者调 `device_private_init`：

```c
static int device_private_init(struct device *dev)
{
    dev->p = kzalloc(sizeof(*dev->p), GFP_KERNEL);   // ★分配device_private
    if (!dev->p)
        return -ENOMEM;
    dev->p->device = dev;                              // 反向指针指回device
    klist_init(&dev->p->klist_children, ...);          // 子设备链表
    INIT_LIST_HEAD(&dev->p->deferred_probe);           // ★deferred probe链表头(Day6学过!)
    return 0;
}
```

`device_private`（`struct device_private`）是 driver core 用的内部状态——和 driver 的 `driver_private`（drv->p）对称：device 有 dev->p、driver 有 drv->p。你 Day6 学的 deferred probe 的 pending list 就挂在 dev->p->deferred_probe 上。

### 三步对照表

| 步骤 | 在哪做 | 干什么 | 做完后有什么 |
|---|---|---|---|
| ① unflatten | setup_arch (Day4) | DTB → device_node 树 (of_root) | 有"硬件描述节点"，无 device 实体 |
| ② of_platform_populate | postcore initcall (级 2) | 遍历 device_node，给有 compatible 的节点建 platform_device，dev.of_node 指回 device_node | 有 platform_device 实体，挂 platform_bus_type |
| ③ device_add → device_private_init | of_device_add 内部 | 分配 dev->p (device_private)，挂进设备层次结构，注册到 bus | device "活"了，可被 driver_attach 遍历匹配 |

### 完整衔接（Day4→本节→Day6）

```text
device_node(Day4 unflatten)
  → platform_device(of_platform_populate, postcore级2, dev.of_node指回device_node)
    → device_private(device_add→device_private_init, dev->p分配)
      → device挂platform_bus_type设备链表
        → driver_attach(Day6, device级6)遍历总线device
          → platform_match: of_driver_match_device拿device->of_node的compatible
            和driver的of_match_table比对
          → 匹配成功 → really_probe → platform_drv_probe → drv->probe
```

### status="disabled" 在哪生效

Day4 学了 DTS 里 `status = "disabled"` 是开关设备。具体生效位置就是这里：`of_platform_device_create_pdata` 里 `of_device_is_available(np)` 读 status——disabled 的不建 platform_device，不挂总线。所以 driver_attach 遍历时根本看不到它，自然不会 probe。**不是驱动层判断 status，是 device 创建层判断的**。

## 6. 闭卷标准答案

**Q1 initcall 机制是什么？module_init 干了什么？**
initcall 是内核启动回调注册系统。`module_init(fn)` 编译期展开成"把 fn 的函数指针塞进 `.initcall6.init` 链接段"——不调用函数。启动时 `do_initcalls` 按级别 0→7 遍历所有 initcall 链接段逐个调。全内核几百个驱动的初始化函数自动收集和调用，不用 main.c 手写。八级层次（pure/core/postcore/arch/subsys/fs/device/late）对应依赖拓扑序：i2c 总线（subsys 级 4）必须先于 sensor 驱动（device 级 6）。

**Q2 驱动注册到 probe 的完整链路？**
`module_platform_driver` → `module_init` → do_initcalls 调 init 函数 → `platform_driver_register`（设 bus=platform_bus_type、probe=platform_drv_probe 包装）→ `driver_register`（查重）→ `bus_add_driver`（挂总线驱动链表、sysfs 建目录）→ `driver_attach`（遍历总线所有 device）→ `__driver_attach`→`driver_match_device`→`platform_match`→`of_driver_match_device`（拿 device_node 的 compatible 和驱动 of_match_table 比对）→ 匹配成功→`driver_probe_device`→`really_probe`（dev->driver=drv 绑定、pinctrl_bind_pins、dma_configure）→`bus->probe`=`platform_drv_probe`（of_clk_set_defaults、dev_pm_domain_attach）→`drv->probe`=`dw8250_probe`（你的驱动代码）→`driver_bound`（device 加进 klist_devices、发 uevent）。

**Q3 platform_match 有几种匹配方式？你板子走哪条？**
四种：① driver_override 强制指定 ② of_driver_match_device DT 匹配 ③ ACPI 匹配 ④ id_table/name 兜底。你板子（RK3568+DTS）主要走②：拿驱动的 of_match_table 和 device 的 of_node（Day4 学的 device_node 树）的 compatible 属性比对。`"rockchip,rk3568-uart"` 在驱动表和 DTS 节点里对上 → 返回 1。

**Q4 really_probe 为什么不直接调你写的 probe，而要先调 platform_drv_probe？**
两层 probe 设计：`really_probe` 调 `bus->probe`（= `platform_drv_probe` 包装函数），不是直接调你的 `dw8250_probe`。`platform_drv_probe` 在调你的 probe 前先做 DT 时钟默认设置（of_clk_set_defaults）和 PM 域挂载（dev_pm_domain_attach）——这是 platform 总线给所有 platform 驱动的统一预处理，你写驱动时不用自己处理。

**Q5（验收）区分初始化函数执行、驱动注册、匹配与 probe？**
- **初始化函数执行**：`do_initcalls` 按级别遍历链接段调 `module_init` 注册的函数
- **驱动注册**：init 函数里调 `platform_driver_register`→`bus_add_driver`→挂总线驱动链表、sysfs 建目录
- **匹配**：`driver_attach`→遍历总线 device→`platform_match`→`of_driver_match_device` 比对 compatible
- **probe**：匹配成功→`really_probe`（绑定 dev->driver、pinctrl/pinctrl_bind_pins/dma_configure）→`platform_drv_probe`（DT 时钟/PM 域预处理）→`drv->probe`（你的驱动真正初始化设备）

## 7. 踩坑 / 易混点

1. `module_init` 不调用函数——编译期塞链接段；`do_initcalls` 启动时遍历段调
2. `module_platform_driver` = `module_init` + `platform_driver_register` 二合一宏
3. `bus_add_driver` 里 `drivers_autoprobe=1` 时立刻调 `driver_attach`——注册完马上匹配
4. `really_probe` 调的是 `bus->probe`（= `platform_drv_probe` 包装），不是直接调你的 `drv->probe`
5. `platform_drv_probe` 先做 DT 时钟/PM 域预处理再调你的 probe——两层 probe 设计
6. `dev->driver = drv` 在 `really_probe` 里、在你的 probe 被调之前——绑定先于 probe
7. deferred probe 不是 bug：probe 返回 `-EPROBE_DEFER` → 挂 pending → supplier 就位后重试
8. `of_driver_match_device` 里的 "of" = Open Firmware = device tree；Day4 的 device_node 树在这里被消费
9. initcall 八级：级别 = 依赖拓扑序（bus 先于 driver、core 先于 device）
10. 内建时 `module_init` = `device_initcall`（级 6）；编译成模块（=m）时 insmod 才调，不走 do_initcalls

## 8. 明日（Day7）

`prepare_namespace` → 根设备选择 → `run_init_process` → 用户空间 PID 1。验收：解释从 root 参数到用户空间的完整路径。7 天学习段收官 → 门槛验收 → 第二周实板任务。
