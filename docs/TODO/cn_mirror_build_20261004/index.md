---
For_Agent: 本目录记录“把一次完整 APK 构建全部改用国内镜像”的工作范围与落地结果
repo: 本地检出 D:\design\Operit（main）
---

# 中国大陆网络下的镜像构建

## 原本状况

标准构建流程假定 `github.com`、`huggingface.co`、`dl.google.com`、Maven Central 与 npm 官方源都可直连：

- Gradle wrapper 已经指向 `mirrors.aliyun.com`，但 Maven 依赖仍优先走 `google()` 与 `mavenCentral()`
- CMake `FetchContent` 直接下载 `https://github.com/<owner>/<repo>/archive/<sha>.tar.gz`，`git ls-remote` 也直连 GitHub
- `terminal` 子模块从 `github.com` 拉取
- 本地 STT 模型从 `huggingface.co` 下载
- npm 依赖走官方 registry
- `liboperit_ripgrep.so` 需要 rustup 与 crates.io

在这样的网络下，上述任一步骤都会超时或连接重置，构建无法开始。

## 意图与期待结果

在不破坏 GitHub 直连环境与 CI 行为的前提下，用镜像完成一次 `:app:assembleDebug`：

- 除 `cmake/operit_git_source.cmake` 增加镜像前缀开关外，改动集中在环境变量、仓库内被忽略的本地目录与镜像 URL
- 构建产物与官方流程产出的 debug APK 结构一致
- 明确记录哪些输入镜像无法替代

## 作用域

- `cmake/operit_git_source.cmake`：新增 `OPERIT_GITHUB_URL_PREFIX`
- `docs/doc-src/dev-core/BUILDING_CN_MIRRORS.md`：镜像构建说明
- `docs/doc-src/dev-core/BUILDING.md`：指向镜像说明
- 不修改 Gradle 依赖声明、不改 `settings.gradle.kts` 的仓库顺序，镜像经 init 脚本注入

## 步骤文档

- [1_DependencyMirrorMap.md](1_DependencyMirrorMap.md)：每类外部输入对应的镜像与落地方式
- [2_CmakeGithubMirrorPrefix.md](2_CmakeGithubMirrorPrefix.md)：CMake 侧镜像前缀的实现与验证
- [3_UnmirrorableInputs.md](3_UnmirrorableInputs.md)：镜像无法提供的输入及其处理
- [4_HostToolchainOnWindows.md](4_HostToolchainOnWindows.md)：无 MSVC 时 MNN 宿主机 flatc 的编译问题与解法
- [5_SherpaFetchContentDeps.md](5_SherpaFetchContentDeps.md)：sherpa-ncnn 内部 FetchContent 依赖的预下载
- [6_SubpackRuntimeAssets.md](6_SubpackRuntimeAssets.md)：无法访问上游网盘时补齐 subpack 运行时资产
