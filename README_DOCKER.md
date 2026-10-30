<div align="center">
  <img src="https://raw.githubusercontent.com/libzonda/FLClash-web/main/icon.png" alt="FlClash-web" width="128">
  <h1><a href="https://github.com/libzonda/FLClash-web">FlClash-web</a></h1>
  <p>A Flutter Web build of <a href="https://github.com/chen08209/FlClash">FlClash</a></p>
  <p>
    <a href="https://hub.docker.com/r/libzonda/flclash-web"><img src="https://img.shields.io/badge/docker-ready-blue?style=flat-square&logo=docker" alt="Docker"></a>
    <a href="https://flutter.dev/multi-platform/web"><img src="https://img.shields.io/badge/flutter-web-02569B?style=flat-square&logo=flutter" alt="Flutter Web"></a>
    <a href="https://go.dev/"><img src="https://img.shields.io/badge/go-1.27+-00ADD8?style=flat-square&logo=go" alt="Go"></a>
    <a href="https://github.com/libzonda/FLClash-web/releases"><img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-brightgreen?style=flat-square" alt="Architecture"></a>
    <a href="https://github.com/libzonda/FLClash-web/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"></a>
  </p>
  <p>
    <img src="https://raw.githubusercontent.com/libzonda/FLClash-web/main/screenshots/01.png" width="75%" alt="FlClash-web Desktop" />
    <img src="https://raw.githubusercontent.com/libzonda/FLClash-web/main/screenshots/phone01.jpg" width="21%" alt="FlClash-web Mobile" />
  </p>
</div>

[More Screenshots / 更多截图](https://github.com/libzonda/FLClash-web/tree/main/screenshots)

## 1 Introduction

[FlClash](https://github.com/chen08209/FlClash) is an excellent multi-platform proxy client, but it cannot be easily operated on headless environments such as Linux servers, NAS devices, or soft routers. **FlClash-web compiles the full Flutter UI natively into Flutter Web** (**without VNC or virtual desktop overhead**) and embeds it directly into the Go (Clash.Meta) core binary, delivering a standalone **single executable binary / single Docker container**. It offers minimal resource footprint, zero interaction lag, persistent background proxy execution when closing the browser, and server-side data persistence with zero code intrusion, tracking upstream's latest stable release tags (e.g. `v0.9.2`) automatically during builds.

---

## 2 Quick Start with Docker Compose

Create a `docker-compose.yml` file:

```yaml
services:
  flclash-web:
    image: libzonda/flclash-web:latest
    container_name: flclash-web
    restart: unless-stopped
    ports:
      - "9090:9090"         # Web UI Dashboard (default 9090)
      - "7890:7890/tcp"     # Clash Mixed Proxy (default 7890, HTTP/SOCKS5)
      - "7890:7890/udp"
    # To enable transparent proxying in TUN mode, uncomment the line below to use host networking:
    # network_mode: host
    environment:
      - TZ=Asia/Shanghai                  # Timezone (default is UTC, recommended local)
      - FLCLASH_WEB_LISTEN=0.0.0.0:9090   # Web listen address (default is 0.0.0.0:9090)
      - FLCLASH_DATA_DIR=/data            # Data directory (default is /data)
    volumes:
      - ./data:/data        # Persistent data storage (default container path is /data)
    # Required only for TUN mode transparent proxying (optional for regular proxy):
    cap_add:
      - NET_ADMIN           # Network administration privileges for TUN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun  # TUN device mapping
```

Start the container:

```bash
docker compose up -d
```

- **Web Dashboard URL**: `http://<SERVER_IP>:9090`
- **Proxy Port**: `7890`

---

## 3 Best Practices

### 3.1 Configure Core Auto-start
To ensure the proxy core starts automatically after container launch or server reboot without requiring manual activation via the Web UI:
- Open the Web UI, navigate to **Tools** -> **General** -> **Startup & Background** -> enable **Auto Run**.

### 3.2 Bypass Router Mode (Macvlan Dedicated IP)
Using Docker Macvlan to assign a dedicated LAN IP to FlClash-web avoids host port conflicts (such as port 53 occupied by systemd-resolved) and seamlessly routes traffic for LAN devices.

#### Step 1: Create Macvlan Network
Run on your host machine (replace `eth0`, subnet, and gateway with your network parameters):

```bash
# 1. Enable promiscuous mode on the host network interface
sudo ip link set eth0 promisc on

# 2. Create Docker macvlan network
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth0 flclash_net
```

#### Step 2: Deploy Container with Dedicated IP
Create `docker-compose.yml` (assuming assigned IP is `192.168.1.200`):

```yaml
services:
  flclash-web:
    image: libzonda/flclash-web:latest
    container_name: flclash-web
    restart: unless-stopped
    networks:
      flclash_net:
        ipv4_address: 192.168.1.200   # Dedicated LAN IP for FlClash
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./data:/data
    environment:
      - TZ=Asia/Shanghai
      - FLCLASH_WEB_LISTEN=0.0.0.0:9090
      - FLCLASH_DATA_DIR=/data

networks:
  flclash_net:
    external: true
```

#### Step 3: Configure FlClash Panel and Target Devices
1. **Enable Port 53 DNS Listening**:
   - Access `http://192.168.1.200:9090`, go to **Tools** -> **Advanced Settings** -> **DNS**;
   - Click **Add Override** -> change **Listen Address** to `0.0.0.0:53` and save, then enable **TUN Mode**.
2. **Target Device Network Configuration (PC / Phone / TV)**:
   - Configure IPv4 manually:
     - **Gateway**: `192.168.1.200`
     - **Preferred DNS**: `192.168.1.200`

---

## 4 Build from Source

No local Flutter or Go development environment is required. You can build the container image directly via Docker multi-stage build:

```bash
# 1. Clone repository with submodules
git clone --recursive https://github.com/libzonda/flclash-web.git
cd flclash-web

# 2. Build Docker image (automatically pulls and builds upstream's latest stable tag)
docker build -t flclash-web:latest .
```

---

## License & Acknowledgments

- This project is licensed under the [GPL-3.0 License](https://github.com/libzonda/FLClash-web/blob/main/LICENSE).
- Special thanks to the upstream project [FlClash](https://github.com/chen08209/FlClash) and its author [chen08209](https://github.com/chen08209).

---

# 简体中文

## 1 项目介绍

[FlClash](https://github.com/chen08209/FlClash) 是一款出色的跨平台代理客户端，但在 Linux 服务器、NAS 或软路由等无图形界面环境下难以远程使用。**本项目通过原生 Flutter Web 编译**（**非 VNC / 远程桌面方案**），将完整的 UI 界面直接内嵌至 Go (Clash.Meta) 核心中，实现**单个可执行文件 / 单个 Docker 容器**开箱即用。具备资源占用低、交互零延迟、浏览器关闭不影响后台代理运行、数据服务端持久化等优点，且代码零侵入，构建时自动跟随上游最新稳定 Release Tag（如 `v0.9.2`）。

---

## 2 Docker Compose 快速部署

创建 `docker-compose.yml`：

```yaml
services:
  flclash-web:
    image: libzonda/flclash-web:latest
    container_name: flclash-web
    restart: unless-stopped
    ports:
      - "9090:9090"         # Web UI 控制面板端口（默认 9090）
      - "7890:7890/tcp"     # Clash 混合代理端口（默认 7890，HTTP/SOCKS5）
      - "7890:7890/udp"
    # 如需 TUN 模式透明代理，建议取消下一行注释使用 host 网络模式：
    # network_mode: host
    environment:
      - TZ=Asia/Shanghai                  # 容器时区（镜像默认 UTC，建议指定本地时区）
      - FLCLASH_WEB_LISTEN=0.0.0.0:9090   # Web 监听地址（镜像默认即为 0.0.0.0:9090）
      - FLCLASH_DATA_DIR=/data            # 数据存储路径（镜像默认即为 /data）
    volumes:
      - ./data:/data        # 持久化配置与节点数据（容器内默认路径为 /data）
    # 以下为 TUN 模式所需权限与虚拟网卡设备（若仅使用普通端口代理可不配）：
    cap_add:
      - NET_ADMIN           # TUN 模式网络管理权限
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun  # TUN 设备映射
```

启动容器：

```bash
docker compose up -d
```

- **Web 访问地址**：`http://<服务器IP>:9090`
- **代理端口**：`7890`

---

## 3 最佳实践

### 3.1 配置核心自启动
为确保容器启动或服务器重启后代理核心自动运行（无需每次手动进入 Web 界面点击启动）：
- 打开 Web 界面，进入 **工具** -> **常规** -> **启动与后台** -> 勾选 **启用自动运行** 选项。

### 3.2 旁路由透明网关模式（Macvlan 独立 IP）
通过 Docker Macvlan 网络为 FlClash-web 分配局域网独立 IP，可避免宿主机端口冲突（如 53 端口占用），轻松实现局域网内单台或多台设备无感透明分流。

#### 第一步：创建 Macvlan 独立网络
在宿主机执行（请将 `eth0` 替换为你的物理网卡名称，网段及网关根据实际网络修改）：

```bash
# 1. 开启宿主机网卡混杂模式
sudo ip link set eth0 promisc on

# 2. 创建 Docker macvlan 网络
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth0 flclash_net
```

#### 第二步：使用独立 IP 启动容器
编写 `docker-compose.yml`（假设分配独立 IP 为 `192.168.1.200`）：

```yaml
services:
  flclash-web:
    image: libzonda/flclash-web:latest
    container_name: flclash-web
    restart: unless-stopped
    networks:
      flclash_net:
        ipv4_address: 192.168.1.200   # 分配给 FlClash 的局域网独立 IP
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./data:/data
    environment:
      - TZ=Asia/Shanghai
      - FLCLASH_WEB_LISTEN=0.0.0.0:9090
      - FLCLASH_DATA_DIR=/data

networks:
  flclash_net:
    external: true
```

#### 第三步：FlClash 面板与目标设备配置
1. **开放 53 端口 DNS 监听**：
   - 访问 `http://192.168.1.200:9090`，进入 **工具** -> **进阶配置** -> **DNS**；
   - 点击 **添加覆写项** -> 将 **监听地址** 修改为 `0.0.0.0:53` 并保存，开启 **TUN 模式**。
2. **目标设备（手机/电脑/电视等）网络设置**：
   - 手动配置 IPv4：
     - **网关**：`192.168.1.200`
     - **首选 DNS**：`192.168.1.200`

---

## 4 自行构建方式

宿主机无需安装 Flutter 和 Go 环境，直接使用 Docker 多阶段构建即可：

```bash
# 1. 克隆代码（递归拉取子模块）
git clone --recursive https://github.com/libzonda/flclash-web.git
cd flclash-web

# 2. 一键构建 Docker 镜像（自动拉取上游最新稳定 Tag 编译）
docker build -t flclash-web:latest .
```

---

## 开源协议与致谢

- 本项目基于 [GPL-3.0 License](https://github.com/libzonda/FLClash-web/blob/main/LICENSE) 开源。
- 特别感谢原项目 [FlClash](https://github.com/chen08209/FlClash) 及其作者 [chen08209](https://github.com/chen08209)。

