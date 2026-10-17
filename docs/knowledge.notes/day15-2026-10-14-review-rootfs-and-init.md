# Day 7 复习笔记：rootfs 挂载与用户空间 init 启动（学习者视角）

> 7 天计划第 7 天。理论：VFS、块设备、ext4、initramfs、rootfs、PID 1 执行；源码：prepare_namespace()、run_init_process()；验收：解释从 root 参数到用户空间的完整路径。
> 源码基准：Rockchip 4.19（虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`）。
> 承接 Day6：kernel_init_freeable 里 do_initcalls 跑完后，内核要挂 rootfs 并 exec 用户空间 init——这是启动链"最后一跳"。

## 0. 学习轨迹：我曾经的错误理解

1. **"root= 指定的分区直接就是 rootfs"** → 错。root= 只是 bootargs 里的参数字符串；`__setup("root=")` 只把它存进 `saved_root_name`；真正的"查设备+挂载"在后面 `prepare_namespace` 里
2. **"initrd 和 initramfs 是同一个东西"** → 错。老式 initrd 是 ext2 磁盘镜像走 initrd_load（几乎不用）；initramfs 是 cpio 包走 populate_rootfs 直接解包。我之前混讲了
3. **"initramfs 不走 prepare_namespace 是因为不用 mount"** → 对但理解不准。真正原因：内存 rootfs 从 start_kernel 起就挂在 `/` 上（init_mount_tree），populate_rootfs 只是把 cpio 文件解进去，`/init` 已在 → exec 成功 → 跳过 prepare_namespace
4. **"mount 就是把分区挂到 /"** → 不全对。mount_root 先挂到 `/root`（子目录），验证成功后 `ksys_mount MS_MOVE` 挪到 `/`——"先准备、后切换"的安全模式，不直接叠挂
5. **"内存 rootfs 是把 eMMC 镜像复制到内存"** → 错。内存 rootfs 是 VFS 的特例：没有 ext4、没有 super_block 在磁盘上，所有元数据在内存里现建现弃，数据来源是页缓存
6. **"厂商把完整 rootfs 打进 initramfs 再编进 kernel"** → 多数嵌入式不是这样。主流是"小 initramfs 过渡 + 块设备真 rootfs"；你板子 SDK（野火）走分开式：小 initrd 文件（lubancat-bin/initrd）由 U-Boot 加载，完整 rootfs 是独立 ext4 分区（Buildroot 产出）

## 0.5 全局一张图

```text
bootargs: root=PARTUUID=614e0000-0000 rw rootwait

start_kernel
  → vfs_kern_mount("rootfs") + init_mount_tree
    → ★内存rootfs(ramfs/tmpfs,页缓存)挂在/上,初始空目录
  → do_initcalls
    → populate_rootfs (rootfs_initcall级5)
      → unpack_to_rootfs: 检测压缩(gzip?)→解压→按cpio流解析
        → sys_open/sys_write把/bin /etc /init...写进/(内存rootfs)
      → 如果有内置initramfs(__initramfs_start)先解;
         如果U-Boot传了initrd(initrd_start)再解
  → kernel_init_freeable
    → do_basic_setup→do_initcalls (Day6)
    → console_on_rootfs: 在rootfs上开/dev/console
    → try_to_run_init_process("/init") ★试initramfs的/init

情况A: /init在initramfs里 → exec成功 → 不进prepare_namespace
  → /init内部: 加载块设备驱动→mount真rootfs→switch_root
  → (或干脆不切,一直用initramfs当rootfs)

情况B: 没有/init或exec失败 → 进prepare_namespace
  → wait_for_device_probe(等Day6的probe全跑完)
  → name_to_dev_t(saved_root_name="PARTUUID=...") → devt_from_partuuid查已注册分区
  → ROOT_DEV = dev_t (如179:3=mmcblk0p3)
  → mount_root → ksys_mount(ROOT_DEV, "/root", "ext4", ...)
  → ksys_mount(".", "/", MS_MOVE) 把/root上的ext4挪到/
  → ksys_chroot(".") 切根
  → run_init_process("/sbin/init") ★
    → do_execve → PID 1从内核线程变用户进程(mm从NULL变有,EL1→EL0)
    → CPU第一次进EL0 → 用户世界开始
```

## 1. rootfs 是什么

**rootfs = 根文件系统 = 挂在 `/` 上的那个文件系统**。

Linux 一切皆文件——`ls /` 看到的 `/bin /sbin /etc /lib /dev /proc /sys` 这些目录和文件必须"存"在某个地方。存它们的那套数据结构就是文件系统；最顶层那个（挂在 `/` 的）叫根文件系统。

**为什么内核必须 rootfs**：`run_init_process("/sbin/init")` 要读 `/sbin/init` 这个文件——要读文件得先有文件系统；要有文件系统得先 mount。所以 exec init 之前必须先把 rootfs 挂好——这就是 `prepare_namespace` 干的事。

**rootfs 怎么来的（Buildroot）**：SDK 的 `./build.sh` 里 Buildroot 那一级产出 `rootfs.ext4`（一个 ext4 镜像文件），烧到 eMMC 的 rootfs 分区。里面就是交叉编译的 BusyBox（提供 ls/cd/cat 等几百个命令）+ /etc/inittab 配置 + libc 等。

## 2. `/` 是什么 / VFS 是什么

### `/` 是一个路径名，不是地址

`/` 是文件系统树最顶层目录的名字。在内核里它对应 `task_struct->fs->root` 指向的 `struct path` = `{ vfsmount, dentry }`：

- **dentry**（目录项）：目录树节点，有名字、父指针、子指针
- **vfsmount**（挂载实例）：记录"哪个文件系统挂在哪个 dentry 上"
- **path**：把两者绑一起，是进程"看 `/` 时实际进入"的入口

`chroot` 改的就是这个 root 指针——`prepare_namespace` 最后 `ksys_chroot(".")` 就是把 PID 1 的 root 指向新挂的 ext4。

### VFS = 虚拟文件系统 = 内核所有文件系统上面的统一抽象层

Linux 支持 ext4/fat/tmpfs/proc/sysfs/nfs... 每种 fs "怎么存数据"完全不同。VFS 定义一套统一接口，让所有 fs 在下面实现：

```text
用户:   open("/etc/passwd") → read(fd, buf)
           ↓
VFS层:  路径解析走dentry树 → 找inode → 调file->f_op->read
           ↓ (统一接口,不管下面是ext4还是tmpfs)
具体fs:  ext4_read / tmpfs_read / proc_read ...
           ↓
数据源:  eMMC磁盘块 / 页缓存 / 内核动态生成
```

五个核心对象（Day9 深学）：

| 对象 | 干什么 |
|---|---|
| super_block | 一个已挂载 fs 的总代表（块大小、inode 数等） |
| inode | 文件身份证（权限、大小、数据块位置） |
| dentry | 路径名分量（名字↔inode 关联，构成目录树） |
| file | 进程打开的文件实例（偏移量、打开模式） |
| vfsmount | 一次挂载的实例（哪个 fs 挂在哪个 dentry 上） |

**用户和具体 fs 互不见面，VFS 当中间层**——这就是为什么 `cat /proc/cpuinfo`（内核虚拟生成）和 `cat /etc/passwd`（eMMC 上 ext4）用一样的 `read` 系统调用。

### 内存 rootfs 不是"把 eMMC 镜像复制到内存"

内存 rootfs 是 VFS 特例：没有 ext4、没有磁盘 super_block，所有元数据在内存里现建现弃，数据来源是**页缓存**（page cache）——写文件 = 从 buddy 拿一页内存挂进 page cache；读文件 = 读 page cache。**不是"块设备镜像在内存里"，是"VFS 假装有个文件系统但底层就是页缓存"**。

## 3. initrd vs initramfs（纠正我此前混讲）

| | 老式 initrd | initramfs |
|---|---|---|
| 格式 | ext2/minix 磁盘镜像 | cpio 归档（通常 gzip 压缩） |
| 加载位置 | 当块设备 /dev/ram0 用 | 直接解包进 rootfs（`/`） |
| 处理函数 | `initrd_load`（prepare_namespace 里） | `populate_rootfs`（rootfs_initcall 级 5） |
| 切换方式 | 跑 ram0 上的 linuxrc，之后切到 root= 指定 rootfs | /init 里通常自己做 switch_root；或干脆不切 |
| 现代用法 | 几乎不用（Linux 2.4 时代） | ★现代方案 |

**prepare_namespace 里 `initrd_load()` 是给老式 initrd 留的兼容路径**——现代系统基本不触发（`mount_initrd=0` 时直接 `return false`）。initramfs 走的是 `populate_rootfs`，根本不进 prepare_namespace。

## 4. populate_rootfs（initramfs.c:639，rootfs_initcall 级 5）

```c
static int __init populate_rootfs(void)
{
    // ① 先解内核内置的initramfs(CONFIG_INITRAMFS_SOURCE指定的cpio包,
    //    链接进vmlinux的.init.ramfs段)
    err = unpack_to_rootfs(__initramfs_start, __initramfs_size);

    // ② 再试U-Boot传来的initrd(如果bootargs指定了)
    if (initrd_start && !IS_ENABLED(CONFIG_INITRAMFS_FORCE)) {
        err = unpack_to_rootfs((char *)initrd_start, initrd_end - initrd_start);
        ...
    }
}
rootfs_initcall(populate_rootfs);   // 级5,在do_initcalls里跑(早于prepare_namespace)
```

### unpack_to_rootfs 干了什么

```c
static char *unpack_to_rootfs(char *buf, unsigned long len)
{
    while (!message && len) {
        if (*buf == '0' && !(this_header & 3)) {
            // 开头是'0'+'7''0''7''0' = 070707 = 未压缩cpio magic
            state = Start;
            written = write_buffer(buf, len);    // ★直接按cpio流解析
        } else {
            // 不是cpio magic → 是压缩的
            decompress = decompress_method(&buf, &len, &compress_name);
            // ★先解压缩(gzip/lzma/xz/zstd),得到纯cpio流,再write_buffer解析
        }
    }
}
```

**流程**：检测 magic → 压缩则先解压 → 按纯 cpio 流逐条解析 → 每条记录 = header（文件名/权限/大小）+ 文件内容 → 调 `sys_open/sys_write` 在 `/` 里建文件。**"边解压边建文件"，不是解到别处再拷贝**。

你板子 SDK 还加了 Rockchip "雷电启动"补丁（`CONFIG_ROCKCHIP_THUNDER_BOOT_CRYPTO`/`CONFIG_ROCKCHIP_HW_DECOMPRESS`）——SHA256 校验 + 硬件解压加速，主线没有。

## 5. prepare_namespace（do_mounts.c:538）——块设备 rootfs 路径

```c
void __init prepare_namespace(void)
{
    if (root_delay) ssleep(root_delay);    // 慢设备等待

    wait_for_device_probe();               // ★等Day6的deferred probe全跑完
    // 源码注释: "typical to wait 5 seconds here"

    md_run_setup();                         // RAID(你板子不走)

    // ★解析root=参数
    if (saved_root_name[0]) {
        root_device_name = saved_root_name;    // "PARTUUID=614e0000-0000"
        if (!strncmp(root_device_name, "mtd", 3) || ...)
            mount_block_root(root_device_name, root_mountflags);  // mtd/ubi特殊路径
            goto out;
        ROOT_DEV = name_to_dev_t(root_device_name);    // ★字符串→dev_t
    }

    if (initrd_load()) goto out;           // 老式initrd兼容(现代不触发)

    if ((ROOT_DEV == 0) && root_wait) {    // rootwait:死等设备出现
        while (driver_probe_done() != 0 ||
            (ROOT_DEV = name_to_dev_t(saved_root_name)) == 0)
            msleep(5);
    }

    mount_root();                           // ★★挂根文件系统(见第6节)

out:
    devtmpfs_mount("dev");                  // 挂/dev(设备节点)
    ksys_mount(".", "/", NULL, MS_MOVE, NULL);  // ★把/root上的ext4挪到/
    ksys_chroot(".");                        // ★切根:PID 1的/变成ext4
}
```

### name_to_dev_t（do_mounts.c:200）

```c
dev_t name_to_dev_t(const char *name)
{
    if (strncmp(name, "PARTUUID=", 9) == 0) {
        name += 9;
        res = devt_from_partuuid(name);      // ★查已注册块设备分区表,找UUID匹配的分区
        goto done;
    }
    if (strncmp(name, "/dev/", 5) != 0) {
        // 可能是"8:0"这种主:从设备号格式
        sscanf(name, "%u:%u", &maj, &min);
        res = MKDEV(maj, min);
    }
    ...
}
// 你板子 root=PARTUUID=614e0000-0000 → devt_from_partuuid("614e0000-0000")
//   → 查分区表 → 返回dev_t(如179:3=mmcblk0p3)
```

## 6. 挂载（mount）是什么 / mount_root 干了什么

### "挂载"是什么

**挂载 = 把一个文件系统的"根目录"接到另一个目录树上，让那个目录变成文件系统的入口**。

本质是三方关联：

```text
块设备(分区,存着ext4格式的数据)
    +
文件系统驱动(ext4.ko,能读懂ext4磁盘格式的代码)
    +
挂载点(一个目录,比如/root)
    ↓ mount系统调用把它们绑一起
此后访问/root/* → VFS找到/root对应的挂载记录
              → 转给ext4驱动 → ext4去块设备读数据 → 返回文件内容
```

**类比**：块设备是仓库（堆着货），ext4 驱动是仓库管理员（懂货架规则），mount 是"把仓库大门开在 /root 这个门牌上"。没 mount 之前仓库在那但门没开，从 /root 走进去是空的。

**必须有"设备 + 文件系统驱动"才能 mount 块设备**——这就是为什么块设备 rootfs 要等驱动 probe 完（wait_for_device_probe）、要 ext4 驱动就位（Day6 的 fs_initcall 级注册 ext4）。

### 为什么 initramfs 不用 mount

内存 rootfs 从 start_kernel 起就挂在 `/` 上（`init_mount_tree`），是 VFS 里一段直接走页缓存的"虚拟文件系统"——**没有块设备、没有 ext4、没有 inode 表在磁盘上**。populate_rootfs 只是把 cpio 文件**解包写进这个已经存在的 `/`**——`sys_open/sys_write` 往页缓存里写文件。**写完 /bin /etc /init 就都在了，没有"挂载"发生，只有"往现成文件系统里解压文件"**。

对比块设备 rootfs：ext4 数据在 eMMC 分区里，不在这个内存 rootfs 里——**必须 mount 把块设备的 ext4 接进来替换掉先天的内存 rootfs**。

### mount_root 干了什么

```c
// mount_root (do_mounts.c) 简化:
mount_block_root(ROOT_DEV, root_mountflags);
// 内部:
//   create_dev("/dev/root", ROOT_DEV);     在/dev下建root设备节点
//   ksys_mount("/dev/root", "/root", "ext4", flags, NULL);
//   ★mount: 设备/dev/root + ext4驱动 + 挂载点/root 三方绑定
//   → 此后访问/root/*实际读的是eMMC分区里的数据
```

### 为什么先挂 /root 再移到 /

```c
ksys_mount(".", "/", NULL, MS_MOVE, NULL);   // 把/root上的ext4"整体挪到/"
ksys_chroot(".");                             // 切根: PID 1的/变成ext4
```

**因为 `/` 上已经挂着内存 rootfs**——VFS 不允许在挂载点上直接叠挂（会盖住原 rootfs 但没法回退）。挂到 `/root`（子目录）→ 验证成功 → MS_MOVE 挪到 `/`——"先准备、后切换"的安全模式。直接 mount 到 / 万一失败，原内存 rootfs 被改了没法回退。

### mount_root 之后的目录层次

`ksys_chroot(".")` 后 PID 1 看到的视图：

```text
/  (现在是ext4,从eMMC分区读)
├── bin/         (BusyBox)
├── sbin/init    ★PID 1 exec它, 变成用户进程
├── etc/
│   ├── inittab  (BusyBox init读它决定起哪些服务)
│   └── fstab
├── lib/         (libc.so)
├── dev/         (devtmpfs自动建节点)
├── proc/        (后面init会 mount -t proc proc /proc)
└── sys/         (后面init会 mount -t sysfs sys /sys)
```

## 7. run_init_process（main.c:1243）——启动链"最后一跳"

```c
static int run_init_process(const char *init_filename)
{
    argv_init[0] = init_filename;
    pr_info("Run %s as init process\n", init_filename);
    return do_execve(getname_kernel(init_filename),
        (const char __user *const __user *)argv_init,
        (const char __user *const __user *)envp_init);
}
```

**就一行核心**：`do_execve`。exec 系统调用的内核实现——**把当前内核线程（PID 1）的"执行体"替换成一个用户程序**：

```text
do_execve 之前:
  PID 1 是内核线程(task_struct, mm=NULL, 在EL1跑kernel_init代码)

do_execve 之后:
  PID 1 的task_struct保留(pid=1不变), 但:
  - mm从NULL变成新的mm_struct(用户地址空间)
  - PC从kernel_init变成用户程序的入口(_start→main)
  - 从EL1切到EL0(用户态)
  → PID 1 从内核线程变成用户进程(systemd/BusyBox init)
```

**这是整个启动链的最后一跳**：之前 7 天学的所有代码都在内核态跑；`do_execve` 这一下，**CPU 第一次进 EL0 执行用户代码**——用户世界从此开始。

### kernel_init 里的五级回退

```c
if (ramdisk_execute_command) {                     // ① 先试initramfs的/init
    ret = run_init_process(ramdisk_execute_command);
    if (!ret) return 0;
}
if (execute_command) {                              // ② 试bootargs的init=参数
    ret = run_init_process(execute_command);
    if (!ret) return 0;
    panic("Requested init %s failed", ...);          // ★指定了但失败→panic
}
if (!try_to_run_init_process("/sbin/init") ||      // ③ systemd/BusyBox
    !try_to_run_init_process("/etc/init") ||        // ④
    !try_to_run_init_process("/bin/init") ||         // ⑤
    !try_to_run_init_process("/bin/sh"))             // 最后兜底用sh
    return 0;
panic("No working init found.");                    // ★全失败→panic
```

## 8. __setup("root=", root_dev_setup) 机制

### `__setup` 宏定义（init.h:283）

```c
#define __setup(str, fn)  __setup_param(str, fn, fn, 0)

#define __setup_param(str, unique_id, fn, early)
    static const char __setup_str_##unique_id[] = str;
    static struct obs_kernel_param __setup_##unique_id
        __section(.init.setup)
        = { str, fn, early };
```

**和 `module_init` 同一手法**：编译期把"参数名+回调"塞进 `.init.setup` 链接段。不调用函数。

`obs_kernel_param` 结构体：

```c
struct obs_kernel_param {
    const char *str;              // 参数名 "root="
    int (*setup_func)(char *);    // 回调 root_dev_setup
    int early;                    // 0=普通(第二轮parse_args调), 1=早期(第一轮parse_early_param调)
};
```

### `__setup` vs `early_param`

```c
#define __setup(str, fn)      __setup_param(str, fn, fn, 0)   // early=0 普通参数
#define early_param(str, fn)  __setup_param(str, fn, fn, 1)   // early=1 早期参数
```

| | `early_param` | `__setup` |
|---|---|---|
| 调用时机 | setup_arch 里 parse_early_param（Day4 学过） | start_kernel 里 parse_args（do_initcalls 前） |
| 典型 | earlycon= / loglevel= | root= / console= / init= |

### root_dev_setup 被调时机和干了什么

```c
// do_mounts.c:283
static int __init root_dev_setup(char *line)
{
    strlcpy(saved_root_name, line, sizeof(saved_root_name));
    return 1;
}
__setup("root=", root_dev_setup);
```

**被调时机**：start_kernel 里 `parse_args("Booting kernel", static_command_line, ...)` 遍历 boot_command_line，遇到 `root=PARTUUID=614e0000-0000` → 匹配 `.init.setup` 段里 `__setup_root_dev_setup` 的 str="root=" → 调 `root_dev_setup("PARTUUID=614e0000-0000")`。

**干了什么**：**只存字符串**到全局变量 `saved_root_name`，不解析不查设备不挂载——"存而不做、延迟解析"。真正解析在 prepare_namespace 里 `name_to_dev_t`。

**为什么"存而不做"**：解析 root= 时块设备驱动还没 probe（do_initcalls 还没跑），此刻查不到分区。必须等 Day6 的 initcalls 跑完、块设备就位后，prepare_namespace 里才能 `name_to_dev_t` 查到。这就是 prepare_namespace 开头 `wait_for_device_probe()` 的原因——等的就是中间这段 probe。

## 9. 你板子 SDK 的 rootfs 打包方式（实测源码证据）

```bash
# device/rockchip/common/build.sh:756
if [[ -e ${TOP_DIR}/lubancat-bin/initrd/$RK_ARCH/initrd-${KERNEL_VERSION} ]]; then
    cp -v ${TOP_DIR}/lubancat-bin/initrd/$RK_ARCH/initrd-$KERNEL_VERSION $EXTBOOT_DIR/initrd-$KERNEL_VERSION
    # 野火预编译的小initrd文件 → 拷进extboot分区 → U-Boot加载
fi

# device/rockchip/common/mkfirmware.sh:279
link_image_optional "$ROOTFS_IMG" rootfs.img "$ROOTFS_IMG_SOURCE"
# Buildroot产出的完整rootfs.img → 独立分区,不打包进kernel
```

**野火走分开式**：小 initrd（过渡用）由 U-Boot 加载到内存 → populate_rootfs 解包；完整 rootfs 是独立 ext4 分区（Buildroot 产出）→ prepare_namespace 挂载。**不是"把完整 rootfs 打进 initramfs 编进 kernel"**。

### 业界打包方式分布

| 方式 | 谁在用 | rootfs 在哪 |
|---|---|---|
| 完整 rootfs 编进 kernel（CONFIG_INITRAMFS_SOURCE） | 极少（微型无存储设备） | vmlinux 内部 |
| 小 initramfs(U-Boot加载) + 完整 rootfs(块设备分区) | **你板子、大多数 ARM 嵌入式** | initramfs 只过渡，真 rootfs 在 eMMC |
| 无 initramfs，直接挂块设备 rootfs | 传统简单嵌入式 | eMMC，prepare_namespace 直接挂 |
| 大 initramfs(含完整用户态) + 不切 | Android GKI 方向、部分现代发行版 | 内存，一直用不切 |

## 10. 闭卷标准答案

**Q1 从 root 参数到用户空间的完整路径？**
bootargs 的 `root=` 经 `__setup("root=", root_dev_setup)` 在 parse_args 时被调，只存字符串到 saved_root_name。prepare_namespace 里 wait_for_device_probe → name_to_dev_t 把字符串转 dev_t（PARTUUID 查块设备分区表）→ mount_root 挂到 /root → ksys_mount MS_MOVE 挪到 / → ksys_chroot 切根。回到 kernel_init 后半 run_init_process → do_execve 把 PID 1 从内核线程变用户进程 → CPU 进 EL0 → init 起 getty/login/shell/网络服务等。

**Q2 initramfs 和块设备 rootfs 两条路径区别？**
initramfs：cpio 包解进内存 rootfs（populate_rootfs, rootfs_initcall 级 5），kernel_init_freeable 里试 /init 成功则不进 prepare_namespace。块设备 rootfs：走 prepare_namespace 挂 root= 指定的块设备（mount_root→MS_MOVE→chroot）。多数嵌入式用"小 initramfs 过渡 + 块设备真 rootfs"（你板子）；微型无存储设备可能把完整 rootfs 编进 kernel。

**Q3 do_execve 干了什么？为什么说它是启动链"最后一跳"？**
把当前内核线程 PID 1 的执行体替换成用户程序：task_struct 保留（pid=1 不变），mm 从 NULL 变成新 mm_struct（用户地址空间），PC 变成用户程序入口，从 EL1 切 EL0。之前 7 天学的全在内核态跑；do_execve 这一下 CPU 第一次进 EL0——用户世界从此开始。

**Q4 prepare_namespace 里 wait_for_device_probe 为什么可能很慢？**
等所有 Day6 的 deferred probe 跑完。某些设备（USB/eMMC 异步扫描）probe 慢，root= 指定的块设备可能还没出现。源码注释"typical to wait 5 seconds here"。rootwait 参数让 `while(ROOT_DEV==0) msleep(5)` 死等。

**Q5 init 找不到会怎样？**
五级回退（initramfs /init → bootargs init= → /sbin/init → /etc/init → /bin/init → /bin/sh）全失败 → `panic("No working init found")`。bootargs 指定了 init= 但那个程序不存在 → `panic("Requested init %s failed")`。

**Q6（rootfs 追问）内存 rootfs 是 `/` 还是 `/root`？initramfs 为什么不用 mount？**
内存 rootfs 是 `/`——start_kernel 里 init_mount_tree 把 ramfs/tmpfs 挂到 `/`，是 VFS 特例（无 ext4、无磁盘 super_block、数据走页缓存）。initramfs 不用 mount 因为 `/` 已经存在，populate_rootfs 只是把 cpio 解包写进去（sys_open/sys_write 往页缓存里建文件）。块设备 rootfs 才要 mount——数据在 eMMC 分区里，必须 mount 把 ext4 接进来。

**Q7（VFS 追问）VFS 是什么？`/` 是地址吗？**
VFS = 虚拟文件系统 = 内核所有文件系统上面的统一抽象层，定义 super_block/inode/dentry/file/vfsmount 五个对象和 open/read/write 统一接口，让用户和具体 fs 互不见面。`/` 不是地址是路径名，在内核里对应 `task->fs->root` 指向的 `struct path{vfsmount,dentry}`——进程看 `/` 的入口。chroot 改的就是这个 root 指针。

## 11. 踩坑 / 易混点

1. `__setup("root=")` 只存字符串不解析——"存而不做、延迟解析"；真正解析在 prepare_namespace 的 name_to_dev_t
2. initrd ≠ initramfs：老式 initrd（ext2 镜像走 initrd_load）vs initramfs（cpio 包走 populate_rootfs）；prepare_namespace 的 initrd_load 是兼容老式 initrd
3. populate_rootfs 是 rootfs_initcall 级 5（在 do_initcalls 里跑），早于 kernel_init_freeable 后半的 prepare_namespace
4. 内存 rootfs 挂在 `/`（init_mount_tree），不是 `/root`；mount_root 先挂 /root 再 MS_MOVE 挪到 /（安全模式）
5. 内存 rootfs 不是"eMMC 镜像在内存里"——是 VFS 特例，数据走页缓存，无 ext4 无磁盘 super_block
6. mount = 设备 + fs 驱动 + 挂载点三方绑定；initramfs 不 mount 因为 `/` 已存在，只是往里解包写文件
7. do_execve 之后 PID 1 的 pid 不变（还是 1），但 mm 从 NULL 变有、EL1→EL0——这是"最后一跳"
8. init 五级回退全失败 → panic；bootargs init= 指定但失败也 → panic
9. Rockchip SDK 的小 initrd 是预编译的（lubancat-bin/initrd/），U-Boot 加载；完整 rootfs 是独立 ext4 分区——不编进 kernel
10. VFS 五对象（super_block/inode/dentry/file/vfsmount）是 Day9 深学内容，Day7 只到"统一接口"概念

## 12. 7 天学习段收官——完整启动链（门槛验收用）

```text
[汇编阶段, 物理地址视角]
U-Boot booti → stext (head.S:120)
  ├─ preserve_boot_args        保存x0~x3(FDT指针→x21)
  ├─ el2_setup                 EL2/EL1处理+VHE
  ├─ set_cpu_boot_mode_flag    存EL到__boot_cpu_mode
  ├─ __create_page_tables      建idmap(VA==PA)+swapper(高VA)两棵页表
  ├─ __cpu_setup               配TCR/MAIR/SCTLR值(备好x0)
  └─ b __primary_switch
      └─ bl __enable_mmu       TTBR0←idmap/TTBR1←swapper, sctlr置M位 ★MMU开
          └─ br __primary_switched (跳高VA)

[过渡阶段]
__primary_switched:
  ├─ 设sp内核栈(init_thread_union+THREAD_SIZE)
  ├─ sp_el0←init_task (current机制)
  ├─ vbar_el1←vectors (异常向量表)
  ├─ 存__fdt_pointer←x21 (FDT落变量)
  ├─ 算kimage_voffset (VA-PA换算差)
  ├─ 清BSS
  └─ b start_kernel

[C阶段, 虚拟地址视角]
start_kernel (init/main.c:557):
  ├─ 阶段1: boot_cpu_init/local_irq_disable/pr_notice(banner)
  ├─ 阶段2: setup_arch ★FDT解析/memory→memblock/chosen→boot_command_line
  │    ├─ setup_machine_fdt (fixmap映射DTB+三扫+只读保护)
  │    ├─ arm64_memblock_init (memblock加工)
  │    └─ unflatten_device_tree (DTB→device_node树挂of_root)
  ├─ 阶段3: build_all_zonelists+mm_init ★buddy/slab/vmalloc就位
  ├─ 阶段4: sched_init+init_IRQ+tick_init+softirq_init+local_irq_enable
  └─ 阶段5: vfs_caches_init+rest_init ★

rest_init:
  ├─ kernel_thread(kernel_init)    → PID 1 (先创建=占号,此时未运行)
  ├─ kernel_thread(kthreadd)      → PID 2 (内核线程母亲)
  ├─ complete(&kthreadd_done)     放行PID 1
  ├─ schedule_preempt_disabled()  ★第一次schedule→多线程时代开始
  └─ cpu_startup_entry→do_idle    PID 0变idle(永不退出)

PID 1: kernel_init
  ├─ kernel_init_freeable
  │   ├─ do_basic_setup
  │   │   ├─ driver_init()        设备模型初始化(/sys/devices/bus/class)
  │   │   └─ do_initcalls()       ★按级别0→7遍历initcall段
  │   │       ├─ postcore级(2): of_platform_populate ★device_node→platform_device
  │   │       │                    dev.of_node指回device_node, device_private_init
  │   │       ├─ subsys级(4):   i2c/spi总线驱动注册
  │   │       ├─ fs级(5):       ext4注册 + populate_rootfs(initramfs解包)
  │   │       └─ device级(6):   ★90%驱动注册
  │   │           platform_driver_register→bus_add_driver→driver_attach
  │   │           →platform_match(of_driver_match_device比对compatible)
  │   │           →really_probe→platform_drv_probe→drv->probe ★你的驱动!
  │   ├─ console_on_rootfs
  │   ├─ try_to_run_init_process("/init")  如果initramfs有/init就exec→不进prepare_namespace
  │   └─ prepare_namespace ★块设备rootfs路径
  │       ├─ wait_for_device_probe (等probe全跑完)
  │       ├─ name_to_dev_t(root=) → ROOT_DEV
  │       ├─ mount_root → ksys_mount(ROOT_DEV, "/root", "ext4")
  │       ├─ ksys_mount MS_MOVE (把/root挪到/)
  │       └─ ksys_chroot (切根)
  ├─ free_initmem (释放__init段)
  └─ run_init_process("/sbin/init") ★★最后一跳
      → do_execve → PID 1从内核线程变用户进程
      → CPU第一次进EL0 → 用户世界开始
      → init起getty/login/shell/网络服务等用户进程

PID 2: kthreadd → for(;;) 睡眠等kthread_create_list → create_kthread
  (所有[kworker]/[ksoftirqd]/...内核线程的母亲,从干净母体fork)

PID 0: cpu_startup_entry → do_idle 永久循环
  (CPU没事干时跑WFI等中断,永不退出)
```

## 13. 明日

7 天学习段收官！下一步：
1. **7 天门槛验收**：脱稿讲清完整启动链（上图）→ 验收通过
2. **立即进第二周实板任务**（第 8~14 天）：板子已到手，上实机验证
   - 第 8 天：原厂基线启动 + 串口日志分析
   - 第 9 天：自编译系统 TF 启动
   - 第 10 天：paging_init + __cpu_setup（划账到这）+ 内存地址模型
   - ...
   - 第 14 天：bsp-v1.0 发布 + 20 道面试题 + 15 分钟模拟面试
3. **BSP 阶段结束后触发安全启动总拷打**（ATF/TrustZone/Hypervisor，锚点已埋 BSP_PLAN.md）
