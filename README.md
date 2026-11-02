# Xray Manager 与 PFW

两个独立安装、独立更新的工具，可以在同一台服务器上使用：

| 命令 | 用途 | 安装的程序 |
|---|---|---|
| `xray-m` | Xray 代理节点、分流、Geo 数据、服务管理 | `/usr/local/sbin/xray-m`，入口 `/usr/local/bin/xray-m` |
| `pfw` | nftables TCP/UDP 端口转发 | `/usr/local/bin/pfwd`，入口 `/usr/local/bin/pfw` |

Xray 脚本已移除所有 PFW 部署和清理代码。PFW 采用实际服务器取回、SHA256 一致的 **pfwd 2.1.1 安全事务版**，不再提供旧广州版/香港 Lite 安装器。公开仓库仅包含程序，不包含服务器的转发规则、IP 清单或凭据。

## 1. 独立安装 / 更新 Xray 管理器

以下命令安装管理器并打开 `xray-m`。Xray 核心和节点需要在菜单中主动安装；更新管理器不会自动切换正在运行的核心版本。

### Debian / Ubuntu

```bash
sudo bash -c 'set -e; apt-get update && apt-get install -y curl ca-certificates; t=$(mktemp); trap "rm -f -- $t" EXIT; curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/install-xray.sh" -o "$t"; bash "$t"; xray-m'
```

### Fedora / Rocky / AlmaLinux / RHEL（dnf）

```bash
sudo bash -c 'set -e; dnf install -y curl ca-certificates; t=$(mktemp); trap "rm -f -- $t" EXIT; curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/install-xray.sh" -o "$t"; bash "$t"; xray-m'
```

### CentOS / RHEL（yum）

```bash
sudo bash -c 'set -e; yum install -y curl ca-certificates; t=$(mktemp); trap "rm -f -- $t" EXIT; curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/install-xray.sh" -o "$t"; bash "$t"; xray-m'
```

### Alpine（root 执行）

```bash
apk add --no-cache bash curl ca-certificates jq openssl unzip iproute2 coreutils && bash -c 'set -e; t=$(mktemp); trap "rm -f -- $t" EXIT; curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/install-xray.sh" -o "$t"; bash "$t"; xray-m'
```

已是 root 时去掉 `sudo`。日常运行 `xray-m`；菜单 `3` 手动更新管理器，也可以重跑对应安装命令。安装失败会停止，不直接覆盖正在运行的核心或配置。管理脚本安装备份位于 `/var/tmp/xray-manager-before-install.*`，菜单更新备份为脚本旁的 `.bak.*` 文件。

## 2. 独立安装 / 更新 PFW

当前独立安装器支持 **Ubuntu 22.04+ / Debian 12+、systemd、Python 3.10+**。其他发行版尚未验收；不要把 Xray 的跨发行版支持理解为 PFW 的支持范围。

```bash
sudo bash -c 'set -e; apt-get update && apt-get install -y python3 nftables curl ca-certificates; t=$(mktemp); trap "rm -f -- $t" EXIT; curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/install-pfw.py" -o "$t"; python3 "$t"; pfw'
```

日常运行 `pfw`；更新时重跑这条 PFW 命令。没有自动更新任务，也不依赖 `frank` 或 Xray。

- **首次安装**：创建空转发规则、开启 IPv4 转发、为 nftables 增加开机 include 并启用服务。只应用 `ip pfwd_nat` 表；不执行全局 `flush ruleset`，不重启/重载共享 nftables 服务，也不覆盖原 `/etc/nftables.conf` 内容。
- **已有安全事务版**：校验规则、解析映射、持久化 nft 文件及实时表一致后，只更新程序。保留规则、解析结果、开机配置和实时转发，不重新解析域名或重新应用规则。
- **旧版/不完整安装**：缺少解析映射、状态不一致或发现残留配置时停止；不把旧规则当成空配置覆盖。旧广州账本版本需要单独评估迁移，不能直接强制替换。
- **并发**：菜单和输入等待不持锁，提交、备份和安装事务才持锁；已有写入事务时报告占用者，不删除锁文件。
- **备份**：每次安装在 `/var/backups/pfwd/install-*` 保存被管理文件的原内容。业务规则修改另有事务快照与失败回滚。
- **防火墙**：本工具负责 DNAT/MASQUERADE；云安全组及已有 FORWARD/入口过滤策略需允许所需流量，不自动放开整个防火墙。代理监听端口与转发端口需避免冲突。

常用命令：

```bash
pfw           # 交互菜单：增删改、批量修改、备份与恢复
pfw list      # 查看规则
pfw status    # 检查源文件、解析映射、持久化文件及实时表
pfw backup    # 备份规则和相关状态
pfw apply     # 明确输入 APPLY 后重新解析并原子应用当前规则
```

## 旧 frank 用户迁移

GitHub 发布不会自动改变已经安装的服务器。分别执行需要的安装命令即可安装/更新独立工具；不需要的工具可以不安装。

- 原 `xray_manager.sh` URL 保留，但内容已变为 **Xray 独立管理器**。继续使用旧命令下载成 `frank` 时，也只会显示 Xray 菜单；建议改用上面的 `xray-m` 安装命令。
- 只安装新 `xray-m` 不会自动改写已存在的旧 `frank` 副本；旧副本仍可能包含危险的旧 PFW 部署功能。确认独立入口可用后，可以用以下命令删除旧总入口（不删除 Xray、PFW 或规则）：

```bash
sudo rm -f /usr/local/bin/frank /usr/local/sbin/frank
```

## Xray 功能与版本

支持 SS2022、VLESS Reality、VLESS Encryption、多节点、服务端分流、Geo 更新、配置还原、日志、服务管理及手动 FQ/BBR 设置。基于 [RomanovCaesar/Install-Xray-Inbounds](https://github.com/RomanovCaesar/Install-Xray-Inbounds) 重构。

### Xray 版本策略（Mihomo / Clash Verge）

新安装固定使用 **Xray v26.6.27**，不查询或回退到上游 `latest`。这是针对
Mihomo Reality 兼容性选择的基线，不代表所有功能和环境都没有问题；上游将该发行版标记为 Pre-release。

2026-10-30 已在 Alpine Linux x86_64 上使用官方 SHA256 校验后的二进制验证：
Mihomo 1.19.32、VLESS Reality + Vision、Chrome 指纹，在**不添加**
`support-x25519mlkem768` 的情况下完成 Reality 握手、出口 IP 查询（HTTP 200）
和 Google 连通性测试（HTTP 204）。测试通过回环监听及 SSH 隧道进行，未替换生产核心。
ARM64 下载路径保留，但未实测 ARM64 运行环境。

- 已安装相同版本时直接复用，新增节点不再反复下载或升级核心。
- 已安装其他版本时，先明确确认，再校验目标核心对现有配置的兼容性。
- 替换前将旧核心和现有配置备份到 `/var/backups/xray-manager/`；配置本身不因版本切换而重写。
- 下载、SHA256、版本号或现有配置校验失败时停止，保留原核心。
- 更新管理脚本本身不会自动降级正在运行的 Xray；版本切换发生在后续节点安装流程中，服务由该流程重启。
- 如需回滚，将备份目录内的 `xray` 恢复到 `/usr/local/bin/xray`（先复制为同目录临时文件再移动替换），
  必要时恢复 `config.json` 到 `/usr/local/etc/xray/config.json`，然后按系统执行 `rc-service xray restart` 或 `systemctl restart xray`。

参考：[官方发行版](https://github.com/XTLS/Xray-core/releases/tag/v26.6.27)、
[Mihomo Reality 兼容性说明](https://wiki.metacubex.one/config/proxies/tls/#reality-opts)。

安装器回归验证（无需 root 或网络）：`bash tests/core-install.sh`。

## 验证

Xray 核心安装器有 11 个回归场景；管理器另测独立安装、自身重复安装和手动更新隔离。PFW 包含 7 个锁/事务回归、8 个安装回归，安装回归在独立 Linux 网络命名空间使用真实 nftables，覆盖新装、更新保留规则、开机文件加载、损坏/旧状态拒绝和失败回滚。服务与 sysctl 调用在安装测试中使用桩；未声称完整发行版矩阵验收。

```bash
bash tests/core-install.sh
bash tests/manager-install.sh
python3 tests/test_pfw_lock.py
sudo unshare -n python3 tests/test_pfw_install.py
```

不要绕过网络命名空间保护直接运行 nftables 安装测试。
