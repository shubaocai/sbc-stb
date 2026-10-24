# sbc-stb

> [鼠宝财](https://blog.mopush.cn) · 一键部署 [Stb 图床](https://github.com/setube/stb)（多用户图床 / 10 种存储后端，VPS / 云服务器，Docker）

给 [Stb 图床](https://github.com/setube/stb) 配套的一键部署脚本：**一条命令**在干净的 Linux 服务器上把图床跑起来 —— 装 Docker、生成配置、拉官方镜像、启动「应用 + MongoDB」两个容器，**自动建好管理员并处理掉上游两个会直接导致上传失败的问题**，最后把「访问地址 + 随机管理员密码 + 运维命令」打在屏幕上。

脚本不重新构建镜像，直接使用上游发布的 `setube/stb` 镜像，因此 1 核 1G 的小机器也能跑（实测两个容器合计约 305MB）。

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Docker-blue)
![Upstream](https://img.shields.io/badge/upstream-Stb%20图床-orange)
![Stack](https://img.shields.io/badge/stack-Node.js%20%7C%20Express%20%7C%20MongoDB-4DB33D)

---

## 目录

- [Stb 图床是什么](#stb-图床是什么)
- [这个脚本做什么](#这个脚本做什么)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [参数](#参数)
- [装完做三件事](#装完做三件事)
- [脚本修掉的两个上游坑](#脚本修掉的两个上游坑)
- [执行流程](#执行流程)
- [部署后的目录结构](#部署后的目录结构)
- [常用运维命令](#常用运维命令)
- [升级](#升级)
- [备份与恢复](#备份与恢复)
- [常见问题](#常见问题)
- [安全建议](#安全建议)
- [其他部署方式（不走本脚本）](#其他部署方式不走本脚本)
- [卸载](#卸载)
- [合规与协议](#合规与协议)
- [License](#license)

---

## Stb 图床是什么

一个**功能相当完整的多用户图床系统**：注册/邀请码、游客上传、相册、图片广场、角色组权限、API、水印压缩、图片鉴黄、上传日志、IP 黑名单、每日限额。

| 能力 | 说明 |
| --- | --- |
| 图片处理 | 质量与压缩、文字/图片水印、指定宽高、格式转换、最小宽高限制、自动缩略图 |
| 用户体系 | 开放注册 / 关闭注册 / 邀请码注册、游客上传、第三方社会化登录、个人主页 |
| 权限 | **角色组**（管理员 / 普通用户 / 游客），每组可独立配置容量、格式、尺寸、水印、**存储策略** |
| 管理 | 图片与相册管理、图片广场（可开关）、上传日志、IP 黑名单、日上传次数、公告、系统配置、站点统计 |
| 接口 | 完整 REST API（上传 / 管理图片 / 管理全站），可对接你自己的系统 |
| 合规辅助 | 图片鉴黄（接入阿里云内容安全；未配置时仅记录状态） |
| **存储后端（10 种）** | 阿里云 OSS、腾讯云 COS、S3 兼容、七牛云、又拍云、SFTP、FTP、WebDAV、GitHub、**Telegram**（用频道当免费图床） |
| 技术栈 | 后端 Node.js + Express + Mongoose，前端 Vue，数据库 **MongoDB** |

## 这个脚本做什么

| 步骤 | 内容 |
| --- | --- |
| 1/8 检查依赖 | 校验 root，缺 `curl / openssl / python3` 按发行版补装 |
| 2/8 安装 Docker | 已有且守护进程可用则**直接跳过**；否则依次探测 5 个软件源（腾讯云内网 / 腾讯云公网 / 阿里云 / 中科大 / 官方），腾讯云机器自动写镜像加速 |
| 3/8 检查端口 | 默认 `25519`，被自己容器占用则复用，被别人占用直接报错退出 |
| 4/8 生成配置 | 写 `docker-compose.yml`：`setube/stb` + `mongo:7`（**缓存按内存自动限制 256~512MB**）；随机 `JWT_SECRET`；随机管理员密码 `SBC` + 8 位十六进制 |
| 5/8 拉取镜像 | 官方镜像 + `mongo:7`（**不在本机构建**，小鸡无压力；中断可续传） |
| 6/8 启动并等待 | `docker compose up -d`，轮询首页直到 HTTP 200（最长 3 分钟） |
| 7/8 初始化站点 | 注册第一个账号为**创始人/管理员**、修角色组容量、写 `site.url`（可选写站点标题） |
| 8/8 汇总 | 打印访问地址、管理员账号密码、凭据文件、放行端口、安全提醒与常用命令 |

**可重复执行（幂等）**：重跑会复用 `.credentials` 里的 JWT 与管理员密码、保留全部数据，只补齐缺失的步骤。

**镜像/数据分离**：镜像只有两个，业务数据全在 `/opt/stb/data`，备份就是打包这个目录。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Linux（需 systemd），Ubuntu 22.04 已实测 |
| 权限 | root（或 `sudo`） |
| 内存 | 实测 `stb` 约 220MB + `stb-mongo` 约 85MB ≈ **305MB**；1 核 1G 可跑，2G 更稳 |
| 磁盘 | ≥ 5GB（镜像 813MB + 1.18GB，其余留给图片与数据库） |
| 端口 | 默认 `25519`，需在云厂商**安全组放行** |
| 网络 | 能拉 Docker Hub 镜像（国内慢可配镜像加速，脚本会在腾讯云机器上自动配） |

## 快速开始

```bash
curl -fsSL -o /tmp/stb.sh https://raw.githubusercontent.com/shubaocai/sbc-stb/main/install_stb.sh && sudo bash /tmp/stb.sh
```

`raw.githubusercontent.com` 时通时不通的话，换 jsDelivr：

```bash
curl -fsSL -o /tmp/stb.sh https://cdn.jsdelivr.net/gh/shubaocai/sbc-stb@main/install_stb.sh && sudo bash /tmp/stb.sh
```

或者 clone 下来跑：

```bash
git clone https://github.com/shubaocai/sbc-stb.git
cd sbc-stb
sudo bash install_stb.sh
```

常用：

```bash
# 指定端口 + 装完自动上传一张测试图自检
sudo bash install_stb.sh --port 8081 --selftest

# 指定管理员密码 / 站点名称
sudo bash install_stb.sh --admin-pass 'MyPass123' --title '我的图床'

# 全部参数
sudo bash install_stb.sh --help
```

跑完重点信息在最底部：

```
  ────────────────────────────────────────────────────────────
   Stb 图床 部署完成
  ────────────────────────────────────────────────────────────
    访问地址   http://<你的公网IP>:25519/
    管理员     admin / SBC3f9c1a04
    凭据文件   /opt/stb/.credentials（600）
    数据目录   /opt/stb/data（uploads 图片 / mongo 数据库）

    必须放行 25519 端口（云厂商安全组）
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `--port N` | 对外端口（默认 `25519`） |
| `--dir PATH` | 安装目录（默认 `/opt/stb`） |
| `--admin-user NAME` | 管理员用户名（默认 `admin`） |
| `--admin-pass PASS` | 管理员密码（默认随机生成 `SBC` + 8 位十六进制） |
| `--title TEXT` | 站点名称（写入数据库，后台也可改） |
| `--selftest` | 装完自动上传一张测试图并访问它（验证全链路） |
| `--recreate` | 强制重建容器（残留容器不健康时用） |
| `--upgrade` | 拉取最新镜像并重建（数据与凭据保留） |
| `--uninstall` | 卸载：删容器、Mongo 数据、图片与目录（需 `--yes`） |
| `-h, --help` | 显示帮助 |

环境变量（可选）：

| 变量 | 说明 |
| --- | --- |
| `STB_IMAGE` | 覆盖应用镜像，如 `STB_IMAGE=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/setube/stb:latest` |
| `MONGO_IMAGE` | 覆盖 MongoDB 镜像（默认 `mongo:7`） |

## 装完做三件事

1. **放行端口**：安全组打开 `25519`（或你指定的端口），否则只有服务器本机能访问。
2. **登录并改密码**：用脚本打印的管理员账号密码登录，到「个人设置」里改成自己的。
3. **决定要不要开放注册**：上游**默认开放注册**（`register: true`）。自己用建议关掉，或改成邀请码制；否则公网上容易被陌生人注册占空间。

## 脚本修掉的两个上游坑

上游默认配置有两个问题，**不处理的话第一次上传就会失败**，脚本已自动修正：

| # | 问题 | 现象 | 脚本做法 |
| --- | --- | --- | --- |
| 1 | 角色组的 `maxCapacity` 默认是 **0** | 上传报「您的累计上传容量已达到角色组设置上限」（而且文件其实**已经写盘**，会留垃圾文件） | 改为 管理员 `20480MB` / 普通 `5120MB` / 游客 `1024MB` |
| 2 | 上传前必须先配置 `site.url` | 上传报「请先配置网站URL」 | 自动写入 `http://<公网IP>:<端口>` |

另外三个部署层面的坑也一并处理了：

| 问题 | 说明 |
| --- | --- |
| `mongo:latest` 不锁版本 | 上游 compose 用 `mongo:latest`，这里锁 `mongo:7` |
| **MongoDB 要求 `wiredTigerCacheSizeGB ≥ 0.25`** | 按内存比例算出来的值小于 0.25 时容器会**崩溃循环**，脚本夹到 256~512MB |
| `VITE_APP_TITLE` 是构建期变量 | 运行时传 `-e` 改不动页面标题，站点名称要改数据库或后台 |

## 执行流程

```
▸ 检查基础依赖     curl / openssl / python3，缺则补装
▸ 检查 Docker      已有且可用则跳过；否则探测 5 个源安装
▸ 检查端口         被自己容器占用则复用，被他人占用报错
▸ 生成配置         compose（app + mongo:7，缓存按内存限制）+ 随机 JWT/密码 + .credentials(600)
▸ 拉取镜像         setube/stb + mongo:7
▸ 启动容器         docker compose up -d，轮询首页直到 200
▸ 初始化站点       建管理员（第一个注册账号=创始人）、修角色组容量、写 site.url
▸ 自检（可选）     上传一张测试图并访问，确认 201 + 200
▸ 汇总             地址 / 账号密码 / 凭据文件 / 放行端口 / 安全提醒
```

## 部署后的目录结构

```
/opt/stb/
├── docker-compose.yml      # app(setube/stb) + mongo:7
├── .credentials            # 600：访问地址、管理员账号密码、JWT_SECRET
└── data/
    ├── uploads/            # 上传的图片（按年/月/日分目录，含 thumbnails）
    └── mongo/              # MongoDB 数据目录

Docker：
  容器  stb（对外端口）· stb-mongo（仅容器网络内可达）
  网络  stb_default
```

## 常用运维命令

```bash
cd /opt/stb

docker compose -p stb ps                        # 状态
docker compose -p stb logs -f stb               # 日志（或 stb-mongo）
docker compose -p stb restart                   # 重启
docker compose -p stb stop                      # 停服（数据保留）

# 查看管理员密码 / JWT
cat /opt/stb/.credentials

# 改 Mongo 缓存上限（内存很小的机器）
sed -i 's/wiredTigerCacheSizeGB", "[0-9.]*"/wiredTigerCacheSizeGB", "0.25"/' /opt/stb/docker-compose.yml
docker compose -p stb up -d
```

## 升级

```bash
sudo bash install_stb.sh --upgrade
```

会拉取 `setube/stb:latest` 最新镜像并重建容器；**数据、图片、管理员账号与密码全部保留**。

> 注意：上游最近一次代码提交是 2026-01，之后主要是镜像/文档维护。脚本锁定了 `mongo:7` 与镜像 tag，降低"上游不维护导致环境漂移"的风险。

## 备份与恢复

数据全在 `/opt/stb/data`（图片 + MongoDB），备份就是打包它：

```bash
# 备份
tar czf /root/stb-backup-$(date +%F).tar.gz -C /opt/stb data

# 恢复（会覆盖现有数据）
cd /opt/stb && docker compose -p stb stop
tar xzf /root/stb-backup-2026-10-18.tar.gz -C /opt/stb
docker compose -p stb start
```

也可以只备份 `data/uploads`（图片）或 `data/mongo`（数据库），但两者要配套——数据库里存了图片的记录和路径。

## 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 浏览器打不开 | 先查**安全组有没有放行端口**；服务器上自测 `curl -I http://127.0.0.1:25519/` |
| 上传报「累计上传容量已达到上限」 | 角色组 `maxCapacity` 为 0。本脚本已自动改成 20480/5120/1024；若是旧实例，到后台「角色组管理」里改 |
| 上传报「请先配置网站URL」 | 到后台「系统配置」填站点 URL（本脚本已自动填公网 IP + 端口） |
| 容器一直重启，日志报 `cacheSizeGB must be greater than or equal to 0.25` | Mongo 缓存参数太小，脚本已夹到 256MB 起；手工改 `--wiredTigerCacheSizeGB 0.25` |
| 改了 `VITE_APP_TITLE` 标题没变 | 那是构建期变量；站点名称在后台「系统配置 → 站点名称」改 |
| 不记得管理员密码 | `cat /opt/stb/.credentials`；忘了就删掉 `users` 集合或用 `--uninstall` 重装 |
| 重跑脚本会不会覆盖数据 | 不会。只重新生成 compose 与凭据（凭据复用 JWT/密码），`data/` 不动 |
| 安装失败了怎么办 | 修好后直接重跑同一条命令：镜像续传、数据与凭据复用；残留容器不健康时加 `--recreate` |
| 想用第三方存储 | 后台「存储配置」选 OSS/COS/S3/七牛/又拍/SFTP/FTP/WebDAV/GitHub/Telegram，填好密钥后在角色组里指定 |

## 安全建议

- **默认开放注册**，公网使用前先关掉注册或改邀请码制，并考虑开启「图片广场」审核。
- 管理员密码是随机生成的，登录后请改成自己的强密码。
- 建议加一层 **HTTPS 反代**（Nginx / Caddy + Let's Encrypt），别长期裸 HTTP 暴露。
- 图片存本地时注意磁盘；用量大就把存储切到对象存储或 Telegram。
- 本系统会接收**任意用户上传的图片**，请自行准备内容审核/举报机制，并为存储目录设置配额或定期清理。
- 开启游客上传 + 开放注册 = 任何人都能往你磁盘写文件，除非你明确需要，否则别同时打开。

## 其他部署方式（不走本脚本）

上游提供镜像与 compose，但要自己处理上面的两个坑：

```bash
git clone https://github.com/setube/stb.git && cd stb
cp .env.example .env                  # 至少改 JWT_SECRET、MongoDB 连接
docker compose up -d                  # 上游 compose 会带一个 mongo 服务
```

也可以直接用官方镜像手动起（**需要你自己提供 MongoDB**）：

```bash
docker run -d -p 25519:25519 \
  -e MONGODB_URI='mongodb://你的mongo:27017/stb' \
  -e JWT_SECRET='一个随机长字符串' \
  -v /opt/stb/uploads:/app/server/uploads \
  setube/stb:latest
```

## 卸载

```bash
sudo bash install_stb.sh --uninstall --yes
```

会删除：两个容器、Mongo 数据、上传的图片、`/opt/stb` 目录。镜像需要手动删（`docker rmi setube/stb:latest mongo:7`），以免影响其它项目。

## 合规与协议

- 上游 [Stb 图床](https://github.com/setube/stb) 采用 **Apache-2.0**，允许商用；本仓库**不重新分发上游代码**，脚本只拉取上游镜像并在你的机器上生成配置。
- 图床承载的是**用户上传的内容**，请自行确认当地对图片存储、传播与备案的要求，并做好审核与滥用防护。
- 使用第三方存储（对象存储 / Telegram / GitHub）时，请遵守对应平台的服务条款。

## License

[MIT License](LICENSE) © 2026 鼠宝财
