---
For_Agent: SSH 优先终端的目标架构与接口契约，动工前先确认本文件与 index.md 的待定决策
---

# 目标架构

## 一、执行目标模型

把“命令在哪里执行”从隐式默认改成显式目标，共三种：

- `android`：应用沙箱与 `/sdcard`，即今天的默认
- `remote`：某个 SSH 主机配置，新增的默认
- `local`：本地 proot Ubuntu，保留但降级为可选

目标是一个持久化的显式选择（`activeTarget`），终端会话、隐藏执行、文件操作、MCP 插件运行都读同一个目标，不再各自判断。

选择规则：

- 已配置并启用 SSH 主机时，新建会话与 `linux` 环境默认走该主机
- 未配置任何主机时，UI 走“添加主机”引导，**不**自动落到本地 Ubuntu
- 远端连接失败时返回错误并保留当前目标，由用户显式切到本地或其他目标；不实现任何静默降级
- 本地目标仍随包提供：proot、rootfs 资产与本地 provider 全部保留，用户可在设置页显式切换；本地环境占用的磁盘由用户自行处理，应用不提供导出或删除入口

## 二、会话数据路径

目标形态：SSH shell channel 直连终端视图，彻底不经 proot。

- 启动：建立 SSH 会话后申请 PTY（`xterm-256color`），把 channel 的 `InputStream`/`OutputStream` 直接交给现有终端读循环
- 不再调用 `install_ubuntu`、不再解压 rootfs、不再需要 Ubuntu 内的 `ssh` 与 `sshpass`
- 首次进入 SSH 会话不再触发 `initializeEnvironment()` 的资产解压，只有显式选择本地目标时才做
- 会话结束后不回落到本地 shell，直接结束会话并给出断开原因

### 会话就绪握手（provider 契约）

`OutputProcessor` 的会话状态机按 `LOGIN_SUCCESSFUL` → `TERMINAL_READY` → 首个提示符三段信号把会话推进到 `READY`，`TerminalManager.createNewSession` 只在这个状态下返回；终端工具与 MCP 共享会话都建立在它之上。

- 本地 provider 由 rootfs 里 `common.sh` 的 `start_shell` 打印两个标记，天然满足
- SSH provider 对面是普通 sshd，没有等价脚本，因此必须在通道打开后主动发一次 `echo LOGIN_SUCCESSFUL; echo TERMINAL_READY`，让远端 shell 执行完再打印提示符，走完同一状态机
- 缺这一步的后果是 `createNewSession` 每次都等满 30 秒抛 `Session initialization timeout`，而命令其实已经写入远端并执行成功——表现为「工具一直报失败、远端却真的改了」，很容易误判成网络或鉴权问题

## 三、传输抽象

现状 `TerminalSession.process` 是 `java.lang.Process`，远程会话没有对应对象。引入与提供者无关的传输：

- 需要的能力：`stdin: OutputStream`、`stdout: InputStream`、`pty: Pty`、`pid: Int?`（远程为 null）、`isAlive()`、`destroy()`、`suspend awaitExit(): Int?`
- `pty` 放进传输而不是留空：终端视图的窗口尺寸下发与输入模式检测都依赖它，远程必须给出由通道驱动的实现，否则 resize 静默失效、全屏程序按错误尺寸绘制
- `TerminalSession` 只持有传输，`stdout`/`stdin`/`pty` 是转发属性，保证视图、读取循环与退出处理读同一份状态
- 已落地：`transport/TerminalTransport.kt` 接口与 `transport/LocalPtyTransport.kt` 本地实现；`TerminalSession(transport)`；`TerminalProvider.startSession` 返回 `Result<TerminalSession>`
- 已改动调用点：`TerminalManager` 的 `startSession`、`handleTerminalSessionExit`（退出码由传输提供，且退出处理移入 `NonCancellable`，否则协程取消会丢掉退出码与状态清理）、`closeTerminalSession`；两个 provider 的 `startSession`／`closeSession`
- 仍需处理：`LocalTerminalProvider` 的隐藏执行仍走独立的 `ProcessBuilder` 与 proot 后台 shell，远程目标要用 exec channel 实现（阶段 2、3）

## 四、窗口尺寸

- 本地路径已经打通：`CanvasTerminalView.kt:2743-2750` 在后台线程调用 `Pty.setWindowSize(rows, cols)`，经 `pty.c:195-203` 的 `TIOCSWINSZ` 下发
- 远程仍需实现：由通道 Pty 覆写 `setWindowSize` 发送 window-change 请求
- `AnsiTerminalEmulator.resize`（`CanvasTerminalView.kt:2727`）只负责屏幕缓冲，不代表已经通知了终端
- 输入模式检测（`OutputProcessor.kt:407-433`）依赖 `getPtyMode()` 的 `availableBytes`，远程实现必须给出真实可读字节数

## 五、隐藏执行

- 远程：用 exec channel，退出码取 SSH 原生 `exit-status`，不再依赖 begin/end 标记解析；`HiddenExecResult` 的 `MISSING_BEGIN_MARKER`/`MISSING_END_MARKER` 状态只对本地路径有意义
- 本地：保持现有后台 shell 复用与标记协议
- `executorKey` 语义在远程对应“独立 exec 通道复用”，超时与中断沿用 `timeoutMs` 契约

## 六、文件系统

- `linux` 环境的文件操作默认由 SFTP provider 承担，`StandardFileSystemTools` 的“优先 SSH”策略变成唯一策略（本地目标时仍用本地 provider）
- `PathMapper`（Android ↔ proot rootfs 路径）只在 `local` 目标下有效；`remote` 目标下的路径就是远端路径，不做映射

## 七、Agent 侧契约

- `environment` 取值与措辞改为：`android`（默认）｜`linux`（当前 Linux 执行目标，默认即远程 SSH 主机，路径为远端路径）｜`repo:<名称>`；不新增取值
- 兼容：`linux` 字符串继续被接受，语义从“本地 Ubuntu via proot”变为“当前 Linux 目标”，指向哪个目标由用户在设置页决定，不由 Agent 决定
- 选择本地环境的方式是 UI 上显式切换目标，而不是让模型在参数里挑环境，避免模型在两种环境间来回漂移
- 需要同步修改的位置：`SystemToolPrompts.kt:112` 与 `:259`，以及所有“same as read_file environment”的引用文案
- toolpkg 的 `linux_ssh` 改为薄封装：参数写入唯一的 SSH 配置来源，执行走新的远端目标，不再经本地终端与 apt 自动安装

## 八、MCP 与插件运行时

- `MCPDeployer` 的 `getPluginRuntimeDirectory` 目前指向 proot 路径，需要按目标解析：`remote` 时部署到远端家目录，`local` 时保持现状
- `MCPBridge` 的 8751/8752 端口与反向隧道不变；手机侧 Apache SSHD 服务端继续承担“远端回连手机”
- 反向隧道与目标选择解耦：它是独立开关，不因为切到远端目标就自动开启

## 九、首次运行与设置

- 首启优先引导“添加 SSH 主机”，本地 Ubuntu 安装入口移到次级位置（“使用本机 Linux 环境（较慢）”）
- 本地环境仍随包提供，设置页保留安装、导出与删除三件事：安装用于重装，导出用于取回文件，删除用于释放磁盘
- 设置页明确展示当前目标与连通状态；缺依赖时不再提示“去 Ubuntu 里 apt 装 ssh”
- 目标切换要显式确认，避免用户在不知情时把命令发到远端主机
- 反向挂载的远端依赖需要写在文档与提示里：挂载命令在远端执行 `sshfs`，通过反向隧道连回手机侧 SSHD，因此远端主机需要安装 `sshfs`。此前这条信息只写在已被移除的“缺少 OpenSSH Server”弹窗里，属于本地侧要求且已经过时

## 十、可测量指标

- 首个 SSH 会话可用时间（不含 rootfs 解压与 apt）
- 同一工作负载在本地方案与远端方案上的耗时对比（npm install、python 脚本、grep -r）
- 首启占用磁盘：SSH-only 路径应为 0 字节 rootfs 解压
- 断线重连与窗口 resize 的正确性

## 十一、明确不做

- 不做自动回退：远端失败不落本地
- 不在 SSH 路径上保留 proot、bash、busybox 依赖
- 不改 `android` 目标与 `repo:` 语义
- 不在本次替换终端渲染层
