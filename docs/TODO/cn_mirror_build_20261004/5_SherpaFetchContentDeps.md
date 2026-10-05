---
For_Agent: 记录 sherpa-ncnn 内部 FetchContent 依赖在慢网络下的处理方式
---

# sherpa-ncnn 的 FetchContent 依赖

## 现象

`:app:buildCMakeDebug[arm64-v8a]` 长时间停在下载阶段，`app/.cxx/Debug/<hash>/arm64-v8a/_deps/` 下出现 0 字节的 `v3.12.0.tar.gz`，`json-src` 始终为空。过程本身没有报错，只是 http 请求既不返回也不失败。

## 原因

`operit_git_source.cmake` 的镜像前缀只覆盖 operit 自己声明的源码依赖。sherpa-ncnn 在它自己的 `cmake/*.cmake` 里另有一批 `FetchContent_Declare`，URL 指向 `github.com`：

- `json.cmake`：`json-3.12.0.tar.gz`
- `kaldi-native-fbank.cmake`：`kaldi-native-fbank-1.22.3.tar.gz`
- `kaldifst.cmake`：`kaldifst-1.7.17.tar.gz`
- `openfst.cmake`：`openfst-sherpa-onnx-2024-06-19.tar.gz`
- `kissfft.cmake`（来自 kaldi-native-fbank）：`kissfft-<sha>.zip`，其 `URL2` 为空，没有镜像兜底
- `ncnn.cmake`：`ncnn-<sha>.zip`，其 `URL2` 指向 `huggingface.co`，在本网络下同样不可达

其中 json、kaldi-native-fbank、kaldifst、openfst 提供了 `hf-mirror.com` 兜底，ncnn 与 kissfft 没有可用兜底。

## 解法

这些脚本本身支持预下载：`download_*()` 会检查 `possible_file_locations`，命中本地文件时直接把 URL 换成该文件。

关键点是这些位置里的 `${PROJECT_BINARY_DIR}` 指的是 **sherpa-ncnn 自己的** 二进制目录，而不是 app 的 CMake 二进制目录，因为它自己的 `CMakeLists.txt` 重新执行了 `project()`：

```text
app/src/main/cpp/.cxx/operit_deps/sherpa_ncnn-<sha>-build/
```

把归档放在该目录（`${PROJECT_BINARY_DIR}`），或放在 `CMAKE_BINARY_DIR`（app 的 CMake 二进制目录，`app/.cxx/Debug/<hash>/arm64-v8a/`）供 json、kaldi-native-fbank、kaldifst、openfst 使用。文件名必须与脚本里写的完全一致。

本次放入的归档与校验值：

- `json-3.12.0.tar.gz`，`SHA256=4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187`，取自 `hf-mirror.com/csukuangfj/sherpa-ncnn-cmake-deps`
- `kaldi-native-fbank-1.22.3.tar.gz`，`SHA256=9176cc66fc7ce1edf85cf355b06e320c57db6297df74277f575183468893cf61`，取自同一仓库
- `kaldifst-1.7.17.tar.gz`，`SHA256=c4b701a23a400bda8032586b02c7e0d5e813a765832df60c23e6df9e62b010f4`，取自同一仓库
- `openfst-sherpa-onnx-2024-06-19.tar.gz`，`SHA256=5c98e82cc509c5618502dde4860b8ea04d843850ed57e6d6b590b644b268853d`，取自 `hf-mirror.com/csukuangfj/sherpa-onnx-cmake-deps`
- `ncnn-c4193aadbbb56582aa87b1850dd3d98fb8fd936d.zip`，`SHA256=da5563a86045d66ecf34820f82edec67906f988c61ecd3787f7e5df8bdfb43c0`，取自 GitHub 归档镜像
- `kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip`，`SHA256=497103e664168ebe39580b757adbe616f6cf85a16572af581ca7bc42d0ab13fd`，取自 GitHub 归档镜像

每个文件都按脚本声明的 `URL_HASH` 校验过，哈希不符时 FetchContent 自己会拒绝，因此不存在“放错文件也能过”的情况。

## 验证

放入后重新 configure，`_deps/json-src` 直接由本地归档解出 1163 个文件，`json-populate-urlinfo.txt` 中的 `repository` 仍记录为 external project URL，但不再产生网络请求。
