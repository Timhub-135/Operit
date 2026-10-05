---
For_Agent: SSH 客户端选型与 tabssh/android 评估结论，替换依赖前更新本文件
---

# SSH 客户端选型

## 现状

`com.jcraft:jsch:0.1.55`（`terminal/build.gradle.kts:102`）。该版本 2018 年后未再维护：

- 不支持 ed25519、rsa-sha2-256/512、curve25519-sha256、chacha20-poly1305、aes-gcm
- OpenSSH 8.8 起默认关闭 `ssh-rsa`（SHA-1）签名，默认配置的新服务器会直接握手失败
- 无法连接使用现代算法的服务器，这是“SSH 不好用”的根因之一，与 proot 的性能问题相互独立

同时 Apache MINA SSHD 2.10.0 已作为**服务端**依赖存在（`terminal/build.gradle.kts:111-116`），承担手机侧 sshd 与 SFTP。

## 候选方案

方案 A：升级到社区维护分支 mwiede/jsch

- 坐标 `com.github.mwiede:jsch`，包名仍是 `com.jcraft.jsch`，是 0.1.55 的直接替代，现有 `SSHFileConnectionManager`、`SSHFileSystemProvider` 的 SFTP／exec／转发代码几乎不用改
- 支持现代算法，官方定位即“OpenSSH 8.8+ 兼容”
- `ChannelShell` 支持 PTY 类型与窗口大小变更，可承担“直连终端、不经 proot”的交互式会话
- BSD-3-Clause，发布在 Maven Central，国内镜像可取
- 代价：继续维护两套 SSH 栈（客户端 mwiede/jsch + 服务端 Apache SSHD）

方案 B：客户端改用 Apache MINA SSHD

- 已随 APK 分发，Apache-2.0，算法覆盖现代
- 与服务端统一栈，长期维护面收窄
- 代价：现有基于 JSch 的 SFTP、exec、端口转发、反向隧道代码需要重写，本次改动面从“换依赖”变成“换数据面”，风险与工期都显著上升

方案 C：移植 tabssh/android

见下一节的评估结论：借模式不搬代码。

方案 D：客户端不动，只把 ssh 二进制塞进本地 Ubuntu

- 只解决“用户还要自己 apt 装 ssh”，完全不解决 proot 性能与 JSch 算法老旧
- 详见 [4_LocalUbuntuSshPackaging.md](4_LocalUbuntuSshPackaging.md)

## 推荐

采用方案 A：升级到 mwiede/jsch，并让交互式 SSH 会话直接走 JSch 的 shell channel。

理由：

- 改动面最小，SFTP／转发／反向隧道／隐藏执行的既有实现全部沿用，能集中精力解决“绕开 proot”这件真正影响体验的事
- 算法兼容问题一并解决，用户不再因为服务器端禁用 `ssh-rsa` 而连不上
- 方案 B 的价值是长期架构统一，可以在 SSH 优先方案稳定后作为独立事项推进，不必与技术路线切换同时进行

## tabssh/android 评估

事实（来自仓库与 API 元数据）：

- 许可为 MIT（`LICENSE`：MIT License, Copyright 2024-2026 TabSSH Contributors），与本品 LGPL-3.0 兼容，集成时需保留版权与许可声明
- 它是**完整应用**，不是库：内含 Room 数据库与 DAO（连接、身份、密钥、主机密钥、端口转发、主题、同步、容器、VNC……）、Activity/Fragment/Adapter 层、后台同步与组件、F-Droid 元数据
- 其 SSH 客户端用的是 `com.github.mwiede:jsch:2.27.7`，并在构建脚本注释中写明“maintained fork with security fixes, OpenSSH 8.8+ compatible”，与本文推荐方案一致
- 终端模拟器基于 Termux terminal-emulator（`deps/termux-terminal-emulator`，v0.118.1，带独立 JNI），另有自研 `ANSIParser`/`TerminalBuffer`
- 附带原生件：`libmosh-client.so`、`libtor.so`、`libtabssh_native.so`（SPICE），与本品本次目标无关
- 有主机密钥 TOFU 流程与主机密钥存储实体（`HostKeyEntry`、`HostKeyVerifierParsing`），可作为硬化实现参考

结论：

- 不直接将其应用代码并入 `OperitTerminalCore`：依赖面与耦合度（数据库、UI、同步）远超本次需要，移植后会带来长期维护负担
- 值得借鉴的三点：mwiede/jsch 的选型、主机密钥 TOFU 的交互与存储设计、以及“SSH 会话不依赖本地 shell”的实现方式
- 若要引入其终端模拟器，应作为独立的渲染层评估议题，不与本次 SSH 默认化捆绑

## 迁移要点

- 换依赖后需回归：密码认证、密钥认证（含口令）、exec 退出码、SFTP 读写、本地/远程端口转发、反向隧道、心跳
- `OpenSourceLicenses.kt:90-91` 中同时列出 Apache SSHD 与 JSch，需改为实际使用的库与许可
- 保留 Apache SSHD 服务端实现，反向隧道行为不变
