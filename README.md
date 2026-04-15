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
- 完整卸载
- 适配 Debian / Ubuntu / Alpine (systemd / OpenRC)

## 安装使用

```bash
curl -Lo xray_manager.sh https://raw.githubusercontent.com/<你的用户名>/xray-manager/main/xray_manager.sh
chmod +x xray_manager.sh
sudo bash xray_manager.sh
```

或直接：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/xray-manager/main/xray_manager.sh)"
```

## 系统要求

- Linux (x86_64 / arm64)
- Root 权限
- 依赖：`jq` `curl` `openssl` `unzip`（脚本会自动安装）
