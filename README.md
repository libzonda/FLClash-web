# FlClash-web

> 将优秀的原生 Flutter 客户端 [FlClash](https://github.com/chen08209/FlClash) 打包为 **原生 Flutter Web + 内嵌 Clash.Meta (Mihomo) 核心** 的单二进制 / 单容器应用。

---

## 1 基本介绍

**FlClash-web** 旨在让 Linux 服务器、NAS、软路由以及各类云端主机能够轻量化运行 FlClash，同时通过现代 Web 浏览器直接访问和操控精美的 Flutter 前端界面。

### 核心亮点

- **原生 Flutter Web 编译（拒绝 VNC / X11）**
  采用标准的 `flutter build web --release` 原生编译方案，产物为纯正的 CanvasKit / HTML5 前端页面，不使用任何 VNC、noVNC、X11 转发或远程桌面等高内存、高延迟的折中手段。
- **单二进制直接运行 & 单容器部署**
  Go 核心借助 `//go:embed` 技术将 Flutter Web 静态资产完整内嵌到可执行程序中。无论是本地运行单个二进制文件，还是启动单个 Docker 容器，都能同时拉起 Clash.Meta 内核与 Web 管理服务。
- **零侵入设计，紧跟上游更新**
  FlClash 原生工程作为 Git Submodule 引入，所有 Web 端垫片、VFS 映射及 Go 服务端源码均隔离在 `overlay/` 与 `scripts/` 中。构建时动态注入、完成后干净回退，**默认每次构建均自动拉取并对齐上游最新的正式版本 Tag（如 `v0.9.2`）**。
- **WebSocket 实时 IPC 桥接**
  原生桌面端采用的 Unix Socket / 管道被改造为同源 WebSocket RPC，浏览器关闭、刷新均不会影响后台代理内核的持续运行，重连后无缝恢复流量、日志与状态。
- **服务端持久化与跨域穿透**
  配置、订阅及 SQLite 数据库在服务端持久化存储（默认挂载目录 `/data`）；订阅拉取、规则更新统一由服务端代发，彻底解决浏览器的 CORS 跨域限制。
- **Web 体验专属调优**
  自动剔除桌面窗口无边框控制栏（最小化/最大化/关闭按钮），界面完整贴顶自适应；彻底去除 Flutter 调试预览水印横幅（PRE）。

---

## 2 部署方式

### 2.1 二进制部署

适用于 Linux 物理机、VPS 或软路由环境直接运行。

#### 1. 下载或获取二进制
从 [Releases](https://github.com/chen08209/FlClash/releases) 下载适合您系统架构的预编译文件（或参考下文自行编译）：
- `FlClash-web-linux-amd64` (x86_64)
- `FlClash-web-linux-arm64` (aarch64)

#### 2. 直接运行
赋予执行权限并启动：

```bash
chmod +x FlClash-web-linux-amd64

# 默认监听 0.0.0.0:9090，数据存储在 ./flclash-data
./FlClash-web-linux-amd64 --listen 0.0.0.0:9090 --data-dir ./flclash-data
```

启动后在浏览器打开 `http://<服务器IP>:9090` 即可进入 Web 管理界面。

#### 3. 命令行参数与环境变量

| 命令行参数 | 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `--listen` | `FLCLASH_WEB_LISTEN` | `0.0.0.0:9090` | Web 管理面板监听地址 |
| `--data-dir` | `FLCLASH_DATA_DIR` | `~/.local/share/flclash-web` | 配置文件、订阅、数据库的持久化目录 |
| `--web-dir` | `FLCLASH_WEB_DIR` | 空 (使用内嵌资源) | 指定外部静态资源目录（调试前端时可选） |
| `--version` | - | - | 打印版本信息并退出 |

#### 4. TUN 模式权限配置（可选）
若需要开启 TUN 虚拟网卡代理，请为二进制授予网络管理特权，或使用 `sudo` 运行：

```bash
sudo setcap cap_net_admin,cap_net_raw+ep ./FlClash-web-linux-amd64
```

#### 5. Systemd 守护进程托管（开机自启）
创建系统服务文件 `/etc/systemd/system/flclash-web.service`：

```ini
[Unit]
Description=FlClash-web Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/FlClash-web --listen 0.0.0.0:9090 --data-dir /var/lib/flclash-web
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

激活并启动服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now flclash-web
```

---

### 2.2 Docker Compose 部署

推荐生产环境与家庭 NAS 使用 Docker Compose 进行单容器部署。

#### 1. 准备 `docker-compose.yml`

在工作目录下新建 `docker-compose.yml`：

```yaml
services:
  flclash-web:
    image: ghcr.io/<your-username>/flclash-web:latest
    container_name: flclash-web
    restart: unless-stopped
    # 方式 A：端口映射模式（适用于常规代理场景）
    ports:
      - "9090:9090"         # Web UI 面板端口
      - "7890:7890/tcp"     # Clash 混合代理端口 (HTTP / SOCKS5)
      - "7890:7890/udp"     # UDP 代理端口
    # 方式 B：Host 网络模式（透明代理 / TUN 模式推荐开启）
    # network_mode: host
    environment:
      - TZ=Asia/Shanghai
      - FLCLASH_WEB_LISTEN=0.0.0.0:9090
      - FLCLASH_DATA_DIR=/data
    volumes:
      - ./data:/data
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
```

> **提示**：
> - 若使用 **TUN 模式** 或透明网关分流，建议取消注释 `network_mode: host`，此时可省去 `ports` 端口映射。
> - 确保宿主机已启用 TUN 模块：`ls -l /dev/net/tun`。

#### 2. 启动容器

```bash
# 后台启动
docker compose up -d

# 查看运行日志
docker compose logs -f

# 停止容器
docker compose down
```

打开浏览器访问：`http://<宿主机IP>:9090` 即可开始使用。

---

## 3 自行构建方式

### 3.1 环境准备

若在本地环境自行编译，需安装以下工具：
- **Go**：>= 1.22
- **Flutter SDK**：stable 通道（建议 >= 3.24）
- **Python**：>= 3.8
- **Git**

### 3.2 获取项目源码

克隆本仓库及关联子模块：

```bash
git clone --recursive https://github.com/<your-username>/FlClash-web.git
cd FlClash-web
```

---

### 3.3 方式一：本地一键构建（推荐）

项目提供了高度自动化的构建脚本 [build.sh](build.sh)：

```bash
chmod +x build.sh
./build.sh
```

#### 构建流程特性：
1. **自动锁定最新稳定 Tag**：默认 `FLCLASH_TAG=latest`，自动抓取并对齐上游最新的正式 Tag（例如当前 `v0.9.2`），也可以通过 `FLCLASH_TAG=v0.9.2 ./build.sh` 指定特定版本。
2. **自动同步 Clash.Meta 核心**：自动检出对应 Tag 要求的内核子模块代码。
3. **自动下载依赖**：自动获取 Web 运行所需的 `sqlite3.wasm`。
4. **编译并自动还原**：编译完成后将自动还原上游源码修改，保持子模块目录 100% 干净。
5. **构建产物**：输出在 `dist/FlClash-web`，即为包含内嵌 Web UI 的单文件可执行文件。

查看编译好的版本：

```bash
./dist/FlClash-web --version
# 输出：FlClash-web v0.9.2 (Clash.Meta core + native Flutter Web UI)
```

---

### 3.4 方式二：Docker 镜像构建

#### 极速构建（基于本地已有的 `dist/FlClash-web`）
若已通过 `./build.sh` 编译了二进制，可直接打包轻量 Alpine 运行时镜像：

```bash
docker build -f Dockerfile.prebuilt -t flclash-web:latest .
```

#### 全源码多阶段自动构建
在没有本地 Flutter / Go 环境的机器上，可直接使用多阶段 Dockerfile 全自动化编译：

```bash
docker build -t flclash-web:latest .
```

---

### 3.5 方式三：GitHub Actions 自动构建与发布

仓库内置了完善的 CI/CD 流程文件 [`.github/workflows/flclash-web.yml`](.github/workflows/flclash-web.yml)：

- **定时同步与更新**：每天自动检查上游 `chen08209/FlClash` 是否有新 Tag 发布，自动拉取并构建最新版本。
- **手动调度构建**：在 GitHub Actions 页面点击 `Run workflow`，可自由指定目标 Tag（默认 `latest`）。
- **多架构产物编译**：自动编译 `amd64` 与 `arm64` Linux 架构二进制，自动生成 GitHub Release 并上传资产。
- **自动推送到镜像源**：
  - **GHCR**：自动构建并推送多架构镜像至 `ghcr.io/<owner>/flclash-web`。
  - **Docker Hub**：在仓库设置中添加 `DOCKERHUB_USERNAME` 与 `DOCKERHUB_TOKEN` 凭证后，自动同步推送至 Docker Hub。
