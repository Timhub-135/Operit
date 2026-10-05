---
For_Agent: 记录镜像无法提供的构建输入及本次采用的替代来源，替换来源变化时同步更新
---

# 镜像拿不到的输入

## 上游 Google Drive 的三份归档

`README.zh-CN.md` 与 `BUILDING.md` 要求从 Google Drive 取得 `libs.zip`、`jniLibs.zip`、`subpack.zip`，`ci/script/download_android_dependencies.sh` 用固定 file ID 通过 `gdown` 下载。该网盘在本次网络下连接被重置，国内外也没有等价的公开镜像。

三份归档在编译与打包阶段的实际作用：

- `libs.zip` 解到 `app/libs/`，但 Gradle 只引用其中的 `ffmpeg-kit-local.aar` 一项，其余 jar 不在任何 configuration 中，不会进入 APK
- `jniLibs.zip` 解到 `app/src/main/jniLibs/`，其中 `libpl_droidsonroids_gif.so` 已在 `prepare_android_dependencies.py` 中被排除，当前唯一被校验的库是自行编译的 `liboperit_ripgrep.so`
- `subpack.zip` 解到 `app/src/main/assets/subpack/`，是运行时资产，被 `ExportDialogs.kt` 读取 `subpack/android.apk` 与 `subpack/windows.zip`

因此本次构建缺少的是运行时资产，而不是编译输入：APK 结构完整、可安装可运行，但 APK 编辑（`subpack/android.apk`）与导出 Windows 运行时（`subpack/windows.zip`）这两条功能缺少随包内容。

后续若要补齐，可选路径：

- 从可访问的网络位置取得三份归档后运行 `python ci/script/prepare_android_dependencies.py --profile full --archives <目录> --repository .`
- 从官方 Release 的 `app-release.apk` 中提取 `assets/subpack/`，再放回 `app/src/main/assets/subpack/`

## ffmpeg-kit AAR

`app/build.gradle.kts` 的 `verifyExternallyBuiltNativeLibraries` 要求 `app/libs/ffmpeg-kit-local.aar` 存在，并含 10 个 arm64 库。官方流程由 `tools/ffmpeg/build_ffmpeg_kit_wsl.sh` 在 WSL 中编译 ffmpeg-kit 后经 `tools/ffmpeg/import_local_ffmpeg_kit.ps1` 导入，它需要 ffmpeg-kit 检出、Linux NDK 22.1.7171670 与本机代理。

本次改用 `maven.aliyun.com/repository/central/com/arthenica/ffmpeg-kit-full/6.0-2/ffmpeg-kit-full-6.0-2.aar`，即上游同版本的 LGPL `full` 变体，落地为 `app/libs/ffmpeg-kit-local.aar`：

- 10 个要求的 arm64 库齐全（`libavcodec`、`libavdevice`、`libavfilter`、`libavformat`、`libavutil`、`libc++_shared`、`libffmpegkit`、`libffmpegkit_abidetect`、`libswresample`、`libswscale`）
- `classes.jar` 含 app 使用的 `FFmpegKit`、`FFmpegKitConfig`、`FFprobeKit`、`MediaInformation`、`ReturnCode`
- 与脚本启用的组件集合基本一致，都是 LGPL 组合；差别仅在个别可选编码库的取舍，需要严格复现原特征集时仍应走 WSL 流程重编

Maven Central 上游本体已下架该坐标（`repo1.maven.org` 返回 404），本次可用正是依赖 aliyun 镜像的缓存。

## 仓库内被忽略的本地目录

`app/libs/`、`app/src/main/jniLibs/`、`app/src/main/assets/subpack/`、`app/build/` 都在 `.gitignore` 中，属于本地产物而非镜像问题，此处一并记录以便复现时区分。
