---
For_Agent: 本目录是“默认改用 SSH、本地 Ubuntu 降为可选目标”的方案设计、现状审计与验证记录；实现已落在 terminal 子模块分支 refactor/terminal-transport-abstraction，验证结果见 10_EmulatorVerification.md
repo: 本地检出 D:\design\Operit（main）+ terminal 子模块（refactor/terminal-transport-abstraction）
status: 实现完成，模拟器 + 容器端到端验证通过；未合并、未提交
---

# 默认使用 SSH 的终端方案

## 为什么做

本地 Ubuntu 走 proot，所有系统调用都要经过 ptrace 拦截，apt、node、python、JVM 这类重负载在同机上比原生慢一个量级；再加上首次会话要解压 62.6 MB 的 rootfs 资产、SSH 还得在 Ubuntu 里 `apt install ssh sshpass` 才能用，用户拿到的“Linux 环境”既慢又不是开箱可用。

远程 SSH 主机把这些负载挪到真正的 Linux 机器上，手机端只保留终端 I/O，是当前架构里最直接的一次性能与可用性改进。

## 现状一句话

SSH 今天不是一条独立执行路径，而是**寄生在 proot Ubuntu 上的可选项**：交互式 SSH 会先 `install_ubuntu` 进 proot，再在 Ubuntu 里跑 `sshpass -p ... ssh ...`，所以用 SSH 反而要先把最慢的那套环境装好。详细证据见 [1_CurrentSshUsage.md](1_CurrentSshUsage.md)。

## 已确认的决策

- D1 本地 Ubuntu：**仅从默认路径移除，仍随包提供**。proot、rootfs 资产与本地 provider 全部保留，只有用户显式选择时才使用
- D2 SSH 客户端：**升级到 mwiede/jsch 并直连 shell channel**，替换今天的 JSch 0.1.55
- D3 默认目标与引导：**只用用户自带主机配置**，首启引导“添加 SSH 主机”，不引入额外配对通道
- D4 本地模式出厂：**rootfs 资产预装 openssh-client，并去掉 sshpass**；`openssh-server` 不再作为本地必需项
- D5 用户数据：**提供导出后再删除**，用户可以把自己的 proot 环境导出或同步到远端后释放磁盘
- D6 `environment="linux"`：**字符串不变，后端改为当前 SSH 主机**，本地环境通过显式选择使用

## 目标

- 终端默认目标改为远程 SSH 主机，SSH 会话不再经过 proot，也不再需要 Ubuntu 里的 `ssh`/`sshpass`
- 本地 Ubuntu 保留但降级为可选目标，已发布行为不消失
- 明确单一 SSH 配置来源，替换过时的 JSch 0.1.55 并补齐主机密钥校验
- 本地环境开箱可用（预装 openssh-client），用户数据可导出后释放

## 非目标

- 不改 Android 端文件系统（`environment="android"`）语义
- 不引入自动降级：远端连不上就报错并让用户显式切换目标，不静默回落本地
- 本次不删除本地环境代码（移除范围见 D1）
- 本次不重写终端渲染层（CanvasTerminalView / AnsiTerminalEmulator）
- 不在本次引入 mosh、X11、容器管理等 tabssh 附带能力

## 步骤文档

- [1_CurrentSshUsage.md](1_CurrentSshUsage.md)：SSH 现状审计，含文件行号证据与问题清单
- [2_TargetArchitecture.md](2_TargetArchitecture.md)：SSH 优先后的目标架构、接口契约与改动清单
- [3_SshClientChoice.md](3_SshClientChoice.md)：客户端选型与 tabssh/android 评估
- [4_LocalUbuntuSshPackaging.md](4_LocalUbuntuSshPackaging.md)：让 ssh 随本地 Ubuntu 出厂的四种做法
- [5_SecurityHardening.md](5_SecurityHardening.md)：主机密钥、凭据存储与硬编码口令
- [6_CompatibilityAndMigration.md](6_CompatibilityAndMigration.md)：已发布接口的兼容与分仓推进顺序
- [7_VerificationPlan.md](7_VerificationPlan.md)：验证与性能基准计划
- [8_LocalEnvironmentExport.md](8_LocalEnvironmentExport.md)：本地环境的导出与磁盘释放流程
- [9_ImplementationPlan.md](9_ImplementationPlan.md)：九个阶段的落地顺序与出口条件
- [10_EmulatorVerification.md](10_EmulatorVerification.md)：模拟器 + 容器 sshd 的端到端验证记录

## 可复用产物

- [../../doc-src/architecture/SSH_TERMINAL_ARCH.md](../../doc-src/architecture/SSH_TERMINAL_ARCH.md)：把本方案的分层、接口契约、失败模式与验收方法抽成与项目无关的设计报告，其它项目可直接引用后按同一契约实现
