---
For_Agent: 让 ssh 随 APK 内本地 Ubuntu 出厂的做法与边界，仅作为本地模式修复，不是性能方案
---

# 本地 Ubuntu 里的 ssh 出厂方式

## 需求

用户的另一条建议：让 `ssh` 默认随 APK 内的本地 Ubuntu 出厂，避免用户装完应用还要自己 `apt install`。当前这块是明确的缺口：`SettingsViewModel.areSshToolsInstalled()`（`terminal/.../ui/SettingsViewModel.kt:129-137`）要求 rootfs 内同时存在 `/usr/bin/ssh` 与 `/usr/bin/sshpass`，否则 SSH 不可用；`SetupScreen.kt` 的包列表（`:106-107`）把 `ssh`、`sshpass`、`openssh-server` 交给用户在环境配置页安装。

## 先明确边界

- 装好 ssh 只消除“还要自己装”的摩擦，**不会**让 proot 变快；性能问题只能靠把负载放到远端解决
- SSH 会话改为直连 shell channel 之后，终端本身不再需要 Ubuntu 里的 `ssh`
- 手机侧反向隧道用的是应用内 Apache SSHD 服务端（`SSHDServerManager`），**不是** Ubuntu 里的 `sshd`，因此 `openssh-server` 在 Ubuntu 内的必要性随之下降，`SettingsScreen` 的“缺少 openssh-server”提示需要重新审视
- 于是本地 Ubuntu 内的 `ssh` 只剩“嵌套使用”场景：用户在 Ubuntu 里执行 `git clone git@...`、`scp`、或让 Ubuntu 内的脚本自己再连别的机器

## 方案一：预装进 rootfs 资产（推荐）

- 做法：以 `ubuntu-noble-aarch64-pd-v4.18.0` 为基础，在构建机里通过 proot 进入该 rootfs，配好国内 apt 源后安装 `openssh-client`，重新打包为新的 `tar.xz` 资产，并在文档中记录可复现的打包步骤
- 收益：首个会话即可用，无网络依赖，无 apt 交互；与现有 `extractAssets()` 流程完全兼容
- 代价：资产体积增加（`openssh-client` 连同 `libcrypto3`、`libgssapi-krb5-2`、`libedit2`、`libfido2-1` 等依赖，解压后约十 MB 量级，压缩后预计增加数 MB）；资产哈希与版本号需要更新，CI 里与 rootfs 相关的检查要同步
- 许可：OpenSSH 为 BSD 系，OpenSSL 为 Apache-2.0，krb5 为 MIT，需要进入第三方许可清单

## 方案二：assets 带 deb，首启离线安装

- 做法：把 `openssh-client` 及其依赖闭包放进 assets，首启用 `dpkg --unpack` + `dpkg --configure -a` 或本地 apt 源安装
- 收益：不必维护定制 rootfs 镜像
- 代价：需要自带完整依赖闭包并保证安装顺序；`dpkg -i` 在缺依赖时直接失败，失败信息对用户不友好；收益与方案一相同，复杂度更高

## 方案三：首启自动 apt 安装

- 做法：把今天的“用户手动装”改成首启自动执行，源用 `SourceManager` 已有的国内镜像（清华、阿里、中科大等）
- 收益：APK 不增大
- 代价：依赖网络；proot 内 apt 本身很慢，首启等待更明显；离线用户拿不到能力
- 定位：作为兜底手段都不适合（本仓库禁止兜底逻辑），只能作为“本地目标首次启用时的显式安装步骤”，由用户确认

## 方案四：去掉 sshpass

- 现状：密码以 `sshpass -p '<密码>'` 形式进入命令行（`SSHTerminalProvider.kt:213`），进程列表可见
- 目标：交互式会话改为 channel 直连后，`sshpass` 在终端路径上不再需要；本地 Ubuntu 内的嵌套使用改为密钥优先，必要时用 `SSH_ASKPASS` 配合 `setsid` 提供口令
- 结论：`sshpass` 不进入出厂清单

## 推荐组合（已确认）

- 出厂清单只要 `openssh-client`（方案一）＋ 去掉 `sshpass`（方案四）
- 本地环境继续随包提供，只是不再是默认目标；因此预装 openssh-client 的意义从“让默认环境可用”变成“让显式选择本地目标的用户开箱可用”
- `openssh-server` 不再作为本地 Ubuntu 的必需项，反向隧道依赖应用内 SSHD；`SettingsScreen` 的“缺少 openssh-server”弹窗与 `SetupScreen` 的对应条目一并移除
- 方案三保留为 UI 上的显式安装入口，仅在用户选择本地目标且确实需要额外包时使用
- 资产更新属于独立变更：需要更新资产名常量（`TerminalManager.kt:121`）、哈希、第三方许可清单，并给出一份可复现的打包步骤

## 与主方案的关系

本文件解决本地模式的“开箱可用”；SSH 作为默认执行目标按 [2_TargetArchitecture.md](2_TargetArchitecture.md) 与 [3_SshClientChoice.md](3_SshClientChoice.md) 推进。用户若日后决定彻底移除本地环境，则本文只剩“rootfs 资产是否继续随包分发”的问题，删除流程见 [8_LocalEnvironmentExport.md](8_LocalEnvironmentExport.md)。
