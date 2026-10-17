# Day 5 复习笔记：rest_init 与 PID 0/1/2 的诞生（学习者视角）

> 7 天计划第 5 天。理论：进程/线程、PID、内核线程、调度与上下文切换概念；源码：rest_init()、kernel_init()、kthreadd 创建路径；验收：解释 PID 0/1/2 如何产生。
> 源码基准：Rockchip 4.19（虚拟机 `/home/liu/linux_driver/project/vendor/sdk/kernel`）。
> 承接 Day4：start_kernel 阶段 5 的最后一行 `rest_init()`——从这里开始内核从单线程进入多线程。

## 0. 学习轨迹：我曾经的错误理解

1. **"内核线程和普通线程差不多"** → 错。本质区别是 `mm` 字段：内核线程 `mm=NULL`（没有用户地址空间，永不进 EL0），普通线程有 `mm_struct`。`PF_KTHREAD` 标志区分
2. **"直接 kernel_thread 就能创建内核线程，kthreadd 只是多余的中间人"** → 错。kthreadd 是"干净母体"——所有运行时创建的内核线程从它 fork，继承"忽略信号/全核/PF_NOFREEZE"的干净上下文；直接从调用者 fork 会继承脏状态（驱动的 signal handler/cgroup/CPU 亲和性）
3. **"rest_init 创建完 PID 1/2 它们就立刻跑了"** → 错。`kernel_thread` 只建 task_struct 挂就绪队列，真正运行要等 `schedule_preempt_disabled()` 这第一次调度
4. **"PID 0 之后就不存在了"** → 错。PID 0 永远不退出——`cpu_startup_entry → do_idle` 永久循环，CPU 没事干时跑它（你 top 看到的 idle%）

## 0.5 全局一张图

```text
start_kernel(一条执行流, PID 0, boot CPU)
  └─ rest_init()   ★分家★
       ├─ rcu_scheduler_starting()       RCU调度器正式工作
       ├─ pid = kernel_thread(kernel_init, ...)   → PID 1(创建=占号, 此时未运行)
       │    └─ set_cpus_allowed_ptr: 钉在boot CPU(多核迁移还没就绪)
       ├─ pid = kernel_thread(kthreadd, ...)      → PID 2(内核线程母亲)
       │    └─ kthreadd_task = find_task_by_pid_ns(pid)  存全局变量
       ├─ system_state = SYSTEM_SCHEDULING
       ├─ complete(&kthreadd_done)        ★放行PID 1(它在等这个)
       ├─ schedule_preempt_disabled()     ★★第一次真正的schedule→多线程时代开始
       └─ cpu_startup_entry(CPUHP_ONLINE) → do_idle()永久循环 → PID 0变idle(永不退出)

PID 1: kernel_init
  ├─ kernel_init_freeable()   → do_initcalls(Day6驱动注册) → free_initmem(释放__init段)
  └─ run_init_process()       → exec用户空间init(/sbin/init等) → 变成用户进程(systemd)
       找不到init → panic("No working init found")

PID 2: kthreadd
  └─ for(;;) {
         睡眠等kthread_create_list有请求
         醒来逐个create_kthread → kernel_thread(kthread) → 新内核线程
         (从kthreadd fork=继承干净上下文: 忽略信号/全核/PF_NOFREEZE)
     }
```

## 1. 基础概念（零基础补课）

### 1.1 进程 / 线程 / 任务 / PID

- **进程**：正在运行的程序，有独立虚拟地址空间。打开一个 app 就是一个进程
- **线程**：进程内部执行单位，同进程线程共享地址空间、各有各的栈
- **Linux 特殊点**：内核不区分进程和线程，统一叫"任务"(task)，都用 `task_struct` 表示。线程就是"共享了地址空间的 task"
- **PID**：每个任务的唯一编号，PID 1=init、PID 2=kthreadd、PID 0=idle

### 1.2 task_struct

内核描述任务的全能结构体（sched.h），每个任务一个：

```c
struct task_struct {
    pid_t pid;                       // 进程号
    struct mm_struct *mm;            // ★我的虚拟地址空间(进程独有/线程共享; 内核线程=NULL)
    struct mm_struct *active_mm;     // 借用的mm(内核线程用,只为TLB不空)
    struct files_struct *files;      // 打开文件表
    volatile long state;             // 运行/睡眠/停止...
    struct task_struct *parent;      // 父进程
    unsigned int flags;              // PF_KTHREAD等标志
    ...
};
```

### 1.3 init

用户空间第一个进程（PID 1）。内核启动完所有驱动、挂好 rootfs 后，从内核态 `exec` 一个用户程序（`/sbin/init`/`/etc/init`/BusyBox init），PID 1 从内核线程变成用户进程。它是所有用户进程的祖先；**PID 1 死了 → 内核 panic**。嵌入式通常是 BusyBox init（读 `/etc/inittab`）。

### 1.4 RCU

Read-Copy-Update：只读不加锁的高并发数据结构保护。读者直接读不加锁；写者复制副本改、换指针、等所有读者退出后释放旧数据。`rcu_scheduler_starting()` 在 rest_init 里正式激活 RCU 的调度回收部分——之前是"没有真正调度"的过渡态。

### 1.5 boot CPU

多核处理器里第一个跑内核的核（CPU0）。RK3568 四核：加电只有 CPU0 跑 BootROM→U-Boot→Kernel，CPU1/2/3 睡眠等待，内核后期 `smp_init_cpus` 从 DTB 读 CPU 数量、`smp_prepare_cpus` 唤醒其他核。rest_init 把 PID 1 钉在 boot CPU 是因为多核负载均衡（sched_init_smp）还没就绪。

## 2. rest_init 逐行（init/main.c:397）

```c
static noinline void __ref rest_init(void)
{
    rcu_scheduler_starting();          // ① RCU调度器正式工作
```
**①** 之前 RCU 处于禁用调度的过渡态，这里激活——之后 kernel_thread 创建任务才安全。

```c
    pid = kernel_thread(kernel_init, NULL, CLONE_FS);   // ② ★创建PID 1
```
**②** 复制当前任务（PID 0）建新任务，入口函数 `kernel_init`。**此时未运行**——只挂就绪队列。注释解释为什么 PID 1 先创建：PID 号按顺序分配，先创建拿 1 号；但 init 要创建内核线程（依赖 kthreadd），所以 kthreadd 必须在 init 真正跑之前就位。

```c
    // ③ 钉PID 1在boot CPU
    tsk = find_task_by_pid_ns(pid, &init_pid_ns);
    set_cpus_allowed_ptr(tsk, cpumask_of(smp_processor_id()));

    pid = kernel_thread(kthreadd, NULL, CLONE_FS | CLONE_FILES);  // ④ ★创建PID 2
    kthreadd_task = find_task_by_pid_ns(pid, &init_pid_ns);       // ⑤ 存全局变量
```
**③** 多核迁移要等 sched_init_smp，现在迁移出问题。
**④⑤** 创建 PID 2，存进全局 `kthreadd_task`——之后任何 `kthread_create` 通过它找 kthreadd。

```c
    system_state = SYSTEM_SCHEDULING;
    complete(&kthreadd_done);           // ⑥ ★放行PID 1
```
**⑥** 同步点。PID 1 的 `kernel_init_freeable` 里有 `wait_for_completion(&kthreadd_done)`——卡住等 kthreadd 就位。**"先创建占号→等就位→放行"的闭环**。原因：PID 1 后续 do_initcalls 会创建内核线程，kthreadd 没就位就 OOPS。

```c
    schedule_preempt_disabled();        // ⑦ ★第一次真正的schedule→多线程时代开始
    cpu_startup_entry(CPUHP_ONLINE);    // ⑧ PID 0变idle,永不返回
}
```
**⑦** 之前所有代码都是单线程串行；schedule 一调调度器从就绪队列挑下一个任务切过去——**多线程时代从这一行开始**。
**⑧** `cpu_startup_entry`（sched/idle.c:350）：

```c
void cpu_startup_entry(enum cpuhp_state state)
{
    while (1)
        do_idle();   // ★永久空闲循环: 没事WFI等中断, 中断来了处理完继续等
}
```
PID 0 的宿命：永不离场。

## 3. PID 1 kernel_init（init/main.c）

```c
static int __ref kernel_init(void *unused)
{
    kernel_init_freeable();      // ★★ Day6的do_initcalls在这里面
    async_synchronize_full();
    free_initmem();              // 释放__init段(所有__init标记的函数用完即弃,内存还回去)
    mark_readonly();             // 内核text段设只读(安全加固)
    system_state = SYSTEM_RUNNING;

    // ★★ Day7主战场: 找init程序并exec
    if (ramdisk_execute_command)
        ret = run_init_process(ramdisk_execute_command);   // 先试ramdisk的/init
    if (execute_command) {        // bootargs的init=参数
        ret = run_init_process(execute_command);
        if (!ret) return 0;
        panic("Requested init %s failed", ...);
    }
    // 回退顺序
    if (!try_to_run_init_process("/sbin/init") ||
        !try_to_run_init_process("/etc/init") ||
        !try_to_run_init_process("/bin/init") ||
        !try_to_run_init_process("/bin/sh"))
        return 0;
    panic("No working init found.");   // 全失败→内核panic
}
```

**两阶段**：
- **内核态**（`kernel_init_freeable`）：跑完所有 initcall（Day6）→ 释放 `__init` 段 → text 只读
- **用户态**（`run_init_process`）：`kernel_execve` 把自己从内核线程变用户进程。查找顺序：ramdisk `/init` → bootargs `init=` 指定的 → `/sbin/init` → `/etc/init` → `/bin/init` → `/bin/sh`，全失败 panic

## 4. PID 2 kthreadd（kernel/kthread.c）

```c
int kthreadd(void *unused)
{
    set_task_comm(tsk, "kthreadd");          // 干净名字
    ignore_signals(tsk);                      // ★忽略所有信号(内核线程不处理信号)
    set_cpus_allowed_ptr(tsk, cpu_all_mask); // ★允许跑在任何核
    current->flags |= PF_NOFREEZE;           // ★suspend时不冻结
    // ↑这套"干净模板"就是所有内核线程要继承的

    for (;;) {                                // 主循环永不退出
        set_current_state(TASK_INTERRUPTIBLE);
        if (list_empty(&kthread_create_list))
            schedule();                       // 没活→睡眠让出CPU
        __set_current_state(TASK_RUNNING);

        // 有活: 从链表取创建请求,逐个create_kthread
        while (!list_empty(&kthread_create_list)) {
            create = list_entry(...);
            list_del_init(&create->list);
            create_kthread(create);           // ★实际创建
        }
    }
}
```

**所有 `[kworker/x:y]`/`[ksoftirqd/x]`/`[ktimers/...]` 内核线程都是它的孩子**。

## 5. 内核线程 vs 普通线程（追问高频）

| | 内核线程 | 普通线程 |
|---|---|---|
| `mm` | **NULL**（没用户空间） | 指向 mm_struct |
| `active_mm` | 借前一个用户进程的（TLB 不空） | = mm |
| 运行区域 | 只在 EL1（内核态） | EL0 + EL1 |
| `PF_KTHREAD` | 有（0x00200000） | 无 |
| 入口 | kernel_thread(fn) 内部创建 | fork() 系统调用 |
| 系统调用 | 不能（已在内核里） | 能 |
| ps 显示 | 名字带方括号 `[xxx]` | 正常名字 |

## 6. 为什么内核线程要通过 kthreadd 中转（本日最关键追问）

### 6.1 kthread_create API 是异步的

```c
// kthread_create 内部(__kthread_create_on_node):
create = kzalloc(sizeof(*create), ...);       // 填请求
create->threadfn = threadfn;
list_add_tail(&create->list, &kthread_create_list);  // 挂链表
wake_up_process(kthreadd_task);               // 叫醒PID 2
wait_for_completion_killable(&create->done);  // ★睡眠等kthreadd干完
return create->result;
```
**kthread_create 自己不创建——挂请求、叫醒 kthreadd、睡眠等结果**。

### 6.2 create_kthread 实际调 kernel_thread

```c
static void create_kthread(struct kthread_create_info *create)
{
    pid = kernel_thread(kthread, create, CLONE_FS | CLONE_FILES | SIGCHLD);
    //                   ↑入口是kthread(包装函数), 不是threadfn!
}
```

### 6.3 kthread 包装函数做"清理上下文"

```c
static int kthread(void *_create)
{
    int (*threadfn)(void *data) = create->threadfn;
    self = kzalloc(sizeof(*self), GFP_KERNEL);   // 分配kthread专属结构
    set_kthread_struct(self);
    // 设名字/调度参数/CPU亲和性
    ...
    ret = threadfn(data);   // ★最后才调用户要的函数
}
```

### 6.4 为什么不直接 kernel_thread(threadfn)——"脏母体"问题

| 方式 | 从谁 fork | 继承 | 问题 |
|---|---|---|---|
| 直接 kernel_thread(threadfn) | 当前调用者（任意驱动/中断） | 调用者的脏状态 | 信号 handler/cgroup/CPU 亲和性不可控 |
| kthread_create → kthreadd → create_kthread | **kthreadd（干净母体）** | 忽略信号/全核/PF_NOFREEZE | 无，多一层异步中转 |

直接从"脏调用者"fork 的风险：
- 继承某个驱动的 signal handler → 收到信号跑驱动的 handler（不该有）
- 继承某个 cgroup → suspend 时被错误冻结
- 继承 CPU 亲和性 → 被错误绑核

**kthreadd 在启动时就清理干净了**（ignore_signals/cpu_all_mask/PF_NOFREEZE），所有内核线程从它 fork = 继承干净模板。多一层中转的代价是异步等待，但内核线程是长期后勤工人，创建时多花点时间换干净上下文值得。

**启动早期 rest_init 直接用 kernel_thread 创建 PID 1/2 的原因**：那是启动早期、没有脏调用者问题（PID 0 的上下文就是干净的 init_task），且 kthreadd 自己都还没创建无法中转。等 kthreadd 就位后所有内核线程都走它。

## 7. 闭卷标准答案

**Q1 PID 0/1/2 分别怎么产生？**
rest_init 里：① `kernel_thread(kernel_init)` 创建 PID 1（先创建=占号，此时未运行）② `kernel_thread(kthreadd)` 创建 PID 2（存全局 kthreadd_task）③ `complete(&kthreadd_done)` 放行 PID 1（它等 kthreadd 就位）④ `schedule_preempt_disabled()` 第一次调度→多线程开始 ⑤ `cpu_startup_entry→do_idle` PID 0 变 idle 永不退出。PID 1 跑 kernel_init_freeable（do_initcalls）→ exec 用户空间 init；PID 2 进 for(;;) 循环当内核线程母亲。

**Q2 为什么先创建 PID 1 再创建 PID 2？**
PID 号按创建顺序分配，先创建才能拿到 1 号。但 init 迟早要创建内核线程（依赖 kthreadd），所以 kthreadd 必须在 init 真正跑起来前就位。顺序是"先创建 PID1 占号→创建 PID2→complete 放行 PID1"。

**Q3 complete(&kthreadd_done) 没有这行会怎样？**
PID 1 的 kernel_init_freeable 里有 wait_for_completion(&kthreadd_done) 卡住等。没有 complete → PID 1 永远卡在那里 → do_initcalls 永远不跑 → 驱动不加载 → rootfs 不挂 → init 永不 exec → 系统死在启动中途。

**Q4 kernel_thread 创建的任务何时真正运行？**
创建时只建 task_struct 挂就绪队列，不立即运行。真正运行要等调度器 schedule() 把它选出来。rest_init 里 schedule_preempt_disabled() 是第一次真正调度——之前所有代码都是单线程串行的。

**Q5 内核线程和普通线程的区别？**
本质：mm 字段。内核线程 mm=NULL（没有用户地址空间、永不进 EL0），普通线程有 mm_struct。PF_KTHREAD 标志区分。内核线程只在内核态跑、不能调系统调用、ps 里名字带方括号。典型：kthreadd/kworker/ksoftirqd。

**Q6 为什么不直接 kernel_thread 而要通过 kthreadd 中转？**
"脏母体"问题。直接 kernel_thread 从当前调用者 fork，继承调用者的信号/cgroup/CPU 亲和性等脏状态。通过 kthreadd 中转：所有内核线程从 kthreadd fork，继承它启动时清理好的干净模板（ignore_signals/cpu_all_mask/PF_NOFREEZE）。多一层异步中转的代价值得——内核线程是长期工人，干净上下文比创建速度重要。

## 8. 踩坑 / 易混点

1. kernel_thread 创建≠立刻运行；要等 schedule()
2. PID 0 不退出——do_idle 永久循环；PID 1 死了→panic
3. complete(&kthreadd_done) 是 PID 0→PID 1 的同步点，缺了系统卡死
4. 内核线程 mm=NULL 但 active_mm 借前一个用户进程的（TLB 不空）
5. rest_init 用 kernel_thread 直接创建 PID 1/2 是启动早期特例（PID 0 干净+kthreadd 没就位）；运行时全走 kthread_create→kthreadd 中转
6. create_kthread 的入口是 kthread 包装函数不是 threadfn——两层包装
7. boot CPU = CPU0 = 唯一全程参与启动的核；CPU1/2/3 后期被 smp 唤醒
8. `[xxx]` 带方括号的 ps 输出 = 内核线程（PF_KTHREAD），无用户空间

## 9. 明日（Day6）

kernel_init_freeable 深入：do_initcalls 驱动注册链路、of_device_id 匹配 device_node 树、probe 调用时机。验收：区分初始化函数执行、驱动注册、匹配与 probe。
## Q1：什么是 COW（写时复制），简单描述机制

A：COW 是 Linux 内核的内存管理软件机制。fork 创建子进程时，内核拷贝一份独立页表，父子页表项指向同一块物理内存，并将页表项标记只读。读访问直接共享，不会拷贝；当任意一方尝试写页面内数据，MMU 触发只读异常，内核识别为 COW 页面，分配新物理页，复制页面数据，修改当前进程的 PTE 映射与权限，之后重试写指令。做到延迟拷贝，节省内存，加快 fork 速度。

## Q2：fork 的时候，拷贝的是物理内存吗？

A：不拷贝物理内存。fork 调用 copy_mm，**只拷贝页表**，生成子进程独立的页表；父子页表项暂时指向同一个物理页，依靠 COW 共享物理内存。物理页的拷贝只会在后续写访问触发 COW 的时候才执行。

## Q3：fork 为什么要拷贝页表，直接共用一套页表不行吗？

A：不行。页表属于 mm 地址空间管理结构。如果父子共用一套页表，父进程修改页表（brk、mmap 等）会直接篡改子进程地址空间，破坏进程地址隔离。
拷贝页表后，父子各自拥有独立页表。fork 瞬间页表内容一致，共享物理页；后续各自的内存映射修改只会改动自己的页表，互不干扰。

## Q4：clone 系统调用的核心逻辑是什么，task_struct 和附属资源如何处理？

A：clone 是 Linux 创建任务的底层原语，fork、pthread_create、kernel_thread 底层都依赖它。
sys_clone 调用 copy_process：首先 dup_task_struct，复制一份独立 task_struct。再根据传入 CLONE 标志，判断附属资源（mm、files、fs、sighand）：标志置位则共享资源（指针复用，引用计数 + 1）；标志不置位则分配新结构体，拷贝内容。最后分配 PID、唤醒新任务。
task_struct 一定拷贝；mm/files/fs 等附属资源由 flag 决定共享 / 拷贝。

## Q5：CLONE_VM 标志的作用，带和不带的区别？

A：CLONE_VM 代表共享 mm_struct，共用一套页表，也就是用户态线程（pthread），线程间地址空间完全共享，修改内存互相可见，不存在 COW。
不带 CLONE_VM（fork 场景），子进程新建独立 mm、拷贝页表，使用 COW 机制实现物理页延迟共享，父子地址空间相互隔离。

## Q6：fork 对应的 clone 标志是什么？含义是什么？

A：`CLONE_CHILD_CLEARTID | CLONE_CHILD_SETTID | SIGCHLD`

1. SIGCHLD：子进程终止时向父进程发送 SIGCHLD 信号，父进程可 wait 回收僵尸进程。
2. CLONE_CHILD_SETTID：子进程创建完成，将 TID 写入用户态指定地址。
3. CLONE_CHILD_CLEARTID：子进程退出时，将该用户地址置 0，并唤醒等待在此地址的任务，用于用户态同步。
这套 flag 不带 CLONE_VM、CLONE_FILES、CLONE_FS，所以是独立进程。

## Q7：什么是系统调用？svc 指令在里面起什么作用？

A：系统调用是用户态 EL0 请求内核特权服务的整套机制。ARM64 下用户态执行 svc #0 指令，硬件自动保存现场，EL0 切换到 EL1，跳转到内核异常向量，内核根据系统调用号执行 sys_xxx 函数；处理完用 eret 切回 EL0。
svc 只是触发特权切换的硬件指令，是系统调用的入口；系统调用是 svc 陷入、内核业务处理、eret 返回的完整流程。内核线程运行在 EL1，不能执行 svc，无法发起系统调用。

## Q8：kernel_thread 为什么要通过 kthreadd (PID2) 中转创建内核线程，不能直接调用 kernel_thread？

A：kernel_thread 底层是 clone，新任务会继承调用者 task 的 files、fs、信号、资源上下文。
如果在内核随机上下文（比如 bash 用户进程陷入内核的上下文）直接调用 kernel_thread，新建内核线程会继承用户进程的 fd、信号等脏资源，容易资源泄漏、收到异常信号。
kthreadd 是纯净内核线程，mm=NULL，无用户资源。kthread_create 把创建请求挂入链表，唤醒 kthreadd，由 kthreadd 调用 kernel_thread 创建新内核线程，新线程继承 kthreadd 干净上下文。
rest_init 直接调用 kernel_thread 创建 PID1、PID2，是启动早期特殊路径，此时系统只有 PID0 idle，环境干净。