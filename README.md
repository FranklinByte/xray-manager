# Xray Local Manager

## 安装 / 更新并运行

### Debian / Ubuntu

```bash
sudo bash -c 'apt-get update && apt-get install -y curl ca-certificates && mkdir -p /usr/local/sbin /usr/local/bin && curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh?ts=$(date +%s)" -o /usr/local/sbin/frank && chmod 755 /usr/local/sbin/frank && ln -sf /usr/local/sbin/frank /usr/local/bin/frank && frank'
```

### Fedora / Rocky / AlmaLinux / RHEL / CentOS Stream（dnf）

```bash
sudo bash -c 'dnf install -y curl ca-certificates && mkdir -p /usr/local/sbin /usr/local/bin && curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh?ts=$(date +%s)" -o /usr/local/sbin/frank && chmod 755 /usr/local/sbin/frank && ln -sf /usr/local/sbin/frank /usr/local/bin/frank && frank'
```

### CentOS / RHEL（使用 yum 的版本）

```bash
sudo bash -c 'yum install -y curl ca-certificates && mkdir -p /usr/local/sbin /usr/local/bin && curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh?ts=$(date +%s)" -o /usr/local/sbin/frank && chmod 755 /usr/local/sbin/frank && ln -sf /usr/local/sbin/frank /usr/local/bin/frank && frank'
```

### Alpine（root 执行）

```sh
apk add --no-cache bash curl ca-certificates jq openssl unzip iproute2 coreutils && bash -c 'mkdir -p /usr/local/sbin /usr/local/bin && curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh?ts=$(date +%s)" -o /usr/local/sbin/frank && chmod 755 /usr/local/sbin/frank && ln -sf /usr/local/sbin/frank /usr/local/bin/frank && frank'
```

> 已是 root 的用户，执行上面的其他系统命令时去掉开头的 `sudo`。Alpine 非 root 用户先执行 `su -` 切换到 root。

## 日常使用 / 更新

安装后，以 root 身份运行 `frank` 打开一级总菜单，选择 `5. 手动更新管理脚本` 即可更新。旧版没有更新选项时，重新执行上方对应系统的命令。

- `frank`：一级总控菜单
- `xray-m`：直达 Xray 分支（需要在 Xray 分支内主动安装）
- `pfw`：直达 PFW（部署广州版或香港版后自动提供）

> 进入 Xray / PFW 分支只显示分支菜单，不会自动下载或创建该分支文件；只有主动选择安装/部署才会写入对应分支内容。未安装分支时，实际功能菜单会拒绝进入。

## 项目说明

Xray 本地化一键管理工具，基于 [RomanovCaesar/Install-Xray-Inbounds](https://github.com/RomanovCaesar/Install-Xray-Inbounds) 重构。

## 与原版的区别

| | 原版 | 本版 |
|---|---|---|
| 架构 | 主脚本 + 7 个远程子脚本，每次从 GitHub 下载执行 | **单文件**，所有功能本地运行 |
| 远程代码执行 | 每次点菜单都 `curl` 拉脚本并 root 执行 | **完全移除**，无任何远程脚本下载 |
| 自动更新 | 有，可远程覆盖 `/usr/bin/` 下的脚本 | **完全移除**，无自动更新通道 |
| Xray 二进制校验 | 无 | **SHA256 校验**（对比官方 `.dgst` 文件） |
| 配置文件权限 | `644`（全局可读，含私钥） | `600`（仅 root 可读） |

## 保留的网络请求

仅保留以下必要的官方上游请求：

- `github.com/XTLS/Xray-core` — 下载 Xray 二进制（带 SHA256 校验）
- `github.com/Loyalsoldier/v2ray-rules-dat` — GeoIP / GeoSite 数据
- `ipinfo.io` / `api.ipify.org` — 获取公网 IP（生成分享链接用）

## 支持的协议

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

### 协议列表

- Shadowsocks 2022 (SS)
- VLESS Reality
- VLESS Encryption (Post-Quantum, ML-KEM-768)

## 功能

- 安装 / 管理 / 删除各协议节点
- 多协议多节点共存
- 服务端分流 (Routing) 配置
- GeoIP / GeoSite 数据更新（支持 crontab 定时）
- 自定义连接地址（NAT / DDNS 场景）
- 配置还原（URL 下载 / 手动编辑 / 测试）
- 一级菜单直接提供网络优化（开启 FQ / BBR）
- 一级总菜单（Xray 分支 / PFW 分支）
- PFW 套件部署（广州版/香港 Lite，自动开启 IPv4 转发）
- 手动更新本脚本（菜单内）
- 一级菜单可一键彻底清理 Xray / PFW 分支痕迹
- 命令分层：`frank` 进入一级菜单，`xray-m` 直达 Xray 分支，`pfw` 直达 PFW
- Xray / PFW 可按需单独安装、同机共存，并支持分支级彻底清理
- 未安装分支时禁止进入对应实际功能菜单，避免生成相关文件
- 完整卸载
- 适配 Debian / Ubuntu / Alpine / CentOS 系（systemd / OpenRC）

## 发行版兼容性

- Debian 11/12：✅ 支持
- Ubuntu 20.04/22.04/24.04：✅ 支持
- Alpine 3.x：✅ 支持
- CentOS / RHEL / Rocky / AlmaLinux / Fedora：✅ 支持（自动识别 dnf / yum）

## 系统要求

- Linux (x86_64 / arm64)
- Root 权限
- 依赖：`jq` `curl` `openssl` `unzip`（脚本会自动安装）
