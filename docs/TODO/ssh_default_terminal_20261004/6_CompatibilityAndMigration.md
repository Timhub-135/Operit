---
For_Agent: 已发布接口的兼容边界与分仓推进顺序，默认值切换前必须按其执行
---

# 兼容与迁移

## 既有版本状态

当前检出的应用版本是 `versionCode 51 / versionName 1.12.2`（`app/build.gradle.kts:400-401`），官方仓库已有对应的 APK 发行物，因此下面这些接口都按**已发布**对待，必须向前兼容。

## 必须保持的接口

- 终端默认行为：老安装的“本地 Ubuntu 终端”必须继续可用，且未被用户显式切换前不改变其目标
- Agent 工具参数 `environment`：继续接受 `android`、`linux`、`repo:<名称>` 三个取值，`linux` 的字符串形式不变，只更新其描述文本与实现目标
- SSH 配置存储：`SharedPreferences("ssh_config")` 中 `config`／`ssh_enabled` 两个键与 JSON 字段名（`host`、`port`、`username`、`authType`、`password`、`privateKeyPath`、`passphrase`、`enableReverseTunnel`、`remoteTunnelPort`、`localSshPort`、`localSshUsername`、`localSshPassword`）必须能读入并迁移
- 终端偏好：`terminal_settings` 与 `terminal_prefs`（`is_first_launch`）的既有键
- 跨进程契约：`ITerminalService.aidl` 现有方法签名不改，目标选择以新增方法或新增可选参数实现
- ToolPkg：`linux_ssh` 的工具名与变量名（`LINUX_SSH_HOST`、`LINUX_SSH_PORT`、`LINUX_SSH_USERNAME`、`LINUX_SSH_PASSWORD`、`LINUX_SSH_PRIVATE_KEY_PATH`、`LINUX_SSH_TIMEOUT_MS`）保持不变，只替换其执行后端
- 本地环境配置入口：`SetupScreen` 的包安装流程与本地 rootfs 逻辑保留，作为可选目标

## 默认值切换策略

- 全新安装（无 SSH 配置、无终端偏好）：走 SSH 优先引导，“添加主机”是首选项
- 已安装且当前使用本地目标：保持本地目标不变，用一次性提示告知可以切到远端，由用户确认
- 已安装且已启用 SSH 配置：目标本就是 SSH，本次仅把会话路径从“proot + Ubuntu 内 ssh”换成“shell channel 直连”，无需用户操作，但要在更新说明中写明行为变化
- 任何情况下都不做“远端失败自动落本地”

## 已确认决策对兼容的影响

- D1 本地环境继续随包提供，因此不存在“删掉老用户依赖的能力”这一类破坏；变化只在默认目标与首启引导
- D4 rootfs 资产预装 `openssh-client` 后，已装本地环境的用户需要重装才能拿到新资产，属可选升级，不强制
- D5 导出与删除都是显式动作，默认不动用户磁盘上的 rootfs，也不清空用户数据
- D6 `linux` 取值与字符串不变，只有其指向由“本地 Ubuntu”变为“当前 Linux 目标”；老对话与 toolpkg 无需改动
- `environment="linux"` 的描述文本变化会影响已有会话的系统提示词内容，按提示词版本化处理，避免把老对话中的历史描述当作当前事实

## 回滚方式

默认目标是配置值，回滚只需改回默认指向本地目标，不删除任何代码路径。因此本次改动与“回退代码”无关，符合仓库对兜底逻辑的禁止要求。

## 分仓推进顺序

第一步，`OperitTerminalCore`（子模块）

- 新增传输抽象与 SSH channel 提供者，保留 `TerminalType.LOCAL` 与既有 provider 行为
- 新增主机密钥 TOFU 与 known_hosts 存储、凭据加密存储、`SSHConfigManager` 迁移
- 升级 JSch 依赖
- AIDL 仅新增方法，不改既有签名，保证独立 Terminal 应用仍可编译与运行

第二步，主仓库 `Operit`

- 升级子模块引用并声明最低版本
- 目标模型、默认选择、首启引导、设置页与错误呈现
- `SystemToolPrompts` 文案与本地化，`DebuggerFileSystemTools` 等按目标解析路径的调用点
- `MCPDeployer` 按目标解析插件运行时目录
- `linux_ssh` toolpkg 改为调用统一配置与远端目标

第三步，独立变更

- rootfs 资产加入 `openssh-client`（见 [4_LocalUbuntuSshPackaging.md](4_LocalUbuntuSshPackaging.md)），更新资产哈希与第三方许可清单
- 文档：`docs/doc-src` 下补充终端目标与 SSH 使用说明，并同步 i18n

## 需要同步的门禁

- 本地化检查（`ci/script/check_localizations.py`）：`SystemToolPrompts` 与终端字符串的中英双语必须同时更新
- 文档链接检查（`ci/script/check_markdown_links.py`）：本目录新增文档的相对链接
- ToolPkg 同步检查：`linux_ssh` 改动后需重跑 `sync_example_packages.py` 并保持白名单一致
- 如果资产变更：与 rootfs 相关的校验（资产名常量 `TerminalManager.kt:121`、CI 中的相关断言）需一并更新

## 明确不在兼容范围内的部分

- JSch 0.1.55 的算法行为：升级后能连上的服务器更多，属于修复而非破坏；但用户若依赖“不校验主机密钥”，升级后会遇到 TOFU 提示，这是有意为之
- Ubuntu 内由用户自行 `apt install` 的包：不随迁移保留，属于用户态内容
