---
For_Agent: 用 VM 替换本地 proot 的方案已定型：从 Podroid 制品抽出 guest 资产，在应用内直接用 qemu-system-aarch64（TCG）启动。未经批准不要写产品代码
repo: https://github.com/Timhub-135/Operit（分支 docs/podroid-vm-replacement-design）
status: 设计已按定型方案改写；未改动任何产品代码
---

# 用自建 QEMU 启动层替换本地 proot 用户空间

## 方案定型

本地目标不再使用 proot 用户空间，改为**在应用进程外启动一台自带内核的 Alpine 虚拟机**：

- guest 资产（内核、initramfs、rootfs）**从 Podroid 的 release APK 抽出**，按哈希固定版本
- 在设备上直接执行 **`qemu-system-aarch64`（TCG，软件模拟）**，不依赖 AVF、不依赖 root、不依赖 pKVM
- 由 Operit 自己承担启动层：设备布局、三条 virtio-console 通道、串口日志、SLIRP 网络、持久盘与生命周期
- Podroid 只是**资产来源与经验来源**，不集成它的应用、也不合并它的代码

选这条路的理由：上一轮在本机用普通 QEMU 直接跑通了 Podroid 的 guest（见 [3_EmulatorAndVerification.md](3_EmulatorAndVerification.md)），启动参数、通道协议、挂载结构与容器能力都已在 PC 上验证；把这些参数搬到 Android 上执行，是改动面最小、可控性最高的一条路。

## 为什么值得替换 proot

proot 通过 ptrace 翻译系统调用，拿不到真实的 user namespace 与 cgroup 语义，因此 podman / docker / LXC 这类要在服务器上跑的东西根本起不来；同时每个系统调用都要过一次拦截，重负载比原生慢一个量级。换成带自有内核的 VM 之后，容器、mount、网络都按服务器的方式工作。

## 复用什么、不复用什么

| 复用 | 说明 |
| --- | --- |
| `vmlinuz-virt`（20.0 MB） | 自带内核 7.1.5，已含 overlayfs / netfilter / bridge / veth / tun / FUSE 等必需项 |
| `initrd.img`（40.7 MB） | 内含 `init-podroid`：挂载持久 ext4 与只读 squashfs、叠 plain overlay、`switch_root` |
| `alpine-rootfs.squashfs`（213.5 MB） | Alpine 3.24.2 + OpenRC + podman/crun/fuse-overlayfs/docker/LXC/dropbear |
| `libqemu-system-aarch64.so`（36.6 MB） | 已按 Android NDK 交叉编译、16 KB 页对齐的 QEMU 可执行文件 |
| `libslirp.so`（1.0 MB） | QEMU 的用户态网络后端 |
| 启动参数与通道布局 | 设备顺序、通道用途、性能旋钮都是被验证过的既定事实 |

| 不复用 | 理由 |
| --- | --- |
| Podroid 的应用与引擎代码 | GPL-2.0-only 与 Operit 的 LGPL-3.0 不兼容，不能合并代码 |
| 它的 UI、X11 桌面、USB 直通、9p 共享 | 与本方案的替换目标无关，能砍则砍 |
| 它的 `libpodroid-launcher.so` | 可用更简单的方式达到同样目的（前台服务 + 子进程收敛），是否复用见 P6 |

## 待你拍板的决策

| # | 决策 | 选项 |
| --- | --- | --- |
| P2 | 体积与分发 | guest 资产 + QEMU 合计约 **311.8 MB**。随包（APK 从 480.8 MB 涨到约 790 MB）／首启按需下载（需哈希校验与失败恢复）／拆 flavor |
| P3 | 老用户迁移 | proot 环境被替换后，用户在里面装的东西不会自动出现。不做迁移（更新说明写清）／提供手工导入说明（注意：导出与删除入口已放弃） |
| P4 | x86_64 设备 | 只支持 arm64（与今天随包 rootfs 的 ABI 一致）／另建 x86_64 的 QEMU 与 guest 资产（成本翻倍） |
| P6 | 资产长期来源 | 继续取 Podroid 的 release 制品（省事，但绑定他人发版与 GPL 义务）／自建构建链（内核 + rootfs + QEMU 交叉编译，成本高但完全自主） |
| P7 | 许可与标注 | 必须做：GPLv2 源码提供、Podroid 与 Alpine 的归属标注、不声称自研。具体形式（应用内许可页 / 仓库文档 / 下载页）待定 |
| P8 | proot 路径的退役节奏 | 立即删除／保留一个发布周期（能力检测下隐藏），第二个版本再删 |

## 非目标

- 不改 Android 端文件系统（`environment="android"`）语义
- 不引入 AVF 后端：本方案只用 QEMU/TCG，后端选择不再是一个维度
- 不合并 Podroid 的代码，不把它的应用作为依赖
- 不做静默回落：VM 起不来就报错并让用户显式切回远端 SSH 目标（远端仍是默认目标）

## 步骤文档

- [1_PodroidAnalysis.md](1_PodroidAnalysis.md)：Podroid 的架构、约束与经验结论，含本方案要复用的具体参数
- [2_ReplacementDesign.md](2_ReplacementDesign.md)：启动层设计、接口契约、生命周期、体积、许可、迁移与风险
- [3_EmulatorAndVerification.md](3_EmulatorAndVerification.md)：模拟器结论、PC 上的参照实现（已跑通）与真机验收清单
