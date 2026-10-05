---
For_Agent: 模拟器为什么不能用（逐版本证据）、PC 参照实现的实测结果与设备端验收清单
---

# 验证环境与实测记录

## 结论先说

**库存 Android 模拟器不能运行 arm64 guest**，因此本方案的验证不依赖模拟器：guest 的启动参数与契约先在 PC 上用发行版 QEMU 跑通（已完成），设备端只验证 Android 侧的启动层与集成。Podroid 的 VM 资产与原生件只有 arm64（`libqemu-system-aarch64.so`、arm64 内核、arm64 Alpine rootfs），而宿主是 x86_64；Android 模拟器从若干年前起就只允许"系统镜像架构与宿主一致"，能跑 arm64 镜像的经典引擎已经移除。下面是逐版本证据。

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
| Podroid release APK v1.2.9（297.3 MB） | `tmp/podroid/Podroid-v1.2.9-release.apk` |
| 抽取出的 guest 资产（内核 / initrd / squashfs） | `tmp/podroid/rig/assets/`，哈希见 [1_PodroidAnalysis.md](1_PodroidAnalysis.md) |
| 抽取出的原生件（QEMU / slirp） | `tmp/podroid/rig/lib/arm64-v8a/` |
| **参照实现夹具（可用）** | `tmp/podroid/rig/`：`run-guest.sh`（规范启动参数）、`chan.py`（virtio-console 通道读写）、`validate-guest.sh` / `validate-guest2.sh`（断言）、`resize-test.py`、`inspect-guest.sh`、`identify.sh`；容器 `podroid-rig` 把该目录挂到 `/rig` |
| 模拟器路线的遗留物（不再使用） | `%USERPROFILE%\.android\avd\podroid_arm64.avd`、`tmp/android-emulator-arm64/emu-*/`、`tmp/android-emulator-arm64/run-arm64-avd.cmd` 与生成脚本 `tmp/cn/build-arm64-launcher.js` |

## 验证策略（方案定型后）

方案已定为「应用内直接跑 `qemu-system-aarch64`（TCG）」，于是验证分成三层，各层的职责不重叠：

| 层 | 载体 | 验证什么 | 状态 |
| --- | --- | --- | --- |
| 参照实现 | PC 上的 Linux 容器 + 发行版 QEMU | **规范启动参数**与 guest 侧契约：设备顺序、通道用途、启动标记、resize、host 桥、容器能力 | 已跑通（见下文实测） |
| 设备端启动层 | 真实 arm64 手机 | 应用内子进程启动、socket 通道、前台服务生命周期、性能与温升、存储扩容 | 待设备 |
| 集成验收 | 真实 arm64 手机 | 终端目标切换、就绪握手、隐藏执行、文件系统、MCP 共享会话、远端目标不受影响 | 待设备 |

模拟器在这一版方案里**不参与验证**：guest 与 QEMU 都是 arm64，而 x86_64 宿主上的模拟器既不允许 arm64 系统镜像（见上文逐版本证据），也无法用 x86_64 端口替代。若要恢复"模拟器可测"，唯一办法是给 x86_64 另建一套 QEMU 与 guest 资产，成本翻倍（对应决策 P4）。

## 参照实现的具体做法（可直接执行）

1. 从 `tmp/podroid/Podroid-v1.2.9-release.apk` 抽出三个 guest 资产与 `libqemu-system-aarch64.so`、`libslirp.so`
2. 准备一个 Linux 容器（Debian/Ubuntu + `qemu-system-arm`），把资产挂进去
3. 按 [2_ReplacementDesign.md](2_ReplacementDesign.md) 的启动参数启动 guest：两个 virtio 块设备分别是持久 ext4（vda）与只读 squashfs（vdb），加串口与三条 virtio-console
4. 断言：串口日志出现 `Starting SSH...` / `Almost ready...` / `Ready!`；guest 内 `podman run` 输出预期内容；往控制通道写 `RESIZE rows cols` 后 `stty size < /dev/hvc0` 与 `/run/term_size` 同步变化；host 通道能收到 guest 自发的一行

这套断言既是"接口契约"一栏的可执行版本，也是设备端要重跑的那一份。

## 参照实现的实测结果（已完成）

在本机用普通 QEMU 直接跑 Podroid 的 guest：把 release APK 里的 `vmlinuz-virt`、`initrd.img`、`alpine-rootfs.squashfs` 抽出来，按 Podroid `QemuEngine.buildCommand()` 的设备布局在 Linux 容器里启动（两个 virtio 块设备、SLIRP 网络、PL011 串口做启动日志、三条 virtio-console 通道），把 Android 侧的 socket 换成 unix socket，于是同一批通道可以从宿主机直接驱动。

环境：Debian bookworm 容器 + `qemu-system-arm` 7.2（TCG，`thread=multi`）、4 vCPU、3 GB 内存、宿主 Intel Core Ultra 9 185H。

结果：

| 断言 | 实测 |
| --- | --- |
| guest 启动到就绪 | 首次启动（含 mkfs 与一次性 overlay 归一化）约 90 s；二次启动复用持久盘 **46.2 s** 进入 `Ready!` |
| 三段就绪标记 | `[podroid-init] switching to real root` → `Network found` → **`Starting SSH...` → `Almost ready...` → `Ready!`** 全部出现 |
| guest 身份 | Alpine **3.24.2**、内核 **7.1.5**、aarch64、4 vCPU、2957 MB、**podman 5.8.6** |
| 挂载结构 | `/dev/vda` ext4 → `/mnt/persist`；`/dev/vdb` squashfs → `/mnt/lower`；`overlay on /`（plain lowerdir/upperdir/workdir）；`/var/lib/containers/storage`、`/var/lib/docker`、`/var/lib/lxc` 都落在持久盘上 |
| 尺寸通道（分辨率契约） | 往控制通道写 `RESIZE 40 120` → `stty size < /dev/hvc0` 读到 `40 120`、`/run/term_size` 为 `40 120`；再写 `RESIZE 24 80` → 两边同步回到 `24 80`（双向可控） |
| guest→宿主桥 | 宿主侧从 `host.sock` 收到守护进程自发的 `STATS containers=0`，行协议连通；`podroid-hostd` 以 pid 627 运行，`podroid-notify`/`podroid-forward` 是指向它的符号链接 |
| 容器 | `podman run --rm docker.m.daocloud.io/library/alpine:latest echo container-ok` 拉取镜像后输出 **`container-ok`** |

复现时踩到的三件事，值得写进后续的验证脚本：

- **guest 内 SSH 在 22，不在 9922**：9922 是 Android 侧的宿主端口，映射关系是 `宿主 9922 → guest 22`。SLIRP 的 `hostfwd` 要按这个写，否则表现为连接被重置
- **CN 网络下 Docker Hub 不可用**：`registry-1.docker.io` 被解析到无关地址并拒绝连接。换 `docker.m.daocloud.io` 这类镜像即可拉取成功——Operit 集成时应当在 guest 里预置 `registries.conf` 的镜像配置，否则用户第一次 `podman run` 必然失败
- **非登录 SSH 的 PATH 很窄**：`podroid-notify` 等工具在 `/usr/local/bin`，直接 `command -v` 会找不到，用绝对路径或在登录 shell 里调用

## 设备端验收清单（arm64 真机，等设备到位）

启动层：

- 资产校验通过后能起子进程，串口日志写进应用私有目录，`Ready!` 在超时内出现（debug 构建可用 `run-as` 读日志）
- 停止路径真的把 QEMU 收敛掉（无孤儿进程、无残留 socket）；崩溃路径不自动重启、有明确报错与日志尾部
- 前台服务存活：切后台、锁屏、长时间空闲后 VM 仍在；内存与温升有记录

契约（在 PC 参照实现上已通过的同一组断言）：

- 终端：三段就绪握手、`stty size` 在 resize 后与请求值一致、退出码正确
- 隐藏执行：超时能真正杀掉进程组；输出与退出码分类正确
- host 桥：guest 自发的一行能被应用收到并正确处理

集成：

- `TerminalTarget.LOCAL` 指向 VM；`environment="linux"` 落到 VM；远端 SSH 目标不受影响
- 文件系统 provider 能读写 guest 内路径；MCP 共享会话可用
- guest 内 `podman run` 可用（CN 镜像预置生效）
- 存储：`storage.img` 扩容后 guest 内可见新容量；清空环境后能重新初始化

性能（记录基线，不做硬性门槛）：

- 冷启动到 `Ready!` 的时间、二次启动时间
- 容器启动与常见操作的耗时，以及与 proot 路径的对照（proot 在 arm64 真机上可测，模拟器上不可测）
