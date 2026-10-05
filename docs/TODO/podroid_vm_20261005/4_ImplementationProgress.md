---
For_Agent: 第一阶段的实施记录：启动层已落地并编译通过，列出改动的文件、构建装配方式与尚未完成的部分
---

# 实施进度

## 已定：资产随包分发

P2 已定：guest 资产与 QEMU 都打进发布包，首次启动不做下载。代价是体积，收益是首启不需要网络、也没有下载失败这一整类问题。

## 已实现（第一阶段：启动层 + 终端契约）

终端模块新增 `vm/` 包，全部为新增文件，原有 proot 实现未删（退役节奏见 P8）：

| 文件 | 职责 |
| --- | --- |
| `vm/VmPaths.kt` | 目录布局：内核、initrd、squashfs、持久盘、四条 socket 都在 `filesDir/vm` 下；QEMU 与 slirp 取 `nativeLibraryDir` |
| `vm/VmAssets.kt` | 资产清单（含 SHA-256 与字节数）与安装：首次抽取后逐件校验哈希，之后只比对大小；校验不过直接失败 |
| `vm/QemuVmEngine.kt` | QEMU 子进程：命令行构造、启动/停止、串口日志读取与**滚动缓冲**上的阶段检测（`KERNEL → INITRAMFS → SERVICES → NETWORK → SSH → ALMOST_READY → READY`）、通道连接、持久盘准备 |
| `vm/VmConsoleShell.kt` | 在终端通道上登录并执行一次性命令（成对标记 + 退出码），用于初始化与命令执行 |
| `vm/VmConsoleTransport.kt` | 尺寸通道（`RESIZE rows cols`）、由 virtio-console 驱动的 `Pty`、会话传输、以及拒绝被销毁的进程外壳 |
| `vm/VmTerminalProvider.kt` | `TerminalProvider` 实现：启动 VM、首次初始化、主机密钥信任、guest SSH 连接、可见会话、隐藏执行、文件系统 |

关键落点：

- **资产装配**：`terminal/build.gradle.kts` 新增 `fetchVmAssets` 任务，从 Podroid release APK 抽取五件输入并逐件校验 SHA-256，`preBuild` 依赖它。guest 三件套落在 `src/main/assets/vm/`，QEMU 与 slirp 落在 `src/main/jniLibs/arm64-v8a/`（安装时由系统提取到 `nativeLibraryDir`，从那里执行是 Android 支持的路径）。这些路径已加入 `.gitignore`：squashfs 单个 213 MB 超过 GitHub 单文件上限，仓库不该背这些二进制。离线构建用 `-PpodroidApk=<path>`。
- **首次初始化**：用镜像出厂口令登录一次，把 root 口令换成 `SecretStore` 生成的每安装随机口令（guest 的 22 端口映射在设备回环上，其他应用也能连，出厂口令是公开的，不换等于留后门），随后把 dropbear 的主机公钥读回来、现算指纹写进 known_hosts。之后 JSch 仍然按 known_hosts 严格比对，只是省掉了让用户为 127.0.0.1 上一个自己刚启动的 VM 点确认。
- **可见会话**：应用先在终端通道上自动登录，再把这条件通道交给终端视图，用户拿到干净的 root 提示符——与今天 proot 本地环境直接给 root shell 的体验一致，同时口令始终留在 `SecretStore` 里。
- **隐藏执行与文件访问**：都走 guest 自带的 dropbear（22 → 宿主回环端口），复用既有的 `SSHFileConnectionManager`，因此退出码、超时、SFTP 都是已经在用的实现，没有新机制。
- **目标接线**：`TerminalTarget.LOCAL` 现在创建 `VmTerminalProvider`；`initializeSession`、隐藏执行入口、以及 app 侧的 `Terminal.initialize()` 都不再触碰 proot 的 rootfs 解压与 `common.sh` 生成，改走新增的 `TerminalManager.ensureTargetConnected()`。

编译状态：`:terminal:compileDebugKotlin` 通过；`:app:assembleDebug` 通过，产物 **713.6 MB**（对比改动前的 480.8 MB）。包内已核对到 `assets/vm/{vmlinuz-virt,initrd.img,alpine-rootfs.squashfs}` 与 `lib/arm64-v8a/{libqemu-system-aarch64.so,libslirp.so}`。体积里同时含有旧的 proot rootfs（62.3 MB）：按 P8 保留一个发布周期的话，去掉它可以回收这部分。

构建期的两个坑，都是这次实际撞到的：

- **依赖镜像**：`avator/mmd` 的 bullet3 走 FetchContent，其 URL 由 `cmake/operit_git_source.cmake` 的 `OPERIT_GITHUB_URL_PREFIX` 决定。该支持原本只在 `ci/cn-mirror-build` 分支上，本分支不带时依赖会直连 github.com 并失败；已把该提交并入本分支。注意它是 **CMake 缓存变量**，旧 `.cxx` 目录里缓存着空值，换环境后要删掉该目录才会重新取值
- **被打断的构建会留下锁**：中途杀掉 Gradle 后，残留的 `cmake`/`ninja` 进程仍占着 `_deps` 里的下载文件，下一次构建会以"另一个程序正在使用此文件"失败，甚至表现为 Gradle 客户端与单次守护进程互相等待的假死。重试前先确认没有残留的 `cmake`/`ninja`，必要时清掉对应模块的 `.cxx`

## 尚未完成

| 项 | 说明 |
| --- | --- |
| 真机验证 | 模拟器跑不了 arm64 guest，启动层只能在 arm64 真机上验收；PC 参照实现已把参数与契约固定下来 |
| proot 退役（P8） | proot 的 provider、`initializeEnvironment`、`common.sh` 生成都还在树里，且旧的 rootfs 资产仍随包分发（发布包因此同时带两套环境，体积 713.6 MB） |
| 文件系统的路径语义 | 现在直接用 guest 的 SFTP，路径是 guest 内的路径（`/root`、`/mnt/persist`）；原来 proot 的 `/sdcard`、`/data/data/<pkg>` 软挂载语义需要在 guest 侧补挂载或做映射 |
| MCP 与 `repo:` | MCP 共享会话已能建立（走 `ensureTargetConnected` + `createSession`），但插件运行时目录在 guest 内的落点还没按新布局校一遍 |
| 端口冲突 | guest SSH 的回环端口目前写死 9022，需要和远端目标端口、以及设备上其他服务避让 |
