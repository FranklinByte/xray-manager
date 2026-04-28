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
- 一级菜单可一键彻底清理 Xray / PFW 分支痕迹
- 命令分层：`frank` 进入一级菜单，`xray-m` 直达 Xray 分支，`pfw` 直达 PFW
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

推荐安装为一级总控命令 `frank`：

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh -o /usr/local/sbin/frank && chmod 755 /usr/local/sbin/frank && ln -sf /usr/local/sbin/frank /usr/local/bin/frank && frank'
```

> `frank` 进入一级总菜单；`xray-m` 只在你进入 Xray 分支并主动安装/修复后才存在；`pfw` 由 PFW 分支部署后提供。

## 已部署旧版本如何更新

### 方式 1：直接覆盖脚本（通用）

```bash
curl -fsSL -o xray_manager.sh https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh
chmod +x xray_manager.sh
sudo bash xray_manager.sh
```

### 方式 2：已安装 `frank` 命令时

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/FranklinByte/xray-manager/main/xray_manager.sh -o /usr/local/sbin/frank && chmod 755 /usr/local/sbin/frank && ln -sf /usr/local/sbin/frank /usr/local/bin/frank && frank'
```

### 命令入口说明

- `frank`：一级总控菜单
- `xray-m`：直达 Xray 分支（需要在 Xray 分支内主动安装）
- `pfw`：直达 PFW（部署广州版或香港版后自动提供）

> 如果你的机器需要严格避免 Xray 痕迹，请只使用 `frank` 进入一级菜单后选择 PFW 分支；不要进入 Xray 分支安装/修复 `xray-m`。

## 发行版兼容性

- Debian 11/12：✅ 支持
- Ubuntu 20.04/22.04/24.04：✅ 支持
- Alpine 3.x：✅ 支持
- CentOS / RHEL / Rocky / AlmaLinux / Fedora：✅ 支持（自动识别 dnf / yum）

## 系统要求

- Linux (x86_64 / arm64)
- Root 权限
- 依赖：`jq` `curl` `openssl` `unzip`（脚本会自动安装）
