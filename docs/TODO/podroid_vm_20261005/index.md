---
For_Agent: 用真实虚拟机替换本地 proot 用户空间的设计；本次只做设计与验证环境勘察，未经批准不要写产品代码
repo: https://github.com/Timhub-135/Operit（分支 feat/ssh-default-terminal-target 之后的独立方案）
status: 设计进行中，等待批准；未改动任何产品代码
---

# 用 Podroid 式虚拟机替换本地 proot 用户空间

## 为什么做

本地目标今天是一套 proot 用户空间：Ubuntu 24.04 ARM64 rootfs 由 proot 以 ptrace 拦截系统调用运行。它能跑 shell、apt、node、python，但有几条硬限制：

- 需要特权的操作一律不可用，`CAP_SYS_ADMIN`、mount 命名空间、`io_uring`（被 seccomp 拦）、TAP 网络都拿不到
- **容器跑不起来**：`podman`、`docker`、`LXC` 依赖 user namespace 与 cgroup 的真实语义，proot 的翻译层满足不了
- 每个系统调用都过一次 ptrace，重负载比原生慢一个量级

按 Podroid 的做法换成一台**自带内核的真实虚拟机**（QEMU/TCG，或在支持 pKVM 的设备上走 AVF）后，容器、mount、网络都按服务器的方式工作，且不再需要把 rootfs 挂在应用进程里翻译系统调用。

## 现状一句话

`TerminalTarget.LOCAL` 今天等于 proot + Ubuntu rootfs（62.3 MB 随包资产，见 `docs/TODO/ssh_default_terminal_20261004/4_LocalUbuntuSshPackaging.md`）；远端 SSH 已是默认目标，本地目标降级为显式选择。

## 意图与预期结果

- 本地目标改为真实 VM，用户在同一入口拿到"能跑容器"的 Linux 环境
- 保持既有接口：`TerminalTarget.LOCAL` 语义、`environment="linux"`、`repo:`、AIDL 仅增量，已发布 v1.12.2 的行为不回退
- 明确 VM 的后端选择（AVF / QEMU-TCG）、体积策略与老用户迁移路径

## 参考实现

[Podroid](https://github.com/ExTV/Podroid)：rootless 的 Android 应用，启动带自有内核的 Alpine 3.24 虚拟机，预装 podman / docker / LXC，另有 X11 桌面、SSH 与 guest→Android 桥。它的架构与踩坑记录见 [1_PodroidAnalysis.md](1_PodroidAnalysis.md)。

它是**参考实现与验证夹具**，不是可并入的依赖：Operit 是 LGPL-3.0，Podroid 是 GPL-2.0-only，两者不能合并代码。形态上的取舍见 [2_ReplacementDesign.md](2_ReplacementDesign.md)。

## 待你拍板的决策

| # | 决策 | 选项 |
| --- | --- | --- |
| P1 | 集成形态 | ① 外部应用集成（零许可冲突，但要用户另装一个 297 MB 的应用）② 自研 VM 层（无许可冲突，工期最长）③ 保留 proot 作轻量本地环境，VM 只在需要容器时启用 |
| P2 | 体积策略 | 随包（APK 从 480.8 MB 涨到约 790 MB）／首启按需下载（约 312 MB，需校验与失败恢复）／拆 flavor |
| P3 | 老用户迁移 | 不做迁移（新环境全新开始）／提供"从 proot 环境导出并手工导入"的说明（注意：导出与删除入口刚被放弃） |
| P4 | x86_64 设备 | 只支持 arm64（与今天的 rootfs 一致）／另建 x86_64 guest 资产（成本翻倍） |
| P5 | 模拟器验证 | 见 [3_EmulatorAndVerification.md](3_EmulatorAndVerification.md)：库存模拟器跑不了 arm64 镜像，需要在"PC 上直跑 guest""x86_64 端口""真机"之间选 |

## 非目标

- 不改 Android 端文件系统（`environment="android"`）语义
- 不把 Podroid 的代码并入 Operit（许可不允许）
- 不为 x86_64 宿主构建 guest 资产，除非 P4 确认
- 不引入静默回落：后端按设备能力选择，但必须在设置页显示当前后端

## 步骤文档

- [1_PodroidAnalysis.md](1_PodroidAnalysis.md)：Podroid 的架构、约束、可复用的经验结论
- [2_ReplacementDesign.md](2_ReplacementDesign.md)：替换方案、接口契约、体积与迁移、风险
- [3_EmulatorAndVerification.md](3_EmulatorAndVerification.md)：模拟器实测结论与可选验证路径
