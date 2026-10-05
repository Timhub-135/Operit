---
For_Agent: 把本地目标从 proot 换成真实虚拟机的设计取舍、接口契约与风险；尚未实施
---

# 替换设计

## 一、许可先决条件（先于技术选型）

Operit 是 **LGPL-3.0**，Podroid 是 **GPL-2.0-only**。LGPLv3 与 GPLv2-only 不兼容，因此**不能把 Podroid 的代码并入 Operit**，这不是偏好问题而是许可约束。

剩下三种形态：

| 路线 | 形态 | 许可 | 工作量 | 体积 | 主要风险 |
| --- | --- | --- | --- | --- | --- |
| A 外部应用集成 | Operit 通过 intent 拉起 Podroid，用它的 SSH（`localhost:9922`）与 `podroid-forward` 当执行通道 | 无冲突（独立进程，非衍生作品） | 小 | 0（用户自装 297 MB） | 依赖第三方应用与其更新节奏；两套界面；用户要装两次 |
| B 自研 VM 层 | 自建 `VmEngine` + 自有内核/rootfs/QEMU 资产 | 无冲突 | 大 | +312 MB | 要把 Podroid 已经踩平的坑重走一遍（switch_root、overlay、迁移、16KB 对齐、尺寸通道） |
| C 混合 | 保留 proot 作轻量本地环境，只有需要容器时启动 VM | 无冲突 | 中 | +312 MB 或按需下载 | 不是"完全替换"，用户要的替换没有达成 |

设计倾向：**B 作为长期方案**，把 Podroid 当参考实现与验证夹具——跑它的 guest 来验证契约、引用它文档化的结论（例如"必须 switch_root""必须 plain overlay"），但不复制代码；**A 作为过渡验证**，先用它把执行通道与体验跑通，再决定是否投入 B。

## 二、必须保持不变的契约

替换的是"本地目标背后的实现"，不是用户可见的接口：

| 契约 | 现状 | VM 之后 |
| --- | --- | --- |
| 目标模型 | `TerminalTarget.LOCAL` = 本机 proot 环境 | 语义不变，实现换成 VM；新增后端枚举（AVF / QEMU-TCG）与能力探测 |
| `environment="linux"` | 指向当前 Linux 目标 | 字符串不变，落到 VM |
| 会话就绪 | `LOGIN_SUCCESSFUL` → `TERMINAL_READY` → 首个提示符三段状态机 | 桥接进程在 VM 报 `Ready!` 并拿到首个提示符后，打印同样两个标记，状态机不动 |
| 窗口尺寸 | 视图尺寸 → `window-change` → 远端 `stty` | 同一份尺寸经控制通道写 `RESIZE rows cols`，guest 侧 `stty` |
| 传输 | `TerminalTransport`（stdin/stdout/pty/pid/isAlive/destroy/awaitExit） | 新增基于 virtio-console（QEMU）或 vsock（AVF）的实现，接口不变 |
| 文件系统 | proot 内的本地文件系统 provider | virtiofs/9p（QEMU 侧需自建，Podroid 只在 AVF 有 9p），退路是 guest 内 sshd + SFTP |
| 隐藏执行 | proot 内后台 shell + 带内标记信封 | guest 内 dropbear exec 或 host bridge 行协议；必须带退出码与超时状态 |
| MCP | 插件运行时目录在本地环境内 | 目录落在 guest，共享会话走同一隐藏执行通道 |
| 主机密钥/凭据 | known_hosts + Keystore | 不受影响（那是 SSH 目标的事） |
| AIDL | 独立 Terminal 应用在用 | 只做增量，不改既有签名 |

## 三、与 Podroid 的形态差异（若走 B）

自研不是照抄，需要自己决定的地方：

- **文件共享**：Podroid 只在 AVF 上有 9p，QEMU 侧没有。我们要么在 QEMU 侧补一个 virtio-9p/virtiofs（内核与 QEMU 都要开），要么统一走 guest 内 SFTP——后者实现快，但文件工具会多一层网络语义
- **端口转发**：QEMU 侧可以照抄 QMP 思路；AVF 侧需要自己的转发代理
- **X11/桌面**：Operit 不需要，可以整块砍掉，这也是自研比集成 Podroid 体积更可控的原因
- **USB 直通**：非必需，先不做
- **体积裁剪**：Podroid 的 213.5 MB squashfs 里装了 podman + docker + LXC + dropbear + iptables 全套。只留 podman（crun + fuse-overlayfs）能显著缩小；这是自研相对集成第三方应用的主要优势
- **CN 网络适配**：guest 内的 `podman run` 默认走 Docker Hub，而国内对 `registry-1.docker.io` 的解析被污染，首次拉取必然失败。落地时应在 squashfs 里预置 `registries.conf` 的镜像配置，否则用户第一次跑容器就撞墙（路径 C 实测：换成 `docker.m.daocloud.io` 即可正常拉取并运行）

## 四、后端与设备矩阵

| 后端 | 设备要求 | 速度 | 备注 |
| --- | --- | --- | --- |
| AVF/pKVM | 设备上报 `android.software.virtualization_framework`（Pixel 级），需 `pm grant` 两个权限 | 接近原生 | 首选的快速路径 |
| QEMU/TCG | 任意 arm64 设备，无特殊权限 | 慢（Podroid 的经验：4 vCPU 优于 8） | 覆盖面广的兜底路径 |
| x86_64 设备 | 目前无可用实现与 guest 资产 | — | 除非 P4 确认，否则不支持 |

不做静默回落：后端由能力选择，但设置页必须显示"当前后端 + 为什么"，切换要用户显式确认。

## 五、体积与分发

- 换算：内核 20.0 + initrd 40.7 + squashfs 213.5 + QEMU 36.6 + slirp 1.0 ≈ **312 MB**；Operit 当前 debug APK 480.8 MB（含 62.3 MB proot rootfs），随包会把 APK 推到约 790 MB
- 三个可选分发形态（对应 P2）：随包 / 首启按需下载（需哈希校验、断点续传与失败恢复，且要评估应用商店对下载可执行文件的政策）/ 拆 flavor（"轻装版"给不需要容器的用户）
- 无论哪种，**必须能回到可用状态**：下载失败不能把用户卡在"本地目标不可用且不能选远端"的状态

## 六、迁移

- proot 的 Ubuntu rootfs 与 Alpine guest 之间**不能原地转换**：包管理、路径、用户态都不同，只能"导出 tar → 在 guest 内手工导入"
- 导出/删除入口刚被放弃（`docs/TODO/ssh_default_terminal_20261004/9_ImplementationPlan.md` 阶段 6），因此 P3 要重新决策：要么不做迁移（新环境全新开始，并在更新说明里写清楚），要么补一个只读的"导出说明"而不提供应用内删除
- guest 系统层的跨版本演进要照抄 Podroid 的机制：plain overlay + `/etc/.../system-version` 锚点 + 幂等迁移钩子

## 七、风险清单

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 许可 | 不能合并 GPL-2.0-only 代码 | 外部集成或自研；文档里明确"参考实现"与"复制代码"的界线 |
| 体积 | +312 MB，接近翻倍 | 按需下载、裁剪 squashfs、拆 flavor |
| TCG 性能 | 软件模拟下容器可用但慢 | AVF 优先；性能旋钮照抄（4 vCPU、tb-size、iothread、ZRAM） |
| 构建链维护 | 内核 + QEMU 交叉编译 + rootfs 打包要长期维护 | 建 Docker 化流水线；固定内核/QEMU 版本并在 CI 里验证 guest 能启动 |
| 16 KB 页对齐 | Android 13+ 强制，原生件不合规会装不上 | ELF 校验进构建流程（Podroid 的做法是构建期解析 ELF 检查） |
| 安全面 | VM 与 host bridge 是新的攻击面；端口转发会把 guest 服务暴露到局域网 | bridge 输入校验（长度/UTF-8 上限）、转发默认关闭且要显式授权、绑定回环 |
| 上游跟随 | guest 系统层会持续演进 | 版本锚点 + 迁移钩子，避免每次升级都要用户重建 |
| 老用户预期 | 现有 proot 环境里的数据不会自动出现 | 更新说明写清楚 + P3 决策 |

## 八、阶段与出口条件（提案）

1. **执行通道打通**：guest 能在真机启动，终端可用（就绪握手、resize、退出码三项都过）
2. **能力落地**：guest 内 `podman run` 可用；文件系统与隐藏执行可用；MCP 共享会话可用
3. **体验与体积**：后端选择界面、体积策略落地、失败可恢复
4. **迁移与文档**：P3 决策落地，更新说明与文档同步

每一阶段的验证都必须在真机上做：按 Podroid 的经验，单元测试覆盖不到 VM 行为与后端差异，而两个后端需要两类设备。
