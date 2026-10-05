---
For_Agent: 默认切到远端 SSH 后的凭据与主机密钥硬化清单
---

# 安全硬化

默认目标改变意味着“更多命令会走到远端主机”，凭据与主机身份校验必须先于默认切换落地。

## 已落地（阶段 2）

- `utils/HostKeyStore.kt`：自实现的 `HostKeyRepository`，known_hosts 落在 `filesDir/ssh/known_hosts`，格式与 OpenSSH 一致（`主机名 密钥类型 Base64公钥`），支持列出与忘记条目
- `SSHFileConnectionManager` 把 `StrictHostKeyChecking` 从 `no` 改为 `yes`，并装入该存储；未知主机与指纹变化都会中断连接
- 未知主机与指纹变化的差异用 `HostKeyChallenge` 表达，连接失败时返回 `HostKeyVerificationException`，指纹按 OpenSSH 的 `SHA256:` 形式给出，便于与 `ssh-keygen -lf` 对照
- `TerminalManager` 把待确认的主机密钥发布为 `pendingHostKey` 状态，提供 `trustPendingHostKey()`（写入 known_hosts 后重试会话）与 `dismissPendingHostKey()`
- 终端界面新增指纹确认弹窗：未知主机展示“首次连接”，指纹变化展示中间人风险提示，确认按钮在变化场景下用警示色
- `utils/SecretStore.kt`：Android Keystore 中的 AES-256-GCM 密钥加密凭据，落盘只有 IV 与密文
- `SSHConfigManager`：密码、私钥口令、手机侧 SSHD 口令一律加密保存，读取到旧版明文格式时就地加密改写（`secretFormat=keystore-gcm`），解密失败时返回空由用户重新输入
- 删除硬编码口令：`SSHConfig.localSshPassword` 默认值改为空并由管理器每安装随机生成；`ConnectionParams.localSshPassword` 不再有 `"ubuntu"` 默认值

## 尚未落地

- known_hosts 的导入导出与设置页查看入口（存储层已提供 `knownHostKeys()`／`forgetHostKeys()`）
- 私钥导入校验与应用内生成密钥对
- 会话级 `IdentitiesOnly`、隧道开关的默认值与暴露面提示

## 主机密钥

问题

- JSch 会话配置 `StrictHostKeyChecking=no`（`terminal/.../utils/SSHFileConnectionManager.kt:177`）
- 命令行路径同样显式关闭（`terminal/.../provider/type/SSHTerminalProvider.kt:228`、`SSHFileConnectionManager.kt:492` 与 `:506`）
- 全仓库没有 known_hosts 或 TOFU 逻辑，中间人可无感替换主机

目标

- 首次连接走 TOFU：展示主机、端口、算法与指纹，由用户确认后写入 known_hosts
- 指纹变化时**硬失败**并提示可能的中间人风险，不提供“忽略并继续”的默认路径
- 主机密钥库可查看与删除条目；支持从 `~/.ssh/known_hosts` 导入导出
- mwiede/jsch 自带 `HostKeyRepository`/known_hosts 支持，可直接作为存储后端

## 凭据存储

问题

- `SSHConfigManager` 把配置以 JSON 明文写入 `SharedPreferences("ssh_config")`，含密码与私钥口令（`terminal/.../utils/SSHConfigManager.kt:55-67`、`:118-134`）
- 密钥口令同理

目标

- 凭据迁入 Android Keystore 保护的存储：应用中已有 `androidx.security:security-crypto`（`app/build.gradle.kts:827`），终端模块按需引入；或以 Keystore 的 AES-GCM 密钥封装后自行落盘
- 迁移策略：升级后首次读取旧配置时解密迁移并清除旧键；迁移失败时不静默丢弃，提示用户重新输入
- 私钥文件默认只读写应用私有目录，导入时校验权限与格式

## 硬编码与默认口令

问题

- `SSHConfig.kt:18` 的 `localSshPassword = "3688368398"`，并同样出现在 `SSHConfigScreen.kt:232`
- `SSHFileConnectionManager.kt:97` 的默认 `localSshPassword = "ubuntu"`
- 手机侧 sshd 的用户名与口令直接取配置值（`SSHDServerManager.kt:92-95`）

目标

- 删除硬编码默认口令，首次启用时生成每安装随机口令并展示给用户
- 手机侧 sshd 默认只监听回环；反向隧道需要显式开启，并在开启时说明暴露面
- 已保存旧默认口令的安装按迁移规则处理：视为不安全，提示重置

## 认证方式

- 优先密钥认证：支持导入 OpenSSH/PEM 私钥（含带口令的 ed25519），支持在应用内生成 ed25519 密钥对并导出公钥
- 密码认证保留，但不再经过 `sshpass -p` 之类暴露 argv 的方式；channel 直连后口令只存在于内存
- 会话级 `IdentitiesOnly`、`ServerAliveInterval` 等参数在远端路径上保持现有行为

## 端口转发与隧道的暴露面

- 本地转发（`localForwardPort` → `remoteForwardPort`，默认 8751 → 8752）与反向隧道（`remoteTunnelPort`、`localSshPort`）默认值要与实际用途对齐：MCP 桥需要，其他场景默认关闭
- 转发规则在 UI 上可查看，可单独关闭；开启反向隧道时提示“远端可访问本机 sshd”
- 手机侧 SFTP 根目录限定在应用允许的目录（现为 `VirtualFileSystemFactory`，需确认根路径不会暴露全盘）

## 交付顺序

主机密钥校验与凭据迁移先落地，默认目标切换在后。否则用户会在“默认把命令发往远端”的第一天就遇到没有主机身份校验的状态。
