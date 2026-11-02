# ProtonVPN Docker: All-in-One Gateway with Embedded Control Panel

A production-ready Dockerized ProtonVPN gateway featuring a **hot-swappable OpenVPN tunnel**, an **embedded Web Control Panel**, and an **independent verification Proof Page** with real-time external IP and geolocation telemetry.

The image `eaeoz/protonvpn-docker` is an **All-in-One** container: it bundles both the OpenVPN tunnel and the Web UI. A single `docker run` command starts the VPN tunnel and serves the full interactive dashboard on port 8000!

---

## ⚡ Instant Run (Single `docker run` Command)

Start the VPN tunnel gateway and the Web Control Panel in one command:

```bash
# 1. Create local directories for your credentials, profiles, and state
mkdir -p ovpn config state

# 2. Run the all-in-one container
docker run -d \
  --name protonvpn \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -p 8000:8000 \
  -v "$(pwd)/ovpn:/site/ovpn" \
  -v "$(pwd)/config:/site/config" \
  -v "$(pwd)/state:/site/state" \
  --dns 8.8.8.8 \
  --dns 1.1.1.1 \
  --restart unless-stopped \
  eaeoz/protonvpn-docker:2
```

👉 Now open **[http://localhost:8000](http://localhost:8000)** in your browser!
- Enter your ProtonVPN OpenVPN username/password directly into the web UI.
- Drag & drop `.ovpn` files to upload new servers.
- Switch your active server with one click ("Use as default").
- Click **"Restart Tunnel"** whenever needed.
- Monitor your live exit IP, Country, City, and ISP.

> **Routing Other Containers:** To route another container through this VPN tunnel, add `--net=container:protonvpn` to that container's `docker run` command.

---

## ⚡ Instant Run (Pre-Built `docker compose`)

If you prefer using Docker Compose with an optional sidecar Proof Page (which runs Nginx through the VPN netns on port 8080):

Create a `docker-compose.yml` with:

```yaml
name: protonvpn-docker

services:
  vpn:
    image: eaeoz/protonvpn-docker:2
    container_name: protonvpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8000:8000"   # Embedded Web Control Panel
      - "8080:80"     # Proof Page (shared netns)
    volumes:
      - ./config:/site/config
      - ./ovpn:/site/ovpn
      - ./state:/site/state
    dns:
      - 8.8.8.8
      - 1.1.1.1
    restart: unless-stopped

  # Optional: proof page that proves web traffic exits through the VPN tunnel
  proof:
    image: nginx:alpine
    depends_on:
      - vpn
    network_mode: "service:vpn"
    volumes:
      - ./www:/usr/share/nginx/html
    restart: unless-stopped
```

Then run:
```bash
docker compose up -d
```

- **Control Panel**: [http://localhost:8000](http://localhost:8000)
- **Proof Page**: [http://localhost:8080](http://localhost:8080)

---

## 🌟 Key Features

- **All-in-One Architecture**: Control panel is embedded directly inside the gateway image—no separate backend containers required.
- **Zero Profile Editing**: Single credential injection via `config/login.conf` automatically applied to all `.ovpn` profiles.
- **Hot-Swapping Without Downtime**: Switch between VPN servers or restart the tunnel directly from the web panel. Containers sharing the VPN network (`network_mode: "service:vpn"`) maintain their network namespace.
- **Web Control Panel (Port 8000)**:
  - System status indicators with live animated status dots (Container state, Tunnel link, Active profile).
  - One-click **Restart Tunnel** trigger with automatic reconnect.
  - In-browser credential manager (passwords are safely stored and never echoed).
  - Drag-and-drop `.ovpn` profile uploader and multi-profile batch manager.
  - Live geolocation and IP detection (Country, City, ISP).
  - Explicit error handling for authentication failures (`AUTH_FAILED`) and TLS handshake issues with previous-session notice banners.
- **Proof & Verification Page (Port 8080)**:
  - Real-time side-by-side comparison between the internal container exit IP and your host browser IP.
  - Deep geolocation details: Country, City/Region, Organization/ISP, and ASN.
  - Warning banner alerting if outbound traffic is paused or if values are cached from a previous session.

---

## 🔑 ProtonVPN Account Prerequisites

> [!IMPORTANT]
> You **cannot** use your Proton account email and login password for OpenVPN. Proton generates dedicated OpenVPN credentials for security.

### 1. Where to Find Your OpenVPN Username & Password
1. Log in to your Proton Account Dashboard:
   👉 **[https://account.protonvpn.com/login](https://account.protonvpn.com/login)**
2. Navigate to the left sidebar and select **Account** or go directly to:
   👉 **[https://account.protonvpn.com/account#openvpn](https://account.protonvpn.com/account#openvpn)**
3. Scroll to the **OpenVPN / IKEv2 username and password** section.
4. Copy:
   - **Username** (format usually looks like `username+p2p` or a long alphanumeric string)
   - **Password** (generated unique token)

### 2. Where to Download OpenVPN Configuration Profiles (`.ovpn`)
1. In the ProtonVPN dashboard, navigate to **Downloads**:
   👉 **[https://account.protonvpn.com/downloads](https://account.protonvpn.com/downloads)**
2. Under **OpenVPN configuration files**, configure your desired settings:
   - **Platform**: `GNU/Linux`
   - **Protocol**: `UDP` (recommended for speed) or `TCP`
   - **Select Tier / Server**: Choose Free or Plus servers, or download Country/Standard configs.
3. Download the `.ovpn` files (e.g. `ca-free-7.protonvpn.udp.ovpn`, `mx-free-4.protonvpn.udp.ovpn`).

---

## 🛠️ Local Development & Building From Source

If you cloned the source code repository:

### 1. Directory Structure

```text
├── config/
│   └── login.conf             # OpenVPN credentials (username on line 1, password on line 2)
├── ovpn/                      # Place your downloaded *.ovpn files here
├── state/                     # Runtime tracking (active profile, connection state, error logs)
├── panel/                     # Web control panel code & templates
├── vpn/                       # All-in-one Gateway container (Alpine + OpenVPN + Embedded Panel)
├── www/                       # Verification proof web server (Nginx)
├── docker-compose.yml         # Local development compose
└── README.md
```

### 2. Run Local Build

```bash
docker compose up -d --build
```

---

## 🐳 Routing Other Containers Through the VPN

To route another service (such as a torrent client, scraper, or curl script) through ProtonVPN, attach it to the `vpn` network namespace:

```yaml
services:
  vpn:
    image: eaeoz/protonvpn-docker:2
    container_name: protonvpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8000:8000"   # Web UI
      - "8080:80"     # Forward any ports needed by attached containers
    volumes:
      - ./config:/site/config
      - ./ovpn:/site/ovpn
      - ./state:/site/state

  my_app:
    image: alpine:latest
    network_mode: "service:vpn"
    depends_on:
      - vpn
    command: sh -c "while true; do wget -q -O- https://api.ipify.org; sleep 60; done"
```

---

## 📦 Building & Publishing Version 2

Run the following commands to tag and push the all-in-one image to Docker Hub:

```powershell
# 1. Build the all-in-one image (includes OpenVPN + Web Control Panel)
docker build -t eaeoz/protonvpn-docker:2 -f vpn/Dockerfile .

# 2. Tag as latest
docker tag eaeoz/protonvpn-docker:2 eaeoz/protonvpn-docker:latest

# 3. Log in to Docker Hub (if not already logged in)
docker login

# 4. Push to Docker Hub
docker push eaeoz/protonvpn-docker:2
docker push eaeoz/protonvpn-docker:latest
```

---

## 🔒 Security Best Practices

- `config/login.conf` and real `.ovpn` files are excluded by default in [`.gitignore`](.gitignore).
- Do not commit your credentials or personal VPN profiles to public git repositories.
- The control panel runs locally on port 8000 by default. Protect with basic authentication or reverse proxy if binding to public network interfaces.
