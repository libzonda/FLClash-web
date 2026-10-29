# FlClash-web

![FlClash-web](screenshots/01.png)

[更多截图](screenshots/)

## 1 项目介绍

[FlClash](https://github.com/chen08209/FlClash) 是一款出色的跨平台代理客户端，但在 Linux 服务器、NAS 或软路由等无图形界面环境下难以远程使用。本项目通过原生 Flutter Web 编译（**非 VNC / 远程桌面方案**），将完整的 UI 界面直接内嵌至 Go (Clash.Meta) 核心中，实现**单个可执行文件 / 单个 Docker 容器**开箱即用。具备资源占用低、交互零延迟、浏览器关闭不影响后台代理运行、数据服务端持久化等优点，且代码零侵入，构建时自动跟随上游最新稳定 Release Tag（如 `v0.9.2`）。

---

## 2 Docker Compose 快速部署

创建 `docker-compose.yml`：

```yaml
services:
  flclash-web:
    image: ghcr.io/libzonda/flclash-web:latest
    container_name: flclash-web
    restart: unless-stopped
    ports:
      - "9090:9090"         # Web UI 控制面板
      - "7890:7890/tcp"     # Clash 混合代理端口 (HTTP/SOCKS5)
      - "7890:7890/udp"
    # 如需 TUN 模式透明代理，建议取消下一行注释使用 host 网络模式：
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

启动容器：

```bash
docker compose up -d
```

- **Web 访问地址**：`http://<服务器IP>:9090`
- **代理端口**：`7890`

---

## 3 自行构建方式

宿主机无需安装 Flutter 和 Go 环境，直接使用 Docker 多阶段构建即可：

```bash
# 1. 克隆代码（递归拉取子模块）
git clone --recursive https://github.com/libzonda/flclash-web.git
cd FlClash-web

# 2. 一键构建 Docker 镜像（自动拉取上游最新稳定 Tag 编译）
docker build -t flclash-web:latest .
```
