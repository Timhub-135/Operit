---
For_Agent: 记录无 MSVC 的 Windows 构建机上编译 MNN 宿主机 flatc 的失败原因与解法
---

# Windows 宿主机工具链

## 症状

`:mnn:configureCMakeDebug[arm64-v8a]` 失败，报错来自 `llm/mnn/CMakeLists.txt` 的宿主 `flatc` 构建：

```text
Failed to build the host FlatBuffers compiler for MNN schema generation.
FAILED: CMakeFiles/flatc.dir/src/reflection.cpp.obj
D:\Tools\Android\Sdk\ndk\27.0.12077973\toolchains\llvm\prebuilt\windows-x86_64\bin\clang++.exe
  -std=c++0x ... -stdlib=libc++ -fsigned-char -O3 -DNDEBUG -Wold-style-cast
fatal error: 'cstdint' file not found
```

## 原因

`llm/mnn/CMakeLists.txt` 通过 `execute_process` 再起一个 `cmake -S -B` 来编宿主机 `flatc`，该子进程继承父 `cmake` 的环境。AGP 为 Android 原生构建准备的环境里 `CC`、`CXX`、`CXXFLAGS` 指向 NDK 的 `clang++` 与 `-stdlib=libc++`，于是宿主机程序被交给 Android 编译器编译，既没有宿主 C++ 头，也带着 Android 的编译参数。

仅在 Gradle 外层设置 `CC`/`CXX` 无法覆盖 AGP 注入的值，因此从外部环境入手不可靠。

## 解法

用工具链文件显式钉住宿主机编译器，并通过环境变量 `CMAKE_TOOLCHAIN_FILE` 让子 `cmake` 采纳：

- CMake 3.22.1 会读取环境变量 `CMAKE_TOOLCHAIN_FILE`
- Android 侧的 configure 由 AGP 传 `-DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/android.toolchain.cmake`，命令行参数优先于环境变量，因此 Android 编译链不受影响

实测验证：

- 环境变量与 `-D` 同时给出不同工具链文件时，CMake 加载的是 `-D` 指定的那个
- 在 `CC`/`CXX`/`CXXFLAGS` 全部指向 NDK clang 的环境下，带工具链文件的 configure 识别出的编译器为 `GNU 16.2.0`，编出并链接成功
- 工具链文件内用 `CACHE ... FORCE` 覆盖 `CMAKE_C_FLAGS`、`CMAKE_CXX_FLAGS`，因此继承来的 `-stdlib=libc++` 等参数不会进入宿主机编译

## 注意事项

- 修改工具链文件或更换编译器后必须删除 `llm/mnn/.cxx/operit_deps/mnn-<sha>-build/flatc-host`，否则 CMake 沿用旧的编译器缓存
- MinGW 的 `bin` 需留在 `PATH`，`flatc.exe` 运行期依赖 `libstdc++-6.dll` 与 `libgcc_s_seh-1.dll`
- 该目录位于 `.cxx`，已被 `.gitignore` 忽略，删除无副作用
