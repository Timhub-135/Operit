---
For_Agent: 模拟器 + 容器的端到端验证记录，复现步骤与证据都在这里，重跑后回填结果
---

# 模拟器端到端验证

## 环境

- Android 模拟器：AVD `operit_x86`，`system-images;android-36;google_apis;x86_64`，Android 16，WHPX 加速
- 远端主机：`tools/ssh_test_host` 构建的 `ubuntu:latest` 容器，容器内 OpenSSH 8.9p1，宿主机端口 `2222`
- 应用：debug 变体（`com.ai.assistance.operit.debug`），`./gradlew :app:assembleDebug` 产物
- 模拟器访问宿主机端口用 `10.0.2.2:2222`

## 复现步骤

```bash
# 1. 远端主机
docker build -t operit-ssh-test tools/ssh_test_host
docker volume create operit-ssh-test-keys
docker run -d --name operit-ssh-test -p 2222:22 -v operit-ssh-test-keys:/etc/ssh operit-ssh-test

# 2. 模拟器
#    -gpu host 是必须的：swiftshader 是纯 CPU 软渲染，终端画布持续重绘时
#    RenderThread 会卡在 egl_window_surface_t::swapBuffers → qemu_pipe_read，
#    主线程随之卡在 ThreadedRenderer.draw，直接触发 ANR（见下文“测试中发现的问题”）
"$ANDROID_HOME/emulator/emulator" -avd operit_x86 -no-snapshot-save -no-audio -gpu host -memory 4096 -cores 4
adb wait-for-device
adb install -r -t app/build/outputs/apk/debug/app-debug.apk
```

界面侧：完成首启向导 → 选择 Standard Permissions → AI Computer 打开终端 → 设置里确认「执行目标 = 远端 SSH 主机」→ 填写主机 `10.0.2.2` / 端口 `2222` / 用户名 `operit` / 密码 `operit-test` → 打开 Enable SSH Connection → 回到终端首页新建会话。

## 实测结果

默认目标与引导（阶段 3、4）

- 全新安装进入终端时没有落到本地 Ubuntu 安装向导，而是弹出「Remote SSH host …Fill in host, port and authentication before enabling SSH」引导，`Go to Setup` 直达设置页
- 设置页出现新的「Execution Target」卡片，`Remote SSH host` 标注 `Currently in use`，另有 `Known Host Keys` 行

主机密钥 TOFU（阶段 2）

- 首次连接被拒绝，日志：`SSH host key rejected: [10.0.2.2]:2222 SHA256:iseO2Dl6JoDn2noZxZZG1zSZz8aOGXCqQ4ynMdzsbto`
- 应用弹出 `Confirm Host Key` 对话框，展示 `[10.0.2.2]:2222 (ssh-ed25519)` 与 `SHA256:iseO2Dl6JoDn2noZxZZG1zSZz8aOGXCqQ4ynMdzsbto`
- 该指纹与容器内 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 的输出完全一致
- 点击 `Trust and continue` 后：`HostKeyStore: Trusted ssh-ed25519 key for [10.0.2.2]:2222`，写入 `files/ssh/known_hosts`（设备内已核对内容），设置页显示 `1 trusted hosts`
- 容器侧 sshd 日志同步记录 `com.jcraft.jsch.JSchUnknownHostKeyException: reject HostKey: [10.0.2.2]:2222 [preauth]`，证明是客户端主动拒绝而非服务端问题

凭据迁移（阶段 2）

- 为绕开 UI 输入掩码不易核对的问题，验证时用 `run-as` 写入旧版**明文**配置（无 `secretFormat` 标记）
- 应用读取后按迁移路径加密改写：`Migrated plaintext SSH secrets to Keystore-backed storage`，随后 `ssh_config.xml` 中的 `password` 字段变为 Keystore 密文

远端会话（阶段 2、3）

- `SSHFileConnManager: SSH connection established: terminal_10.0.2.2_2222`
- `SSHFileConnManager: Opened shell channel on terminal_10.0.2.2_2222 with 80x24 PTY`
- `SSHTerminalProvider: SSH terminal session started on shell channel: 95358df3-…`
- 容器侧 sshd 日志：`Accepted password for operit from 172.17.0.1 port 46870 ssh2`
- 会话关闭正常：`Closed SSH terminal session (process)`

关键结论：整条链路没有经过 proot、没有使用本地 Ubuntu 内的 `ssh`，且握手对象是 OpenSSH 8.9（默认禁用 `ssh-rsa` 的现代服务端）——旧依赖 `com.jcraft:jsch:0.1.55` 在这台服务器上无法完成握手。

## 测试中发现并修掉的问题

- 首启路由：`TerminalScreen` 在 `is_first_launch` 时无条件进入本地环境安装向导，与「默认远端」自相矛盾；改为仅本地目标进入向导
- 隐藏执行：`executeHiddenCommand` 无条件 `initializeEnvironment()`，远端目标下会为执行一条命令解压 62 MB 的 rootfs；改为仅本地目标初始化
- **会话就绪握手（本轮新发现）**：`OutputProcessor` 的会话状态机靠 `LOGIN_SUCCESSFUL` → `TERMINAL_READY` → 首个提示符三段信号才把会话推进到 `READY`。本地 proot 由 `common.sh` 的 `start_shell` 打印这两个标记，而 SSH 通道对面是一台普通 sshd，没有等价脚本，于是 `createNewSession` 每次都等满 30 秒抛 `Session initialization timeout`：终端工具、MCP 共享会话（`MCPSharedSession.getOrCreateSharedSession`）全部失败，尽管命令其实已经写进了远端 shell 并执行成功。修法是 `SSHTerminalProvider.startSession` 在通道打开后立刻补发 `echo LOGIN_SUCCESSFUL; echo TERMINAL_READY`，让远端 shell 重新打印提示符来完成同一次握手（`terminal/.../provider/type/SSHTerminalProvider.kt`）
- 修复后的日志链路：`Login successful marker found` → `TERMINAL_READY marker found` → `First prompt detected. Session is now ready` → `Session <id> initialized successfully`

## 对话级验证（本轮）

前置：模型配置走本机 litellm 网关（`http://10.0.2.2:4000/v1/chat/completions`，`sk-1234`，`deepseek-v4-flash`），工具确认改为全局 `ALLOW`，执行目标为远端 SSH 主机。

### 1. 模型自己执行远端 shell 命令

- 提示词只说「用 linux 终端工具跑 `hostname`、`whoami`、`mkdir -p /tmp/papers`」，模型自行走 `use_package super_admin` → `package_proxy` → `super_admin:terminal`
- 应用侧：`ToolPkg : [terminal] 执行终端命令: hostname; whoami; mkdir -p /tmp/papers && echo "mkdir exit: $?" && ls -ld /tmp/papers`，`TerminalManager: Session … initialized successfully`，工具结果为 `成功: true`
- 容器侧独立核对：`hostname` = `2c644c686d3b`、`whoami` = `operit`、`/tmp/papers` 属主 `operit:operit` 权限 `drwxrwxr-x`
- 模型在回答里主动说明「super_admin:terminal 执行在 Linux 执行目标（默认是远端 SSH 主机）上」，与 `SystemToolPrompts` 的新 `environment` 描述一致

### 2. tmux

- 提示词：在远端起一个 detached tmux 会话 `operit_verify` 跑 `sleep 600`
- 容器侧：`tmux ls` 列出 `operit_verify`（创建于本轮时间点）与既有 `operit_test`；`list-panes` 显示 `operit_verify:0.0 cmd=sleep size=80x24`；`ps -C sleep` 显示 `sleep 600` 的 PID
- 模型自行给出正确结论（会话随 `sleep` 结束而消失），说明它读到了真实输出

### 3. arXiv 论文 → markdown（在目标机器上完成）

- 提示词只给 URL，不给命令：`curl` 下载 `https://arxiv.org/html/1706.03762v7` 到 `/tmp/papers/paper.html`
- 模型先自查（`ls -l` / `stat` / `md5sum` / `grep <title>`），容器侧核对到 188707 字节、标题 `Attention Is All You Need`
- 第二轮让它用 pandoc 转 GitHub markdown：模型执行 `pandoc paper.html -f html -t gfm --wrap=none -o attention.md`
- 首版结果带着 arXiv 页面外壳（issue 弹窗、公告条），指出后模型自己写了 `/tmp/papers/extract_article.py` 抽出 `<article>` 元素，备份旧文件并重转：`attention.md` 从 89964 字节降到 48753 字节（639 行），开头即论文标题与 Abstract
- 容器侧核对最终文件头部内容为论文正文，确认转换在远端完成、非本地回传

### 4. 窗口 resize → 远端 `stty size`

- 在应用可见 SSH 会话里启动 `/tmp/ptysize-loop.sh`（每 2 秒把 `stty size` 追加到 `/tmp/ptysize.log`，输出不进终端以免持续重绘）
- `SshChannelPty: Requested window-change to 43x23` ↔ 远端的 `stty size` 同步读到 `23 43`
- `adb shell wm size 720x1280` 后：`Requested window-change to 28x1`，远端读到 `1 28`
- `adb shell wm size reset` 后：`Requested window-change to 43x23`，远端回到 `23 43`
- 结论：视图尺寸变化 → `CanvasTerminalView.updateTerminalSize` → `SshChannelPty.setWindowSize` → 远端 tty 尺寸，整条链路成立

### 5. 私钥认证

- 容器内 `ssh-keygen -t rsa -b 3072`，公钥写入 `~operit/.ssh/authorized_keys`（先在本机验证 `PUBKEY_LOGIN_OK`）
- 私钥 `adb push` 到 `/data/local/tmp` 后由 `run-as` 拷入 `files/ssh/operit_test_key`（0600），配置改为 `authType=PUBLIC_KEY` + `privateKeyPath`
- 容器侧 sshd 日志：`Accepted publickey for operit from 172.17.0.1 port 50154 ssh2: RSA SHA256:3ikccxuRdvrpxcCjvywr3mHjBwIaCKaTBb2j0xMKEG0`
- 应用侧：`SSH session connected` → `Port forwarding established` → `Opened shell channel … with 80x24 PTY` → `Session … initialized successfully`

### 6. 反向隧道与 MCP 桥

- 配置 `enableReverseTunnel=true` 后：`Setting up reverse tunnel: remote:8881 -> localhost:2223` → `Reverse tunnel established`；应用内嵌 sshd（Apache SSHD 2.10.0）同时起在设备 `2223`，用户 `android`，根目录 `/storage/emulated/0`
- 容器 → `127.0.0.1:8881` 收到 `SSH-2.0-APACHE-SSHD-2.10.0`，即隧道确实把连接送回设备
- 用密码通过隧道登录：应用侧 `SSHDServerManager: Authentication attempt - username: android, success: true`；`exec`/`shell` 通道被拒（内嵌 sshd 只挂 SFTP 子系统，设计如此），但 **sftp 通道可用**：容器里 `sftp -P 8881 android@127.0.0.1` 列出设备的 `/storage/emulated/0`（Alarms / Android / DCIM / Download …）
  - 注意 `sftp -b batchfile` 会隐式打开 `BatchMode`，sshpass 送不进口令，表现为 `Permission denied`；去掉 `-b` 用 stdin 喂命令即可
- MCP 桥（正向本地转发 `localhost:8751 → remote:8752`）双向验证：容器在 8752 起监听，设备连 `127.0.0.1:8751` 后容器收到 `DEVICE-BRIDGE-HELLO`，设备收到 `REMOTE-BRIDGE-REPLY`
- `mountStorage` 在远端执行 `sshfs` 时返回 `Mount output: sshfs not installed`：反向隧道与设备 sshd 都正常，缺的是远端主机的 `sshfs`（且容器还需要 FUSE 权限），属环境依赖而非应用缺陷

## 测试中发现的问题（未修，待决策）

- **键盘弹起时终端行数塌成 1 行**：`CanvasTerminalView.updateTerminalSize` 用 `height - contentTop - committedImeBottomInsetPx` 算行数；视图高度已经因 IME 缩小，再减一次 IME 高度就会接近 0，`coerceAtLeast(1)` 兜到 1 行。实测（远端 `stty size` 佐证）：软键盘关闭 `43x23`，键盘弹起 `43x8`（原生分辨率）/ `28x1`（override 分辨率）。这会让远端 tty 也变成 1 行，影响 `tmux`、`less`、进度条等全屏程序。属本次重构之前就存在的画布逻辑（本地 PTY 同样受影响），修它要动布局与 IME inset 的取值语义，改动面比本轮验证大，先记录
- **模拟器软渲染导致 ANR**：`-gpu swiftshader_indirect` 下打开终端画布后 RenderThread 卡在 `egl_window_surface_t::swapBuffers → qemu_pipe_read`，主线程卡在 `DrawFrameTask::drawFrame`，触发 `ANR in … Input dispatching timed out`；换成 `-gpu host` 后不再复现。与代码无关，但复现验证时容易误判成应用缺陷

## 上游模型侧的问题（本轮定位）

- 应用以「OpenAI (Generic)」provider 指向 litellm 网关、模型 `deepseek-v4-flash`、`thinkingOptionId=low` 时，第二轮起每次请求都 400：`The reasoning_content in the thinking mode must be passed back to the API`
- 本地直连网关复现：同一条历史里 assistant 消息带 `tool_calls` 但**缺** `reasoning_content` → 400；补上（哪怕是空串）→ 200。无论是否带 `reasoning_effort`/`thinking` 参数，上游都在思考模式，所以这个字段是硬要求
- 应用里只有 DeepSeek / Kimi / Mimo / OpenCode 这几个 provider 会回填 `reasoning_content`；通用 OpenAI Chat 路径（`OPENAI_GENERIC`）不会，于是走网关时必炸
- 本轮的处理是把模型配置的 provider 切到 `Deepseek Models`（endpoint / key / model 名都不变），请求随即正常，且 assistant 历史里能看到 `reasoning_content` 被回填
- 待决策：是否给通用 OpenAI Chat 路径也加上「按 thinking 规则声明后回填 reasoning_content」的能力（可复用 `ThinkingQualityMapping` 的规则 JSON 加一个字段），还是维持现状、由文档说明「DeepSeek 系模型走网关时请选 DeepSeek provider」

## 性能基线（远端路径）

测量环境：AVD `operit_x86`（x86_64、Android 16、`-gpu host`）× 容器 `operit-ssh-test`（宿主 Intel Core Ultra 9 185H，容器内可见 2 核 / 3.9 GB，Python 3.10.12，pandoc 2.9.2.1，tmux 3.2a），经模拟器 NAT 访问 `10.0.2.2:2222`。下列数值都取自 logcat 标记的时间戳差值，不是手工掐表。

会话就绪：

| 阶段 | 耗时 |
| --- | --- |
| 进程内首个会话：创建会话到 SSH 传输就绪（TCP + KEX + 认证） | 1730 ms |
| 通道打开 + 就绪握手标记 + 首个提示符 | 139 ms |
| 冷启动首个会话合计（到 READY） | 1869 ms |
| 复用连接后新建会话（到 READY） | 68 ms |

命令往返（可见会话里执行 `echo ROUNDTRIP-OK`）：写入到远端首字节 4 ms，到命令完结（命中提示符）7 ms。

磁盘与进程：

- 远端目标不解压 rootfs：设备上 `ps -A -o NAME | grep -c proot` 为 0；`files/usr` 仅 180 KB，且应用数据里那份 rootfs 包仍是旧的 `v4.18.0`，说明远端路径从未触碰它
- 应用数据目录 97 MB，其中 64 MB 是旧版 rootfs 包遗留、32 MB 是 toolpkg 缓存；远端路径自身只新增 `files/ssh` 24 KB（known_hosts 与测试私钥）
- 随包资产 62.3 MB，debug APK 480.8 MB
- 目标机固定负载：`sum(range(5_000_000))` 0.040 s，20 万次字符串反转 0.104 s

CPU：

- 启动阶段与终端画布渲染会把应用推到数百 %，这是首启初始化与模拟器渲染（软件或宿主 GPU）主导，与 SSH 路径无关
- 启动完成、会话已连接的空闲状态为 2.9% CPU（`top -b -n 2 -d 2` 差值，聊天页前台，此时无 proot 进程）

仍未覆盖：本地 proot 侧的对照数据需要 arm64 设备（x86_64 模拟器跑不了随包 rootfs），所以「何时仍然值得用本地环境」的判断还缺一半数据；`npm install` 与编译类重负载未测，且容器只有 2 核，绝对值不代表真实服务器。

## 环境限制与未覆盖项

- 模拟器是 x86_64，而应用只打包 `arm64-v8a`。Compose 界面与 SSH 会话（纯 Java 的 jsch）不受影响，实测通过；但依赖原生库的功能（QuickJS 工具包、MNN/llama 本地模型、sherpa 语音）无法在该模拟器上验证
- 本地方案（proot + rootfs）在 x86_64 模拟器上不可用，未做回归；本地方案需要在 arm64 设备上验证
- 本轮已覆盖：对话级远端命令执行、tmux、窗口 resize 后的 `stty size`、反向隧道（含 SFTP 回连）、MCP 桥双向连通、私钥认证、目标机上的 arXiv → markdown、远端路径的会话就绪与命令往返基线
- 仍未覆盖：安装真实的第三方 MCP 插件（需要 MCP 仓库联网拉包）后走一遍插件调用；远端 `sshfs` 挂载（容器缺 FUSE 权限，未装 sshfs）；本地 proot 侧的对照性能数据（见上一节）
- 容器镜像缺少 `ca-certificates` 时所有 HTTPS 都会以 `curl: (77) error setting certificate file` 失败，表现为「网络不通」。本轮先装上 `ca-certificates` 才验证 arXiv 抓取；`tools/ssh_test_host/Dockerfile` 应把该包写进镜像，避免复现验证时误判
- 提示文字在模拟器上仍显示英文（应用语言未切到中文），属测试环境设置，不是缺陷
