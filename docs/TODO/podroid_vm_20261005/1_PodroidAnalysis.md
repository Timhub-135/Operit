---
For_Agent: Podroid 的架构与约束分析，结论来自阅读其源码、CLAUDE.md 与 release APK（v1.2.9）
---

# Podroid 分析

## 它是什么

rootless 的 Android 应用（`com.excp.podroid`），在 stock Android 8+ 上启动一台**带自有内核的真实 Alpine 3.24 虚拟机**，因此 podman / docker / LXC 与服务器上行为一致；另有应用内终端、X11 桌面、USB 直通、SSH 与 guest→Android 桥。不依赖 root、不刷机。

关键事实（源码与 release 制品实测）：

| 项 | 值 |
| --- | --- |
| 版本 | v1.2.9（versionCode 33） |
| minSdk / targetSdk | 26 / 36 |
| 架构 | 仅 arm64（`abiFilters += "arm64-v8a"`） |
| 内核 | 自建 Linux，版本固定在 `podroidKernelVersion=7.1.5` |
| QEMU | `podroidQemuVersion=11.0.4`，交叉编译自 NDK |
| APK | 297.3 MB（release 实测） |
| VM 资产 | `alpine-rootfs.squashfs` 213.5 MB、`initrd.img` 40.7 MB、`vmlinuz-virt` 20.0 MB |
| 原生件 | `libqemu-system-aarch64.so` 36.6 MB、`libslirp.so` 1.0 MB、`libpodroid-bridge.so`、`libpodroid-launcher.so`、`libtermux.so` |
| 许可 | GPL-2.0 |

## 两个后端，一个接口

`engine/VmEngine.kt` 是唯一接口，两个实现加一个路由：

- **QEMU/TCG**（默认，无需特殊权限）：软件模拟，SLIRP 用户态网络，控制面是 Unix socket（`terminal.sock`/`ctrl.sock`/`serial.sock`/`qmp.sock`/`host.sock`），QMP 做运行时端口转发与 USB 热插拔
- **AVF/pKVM**（Pixel 级设备 + `pm grant` 两个权限）：硬件加速，网络与控制走 vsock，没有 QMP 与 PL011

后端差异是这个项目最大的 bug 来源，其文档明确要求两个后端都要在真机上验证。

**本方案只采用 QEMU/TCG 这一条**：不需要 pKVM 设备、不需要 `pm grant`，覆盖面最广；代价是软件模拟的性能，靠下面的性能旋钮缓解。AVF 相关的实现与约束只作为背景记录，不进入设计。

## 启动管线（对集成最要紧的部分）

1. initramfs 里的 `init-podroid`（约 45 行）挂载持久 ext4（`/dev/vda` → upper）与只读 squashfs（`/dev/vdb` → lower），叠加 overlayfs，然后把挂载点搬进新根并 `switch_root` 到 busybox `/sbin/init`
2. busybox init → OpenRC（runlevel 在建包时直接软链好）
3. OpenRC 服务做系统 bringup：`podroid-bootstrap`（内核模块、cgroup v2、devpts/shm/mqueue、sysctl、ZRAM swap、`mount --make-rshared /`）、`podroid-network`、`podroid-resize`、`podroid-hostd`、`podroid-vsock`、`dropbear`、`podroid-ready`
4. `podroid-ready` 依次输出 `Starting SSH...` / `Almost ready...` / `Ready!`，Android 侧的 `BootStageDetector` 在滚动缓冲（不是单个 read 块）里匹配这些标记，`Ready!` 之后才拉起终端桥

**为什么必须 `switch_root` 而不是 `chroot`**：早期版本 chroot 进 overlay 后 `podman exec -it` 坏掉——`crun exec` 的 `setns(MNT)` 会重置 `fs->root`，exec 出来的进程看到的是 `/mnt/overlay/proc` 这类原始路径而不是 `/proc`。`switch_root` 重组的是内核挂载树本身，命名空间 fork 才能看到干净的 `/`。这一条直接否决了任何"把 VM 根当目录 chroot 进去"的集成思路。

## 控制面与数据面

| 通道 | QEMU | AVF | 作用 |
| --- | --- | --- | --- |
| 终端 I/O | `terminal.sock` ↔ virtio-console `/dev/hvc0` | vsock | getty 在 hvc0，`libpodroid-bridge.so` 把它接到 Termux PTY |
| 尺寸 | `ctrl.sock` ↔ `/dev/hvc1` | `VsockControlChannel` | 桥接层把 SIGWINCH 抖动去抖后写一行 `RESIZE rows cols`，guest 侧守护进程 `stty` hvc0 |
| 启动日志 | `serial.sock` ↔ PL011 `/dev/ttyAMA0` | `ConsoleFanout` | 只做日志，喂给 boot stage 检测 |
| 运行时控制 | `qmp.sock` | 无 | 端口转发、USB 热插拔 |
| guest→Android | `host.sock` ↔ `/dev/hvc2` | vsock:9101 | `podroid-notify` / `podroid-forward` 的行协议 |

尺寸通道与我们终端模块的 window-change 契约同构，可以一对一直译：视图尺寸变化 → 控制通道写入 → guest `stty`。

host bridge 的细节值得抄成"注意事项"：`/dev/hvc2` 是默认开启回显的 virtio-console TTY，守护进程必须 `cfmakeraw()`，否则 Android 的响应会被回显回来、协议在第一个请求后就失步；AVF 的裸 vsock 不受影响。

## 存储共享与 USB

- **Downloads 共享是 AVF 专属**：进程内实现 9p2000.L 服务器（`Ninep2000LServer.kt`，约 886 行）走 vsock，因此 guest 读写用户文件不需要应用持有宽泛存储权限。QEMU 侧没有等价物，凡是建立在这个共享上的功能按构造就是后端不对称的
- **USB 直通是 QEMU 专属**：无权限应用打不开 `/dev/bus/usb`，于是从 `UsbManager` 拿已打开的 fd，用 SCM_RIGHTS 经 `qmp.sock` 交给 QEMU，再 `device_add usb-host`

## 性能旋钮（TCG 路径）

`tcg,thread=multi`、≥2 GB 内存时加大 `tb-size`、`virtio-blk-pci` 配独立 iothread、`-cpu max,pauth-impdef=on`；**更多 vCPU 不等于更快**——8 核手机上 8 个 vCPU 在所有指标上都慢于 4 个。guest cmdline 用 `mitigations=off`，每设备 `mq-deadline`，ZRAM lz4 swap 取内存 1.5 倍。无 root 拿不到的东西：`io_uring`（seccomp）、CPU 亲和性、KSM、TAP 网络、宿主大页。

## guest 系统层如何跨版本升级（值得照抄的机制）

- **plain overlay，绝不加 `metacopy`/`index`/`redirect`**：plain overlayfs 容忍 lower 被整块替换，所以新 squashfs 在下次启动即生效而持久 upper 保留；加了 metacopy 会把 upper 绑死在某个 lower 上，重现"升级后必须重置"的损坏
- **版本锚点**：squashfs 里带 `/etc/podroid/system-version`，已应用版本记在 `/mnt/persist/.podroid/applied-version`
- **迁移钩子**：`podroid-migrate` 按顺序执行 `/etc/podroid/migrations/<v>.sh`，成功后原子推进 applied-version；崩溃可幂等重跑

对我们同样适用的结论：**VM 的 guest 系统层是需要长期演进的资产**，落地时就要有版本锚点与迁移钩子，否则每次升级都要用户重建环境。

## 本方案要从它的制品里抽取什么

抽取动作只做一次，之后按哈希固定版本：

```
tar -xf Podroid-v1.2.9-release.apk \
    assets/vmlinuz-virt assets/initrd.img assets/alpine-rootfs.squashfs \
    lib/arm64-v8a/libqemu-system-aarch64.so lib/arm64-v8a/libslirp.so
```

| 文件 | SHA-256 |
| --- | --- |
| `vmlinuz-virt` | `6c4a6b1fff352b618cd661c8938803e5a4e16a124efbe7c0450199c2ef42eea6` |
| `initrd.img` | `57ae98b7aa54271da846e8c57d9c31f5474b452e77561a69263309931ce403dc` |
| `alpine-rootfs.squashfs` | `04b7dfdaebeb1dccce6824a22c8cceaa1483aef6a7643bb9ccd96feee3618121` |
| `libqemu-system-aarch64.so` | `0eccc1a9fcf26906ba6e855223a22832e1c6fc614787498cc274c1099766448f` |
| `libslirp.so` | `349aeb91b0e998c2dc6d34e8e4a92f578402bec6210b781a0a37e36a4fa3515e` |

配套要在我们这边自己实现的部分：

- **执行方式**：原生件以 `.so` 名义打包、按可执行文件运行；`ProcessBuilder` 的工作目录设为 `filesDir`，`LD_LIBRARY_PATH` 指向 `nativeLibraryDir` 与 `filesDir`，否则 `libslirp.so` 找不到
- **进程收敛**：Podroid 用一个 C 写的 launcher 设置 `PR_SET_PDEATHSIG(SIGKILL)`，让 QEMU 随应用进程一起死。我们至少要有等价保证（前台服务 + 停止时显式收敛），否则会留下孤儿 VM 占着 3 GB 内存
- **设备与通道布局**：见 [2_ReplacementDesign.md](2_ReplacementDesign.md) 的启动参数一节，已在 PC 上验证
- **不做**：它的 Compose UI、X11/VNC 查看器、USB 直通、9p Downloads 共享、AVF 后端、容器备份等

## 它的约束

- 仅 arm64：没有 x86_64 设备的现成实现，也没有 x86_64 guest 资产
- AVF 需要设备上报 `android.software.virtualization_framework`（Pixel 级）并 `pm grant`（本方案不用）
- 不可绑特权端口（无 `CAP_NET_BIND_SERVICE`），SSH 在 9922
- 原生件必须 16 KB 页对齐（Android 13+ 强制）
- 体积换能力：VM 资产合计约 312 MB
