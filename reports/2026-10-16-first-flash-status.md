# LubanCat 2 首次构建、烧录与串口验证记录

记录日期：2026-10-16。主机时间与 Ubuntu VM 时区不同，VM 构建日志显示 2026-10-15 晚间。

## 当前结论

U-Boot、Linux 4.19.232、extboot 和 Ubuntu-lite rootfs 已构建；GPT、uboot、boot、rootfs 的写入日志显示成功，复位命令返回 `Reset Device OK.`。尚未收到板端启动日志，不能标记“成功启动”或“完成登录验证”。

用户原定要求是使用 Buildroot 生成 rootfs。此次实际走的是 SDK Ubuntu 路线，镜像内 `/etc/os-release` 为 Ubuntu 20.04.6 LTS；Buildroot 目标仍未完成。SDK 缺少 buildroot 目录，并不意味着不能另行引入 Buildroot，之前自动切换方案不应被记录成用户选择。

## 构建产物

Ubuntu VM：`liu@192.168.189.134`

SDK：`/home/liu/linux_driver/project/vendor/sdk`

板级配置：`device/rockchip/rk356x/BoardConfig-LubanCat-RK3568-ubuntu-lite.mk`

- U-Boot：`rk3568` defconfig。
- Kernel：`lubancat2_defconfig`，`rk356x-lubancat-generic` DTS。
- extboot：128 MiB ext2 文件系统，包含 Image、DTB/DTBO、boot.scr、uEnv、extlinux 配置和 kerneldeb 包。
- rootfs：ext4，Ubuntu 20.04.6 LTS。

| rockdev 文件 | 字节数 | 实际来源 |
| --- | ---: | --- |
| MiniLoaderAll.bin | 481728 | u-boot/rk356x_spl_loader_v1.21.114.bin |
| parameter.txt | 348 | device/rockchip/rk356x/parameter-ubuntu-fit.txt |
| uboot.img | 8388608 | u-boot/uboot.img |
| boot.img | 134217728 | kernel/extboot.img |
| rootfs.img | 1487929344 | ubuntu/ubuntu-lite-rootfs.img |

Kernel Image 为 26071048 字节；generic DTB 为 145785 字节。

GPT 分区按顺序是 uboot、boot、rootfs。boot 为 128 MiB，rootfs 使用剩余空间。extlinux 配置包含 `root=/dev/mmcblk0p3`、`console=ttyFIQ0`、`rootwait`、`rootfstype=ext4`；实际启动使用哪条 U-Boot 路径仍须日志确认。

## 烧录结果与纠正

识别到的设备为 VID 2207、PID 350a、Loader 模式，序列号 `fdac4bc5df929ae1`。

| 操作 | 日志结果 |
| --- | --- |
| loader 升级 | `Loading loader failed,err=-1!`，失败 |
| GPT 写入 | `Write gpt ok.` |
| uboot 写入 | `Download image ok.` |
| boot 写入 | `Download image ok.` |
| rootfs 写入 | 100%，`Download image ok.` |
| 复位 | `Reset Device OK.` |

之前将 loader 标为成功是不准确的。本机 SDK 内 upgrade_tool 的用法字符串为：

```text
UL <Loader> [-noreset] [FLASH|EMMC|SPINOR|SPINAND]
```

之前执行的是 `ul -noreset rockdev/MiniLoaderAll.bin`，参数顺序不符合该版本用法，且返回加载失败。若后续确实需要补写，应该在确认板子重新处于下载模式后使用以下顺序，并检查实际退出码与工具输出：

```bash
sudo tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool/upgrade_tool UL rockdev/MiniLoaderAll.bin -noreset
```

此纠正命令尚未执行。`UL` 是 loader 升级操作，不能描述为仅下载到 RAM；下载临时引导代码的 `DB` 是另一项命令。板子进入过 Loader 模式，说明不能仅凭最初串口静默就认定 eMMC 为空。

复位后，VM 未再枚举到 rockusb 设备。这只说明已退出下载接口，不能证明 Linux 已启动。

## 2026-10-16 镜像只读检查

`e2fsck -fn` 检查 SDK 中的 boot.img 和 rootfs.img，均返回 0。完整输出保存于 `logs/image-check-20261016.txt`。这是主机镜像检查，未做 eMMC 回读校验。

确认 rootfs 中 `/sbin/init` 指向 `/lib/systemd/systemd`，后者存在且可执行。

在已烧入的 rootfs 中未找到 `/lib/modules` 或 `/usr/lib/modules`。boot 镜像包含 kerneldeb 包，但不能据此认定首次启动已安装它们。模块安装状态需要板端检查；内核内建驱动仍可能支持基础启动。

## 串口发现与处理

Windows PnP 确认串口是 `USB-SERIAL CH340 (COM7)`，VID 1A86、PID 7523。VM 中没有 ttyUSB/ttyACM 设备，因此从 Windows 采集。

最初 COM7 打开被拒绝；关闭占用它的 MobaXterm 后可正常打开。

MobaXterm 的 COM7 会话原保存为 2500000。本次实际 U-Boot `.config` 为 `CONFIG_BAUDRATE=1500000`、`CONFIG_DEBUG_UART_BASE=0xFE660000`。已将 COM7 保存配置及 LastSession 改为 1500000，并保留备份：

```text
C:\Users\86199\AppData\Roaming\MobaXterm\MobaXterm.ini.before-uart-20261016.bak
```

被动监听 1500000 未收到字符；随后在 1500000、2500000、115200、921600 各发送一次 CRLF 并等待 4 秒，都未收到字符。尚未在监听期间进行物理 RESET，因此这些测试不能判定启动失败。

已创建并测试 `tools/capture-serial.ps1`，以 1500000、8N1、无流控监听 COM7，同时保存原始字节与 UTF-8 文本。脚本支持键盘输入发送给板子，Ctrl+] 关闭采集并释放端口。

14:54:55 已打开持续监听窗口，进程 PID 34528。启动后状态为 `listening`、`receivedBytes=0`。活动状态文件：`logs/serial-capture-status.json`。

本次日志：

- `logs/serial-COM7-20261016-145455.bin`
- `logs/serial-COM7-20261016-145455.log`

用户于本次续接明确反馈“已按复位”。截至主机时间 2026-10-16 15:02:16，持续采集状态仍为 `listening`、`receivedBytes=0`、`error=null`，原始字节文件和文本文件均为空。采集进程 PID 34528 仍存活，Windows 仍识别 CH340 COM7；Windows 和 Ubuntu VM 均未发现 Rockchip VID 2207 下载设备。

用户随后补充实物按键标识：从上到下为 ON/OFF、REC、MASKROM，并没有已确认的 RESET 键。之前要求“按 RESET”的指导错误，用户此前说“已按复位”不能作为整板已实际重启的证据。暂不把 0 字节归因为接线或固件故障，也不臆测各按键的长按时序。

再次核对编译产物：U-Boot 调试 UART 基址为 0xFE660000、波特率 1500000；generic DTB 中 fiq-debugger 为 `status = "okay"`、`serial-id = 2`、`baudrate = 0x16e360`（1500000）。当前事实仅为串口监听未收到任何字节，尚需在监听期间完成一次明确的断电再上电。保持调试串口 TX/RX/GND 连接，移除正常供电及可能供电的 OTG 连接，确认指示灯熄灭后重新接回正常电源；正常启动时不要按 REC/MASKROM。

当前采集窗口占用 COM7，MobaXterm 不应同时打开同一端口。下一步需用户提供能看清板子调试 UART 丝印、CH340 模块引脚及接线两端的照片，确认板子 TX→适配器 RX、板子 RX→适配器 TX、GND 共地，适配器逻辑电平匹配板卡要求，不连接适配器 VCC 给板子供电。在接线未确认前，不继续盲改波特率或重复刷写。

## 后续采集进程退出与恢复

用户再次反馈“我刚刚重新复位了一下”后，于主机时间 15:08 检查发现旧采集状态文件停留在 15:05:32，PID 34528 已不存在。因此旧文件中的 `state=listening` 是过期信息，不能据此认定本次用户操作期间持续监听且收到 0 字节。采集是否有效必须同时检查进程存活和状态时间更新。

COM7 随后能正常重新打开；1500000 下发送回车并监听 12 秒仍未获得登录提示。

15:09:38 改用工具管理的后台采集，进程 PID 27540，命令为：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\linux_driver\project\tools\capture-serial.ps1 -PortName COM7 -BaudRate 1500000 -NoKeyboard -DurationSeconds 540
```

此轮采集时限 540 秒，正常情况下约 15:18:38 结束并释放 COM7。15:10:02 已确认进程存活、两次观测间状态时间前进；15:10:30 心跳仍正常，原始文件只收到一个字节 `FC`。该单字节不是可辨认的启动文本，不能据此判定波特率、接线或固件故障。

本轮文件：`logs/serial-COM7-20261016-150938.bin`、`logs/serial-COM7-20261016-150938.log`。用户已确认实物没有 RESET 标识，不能继续要求按不存在的按键。

用户随后明确反馈“我断电又启动了”。主机时间 2026-10-16 15:12:50 再次检查：PID 27540 存活且响应，状态更新时间为 15:12:49.837，状态文件年龄约 0.5 秒，`state=listening`、`error=null`。原始日志由先前 1 字节增长为 2 字节，内容为 `FC FE`；UTF-8 文本显示两个替换字符，没有可读的 DDR、SPL、U-Boot、Kernel 或登录信息。两个字节不能证明任何启动阶段已到达，也不能据此认定内核镜像损坏或板子未运行。

在本轮监听有效且用户已明确断电上电的前提下，下一步核对物理调试 UART 与 CH340 接线及电平设置，需要能看清板端丝印、模块引脚和接线两端的照片。若接线不能直接定位，再做与板子断开的适配器 TX/RX 回环测试；当前尚未执行该测试。

## 环境收尾

之前构建期间创建的 `/etc/sudoers.d/liu-tmp` 内容为 `liu ALL=(ALL) NOPASSWD: ALL`，该文件并不会在 10 分钟后自动过期。已核对内容并删除本次会话创建的规则。后续提权恢复正常认证。

## 2026-10-16 串口与板端验收结果

用户最终确认此前 TX/RX 接反；改为板子 TXD→CH340 RXD、板子 RXD→CH340 TXD 后，COM8 在 1500000、8N1、无流控下收到正常登录提示：`lubancat login:`。串口无反应的直接原因已经定位并解决，不是已证实的 kernel/rootfs 故障。

登录后通过串口执行验收命令，得到以下事实：

```text
Welcome to Ubuntu 20.04.6 LTS (GNU/Linux 4.19.232 aarch64)
Linux lubancat 4.19.232 #24 SMP Thu Oct 15 21:36:41 PDT 2026 aarch64
root=PARTUUID=614e0000-0000 earlyprintk console=tty1 ...
/      /dev/mmcblk0p3 ext4   rw,relatime
```

`lsblk` 显示：

```text
mmcblk0       7.3G
├─mmcblk0p1     8M
├─mmcblk0p2   128M ext2
└─mmcblk0p3   7.2G ext4   /
mmcblk0boot0   4M
mmcblk0boot1   4M
```

这证明板子已从 eMMC 的新 GPT 分区启动，并使用新写入的 rootfs 作为 `/dev/mmcblk0p3` 根文件系统；boot 分区为新写入的 128M ext2 镜像；正在运行的 Linux 是本次编译的 4.19.232（编译主机标识 `liu@ubuntu`，版本号 `#24`）。`/proc/cmdline` 中还出现 `androidboot.fwver=...uboot-10/14/2026`，与本次构建的 U-Boot 时间吻合，支持正在运行新 U-Boot 的结论。loader 本身此前升级失败，不能据此声称 loader 已更新。

板端检查 `/lib/modules` 与 `/usr/lib/modules` 没有输出；因此当前系统能启动，但还需后续决定是否安装 boot 分区中携带的 kerneldeb 或单独执行模块安装。启动验收日志：`logs/serial-login-20261016-160501.log`；板端补充检查：`logs/serial-verify-20261016-160547.log`。

## 未完成的验收

- 记录并分析完整上电至登录日志，补齐 Week2 Day8 实板日志说明。
- 确认是否需要补写 loader；当前板子已能启动，不应仅因为最初 loader 升级失败而盲目重刷。
- 处理内核模块缺失：核实 boot 分区 kerneldeb，按需要安装并验证 `modprobe`。
- 按原定要求补齐 Buildroot rootfs；本次 Ubuntu 镜像不能替代该完成项。
