# Usque WARP 一键脚本

一个为 **IPv6-only VPS** 提供 IPv4 访问能力的自动化管理脚本。基于 [usque](https://github.com/Diniboy1123/usque) 项目，使用 Cloudflare WARP 的 MASQUE 协议建立隧道，使用 **Native Tunnel Mode** 提供最高的性能。

## ✨ 特性

- 🚀 **一键安装** - 自动完成下载、注册、配置、启动全流程
- 🌐 **IPv6-only 完美支持** - 自动检测并修复 IPv6-only 环境
- ⚡ **WARP+ 支持** - 通过密钥激活 WARP+ 获得更好的性能
- 🔄 **自动重连** - 定时监控网络连通性，故障自动重启
- 📦 **多镜像源** - 内置多个 GitHub 镜像，解决下载困难问题
- 🛡️ **完整卸载** - 一键清理所有安装内容，恢复系统原状

## 📋 系统要求

- **操作系统**: Linux (Debian/Ubuntu)
- **架构**: amd64, arm64
- **权限**: root
- **网络**: IPv6 连接（用于 IPv6-only VPS）或 IPv4/双栈
- **依赖**: curl, unzip, jq, iproute2, iptables（脚本会自动安装）

## 🚀 快速开始

### 一键安装

```bash
wget -N --no-check-certificate "https://raw.githubusercontent.com/Joseph-ink/usque-easy/main/usque-easy.sh" && chmod +x usque-easy.sh && ./usque-easy.sh
```

### 交互式菜单

```bash
sudo ./usque-easy.sh
```

## 📖 使用说明

### 命令行参数

| 参数 | 说明 |
|------|------|
| `install` | 完整安装 |
| `uninstall` | 卸载 |
| `status` | 查看状态 |
| `test` | 测试连接 |
| `fix-ipv6` | 修复 IPv6-only 环境 endpoint |
| `warp-plus` | 激活 WARP+ |
| `watchdog-on` | 启用定时监控 |
| `watchdog-off` | 禁用定时监控 |
| `watchdog-status` | 查看监控状态 |

### 交互式菜单选项

```
基础功能
  1) 完整安装 (推荐首次使用)
  2) 仅下载/更新二进制文件
  3) 仅注册WARP账号
  4) 配置Systemd服务

新增功能
  5) 修复IPv6-only环境 (修改endpoint)
  6) 启用WARP+ (输入密钥)
  7) 设置定时监控 (每5分钟检测)
  8) 移除定时监控

运维功能
  9) 测试连接
 10) 查看状态
 11) 重启服务
 12) 查看日志
 13) 查看监控日志
 14) 卸载
```

## 🙏 致谢

- [usque](https://github.com/Diniboy1123/usque) - 核心 WARP MASQUE 客户端
- [Cloudflare WARP](https://1.1.1.1/) - 提供免费的 VPN 服务

## 📄 许可证

MIT License
