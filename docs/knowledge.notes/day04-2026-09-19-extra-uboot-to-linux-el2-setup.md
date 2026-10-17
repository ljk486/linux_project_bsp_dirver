# Day 03 番外：从U-Boot `booti`到Linux `el2_setup`

记录日期：2026-09-19  
项目平台：野火鲁班猫2 / Rockchip RK3568  
目标：只掌握U-Boot跳转到Linux Image并运行到`el2_setup`的高层流程

## 一、总流程

```text
U-Boot执行booti
-> 确定并检查ARM64 Image入口
-> 准备DTB地址及Linux启动数据
-> 清理U-Boot运行环境
-> x0 = DTB物理地址
-> x4 = Image入口地址
-> br x4跳转到Linux Image
-> Linux `_head`执行`b stext`
-> `preserve_boot_args`保存DTB地址
-> `bl el2_setup`
```

## 二、U-Boot `booti`入口

源码：

```text
u-boot/cmd/booti.c
```

主要调用：

```text
do_booti()
-> booti_start()
-> booti_setup()
-> do_bootm_states()
```

### `booti_start()`

作用：

- 从命令行参数或默认`load_addr`取得Kernel Image地址。
- 将地址保存到`images->ep`。
- 调用`booti_setup()`检查和调整Image。
- 查找DTB、initrd等其他启动对象。

核心关系：

```text
images->ep = Linux Image最终入口地址
images->ft_addr = DTB最终地址
```

### `booti_setup()`

作用：

- 将`images->ep`映射为`struct Image_header`。
- 检查ARM64 Image魔数`0x644d5241`，对应`ARM\x64`。
- 读取Image Header中的`image_size`、`text_offset`和`flags`。
- 按ARM64启动协议计算目标加载位置。
- 必要时使用`memmove()`移动Image，并更新`images->ep`。

因此`images->ep`不是随意地址，而是经过Image Header检查和对齐处理后的实际Kernel入口。

### `do_booti()`

在Image准备完成后：

- 关闭中断。
- 指定目标系统为Linux、架构为ARM64。
- 通过`do_bootm_states()`进入Linux准备和跳转阶段。

## 三、U-Boot ARM Linux启动阶段

源码：

```text
u-boot/arch/arm/lib/bootm.c
```

主要调用：

```text
do_bootm_linux()
├── BOOTM_STATE_OS_PREP -> boot_prep_linux()
└── BOOTM_STATE_OS_GO   -> boot_jump_linux()
```

### `boot_prep_linux()`

负责Linux启动数据准备，包括DTB、bootargs和内存信息等。详细FDT fixup流程留到设备树专题学习。

### `boot_jump_linux()`

关键逻辑：

```text
kernel_entry = images->ep
announce_and_cleanup()
armv8_switch_to_el2(
    images->ft_addr,
    0,
    0,
    es_flag,
    images->ep,
    ES_TO_AARCH64
)
```

按ARM64调用约定，参数进入寄存器：

```text
x0 = images->ft_addr = DTB物理地址
x1 = 0
x2 = 0
x3 = es_flag
x4 = images->ep = Image入口地址
x5 = ES_TO_AARCH64
```

## 四、U-Boot最终跳转指令

源码：

```text
u-boot/arch/arm/cpu/armv8/transition.S
```

函数：

```asm
ENTRY(armv8_switch_to_el2)
        switch_el x6, 1f, 0f, 0f
0:
        cmp x5, #ES_TO_AARCH64
        b.eq 2f
        bl armv8_el2_to_aarch32
2:
        br x4
1:
        armv8_switch_to_el2_m x4, x5, x6
ENDPROC(armv8_switch_to_el2)
```

核心指令：

```asm
br x4
```

执行效果：

```text
PC = x4 = images->ep = Linux Image入口
```

从这一刻起，CPU不再执行U-Boot代码，开始执行Linux Image。

`switch_el`和`armv8_switch_to_el2_m`负责根据U-Boot当前异常级别进行交接；本番外只要求知道它最终保留Linux启动参数并跳到`x4`。

## 五、进入Linux Image Header

源码：

```text
kernel/arch/arm64/kernel/head.S
```

入口：

```asm
_head:
#ifdef CONFIG_EFI
        add     x13, x18, #0x16
        b       stext
#else
        b       stext
        .long   0
#endif
        le64sym _kernel_offset_le
        le64sym _kernel_size_le
        le64sym _kernel_flags_le
        .quad   0
        .quad   0
        .quad   0
        .ascii  "ARM\x64"
```

Image开头同时包含：

- CPU执行的跳转指令。
- U-Boot读取的Image Header数据。
- ARM64 Image魔数`ARM\x64`。

CPU执行：

```asm
b stext
```

从Header跳到Kernel真正的启动代码。

## 六、`stext`到`el2_setup`

仍位于：

```text
kernel/arch/arm64/kernel/head.S
```

真实主线：

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

U-Boot跳转到Image时：

```text
x0 = DTB物理地址
```

`preserve_boot_args`执行：

```asm
mov x21, x0
```

将DTB物理地址长期保存在`x21`，因为后续代码会复用`x0`。

返回`stext`后执行：

```asm
bl el2_setup
```

进入异常级别初始化流程。

## 七、最简文件调用图

```text
U-Boot命令入口
u-boot/cmd/booti.c
    do_booti()
    -> booti_start()
    -> booti_setup()
             |
             v
U-Boot Linux准备和跳转
u-boot/arch/arm/lib/bootm.c
    do_bootm_linux()
    -> boot_prep_linux()
    -> boot_jump_linux()
             |
             v
U-Boot异常级别交接
u-boot/arch/arm/cpu/armv8/transition.S
    armv8_switch_to_el2()
    -> br x4
             |
             v
Linux Image入口
kernel/arch/arm64/kernel/head.S
    _head
    -> b stext
             |
             v
    stext
    -> preserve_boot_args
    -> el2_setup
```

## 八、两个必须记住的参数

```text
images->ep
-> x4
-> br x4
-> Linux Image入口`_head`
```

```text
images->ft_addr
-> x0
-> preserve_boot_args
-> x21
-> 后续Kernel解析DTB
```

## 九、一句话总结

U-Boot的`booti`检查并定位Image和DTB，将Image入口放入`x4`、DTB物理地址放入`x0`；`armv8_switch_to_el2()`最终执行`br x4`进入Linux `_head`，`_head`跳到`stext`，`stext`保存DTB地址并调用`el2_setup`整理异常级别环境。

