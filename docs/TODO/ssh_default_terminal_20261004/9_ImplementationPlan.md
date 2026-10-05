---
For_Agent: 本方案的落地阶段与每阶段出口条件，实施时按阶段推进并回填状态
---

# 实施计划

原则：先把能力做出来、把兼容面固定住，最后才切换默认值。每一阶段都可独立验证、独立回退（回退=改配置值或撤该阶段提交，不写兜底代码）。

## 进度

- 阶段 1 已完成（代码在 `OperitTerminalCore` 分支 `refactor/terminal-transport-abstraction`，未提交）
- 阶段 2 主体完成：依赖升级、SSH shell 通道传输、provider 切换、旧方案清理、主机密钥 TOFU、凭据加密与硬编码口令清理、known_hosts 设置页入口均已落地；余下私钥导入校验与生成密钥对、隐藏执行错误状态映射
- 阶段 3 与阶段 4 已完成：`activeTarget` 目标模型、默认远端、缺少配置时的引导、执行目标与已知主机设置界面、`environment="linux"` 文案、首启不再进本地安装向导
- 阶段 5 已完成：rootfs 资产预装 `openssh-client`（新资产 `ubuntu-noble-aarch64-pd-v4.19.0.tar.xz`）、`sshpass`/`openssh-server` 路径与安装条目清理、第三方许可清单补齐
- 阶段 0 已完成：容器化 sshd 夹具（`tools/ssh_test_host`）与远端路径性能基线均已落地并记录
- 阶段 6 已放弃（原计划的本地环境导出与磁盘释放，见下文），阶段 7 的验证记录已回填
- 真机验证：Android 16 x86_64 模拟器 + `ubuntu:latest` sshd 容器跑通远端目标全链路，证据见 [10_EmulatorVerification.md](10_EmulatorVerification.md)；可复用的设计报告见 [../../doc-src/architecture/SSH_TERMINAL_ARCH.md](../../doc-src/architecture/SSH_TERMINAL_ARCH.md)

## 阶段 0：基线与夹具

- 记录当前本地方案的性能基线：会话就绪时间、固定工作负载耗时、首启磁盘占用
- 准备可用的远端 sshd 夹具（本地容器或一台测试机），覆盖现代算法与禁用 `ssh-rsa` 的两种服务器
- 出口条件：基线数据与夹具记录落到本目录的验证文档里

## 阶段 1：终端模块的传输抽象（行为不变）[DONE]

- `transport/TerminalTransport.kt` 定义 `stdout`、`stdin`、`pty`、`pid`、`isAlive`、`destroy`、`awaitExit`
- `transport/LocalPtyTransport.kt` 包装本地 PTY；`TerminalSession` 只持有传输，`stdout`/`stdin`/`pty` 为转发属性
- `TerminalProvider.startSession` 改为返回 `Result<TerminalSession>`，不再返回 `Pair<TerminalSession, Pty>`
- `TerminalManager` 的退出处理改为向传输取退出码，并放进 `NonCancellable`，避免协程取消时丢失退出码与状态清理
- 顺带删除 `SessionManager` 中引用已失效 API 的注释代码块
- 本地 PTY 的 resize 下发本来就已经存在（`CanvasTerminalView` → `Pty.setWindowSize` → `TIOCSWINSZ`），本阶段未改

## 阶段 2：SSH channel 提供者与安全基础（进行中）

已完成：

- `com.jcraft:jsch:0.1.55` 升级为 `com.github.mwiede:jsch:2.27.7`（补齐 ed25519、rsa-sha2、curve25519）
- `SSHFileConnectionManager.openShellChannel` 建立带 PTY 的 shell 通道，并在 `connect()` 之前取好输入输出流（JSch 要求）
- `transport/SshChannelPty.kt` 覆写 `setWindowSize` 发送 window-change，并用通道可读字节数支撑输入模式检测；`transport/SshChannelProcess.kt` 提供替身进程；`transport/SshChannelTransport.kt` 提供 I/O、存活、销毁与退出码
- `SSHTerminalProvider.startSession` 改为通道直连，删除 `buildSshCommand`／`buildEnvironment` 与 proot 内的 `ssh_shell`
- 删除 `areSshToolsInstalled`／`isOpensshServerInstalled` 与“缺少 OpenSSH Server”弹窗，SSH 开关只要求存在连接配置；`SetupScreen` 移除 `sshpass` 与 `openssh-server` 条目；两处本地化文案同步更新

待完成：

- 主机密钥 TOFU 与 known_hosts 存储，替换 `StrictHostKeyChecking=no`
- 凭据迁入 Keystore 保护的存储，清除硬编码口令 `3688368398`／`ubuntu`
- 隐藏执行改用 exec channel 的原生退出码（当前已用 exec 通道，退出码取 `channel.exitStatus`，需补状态映射与超时中断）
- 出口条件：默认目标仍是本地，但可手动切到 SSH 并跑通全部集成矩阵

已完成的安全部分：

- `utils/HostKeyStore.kt` 自实现 `HostKeyRepository`，known_hosts 落在应用私有目录，格式与 OpenSSH 一致
- `StrictHostKeyChecking` 改为 `yes`；`HostKeyChallenge` + `HostKeyVerificationException` 表达未知主机与指纹变化
- `TerminalManager.pendingHostKey` + 终端界面指纹确认弹窗（未知主机／指纹变化两种文案），确认后写入 known_hosts 并重试会话
- `utils/SecretStore.kt`（Keystore AES-256-GCM）+ `SSHConfigManager` 加密保存与明文迁移
- 硬编码口令全部移除，手机侧 SSHD 口令改为每安装随机生成

仍未完成：

- known_hosts 的设置页查看／导入导出入口（存储层 API 已就绪）
- 私钥导入校验与应用内生成密钥对
- 隐藏执行的退出码状态映射与超时中断收尾
- 集成矩阵尚未在真实远端主机上跑过（本次只做了编译与打包验证）

## 阶段 3：主仓库目标模型与界面

- 引入 `activeTarget` 与目标解析，终端、隐藏执行、文件操作、MCP 运行时目录统一读取
- 首启引导改为“添加主机”；设置页展示目标与连通状态；本地环境安装入口降级为次级
- `SystemToolPrompts` 文案与本地化更新；`DebuggerFileSystemTools` 等按目标解析路径的调用点同步
- `linux_ssh` toolpkg 改为调用统一配置与远端目标，并重跑 `sync_example_packages.py`
- 出口条件：手工切换目标全部功能可用，老安装的目标不被静默改变

## 阶段 4：默认值切换

- 全新安装默认走 SSH 引导；未配置主机时不再自动进入本地 Ubuntu
- 更新说明中写明：已启用 SSH 的用户会话路径改为 channel 直连
- 出口条件：验收标准全部满足，且本地目标仍可手动选择并正常工作

## 阶段 5：本地环境出厂与依赖清理（独立变更）

- rootfs 资产预装 `openssh-client`，给出可复现打包步骤，更新资产名常量与哈希、第三方许可清单
- 移除 `sshpass` 路径；移除“缺少 openssh-server”弹窗与 `SetupScreen` 条目
- 出口条件：本地目标开箱即用，`areSshToolsInstalled()` 之类的旧检查被替换

## 阶段 6：导出与磁盘释放 [已放弃]

维护者已决定不做这一步：不再提供本地 proot 环境的导出与显式删除入口，[8_LocalEnvironmentExport.md](8_LocalEnvironmentExport.md) 保留为设计记录，但不作为待办实施。

放弃后的影响：

- 本地目标的磁盘占用仍需用户自行处理，应用内没有回收入口
- 应用数据里可能长期留着旧版 rootfs 包与已解压的 `usr/`（模拟器上实测遗留 64 MB 的 `v4.18.0` 包），这属于用户可见的既有行为，不再是本方案的待办
- 若日后又要做，设计文档里的导出形态、删除范围与二次确认要求可以直接复用

## 阶段 7：文档与验证记录

- 在 `docs/doc-src` 下补终端目标与 SSH 使用说明，同步 i18n
- 回填性能对比与验收结果到本目录
- 出口条件：文档链接检查、本地化检查、JVM 单测全部通过

## 风险与前置

- 子模块版本错配：主仓库必须声明最低 `OperitTerminalCore` 版本，独立 Terminal 应用需可继续编译
- AIDL 只做增量：`createSession()` 签名保持不变，目标选择用新增方法表达
- 主机密钥校验上线后，用户首次连接会多一步确认，属于有意的行为变化，需在更新说明中提前告知
- 阶段 1 与阶段 2 的顺序不可颠倒：先抽象后接入，才能保证本地路径不退化
