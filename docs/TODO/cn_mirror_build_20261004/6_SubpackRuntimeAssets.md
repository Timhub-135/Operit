---
For_Agent: 记录在无法访问上游网盘时补齐 subpack 运行时资产的做法
---

# 补齐 subpack 运行时资产

## 缺口

`app/src/main/assets/subpack/` 的内容来自上游 Google Drive 的 `subpack.zip`，该网盘在本次网络下不可达。缺失后果是运行时功能缺失而非编译失败：

- `ExportDialogs.kt` 读取 `subpack/android.apk` 用于 APK 编辑
- `ExportDialogs.kt` 读取 `subpack/windows.zip` 用于导出 Windows 运行时

## 做法

官方 Release 的 `app-release.apk` 由同一份源码产出，其中的 `assets/subpack/` 就是这两个文件本身。APK 是普通 ZIP，中央目录记录了每个条目的偏移与压缩方式，因此可以只取需要的条目：

1. 读文件尾部 256 KB，定位 EOCD，取得中央目录的偏移与长度
2. 读中央目录，筛出 `assets/subpack/` 前缀的条目
3. 对每个条目读一次 30 字节的本地头，按名字与扩展字段长度算出数据起点
4. 按 `offset..offset+compressedSize` 取数据，`deflate` 用 raw inflate 还原，并核对解压后长度

实测结果，`app-release.apk` 中该前缀下正好两个条目：

- `assets/subpack/android.apk`，压缩后 22.79 MB，解出 45.91 MB
- `assets/subpack/windows.zip`，压缩后 10.87 MB，解出 10.88 MB

共下载约 34 MB，而完整 APK 为 385 MB。两个解出的文件都校验为合法 ZIP，前者含 431 个条目。

## 边界

这不是镜像方案，而是用官方发行物补齐上游网盘内容，适用于网盘不可达、又需要可运行 APK 的场景。要在 CI 或长期复现中使用，仍应以 `ci/script/download_android_dependencies.sh` 拉取的归档为准；归档内容寻址与清单记录仍由 [refactor_building_sys/3_ExternalArtifactManifest.md](../refactor_building_sys/3_ExternalArtifactManifest.md) 跟踪。
