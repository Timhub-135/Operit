---
For_Agent: 定型方案的设计：应用内以 qemu-system-aarch64(TCG) 启动从 Podroid 抽出的 guest 资产，替换 proot 本地目标
---

# 替换设计

## 一、总体形状

```
Operit 应用进程
├── VmService（前台服务：持锁、通知、随进程存活）
│   └── 子进程：libqemu-system-aarch64.so -M virt -accel tcg ...
│         ├── serial.sock      → 启动日志（内核 + init + OpenRC 阶段标记）
│         ├── terminal.sock    → /dev/hvc0：交互式 shell（getty + login）
│         ├── ctrl.sock        → /dev/hvc1：RESIZE rows cols
│         ├── host.sock        → /dev/hvc2：guest → 宿主 行协议
│         ├── qmp.sock         → 运行时端口转发
│         ├── filesDir/storage.img        （vda：持久 ext4，容器与用户数据）
│         └── filesDir/alpine-rootfs.squashfs（vdb：只读系统层）
└── terminal 模块
    ├── TerminalManager / TerminalTarget.LOCAL  → 现在指向 VM
    ├── LocalVmTerminalProvider（新）→ TerminalTransport 的实现
    └── 既有的就绪状态机、隐藏执行、MCP 共享会话（不动）
```

关键点：**QEMU 是应用的一个子进程**，guest 的 I/O 通过 Unix socket 回到应用，和今天 proot 的 PTY 在应用内的位置一致。因此终端模块里所有面向 `TerminalTransport` 的代码不需要改语义。

## 二、资产与目录布局

全部落在 `context.filesDir`（与 Podroid 相同，便于对照与排错）：

| 路径 | 内容 | 大小 |
| --- | --- | --- |
| `vmlinuz-virt` | 内核 | 20.0 MB |
| `initrd.img` | initramfs（含 `init-podroid`） | 40.7 MB |
| `alpine-rootfs.squashfs` | 只读系统层 | 213.5 MB |
| `storage.img` | 持久 ext4（首次启动由 initramfs 格式化，可用 `resize2fs` 在线扩容） | 按用户设置，建议 ≥4 GB |
| `*.sock` | 四条控制/数据通道 | — |
| `console.log` | 串口日志，用于启动阶段检测与排错 | 滚动 |

原生件放在 `jniLibs/arm64-v8a/`，以 `.so` 名义打包但按可执行文件运行：

| 文件 | 作用 | 大小 |
| --- | --- | --- |
| `libqemu-system-aarch64.so` | QEMU 本体 | 36.6 MB |
| `libslirp.so` | 用户态网络（soname 需与 QEMU 的期望一致） | 1.0 MB |

运行方式（照抄 Podroid 的做法，已在真机层面验证可行）：`ProcessBuilder` 启动，工作目录设为 `filesDir`，环境变量 `LD_LIBRARY_PATH=<nativeLibraryDir>:<filesDir>`，因为 `libslirp.so` 是靠动态库搜索路径找到的。

版本固定：抽取时校验 SHA-256，不匹配就拒绝使用并提示重新获取。

```
vmlinuz-virt              6c4a6b1fff352b618cd661c8938803e5a4e16a124efbe7c0450199c2ef42eea6
initrd.img                57ae98b7aa54271da846e8c57d9c31f5474b452e77561a69263309931ce403dc
alpine-rootfs.squashfs    04b7dfdaebeb1dccce6824a22c8cceaa1483aef6a7643bb9ccd96feee3618121
libqemu-system-aarch64.so 0eccc1a9fcf26906ba6e855223a22832e1c6fc614787498cc274c1099766448f
libslirp.so               349aeb91b0e998c2dc6d34e8e4a92f578402bec6210b781a0a37e36a4fa3515e
```

（哈希取自 Podroid v1.2.9 release 制品，本机实测。）

## 三、启动参数（规范）

以下参数已在 PC 上用同一套资产验证过（`tmp/podroid/rig/run-guest.sh`），设备端照搬，只把路径换成应用私有目录：

```
qemu-system-aarch64
  -M virt,gic-version=3
  -cpu max                       # Podroid 用 max,pauth-impdef=on；若目标 QEMU 版本不支持该属性则用 max
  -accel tcg,thread=multi,tb-size=512
  -smp 4 -m 3072                 # 4 vCPU 优于更多；内存按设备裁剪
  -kernel <filesDir>/vmlinuz-virt
  -initrd <filesDir>/initrd.img
  -append "console=ttyAMA0 mitigations=off ssh=1 androidip=10.0.2.15 podroid.dns=<设备解析器>"
  -object iothread,id=iothread0
  -device virtio-blk-pci,drive=drive1,num-queues=4,iothread=iothread0
  -drive  file=<filesDir>/storage.img,if=none,id=drive1,format=raw,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap
  -object iothread,id=iothread1
  -device virtio-blk-pci,drive=drive2,num-queues=4,iothread=iothread1
  -drive  file=<filesDir>/alpine-rootfs.squashfs,if=none,id=drive2,format=raw,readonly=on,cache=writeback,aio=threads
  -netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:9922-:22
  -device virtio-net-pci,netdev=net0,romfile=
  -serial unix:<filesDir>/serial.sock,server,nowait
  -device virtio-serial-pci
  -chardev socket,id=term0,path=<filesDir>/terminal.sock,server=on,wait=off
  -device virtconsole,chardev=term0,name=org.operit.term
  -chardev socket,id=ctrl0,path=<filesDir>/ctrl.sock,server=on,wait=off
  -device virtconsole,chardev=ctrl0,name=org.operit.ctrl
  -chardev socket,id=host0,path=<filesDir>/host.sock,server=on,wait=off
  -device virtconsole,chardev=host0,name=org.operit.host
  -display none
```

必须保留的细节：

- **设备顺序**：`/dev/vda` = 持久 ext4，`/dev/vdb` = 只读 squashfs。initramfs 按这个顺序找设备，反了会走到 FATAL 分支
- **三通道顺序**：guest 侧固定把 terminal / ctrl / host 认作 hvc0 / hvc1 / hvc2
- **`-no-reboot`**：guest 崩溃时不要静默重启，交给上层决定
- **hostfwd 端口**：guest 内 SSH 在 22，宿主侧端口由应用选（Podroid 用 9922）。设备上要避免与远端目标端口撞车
- **16 KB 页对齐**：Android 13+ 强制，原生件不合规会直接装不上，构建或抽取环节都要校验

## 四、接口契约（与既有代码的接缝）

| 现有契约 | VM 之后如何满足 |
| --- | --- |
| `TerminalTransport`（stdin/stdout/pty/pid/isAlive/destroy/awaitExit） | 新增基于 `terminal.sock` 的实现：stdin/stdout 走 socket，`pty` 提供 `setWindowSize` 并转发到 ctrl 通道，`pid` 为 QEMU 子进程 pid，`awaitExit` 等子进程退出 |
| 会话就绪三段握手（`LOGIN_SUCCESSFUL` → `TERMINAL_READY` → 首个提示符） | 启动层在串口日志看到 `Ready!` 后向 terminal 通道发一次 `echo LOGIN_SUCCESSFUL; echo TERMINAL_READY`，随后 getty 的提示符自然出现；状态机不改 |
| 窗口尺寸（window-change） | 视图尺寸 → ctrl 通道写 `RESIZE rows cols` → guest 的 `podroid-resize` 对 hvc0 执行 `stty` 并写 `/run/term_size`（PC 实测双向可控） |
| 隐藏执行（Agent 的批量命令） | 优先走 guest 内 dropbear（`ssh root@127.0.0.1 -p <宿主端口>`），退出码与超时天然可用；次选 host 桥的行协议 |
| 文件系统 provider | guest 内 SFTP（dropbear 自带）或后续补 virtiofs/9p；先用 SFTP 落地，语义与今天的远端文件系统一致 |
| MCP 共享会话 | 走 `Terminal.createSession`，与终端工具同一条通道，不需要新机制 |
| host 桥（guest → 应用） | 解析 hvc2 的行协议：`STATS`、通知、端口转发请求；这是把 guest 事件送到应用 UI/通知的通道 |
| 端口转发 | QMP（`qmp.sock`）在运行时 `netdev_add`/`netdev_del`，或启动时写死 hostfwd 列表 |
| 前台服务 | VM 必须挂在 `VmService` 上并持有唤醒锁，否则后台被杀；`-display none` 的 QEMU 无 UI，生命周期完全由服务决定 |

## 五、生命周期与故障处理

- 启动顺序：校验资产 → 确保 `storage.img` 存在（不足则扩容）→ 清理残留 socket → 起 QEMU → 监听串口日志直到 `Ready!`（带超时）→ 打开 terminal 通道 → 完成就绪握手
- 停止：向 QEMU 发 SIGTERM，超时后 SIGKILL；同时关闭 socket、更新状态。**不要**用「杀应用进程」代替停止，否则持久盘可能留下未落盘的写
- 崩溃：QEMU 退出即视为 VM 停止，向上报明确原因（串口日志尾部作为诊断信息）；**不自动重启**，避免崩溃循环
- 冷启动慢：TCG 下首次启动要 mkfs 与 overlay 归一化（PC 实测约 90 s），二次启动约 46 s。UI 必须有明确进度与阶段文案（串口标记可直接喂给进度条）
- 存储清理：容器镜像与用户数据都在 `storage.img` 里，用户可见的「清空环境」动作就是删除该文件（重新启动会重新格式化）

## 六、体积、许可与迁移

- **体积**：内核 20.0 + initrd 40.7 + squashfs 213.5 + QEMU 36.6 + slirp 1.0 ≈ **311.8 MB**，加上 `storage.img`（运行时分配）。随包会把 debug APK 从 480.8 MB 推到约 790 MB；按需下载是更现实的默认（对应 P2），但必须有哈希校验、断点续传、失败恢复与「没有本地环境也能用远端目标」的兜底路径
- **许可**：QEMU 与 Linux 内核是 GPLv2，Alpine 及其软件包各有许可。分发这些二进制意味着要提供对应源码获取方式并保留归属声明；Podroid 的打包工作也要标注来源。**不能声称这些资产是自研**。这条在选定 P2 分发形态时必须一起落地（对应 P7）
- **迁移**：proot 的 Ubuntu rootfs 与 Alpine guest 之间无法原地转换，用户在原环境里 `apt install` 的东西不会出现。P3 要决定是只写进更新说明，还是提供导出说明 + 手工导入

## 七、风险

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| TCG 性能 | 软件模拟下容器可用但慢，重编译类任务体验一般 | 4 vCPU、`tb-size`、独立 iothread、`mitigations=off`、guest 内 ZRAM；UI 上给出预期管理 |
| 设备差异 | 不同 SoC/内核版本对 TCG 的容忍度不同（Podroid 也主要在 arm64 手机上验证） | 首启做一次能力自检（能否启动到 `Ready!`），失败时给出可诊断的串口尾部日志 |
| 体积与商店政策 | 312 MB 资产 + 可能的大文件下载 | P2 + 应用商店对下载可执行文件的政策评估 |
| 许可合规 | 分发 GPLv2 二进制 | P7：源码提供方式、归属标注、许可页 |
| proot 退役 | 老用户环境消失，且本地目标曾是默认 | P8：保留一个发布周期，能力检测下隐藏，第二个版本删除；更新说明提前告知 |
| 资产耦合 | 资产来自 Podroid 制品，其发版节奏不可控 | 固定版本 + 哈希；长期看 P6（自建构建链） |
| 无模拟器可测 | arm64 镜像在 x86_64 宿主上跑不了（见 3），设备端行为只能真机验证 | PC 上的参照实现（rig）先固定启动参数与契约；真机上按清单验收 |

## 八、阶段与出口条件（提案）

1. **启动层落地**：设备上一次启动到 `Ready!`；串口阶段标记能驱动进度；停止与崩溃路径可控
2. **终端契约**：就绪握手、resize 后 guest `stty size` 一致、退出码正确；原 proot 的本地目标入口切到 VM
3. **能力**：guest 内 `podman run` 可用（CN 镜像预置）；隐藏执行与文件系统可用；MCP 共享会话可用
4. **分发与合规**：P2 的分发形态落地，P7 的源码提供与标注到位
5. **退役与迁移**：P8 的节奏执行完，P3 的迁移说明发布

阶段 1 与 2 的验证先在 PC rig 上固定参数，再上真机；真机上没有捷径——模拟器跑不了 arm64 guest。
