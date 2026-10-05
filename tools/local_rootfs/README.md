---
For_Agent: 本地 rootfs 资产的重建方式说明，换基础镜像或包清单时同步更新
---

# 本地环境 rootfs 重建

终端模块随包分发一个 arm64 Ubuntu rootfs 资产，位于 `terminal/src/main/assets/`。本地目标（`TerminalTarget.LOCAL`）依赖它；远端 SSH 目标完全不需要它。

资产里预装 `openssh-client`，这样选择本地目标的用户不必在安装应用之后再手动 `apt install ssh`。

## 为什么需要单独的重建流程

- rootfs 是 arm64 用户态，在 x86_64 构建机（含 CI 容器）里执行 apt 需要 `qemu-user-static`
- 直接改压缩包会破坏权限、符号链接与属主；必须解包后在原地安装再重新打包
- 应用侧用 `busybox tar xf` 解包，并要求顶层目录名与资产名前缀一致（安装脚本据文件名推导发行版名）

## 用法

在仓库根目录执行：

```bash
docker run --rm --privileged \
  -v "$PWD":/repo -v operit-rootfs-work:/work \
  -e IN_NAME=ubuntu-noble-aarch64-pd-v4.18.0.tar.xz \
  -e OUT_NAME=ubuntu-noble-aarch64-pd-v4.19.0.tar.xz \
  ubuntu:latest bash /repo/tools/local_rootfs/build_local_rootfs.sh
```

`--privileged` 是 `qemu-user-static` 注册 binfmt 所必需的。脚本以 chroot 方式进入 rootfs 安装 `openssh-client`，随后清理 apt 列表与 qemu 二进制再重新打包。

## 换新资产后必须同步的地方

- `terminal/src/main/java/com/ai/assistance/operit/terminal/TerminalManager.kt` 的 `UBUNTU_FILENAME` 常量
- 第三方许可清单（OpenSSH 为 BSD 系、OpenSSL 为 Apache-2.0）
- 若资产名改变，注意安装脚本用文件名前缀推导发行版名，顶层目录名要保持 `<前缀>/`

## 验收

脚本末尾会在 chroot 内执行 `ssh -V`；此外可在应用内选择本地目标，确认进入 Ubuntu 后 `command -v ssh` 直接有结果，不需要再装包。
