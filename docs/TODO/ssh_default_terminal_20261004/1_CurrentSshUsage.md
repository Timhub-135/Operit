---
For_Agent: SSH 现状审计，所有结论都带文件与行号；改动现状前先更新本文件
---

# SSH 现状审计

## 一、用户可见入口

终端界面

- `terminal/src/main/java/com/ai/assistance/operit/terminal/ui/SSHConfigScreen.kt`：SSH 主机、端口、用户名、密码／私钥、反向隧道、本地转发、心跳的配置界面，单一配置
- `terminal/.../ui/SettingsScreen.kt`：SSH 总开关（`loadSSHEnabled`），缺 `openssh-server` 时弹提示，给出“在本地 Ubuntu 安装”与“在远端安装”的两条命令
- `terminal/.../ui/SetupScreen.kt`：环境配置页，按 `PackageItem` 列表用 apt 装包，其中包含 `ssh`、`sshpass`、`openssh-server`

工具包与 Agent

- `examples/linux_ssh`：ToolPkg，提供 `linux_ssh_configure`、连接测试、tmux 长任务、远端文件操作，参数存自己的变量（`LINUX_SSH_HOST`、`LINUX_SSH_PORT`、`LINUX_SSH_USERNAME`、`LINUX_SSH_PASSWORD`、`LINUX_SSH_PRIVATE_KEY_PATH`），执行时经 `Tools.System.terminal.hiddenExec` 落到本地终端
- `app/.../core/config/SystemToolPrompts.kt:112`：文件类工具的参数 `environment` 取值为 `"android"`（默认）｜`"linux"`（本地 Ubuntu 24，proot）｜`"repo:<仓库名>"`，中文本地化在 `:259`

## 二、交互式 SSH 会话链路

默认目标是本地

- `terminal/.../data/TerminalModels.kt:84`：`terminalType: TerminalType = TerminalType.LOCAL`
- `terminal/.../TerminalManager.kt:159-163`：仅当 `sshConfigManager.getConfig() != null && isEnabled()` 才创建 `TerminalType.SSH` 会话
- `terminal/.../TerminalManager.kt:522-537`：`getTerminalProvider()` 按同一条件二选一，随后 `provider.connect()`

SSH 会话其实跑在 proot 里

- `terminal/.../provider/type/SSHTerminalProvider.kt:118`：会话启动命令是 `bash -c "source $HOME/common.sh && ssh_shell"`
- `terminal/.../TerminalManager.kt` 生成的 `common.sh` 中 `ssh_shell()` 依次执行 `install_ubuntu`、`configure_sources`、`fix_permissions`、`sleep 1`、`bump_progress`，最后 `login_ubuntu 'echo ...; $SSH_COMMAND; echo "SSH connection closed..."; /bin/bash -il'`
- 也就是说：连接远端之前，先要解压并进入本地 Ubuntu，SSH 退出后还会落回本地 Ubuntu shell

`SSH_COMMAND` 的实际内容

- `terminal/.../provider/type/SSHTerminalProvider.kt:208-239`：密码认证时前缀 `sshpass -p '<密码>'`，然后 `ssh -p <port> [-i <key>] -o StrictHostKeyChecking=no [-o ServerAliveInterval=N -o ServerAliveCountMax=3] user@host`
- 该字符串通过环境变量 `SSH_COMMAND` 传入 proot（同文件 `:258`）

前置条件

- `terminal/.../ui/SettingsViewModel.kt:129-137`：`areSshToolsInstalled()` 检查 `<rootfs>/usr/bin/ssh` 与 `<rootfs>/usr/bin/sshpass` 同时存在
- 因此“要用 SSH”实际等于“先在本地 Ubuntu 里 apt 装好 ssh 与 sshpass”，这正是用户抱怨的“安装后还要自己折腾”

## 三、数据面（不经过 proot）

- SSH 客户端库是 `com.jcraft:jsch:0.1.55`（`terminal/build.gradle.kts:102`），Android 客户端库列表页面写的是 mwiede/jsch（`app/.../ui/features/about/screens/OpenSourceLicenses.kt:91`），与代码实际使用不一致
- `terminal/.../utils/SSHFileConnectionManager.kt`：连接、心跳（`:188-189`）、反向隧道、本地端口转发、`openChannel("exec")` 隐藏执行（`:356`、`:515`、`:633`），连接超时 180 秒（`:193`）
- `terminal/.../provider/filesystem/SSHFileSystemProvider.kt`：基于 JSch SFTP 的文件系统实现
- `app/.../core/tools/defaultTool/standard/StandardFileSystemTools.kt:113-132`：Linux 文件系统优先用 SSH provider，未连接时才回落到终端自己的 provider

## 四、手机侧 SSHD 与 MCP 桥

- `terminal/.../utils/SSHDServerManager.kt`：内置 Apache SSHD 服务端，端口取 `sshConfig.localSshPort`，用户名／口令取 `sshConfig.localSshUsername` / `localSshPassword`，带 SFTP 子系统与 `VirtualFileSystemFactory`
- `app/.../data/mcp/plugins/MCPBridge.kt:48,109-130`：MCP 客户端端口 8751 经 SSH 转发，本地直连端口 8752
- `app/.../data/mcp/plugins/MCPDeployer.kt:179-188`：插件运行时目录取自 `getPluginRuntimeDirectory`，注释明确写着“插件在 proot 环境中的目录路径”
- 反向隧道的用途即“远端主机 SSH 回手机”，用于挂载存储与 MCP 桥

## 五、路径与资产

- rootfs 资产：`terminal/src/main/assets/ubuntu-noble-aarch64-pd-v4.18.0.tar.xz`，62.6 MB，常量在 `TerminalManager.kt:121`
- 解压位置：`{filesDir}/usr/var/lib/proot-distro/installed-rootfs/ubuntu`（`app/.../util/PathMapper.kt:20-31`）
- 原生件：`liboperit_proot.so`、`liboperit_loader.so`、`libbash.so`、`libbusybox.so`（`terminal/src/main/jniLibs/arm64-v8a/`）
- 环境初始化 `TerminalManager.initializeEnvironment()`（`:540`，`:426` 与 `:1370` 触发）对**所有**会话类型都会解压资产，包括 SSH 会话

## 六、问题清单

- SSH 依赖最慢的那套环境：SSH 会话必须先解压并进入 proot Ubuntu，还要 apt 装 `ssh` 与 `sshpass`，性能与可用性双重受损
- 主机密钥完全不做校验：JSch 会话配置 `StrictHostKeyChecking=no`（`SSHFileConnectionManager.kt:177`），命令行路径同样带该参数（`SSHTerminalProvider.kt:228`、`SSHFileConnectionManager.kt:492,506`），没有 known_hosts 或 TOFU
- 凭据明文落盘：`SSHConfigManager` 用 `SharedPreferences("ssh_config")` 存 JSON，密码与私钥口令明文（`:55-67`、`:118-134`）
- 硬编码口令：`SSHConfig.kt:18` 的 `localSshPassword = "3688368398"` 同时出现在 `SSHConfigScreen.kt:232`；`SSHFileConnectionManager.kt:97` 另有一个默认 `"ubuntu"`
- 密码进 argv：`sshpass -p '<密码>'` 会出现在进程命令行中
- 客户端库过旧：JSch 0.1.55 不支持 ed25519、rsa-sha2-256/512、curve25519、chacha20、aes-gcm，对 OpenSSH 8.8+ 默认关闭 ssh-rsa 的服务器会直接连不上
- 配置来源有两套：终端模块的 `SSHConfigManager`（单一配置）与 toolpkg `linux_ssh` 的自有变量，两者互不感知
- 会话模型与本地进程强耦合：`TerminalSession.process` 是 `java.lang.Process`，`SessionManager.kt:166`、`TerminalManager.kt:469,496,499,1308`、两个 provider（`LocalTerminalProvider.kt:97,113,188,196,281,334,487`、`SSHTerminalProvider.kt:129,154`）都在用它，远程会话没有真正的进程对象
- `Pty` 已经为远程会话留了口子（`Pty.kt` 的 `pid: Int = -1` 与“无法取得 pid 的实现（如远程会话）”注释），但上层没有利用
- 窗口尺寸：本地路径已经打通，`CanvasTerminalView.kt:2743-2750` 在后台线程调用 `Pty.setWindowSize(rows, cols)`，经 `pty.c:195-203` 的 `TIOCSWINSZ` 下发；缺的是远程 window-change，以及让视图改从传输取 Pty
- 输入模式检测完全依赖 Pty：`OutputProcessor.kt:407-433` 用 `pty.getPtyMode().isWaitingForInput()` 判断交互式提示；`Pty.getPtyMode()` 在 `ptyMaster <= 0`（远程）时返回默认模式且 `availableBytes` 恒为 0，会让命令执行期间的远程会话一直被判定为“等待输入”，远程实现必须给出真实可读字节数
- 跨进程契约不含目标：`ITerminalService.aidl` 的 `createSession()` 无参数，无法表达“建一个 SSH 会话还是本地会话”
- 文件工具契约把 `linux` 定义成“本地 Ubuntu via proot”，一旦默认改为远端，措辞与实现就分离，两处提示（`:112` 与 `:259`）都要改
