---
For_Agent: 终端 SSH 远程目标的测试夹具说明，改动镜像或端口时同步更新
---

# SSH 测试主机

给终端模块的远程目标与反向隧道做端到端测试用的最小 sshd 容器，基于 `ubuntu:latest`，只装 sshd 与几个常用工具，不引入任何 Operit 侧的依赖。

## 用途

- 验证交互式 SSH 会话：PTY、窗口尺寸变更、退出码、长任务（tmux）
- 验证文件系统与隐藏执行：SFTP、exec 通道
- 验证反向隧道：容器侧通过转发端口连回手机端内置 SSHD

## 构建与启动

```bash
docker build -t operit-ssh-test tools/ssh_test_host
docker volume create operit-ssh-test-keys
docker run -d --name operit-ssh-test \
  -p 2222:22 \
  -v operit-ssh-test-keys:/etc/ssh \
  operit-ssh-test
```

- 默认测试账号：`operit` / `operit-test`
- 主机密钥放在卷 `operit-ssh-test-keys` 里，容器重建后指纹不变，不会把已经信任过的条目变成“指纹变化”
- 从 Android 模拟器访问宿主机的端口用 `10.0.2.2:2222`；真机同一局域网时用宿主机的内网地址

## 与测试的对应关系

- 密码认证：用上面的默认账号
- 公钥认证：把测试公钥写进容器 `/home/operit/.ssh/authorized_keys`（例如 `docker exec` 或构建时注入）
- 主机密钥挑战：删除卷里的 `ssh_host_*` 后重建容器可复现“首次连接”；`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 的输出应与应用弹窗里的 `SHA256:` 指纹一致
- 反向隧道：容器侧 `ssh -p 8881 android@127.0.0.1` 连回手机端 SSHD（端口取应用配置里的 `remoteTunnelPort`）

## 清理

```bash
docker rm -f operit-ssh-test
docker volume rm operit-ssh-test-keys
```
