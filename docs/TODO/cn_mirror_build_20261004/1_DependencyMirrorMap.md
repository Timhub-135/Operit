---
For_Agent: 列出本次镜像构建中每一类外部输入的镜像落地方式，新增外部依赖时同步补充
---

# 依赖镜像对照

## Gradle 发行版

`gradle/wrapper/gradle-wrapper.properties` 已经指向 `mirrors.aliyun.com/macports/distfiles/gradle/gradle-8.13-bin.zip`，并保留官方 `distributionSha256Sum`。构建日志中的 `Downloading https://mirrors.aliyun.com/...` 即该步骤，无需改动。

## Maven 与 Gradle 插件

`settings.gradle.kts` 的仓库顺序保持原样，镜像通过 init 脚本前置注入。本次使用仓库内的 Gradle home，脚本位置为 `.gradle-local/init.d/cn-mirrors.gradle`，与用户全局的 `~/.gradle/init.d/cn-mirrors.gradle` 内容一致，并额外覆盖各项目的 `buildscript.repositories`，使根构建脚本里的 ObjectBox 插件也走镜像。

注入的镜像，依赖解析顺序：

- `https://maven.aliyun.com/repository/central`
- `https://maven.aliyun.com/repository/public`
- `https://maven.aliyun.com/repository/google`
- `https://repo.huaweicloud.com/repository/maven/`
- `https://maven.aliyun.com/repository/gradle-plugin`

插件解析顺序为 `gradle-plugin`、`google`、`public`、`central`、`huaweicloud`，其后追加 `gradlePluginPortal()`。

把 Central 排在 Google 之前是被一次真实失败逼出来的：aliyun 的 Google 镜像对 `com.google.android.filament:filament-android:1.69.2` 返回了模块元数据，但没有对应 AAR，而 Gradle 只从给出元数据的仓库取制品，于是 `:app:compileDebugAidl` 直接报 `Could not find filament-android-1.69.2.aar`。filament 实际上发布在 Maven Central，aliyun 的 central 与 public 仓库同时具备 pom、module 与 aar，把 Central 提前即可完整解析；纯 Google 制品在 Central 侧 404 后会落到 Google 镜像，只是多一次请求。

未注入 `project.repositories`，因为本仓库设置了 `RepositoriesMode.FAIL_ON_PROJECT_REPOS`。

`jitpack.io` 与 `api.xposed.info` 未做替换：本机可直连，且 aliyun 的 public 仓库不含 `com.github.*` 坐标，遇到这类依赖会落到原仓库。

## npm 与 pnpm

- registry 由 `npm_config_registry=https://registry.npmmirror.com` 指定
- 缓存写入仓库内忽略目录 `.npm-cache`，不污染用户 npm 缓存
- `pnpm` 使用 `@pnpm/win-x64` 的独立 `pnpm.exe`，供 Python 子进程调用，见 [BUILDING_CN_MIRRORS.md](../../doc-src/dev-core/BUILDING_CN_MIRRORS.md)

## Rust 与 crates.io

- `RUSTUP_DIST_SERVER=https://rsproxy.cn`、`RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup`
- `RUSTUP_HOME`、`CARGO_HOME` 指向仓库内忽略目录，`$CARGO_HOME/config.toml` 把 crates.io 换为 `sparse+https://rsproxy.cn/index/`
- 安装结果：`stable-x86_64-pc-windows-gnu` 与 `aarch64-linux-android` 目标

本机没有 MSVC，因此宿主机工具链选用 `x86_64-pc-windows-gnu`，并由 MinGW-w64 提供 `gcc.exe` 作为链接器。

## Hugging Face 语音模型

清单 `app/config/stt-model-assets.properties` 中的 `huggingface.co` 前缀替换为 `hf-mirror.com`，下载后先自查字节数与 SHA-256，再放入 `app/build/generated/stt-model-assets`。8 个文件全部与清单一致：

- `silero_vad.onnx`
- `sherpa-ncnn-streaming-zipformer-bilingual-zh-en-2023-02-13` 下的 7 个文件

清单本身不改，Gradle 任务仍然按原 URL 校验，命中已存在的合法文件时不会发起下载。

## GitHub

- CMake：`OPERIT_GITHUB_URL_PREFIX=https://ghfast.top/`
- `terminal` 子模块：`GIT_CONFIG_GLOBAL` 指向临时配置，内含 `url."https://ghfast.top/https://github.com/".insteadOf`
- 实测 `github.com` 直连返回 `Connection was reset`，镜像前缀下的 `git ls-remote` 与归档下载均正常

## 宿主机 C/C++ 编译器

MNN 需要宿主机 `flatc`。本机没有 MSVC，使用 `niXman/mingw-builds-binaries` 的 GCC 16.2.0 msvcrt 包，经 `https://ghfast.top/` 下载后解压到仓库内忽略目录，并把 `CMAKE_GENERATOR` 固定为 `Ninja`、`CC`/`CXX` 指向该 MinGW。
