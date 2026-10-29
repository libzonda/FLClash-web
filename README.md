# FlClash-web

**FlClash-web** 将原生桌面端 [FlClash](https://github.com/chen08209/FlClash) 编译打包为 **原生 Flutter Web (`flutter build web`) + Go (Clash.Meta / Mihomo) 单二进制 / 单容器** 应用，不使用任何 VNC / X11 / 远程桌面方案。

运行单个二进制文件 `FlClash-web`（或单个 Docker 容器）即可同时启动 Clash.Meta 核心与内嵌的原生 Flutter Web 管理界面。

---

## 核心特性与架构设计

1. **原生 Flutter Web 编译（非 VNC）**：
   - 使用 `flutter build web --release` 将 FlClash 完整 UI 编译为原生 Web 静态资源（CanvasKit / JS / WASM），通过 Go `//go:embed` 直接内嵌进单个可执行二进制文件 `FlClash-web`。
2. **基于原始项目，零侵入持续跟随上游更新**：
   - 所有 Web 适配层均位于新增文件中（[`FlClash/lib/web_shim/`](file:///home/superearth/Projects/flash_web_migrate/FlClash/lib/web_shim/)、[`FlClash/web/`](file:///home/superearth/Projects/flash_web_migrate/FlClash/web/)、[`FlClash/core/web_server.go`](file:///home/superearth/Projects/flash_web_migrate/FlClash/core/web_server.go)、[`FlClash/core/cmd/flclash-web/main.go`](file:///home/superearth/Projects/flash_web_migrate/FlClash/core/cmd/flclash-web/main.go)）。
   - 构建时由 [`scripts/prepare_web.py`](file:///home/superearth/Projects/flash_web_migrate/scripts/prepare_web.py) 自动注入 Web 垫片（`--apply`），构建结束后自动还原所有上游跟踪文件（`--revert`），因此 `FlClash` 目录随时可以直接 `git pull` 同步上游更新而不会产生代码冲突。
3. **单二进制直接运行 & 单容器 Docker 部署**：
   - **WebSocket IPC 桥接 (`/ws/core`)**：将桌面端 Unix Socket / Named Pipe 替换为同源 WebSocket，直接调用 Go 核心的 `dispatchMethodCall` 并实时推送日志、连接、流量与 DNS 事件。关闭浏览器标签页不会中断服务端代理运行。
   - **服务端虚拟文件系统 (`/api/fs/*`) + SQLite WASM 持久化**：配置文件、`shared_preferences.json`、订阅 YAML 与 SQLite 数据库（`database.sqlite`）全部实时持久化在服务端 `--data-dir`（默认 `/data`）目录中。
   - **服务端 HTTP 代理网关 (`/api/http-proxy`)**：订阅拉取、WebDAV 备份恢复、GeoIP 更新、IP 质量检测等请求统一由 Go 后端代发，彻底解决浏览器 CORS 跨域限制。

---

## 快速开始

### 方式一：Docker 单容器部署（推荐）

使用 [`docker-compose.yml`](file:///home/superearth/Projects/flash_web_migrate/docker-compose.yml) 启动单容器：

```bash
docker compose up -d
```

或者直接使用 `docker run`：

```bash
docker run -d \
  --name flclash-web \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun:/dev/net/tun \
  -p 9090:9090 \
  -p 7890:7890/tcp \
  -p 7890:7890/udp \
  -v $(pwd)/data:/data \
  ghcr.io/<your-github-username>/flclash-web:latest
```

启动后在浏览器访问：
- **Web UI 地址**：`http://<服务器IP>:9090`
- **混合代理端口 (HTTP / SOCKS5)**：`7890`

---

### 方式二：Linux 二进制本地直接运行

从 GitHub Releases 下载对应架构的单文件二进制 `FlClash-web-linux-amd64`（或 `arm64`），或者本地执行 [`build.sh`](file:///home/superearth/Projects/flash_web_migrate/build.sh) 编译：

```bash
chmod +x ./FlClash-web
./FlClash-web --listen 0.0.0.0:9090 --data-dir ./flclash-data
```

支持的参数与环境变量：
- `--listen`（环境变量 `FLCLASH_WEB_LISTEN`）：Web UI 监听地址，默认 `0.0.0.0:9090`
- `--data-dir`（环境变量 `FLCLASH_DATA_DIR`）：配置与数据存储目录，容器内默认 `/data`，本地默认 `~/.local/share/flclash-web`
- `--web-dir`（环境变量 `FLCLASH_WEB_DIR`）：可选外部静态资源目录（默认使用二进制内嵌的 Flutter Web 资源）

---

## 本地构建

### 1. 构建单文件二进制
确保已安装 Flutter SDK、Go、Python 3，然后执行：

```bash
chmod +x build.sh
./build.sh
```
构建完成后将在 `dist/FlClash-web` 生成内嵌了 Flutter Web 前端的独立可执行文件。

### 2. 本地构建 Docker 镜像
- **方式 A（基于已编译的 `dist/FlClash-web-linux-*` 秒级打包单容器镜像，推荐）**：
  ```bash
  sudo docker build -f Dockerfile.prebuilt -t flclash-web:latest .
  ```
- **方式 B（Docker 多阶段全量构建）**：
  ```bash
  sudo docker build -t flclash-web:latest .
  ```

---

## 跟随上游 FlClash 持续更新

由于项目采用非侵入式构建期补丁 [`scripts/prepare_web.py`](file:///home/superearth/Projects/flash_web_migrate/scripts/prepare_web.py)，日常同步上游代码只需：

```bash
cd FlClash
git pull origin main
git submodule update --init --recursive
cd ..
./build.sh
```

---

## GitHub Actions 自动构建（推送到 GHCR 与 Docker Hub）

工作流文件位于 [`.github/workflows/flclash-web.yml`](file:///home/superearth/Projects/flash_web_migrate/.github/workflows/flclash-web.yml)，支持：
1. **自动同步上游**：支持每日定时（`schedule`）或手动触发（`workflow_dispatch` 选择 `sync_upstream=true`）拉取最新 `chen08209/FlClash` 源码并打包。
2. **多架构独立二进制产物**：自动编译 `FlClash-web-linux-amd64` 与 `FlClash-web-linux-arm64` 单文件二进制并上传至 Actions Artifacts / GitHub Releases。
3. **推送至 GHCR (`ghcr.io`) 与 Docker Hub (`docker.io`)**：
   - **GHCR**：默认使用仓库内置 `GITHUB_TOKEN` 自动推送至 `ghcr.io/<owner>/flclash-web`。
   - **Docker Hub**：在 GitHub 仓库的 `Settings -> Secrets and variables -> Actions` 中添加以下两个 Secret 即可自动同时推送到 Docker Hub：
     - `DOCKERHUB_USERNAME`：Docker Hub 用户名
     - `DOCKERHUB_TOKEN`：Docker Hub Access Token

