# Xray Local Manager

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
- 网络优化（开启 FQ / BBR）
- 一级总菜单（Xray 分支 / PFW 分支）
- PFW 套件部署（广州版/香港 Lite）
- 手动更新本脚本（菜单内）
- 管理器命令与环境清理（安装/删除 xray-m、清理脚本环境改动）
- Xray / PFW 安装互斥保护（避免同机混装）
- 完整卸载
- 适配 Debian / Ubuntu / Alpine / CentOS 系（systemd / OpenRC）

## 安装使用

```bash
curl -Lo xray_manager.sh https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh
chmod +x xray_manager.sh
sudo bash xray_manager.sh
```

或直接：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh)"
```

可选安装为命令（仅在你主动进入 Xray 分支并选择安装时使用）：

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh -o /usr/local/sbin/xray-m && chmod 755 /usr/local/sbin/xray-m && /usr/local/sbin/xray-m'
```

> 脚本默认进入一级总菜单，只显示 Xray / PFW 两个分支状态；不主动安装 Xray。

## 已部署旧版本如何更新

### 方式 1：直接覆盖脚本（通用）

```bash
curl -fsSL -o xray_manager.sh https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh
chmod +x xray_manager.sh
sudo bash xray_manager.sh
```

### 方式 2：已安装 `xray-m` 命令时

```bash
sudo curl -fsSL https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh -o /usr/local/sbin/xray-m
sudo chmod 755 /usr/local/sbin/xray-m
sudo xray-m
```

> 如果你的机器需要严格避免 Xray 痕迹，请只进入 PFW 分支操作；不要进入 Xray 分支安装/修复 `xray-m`。

## 发行版兼容性

- Debian 11/12：✅ 支持
- Ubuntu 20.04/22.04/24.04：✅ 支持
- Alpine 3.x：✅ 支持
- CentOS / RHEL / Rocky / AlmaLinux / Fedora：✅ 支持（自动识别 dnf / yum）

## 系统要求

- Linux (x86_64 / arm64)
- Root 权限
- 依赖：`jq` `curl` `openssl` `unzip`（脚本会自动安装）
