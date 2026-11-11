# SUIOK — s-ui 一键部署

在一台**空的** Debian / Ubuntu 服务器上，填一个域名，自动部署出整套 [s-ui](https://github.com/alireza0/s-ui) 面板和节点：

- **HTTPS 全自动**：acme.sh 申请 Let's Encrypt 证书，自动续期，续期后自动重启 s-ui
- **面板 / 订阅**：随机端口 + 随机路径 + 随机管理员账号密码
- **5 个节点**（共用一个订阅）：

| 节点 | 传输 | 特点 |
|---|---|---|
| VLESS + Reality + Vision | TCP | 最隐蔽，借用 `swdist.apple.com` 的 TLS 握手，探测看到的是苹果证书 |
| Hysteria2 | UDP | HTTP/3，被探测时返回苹果官网（masquerade） |
| TUIC v5 | UDP | HTTP/3，BBR 拥塞控制 |
| Trojan | TCP | 正式证书 TLS |
| VMess | TCP | 正式证书 TLS |

- **自动跟踪官方版本**：GitHub Actions 每天检查 s-ui 最新正式版，校验发布文件齐全后自动更新 `deploy.sh` 里的版本号

## 使用

### 1. 准备

1. 一台空服务器（Debian 11+ / Ubuntu 20.04+，root 权限）
2. 一个域名，添加 **A 记录** 指向服务器 IP
   - Cloudflare 用户：必须是 **仅 DNS（灰色云朵）**，不能开代理
3. 云厂商安全组放行 **TCP 80**（申请/续期证书）和所有端口（或部署完按输出放行）

### 2. 一键部署

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chaow0879-collab/SUIOK/main/deploy.sh) 你的域名
```

例如：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chaow0879-collab/SUIOK/main/deploy.sh) node1.example.com
```

大约 2~3 分钟后会输出：

```
面板地址  : https://node1.example.com:xxxxx/随机路径/
面板账号  : adminxxxxx
面板密码  : xxxxxxxxxxxxxxxxxxxx
订阅地址  : https://node1.example.com:xxxxx/随机路径/node1-xxxxxx
```

这些信息同时保存在服务器的 `/root/sui-info.txt`。

### 3. 客户端

v2rayN → 订阅分组 → 添加 → 填入「订阅地址」→ 更新订阅。

> v2rayN 若 Hysteria2 测速为 -1：设置 → 参数设置 → Core 类型设置，把 Hysteria2 改为 `sing_box`。

## 可选参数

| 参数 | 说明 |
|---|---|
| `--email you@mail.com` | 证书通知邮箱，默认 `admin@域名` |
| `--version v1.6.7` | 指定 s-ui 版本（默认用脚本内的 `SUI_VERSION`） |
| `--reality-target host` | Reality 借用的网站，默认 `swdist.apple.com`（需支持 TLS1.3 + H2） |
| `--skip-dns-check` | 跳过域名解析检查 |
| `--force` | 已安装 s-ui 时仍继续（会新增一套配置，旧服务器慎用） |

## 日常维护

| 操作 | 命令 |
|---|---|
| 查看部署信息 | `cat /root/sui-info.txt` |
| s-ui 菜单 | `s-ui` |
| 查看日志 | `journalctl -u s-ui -f` |
| 手动续期证书 | `~/.acme.sh/acme.sh --renew -d 你的域名 --ecc --force` |
| 升级 s-ui | 面板「设置」里一键更新，或 `s-ui update` |
| 备份数据库 | `cp /usr/local/s-ui/db/s-ui.db ~/s-ui.db.bak` |

## 版本自动跟踪

`.github/workflows/track-sui.yml` 每天北京时间 04:17 运行：

1. 查询 `alireza0/s-ui` 最新正式版
2. 确认 amd64 / arm64 安装包和 `SHA256SUMS` 都已发布，官方安装脚本交互流程没变
3. 更新 `deploy.sh` 的 `SUI_VERSION` 并提交，记录到 `CHANGELOG.md`

也可以在 GitHub 仓库的 **Actions → 跟踪 s-ui 官方版本 → Run workflow** 手动触发。

> 只影响**之后新部署**的服务器；已部署的服务器请用面板或 `s-ui update` 升级。

## 安全说明

- 官方安装脚本会校验 s-ui 安装包的 SHA256
- 管理员账号、密码、端口、路径、节点密钥全部随机生成，只保存在服务器 `/root/sui-info.txt`（权限 600）
- 订阅地址等同于全部节点密码，不要公开
