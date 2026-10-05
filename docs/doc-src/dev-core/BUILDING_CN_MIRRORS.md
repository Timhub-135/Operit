---
For_Agent: 本文件描述在中国大陆网络下用镜像完成一次完整 Android 构建所需的全部外部输入，构建脚本变化时应同步更新
---

# 镜像构建：把每一条外部依赖换成能走通的路

`BUILDING.md` 描述的是 GitHub 与 Google 都能直连时的标准流程。当 `github.com` 连不上、`huggingface.co` 超时、Maven Central 与 npm 官方源很慢时，本文件给出等价的镜像路径。

除 `cmake/operit_git_source.cmake` 的镜像前缀开关外，本文件描述的手段都不需要改动仓库源码：全部通过环境变量、仓库内的本地配置目录与镜像 URL 完成。

## 每一类外部输入对应的镜像

Gradle 发行版

- 由 `gradle/wrapper/gradle-wrapper.properties` 固定为 `mirrors.aliyun.com` 的 Gradle 8.13 包，并带官方 `distributionSha256Sum`

Maven 依赖（AndroidX、Compose、Google Maven、Gradle 插件、JitPack 之外的第三方库）

- `maven.aliyun.com` 的 `central`、`public`、`google`、`gradle-plugin` 四个仓库，以及 `repo.huaweicloud.com/repository/maven` 作为补充
- 依赖解析时 `central` 与 `public` 排在 `google` 之前：aliyun 的 Google 镜像会对部分托管在 Maven Central 的模块（例如 `com.google.android.filament:filament-android`）返回元数据却不返回制品，而 Gradle 只从提供元数据的仓库取制品，于是报 `Could not find filament-android-...aar`。Central 在前可完整解析这类模块，纯 Google 制品则会在下一次尝试落到 Google 镜像
- 插件解析保持 `gradle-plugin`、`google`、`public`、`central` 的顺序，`gradlePluginPortal()` 追加在最后
- 通过 Gradle init 脚本注入，写法见 `~/.gradle/init.d/cn-mirrors.gradle`；使用仓库内 Gradle home 时可复制到 `$GRADLE_USER_HOME/init.d/cn-mirrors.gradle`

npm 依赖（根项目、`web-chat`、工具包示例）

- `registry.npmmirror.com`
- 本地缓存建议指向仓库内的忽略目录，避免污染用户目录

Rust 工具链与 crates.io

- `RUSTUP_DIST_SERVER=https://rsproxy.cn`、`RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup`
- crates 索引由 `$CARGO_HOME/config.toml` 指向 `sparse+https://rsproxy.cn/index/`

Hugging Face 语音模型

- `app/config/stt-model-assets.properties` 中的 `huggingface.co` 前缀替换为 `hf-mirror.com` 后下载到 `app/build/generated/stt-model-assets`，Gradle 任务按清单校验字节数与 SHA-256 后跳过下载

github.com（CMake `FetchContent` 的源码归档、`terminal` 子模块、CMake 中的 `git ls-remote`）

- CMake 侧使用 `OPERIT_GITHUB_URL_PREFIX`，见下一节
- Git 侧可用 `url.<镜像前缀>.insteadOf` 重写，见“子模块与 Git 远端”一节
- 本文使用 `https://ghfast.top/` 作为示例前缀；它同时支持 GitHub 归档下载与 Git 智能 HTTP 协议

## CMake 源码依赖的镜像前缀

`cmake/operit_git_source.cmake` 会把 `OPERIT_GITHUB_URL_PREFIX` 原样拼在每个 GitHub URL 前面，既作用于 `git ls-remote` 的 ref 解析，也作用于 `FetchContent` 的归档下载：

```bash
OPERIT_GITHUB_URL_PREFIX=https://ghfast.top/ ./gradlew :app:assembleDebug
```

该值优先从环境变量读取，因此 app、`quickjs`、`avator/*`、`llm/*` 这些独立 configure 的原生模块都能继承，无需逐模块传参；也可以通过 `-DOPERIT_GITHUB_URL_PREFIX=https://ghfast.top/` 显式传入。前缀为空时保持 `https://github.com` 原样，GitHub 直连环境与 CI 行为不变。

## 子模块与 Git 远端

`terminal` 子模块来自 `github.com`，可让 Git 自己在取远端时改写 URL，而不改动用户全局配置：

```bash
cat > /tmp/git-cn.config <<'EOF'
[url "https://ghfast.top/https://github.com/"]
	insteadOf = https://github.com/
EOF
GIT_CONFIG_GLOBAL=/tmp/git-cn.config git submodule update --init --recursive --depth 1 terminal
```

## 三份必须手工准备的输入

以下输入不属于 Maven/npm 生态，镜像无法替代：

- `app/libs/ffmpeg-kit-local.aar`：默认由 `tools/ffmpeg/build_ffmpeg_kit_wsl.sh` 在 WSL 中编译 ffmpeg-kit 后经 `tools/ffmpeg/import_local_ffmpeg_kit.ps1` 导入；无法编译时，可用 `maven.aliyun.com/repository/central/com/arthenica/ffmpeg-kit-full/6.0-2/ffmpeg-kit-full-6.0-2.aar` 作为同版本 LGPL 变体，它包含 `verifyExternallyBuiltNativeLibraries` 要求的 10 个 arm64 库
- `app/src/main/jniLibs/arm64-v8a/liboperit_ripgrep.so`：由 `tools/native_ripgrep/build_native_ripgrep.ps1` 交叉编译
- `app/src/main/assets/subpack/`：来自上游 Google Drive 归档 `subpack.zip`，`app/libs/` 与 `app/src/main/jniLibs/` 的其余历史内容同样来自该网盘的 `libs.zip`、`jniLibs.zip`。它们是运行时资产，缺失不影响编译与打包

## Windows 主机上的额外要求

MNN 的 schema 生成需要在宿主机上编译 `flatc`，因此 Windows 构建机必须具备宿主机 C/C++ 编译器。没有 MSVC 时可用 MinGW-w64，并把生成器固定为 Ninja。

只设置 `CC`/`CXX` 并不足够：AGP 会为原生构建准备自己的环境（`CC`、`CXX` 与 `CXXFLAGS` 指向 NDK 的 `clang++` 与 `-stdlib=libc++`），子 `cmake` 进程继承这套环境后会用 NDK 编译器去编宿主机程序，报 `fatal error: 'cstdint' file not found`。可靠的做法是用工具链文件把宿主机编译器钉死，并把继承来的编译参数清空。`CMAKE_TOOLCHAIN_FILE` 环境变量会被 CMake 采纳，而 Android 侧由 AGP 通过 `-DCMAKE_TOOLCHAIN_FILE=` 显式指定，命令行参数优先于环境变量，两边互不干扰。

```powershell
# tmp/cn/host-toolchain.cmake 内容见下
$env:CMAKE_GENERATOR = 'Ninja'
$env:CMAKE_TOOLCHAIN_FILE = '<repo>\tmp\cn\host-toolchain.cmake'
$env:PATH = "<mingw>\bin;D:\Tools\Android\Sdk\cmake\3.22.1\bin;$env:PATH"
```

```cmake
set(CMAKE_C_COMPILER "<mingw>/bin/gcc.exe" CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER "<mingw>/bin/g++.exe" CACHE FILEPATH "" FORCE)
set(CMAKE_C_FLAGS "" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "" CACHE STRING "" FORCE)
set(CMAKE_AR "<mingw>/bin/ar.exe" CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "<mingw>/bin/ranlib.exe" CACHE FILEPATH "" FORCE)
```

MinGW 的 `bin` 目录还要留在 `PATH` 上，因为 `flatc.exe` 运行期需要 `libstdc++-6.dll`、`libgcc_s_seh-1.dll`。若某次尝试已经用错误的编译器生成了 `flatc-host` 的 `CMakeCache.txt`，需要先删掉该目录，否则 CMake 会继续沿用缓存的编译器。

`tools/example_packages/sync_example_packages.py` 以子进程方式调用 `pnpm`。Windows 上 `npm i -g pnpm` 只提供 `pnpm.cmd` 与 `pnpm.ps1`，Python 的 `subprocess` 找不到可执行文件而报 `[WinError 2]`，需要让 `PATH` 上存在真正的 `pnpm.exe`，例如解包 `@pnpm/win-x64` 后把其中的 `pnpm.exe` 所在目录加入 `PATH`。

`tools/native_ripgrep/build_native_ripgrep.ps1` 使用 `$ErrorActionPreference = "Stop"`，在 Windows PowerShell 5.1 下 `rustup target add` 写到 stderr 的 `info:` 会被当成终止错误而中断脚本。可改用 PowerShell 7 执行该脚本，或按脚本内的等价命令手动执行 `cargo build --release --target aarch64-linux-android` 并复制产物。
