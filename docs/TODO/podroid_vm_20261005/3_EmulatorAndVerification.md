---
For_Agent: 当前 PC 上运行 Podroid 的实测结论与可选验证路径；结论是库存模拟器跑不了 arm64 镜像
---

# 模拟器与验证路径

## 结论先说

**在当前 PC 上无法用库存 Android 模拟器运行 Podroid。** Podroid 的 VM 资产与原生件只有 arm64（`libqemu-system-aarch64.so`、arm64 内核、arm64 Alpine rootfs），而宿主是 x86_64；Android 模拟器从若干年前起就只允许"系统镜像架构与宿主一致"，能跑 arm64 镜像的经典引擎已经移除。下面是被验证过的证据与可选替代路径。

## 实测证据（逐版本）

先按 VM-in-VM 的需要建好 AVD：`podroid_arm64`，镜像 `system-images;android-30;default;arm64-v8a`（本机已装），Pixel 3a 外壳，4 GB 内存、4 vCPU、12 GB data、720×1280@320、硬件键盘开、音频关。

| 模拟器版本 | 结果 |
| --- | --- |
| 36.2.12（SDK 当前） | `FATAL \| Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host. System image must match the host architecture.` |
| 31.3.10（build 8807927） | 同样 `PANIC`，措辞一致 |
| 30.4.5（build 7140946） | 不再拦截，确实调起 `qemu-system-aarch64-headless.exe`（`-machine type=ranchu -cpu cortex-a57`），但启动阶段即失败：`PCI bus not available for hda` |
| 30.3.5（build 7033400） | 与 30.4.5 一致 |

30.x 的失败原因很具体：模拟器**无条件**在 QEMU 命令行末尾追加 `-soundhw hda`，而 arm64 的 `ranchu` 机器没有可供 HDA 控制器使用的 PCI 总线，QEMU 在 guest 起来之前就退出。以下三种规避都无效：

- `-no-audio`（30.x 仍追加 `-soundhw hda`）
- `-audio none`（同上）
- `-qemu -device pcie-pci-bridge`（补 PCI 桥也无法让 hda 落位）

**直接重放 QEMU 命令行**也试过：用 `-verbose` 抓出模拟器实际执行的完整 QEMU argv，去掉 `-soundhw hda` 与 `-mem-path` 后自行启动。第一次失败于 `0xC0000135`（缺 DLL；把模拟器目录加进 PATH 无效，因为模拟器的 DLL 搜索顺序被限制），把 QEMU 可执行文件复制到模拟器根目录与 DLL 同处后该问题消失，但随后进程无输出退出，guest 仍未启动。这条路径没有继续深入。

附带说明：模拟器的 `qemu/` 目录里确实有 `qemu-system-aarch64.exe`，容易让人以为支持 arm64 宿主之外的场景；它是给 ARM 宿主（如 Apple Silicon）用的，arch 拦截发生在启动器里，与这个二进制无关。

## 已就绪的资产（都在 `tmp/`，已被 gitignore）

| 资产 | 位置 |
| --- | --- |
| arm64 AVD（已调参） | `%USERPROFILE%\.android\avd\podroid_arm64.avd` |
| Podroid release APK v1.2.9（297.3 MB） | `tmp/podroid/Podroid-v1.2.9-release.apk` |
| 旧版模拟器 30.3.5 / 30.4.5 / 31.3.10 | `tmp/android-emulator-arm64/emu-*/` |
| 抓取并重放的 QEMU 启动器 | `tmp/android-emulator-arm64/run-arm64-avd.cmd`，生成脚本 `tmp/cn/build-arm64-launcher.js` |

## 四条可选路径

| 路径 | 做法 | 能得到什么 | 成本 | 建议 |
| --- | --- | --- | --- | --- |
| A 把 VM 栈端口到 x86_64 | 为该架构各自构建 QEMU、内核、Alpine rootfs，跑在现有 x86_64 AVD（Android 侧有 WHPX 加速，只有内层 VM 走 TCG） | 唯一能在模拟器里形成可用开发闭环的路径 | 大：三套跨架构构建；Operit 自身的原生件也要出 x86_64 变体；产物只服务开发，生产仍是 arm64 | 若"模拟器可测"是长期需求则投入，否则不做 |
| B 真机 arm64 | Pixel 级设备走 AVF（快），其他 arm64 设备走 QEMU/TCG | 与上游一致的验证面，两个后端都能覆盖 | 需要设备 | **集成验收走这条** |
| C 在 PC 上直跑 Podroid 的 guest | 从 release APK 抽出 `vmlinuz-virt`、`initrd.img`、`alpine-rootfs.squashfs`，在 Linux 容器里用 `qemu-system-aarch64`（TCG）启动 | guest 的启动标记、OpenRC 服务、podman、resize 通道、host bridge 协议——除了 Android 侧的胶水以外的一切 | 小，一小时级 | **契约与 guest 侧工作现在就走这条** |
| D 继续 QEMU 直启 rig | 把直接重放 QEMU 的启动器补完（DLL 布局、显示/GPU 通道、模拟器自有 socket 协议） | 模拟器里的 UI 与图形栈 | 不确定，属不受支持的配置 | 只有在必须看图形/UI 时才继续 |

推荐组合：**C 立刻做契约验证，B 做集成验收，A 视长期需求再投入，D 按需**。

## 路径 C 的具体做法（可直接执行）

1. 从 `tmp/podroid/Podroid-v1.2.9-release.apk` 抽出 `assets/vmlinuz-virt`、`assets/initrd.img`、`assets/alpine-rootfs.squashfs`
2. 准备一个 Linux 容器（Debian/Ubuntu + `qemu-system-arm`），把三个资产挂进去
3. 依 Podroid 的 QEMU 参数启动 guest：两个 virtio 块设备分别是持久 ext4（upper）与只读 squashfs（lower），外加 virtio-console 与串口；`init-podroid` 会自行叠加 overlay 并 `switch_root`
4. 断言：串口日志里出现 `Starting SSH...` / `Almost ready...` / `Ready!`；进入 guest 后 `podman run --rm alpine echo ok` 成功；往控制通道写 `RESIZE 40 120` 后 guest 的 `stty size` 变化

这套断言就是上表里"接口契约"一栏的可执行版本，也是将来在真机上要重跑的那一份。

## 真机验收清单（路径 B，等设备到位）

- 设备能力：`adb shell pm list features | grep virtualization` 决定是否有 AVF；有则 `pm grant` 两个权限后强停重启才会生效
- 启动：`console.log`（debug 构建 `run-as` 可读）出现 `Ready!`；无 rootfs 解压进应用数据目录
- 终端：就绪握手三段信号、resize 后 guest `stty size` 与请求值一致、退出码正确
- 能力：guest 内 `podman run` 可用；文件共享双向可写；隐藏执行的超时能真正杀掉进程
- 集成：`environment="linux"` 落到 VM；MCP 共享会话可用；设置页显示当前后端
- 两个后端各跑一遍：AVF 与 QEMU/TCG 的行为差异是这个领域最常见的回归来源
