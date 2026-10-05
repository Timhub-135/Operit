---
For_Agent: 记录 cmake/operit_git_source.cmake 的镜像前缀开关，改动行为或默认值时同步更新
---

# CMake 侧 GitHub 镜像前缀

## 旧实现

`cmake/operit_git_source.cmake` 把仓库地址写死成 `https://github.com/...`：

- `operit_resolve_git_ref` 直接 `git ls-remote "${repository}"`
- `operit_github_archive_url` 用正则把仓库地址改写成 `https://github.com/<owner>/<repo>/archive/<sha>.tar.gz`

两条路径都必须能访问 `github.com`。该模块由 app、`quickjs`、`avator/dragonbones`、`avator/mmd`、`avator/fbx`、`llm/mnn`、`llm/llama` 分别 include，各自在独立的 CMake configure 中运行，因此不能靠给单个模块传参解决。

## 新实现

新增一个可配置前缀，原样拼在每个 GitHub URL 前面：

```cmake
set(
    OPERIT_GITHUB_URL_PREFIX
    "$ENV{OPERIT_GITHUB_URL_PREFIX}"
    CACHE STRING "Prefix prepended to GitHub URLs fetched by this module"
)
```

- `git ls-remote` 使用 `${OPERIT_GITHUB_URL_PREFIX}${repository}`，镜像若支持 Git 智能 HTTP 即可解析 ref
- 归档地址由原来的 `"\1/\2/archive/..."` 改写为 `"${OPERIT_GITHUB_URL_PREFIX}https://github.com/\1/\2/archive/..."`

选择拼接而不是分支判断，是因为前缀为空字符串时结果就是原来的规范 URL，GitHub 直连环境与 CI 的行为逐字节不变，不需要任何回退分支。

## 为什么读环境变量

CMake 在每个原生模块里各跑一次，环境变量是唯一能一次设置、全部继承的入口：

- `OPERIT_GITHUB_URL_PREFIX=https://ghfast.top/ ./gradlew :app:assembleDebug`
- 也可显式传 `-DOPERIT_GITHUB_URL_PREFIX=https://ghfast.top/`

## 验证

- 镜像前缀下的 ref 解析：`git ls-remote https://ghfast.top/https://github.com/k2-fsa/sherpa-ncnn.git master` 返回 `c61e50d61e9fbed5972afa4d95bc560e168affe2`
- 归档下载：`file(DOWNLOAD "https://ghfast.top/https://github.com/k2-fsa/sherpa-ncnn/archive/refs/heads/master.tar.gz")` 返回状态 0
- 不设置前缀时，`OPERIT_GITHUB_URL_PREFIX` 为空，URL 与改动前一致
