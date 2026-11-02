# ProtonVPN Docker: All-in-One Gateway with Embedded Control Panel

A production-ready Dockerized ProtonVPN gateway featuring a **hot-swappable OpenVPN tunnel**, an **embedded Web Control Panel**, and an **independent verification Proof Page** with real-time external IP and geolocation telemetry.

The image `eaeoz/protonvpn-docker:1` is an **All-in-One** container: it bundles both the OpenVPN tunnel and the Web UI.

---

## ⚡ Instant Run (Pre-Built `docker compose`)

If you want the VPN gateway along with the verification proof page, create a `docker-compose.yml` file:

```yaml
name: protonvpn-docker

services:
  # ------------------------------------------------------------------
  # The OpenVPN tunnel gateway
  # ------------------------------------------------------------------
  vpn:
    image: eaeoz/protonvpn-docker:latest
    container_name: protonvpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./config:/site/config
      - ./ovpn:/site/ovpn
      - ./state:/site/state
    environment:
      DEFAULT_OVPN: ${DEFAULT_OVPN:-}
    dns:
      - 8.8.8.8
      - 1.1.1.1
    ports:
      - "8080:80"   # Proof page (web service attaches to vpn netns)
    healthcheck:
      test: ["CMD-SHELL", "test -f /run/tunnel-up || test -f /site/state/tunnel-stopped"]
      interval: 30s
      timeout: 5s
      start_period: 60s
      retries: 3
    restart: unless-stopped

  # ------------------------------------------------------------------
  # Control panel: web UI (profile picker + tunnel status + reconnect)
  # ------------------------------------------------------------------
  panel:
    image: eaeoz/protonvpn-docker-panel:latest
    container_name: protonvpn-panel
    depends_on:
      - vpn
    environment:
      DEFAULT_OVPN: ${DEFAULT_OVPN:-}
    ports:
      - "8000:8000"
    volumes:
      - ./ovpn:/app/ovpn
      - ./state:/app/state
      - ./www:/app/www:ro
      - ./config:/app/config
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped

  # ------------------------------------------------------------------
  # Proof container: shares VPN network to verify exit IP.
  # Fully self-contained image (page + updater baked in).
  # ------------------------------------------------------------------
  web:
    image: eaeoz/protonvpn-docker-proof:1
    depends_on:
      - vpn
    network_mode: "service:vpn"
    volumes:
      - ./state:/site/state      # optional: live "current profile" name
    restart: unless-stopped
```

Then run:
```bash
docker compose up -d
```

- **Control Panel**: [http://localhost:8000](http://localhost:8000)
- **Proof Page**: [http://localhost:8080](http://localhost:8080)

---

👉 Now open **[http://localhost:8000](http://localhost:8000)** in your browser!
- Enter your ProtonVPN OpenVPN username/password directly into the web UI.
- Drag & drop `.ovpn` files to upload new servers.
- Switch your active server with one click ("Use as default").
- Control the tunnel with **Restart Tunnel**, **Stop Tunnel** and **Start Tunnel** buttons.
- Monitor your live exit IP, Country, City, and ISP.

> **Routing Other Containers:** To route another container through this VPN tunnel, add `--net=container:protonvpn` to that container's `docker run` command.

---

## 🔎 Standalone Proof Page (attach to an already-running gateway)

Test your exit IP from any folder, without touching the tunnel. Ships as
[`docker-compose.proof.yml`](docker-compose.proof.yml) - it attaches to an
**already-running** `protonvpn` container and shares its network namespace:

```bash
docker compose -f docker-compose.proof.yml up -d
# -> open http://localhost:8080
```

Or as a single `docker run`:

```bash
docker run -d --name protonvpn-proof --network container:protonvpn --restart unless-stopped eaeoz/protonvpn-docker-proof:1
```

> **Note:** run EITHER this standalone proof container OR the `web`/`proof`
> service of the main stack - both listen on port 80 inside the same shared
> network namespace, so running both at once causes a bind conflict (the VPN
> tunnel and the control panel keep working either way). If no profile is
> loaded yet, the proof page shows a "No OpenVPN profile loaded" message and
> hides IP data instead of stale values.

---

## 🌟 Key Features

- **All-in-One Architecture**: Control panel is embedded directly inside the gateway image—no separate backend containers required.
- **Zero Profile Editing**: Single credential injection via `config/login.conf` automatically applied to all `.ovpn` profiles.
- **Hot-Swapping Without Downtime**: Switch between VPN servers or restart the tunnel directly from the web panel. Containers sharing the VPN network (`network_mode: "service:vpn"`) maintain their network namespace. The tunnel always runs on a **pinned `tun0` device** (the profile's own `dev` directive is replaced), and every switch fully tears down the previous OpenVPN session first (no stacked processes or stale routes), so the exit IP always matches the selected profile.
- **Full Tunnel Control (Port 8000)**:
  - **Restart Tunnel** – reconnect the current profile in place.
  - **Stop Tunnel** – take the tunnel down on purpose; the gateway tears OpenVPN down, removes the VPN routes, restores container DNS and stays down (auto-restart is suppressed) until you start it again.
  - **Start Tunnel** – bring a stopped tunnel back up.
  - Switching profiles, saving credentials or Restart while stopped **re-enables the tunnel** automatically.
- **Web Control Panel**:
  - System status indicators with live animated status dots (Container state, Tunnel link, Active profile, Exit IP & location, auto-refresh every 5s).
  - In-browser credential manager (passwords are safely stored and never echoed).
  - Drag-and-drop `.ovpn` profile uploader and multi-profile batch manager.
  - Live geolocation and IP detection (Country, City, ISP); cleared on every reconnect so no stale location lingers.
  - Explicit error handling for authentication failures (`AUTH_FAILED`) and TLS handshake issues with previous-session notice banners.
- **Proof & Verification Page (Port 8080)**:
  - Real-time side-by-side comparison between the internal container exit IP and your host browser IP.
  - Deep geolocation details: Country, City/Region, Organization/ISP, and ASN.
  - Warning banner alerting if outbound traffic is paused or if values are cached from a previous session.
  - Self-healing IP updater: the updater loop is the container's PID 1 and restarts the container (re-attaching to the fresh tunnel netns) if the network namespace is ever lost; while the tunnel is stopped it shows "Tunnel stopped" instead of leaving stale exit-IP data on the page.

---

## 🎛️ Tunnel Control & State Files

The panel buttons communicate with the gateway through small marker files in the shared `state/` directory (also consumed by the embedded panel inside the vpn container):

| File | Written by | Effect |
|---|---|---|
| `selected.ovpn` | panel ("Use as default") | hot-switches the tunnel to that profile |
| `reload-request` | Restart button / credentials save | reconnects the tunnel (also revives a stopped one) |
| `tunnel-stop-request` | **Stop Tunnel** | tears the tunnel down and persists the stop |
| `tunnel-start-request` | **Start Tunnel** | brings the tunnel back up |
| `tunnel-stopped` | gateway (after a stop) | persists "off" state; blocks auto-restart & healthcheck restart until removed |
| `current-profile`, `ipinfo.json` | gateway / proof page | active profile name and live exit-IP telemetry |

These persist across container restarts, so a deliberate stop survives `docker restart` and Docker Desktop restarts.

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
├── state/                     # Runtime tracking (active profile, connection state, error logs,
│                              #   tunnel stop/start requests, exit-IP telemetry)
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
    image: eaeoz/protonvpn-docker:1
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

## 📦 Building & Publishing

Images are versioned with the integer tag `1` and always pushed together with `latest`:

```powershell
# 1. Build all-in-one image as tag "1"
docker build -t eaeoz/protonvpn-docker:1 -f vpn/Dockerfile .

# 2. Build standalone control panel image
docker build -t eaeoz/protonvpn-docker-panel:1 ./panel

# 3. Build self-contained proof page image
docker build -t eaeoz/protonvpn-docker-proof:1 -f www/Dockerfile ./www

# 4. Also tag everything as latest
docker tag eaeoz/protonvpn-docker:1 eaeoz/protonvpn-docker:latest
docker tag eaeoz/protonvpn-docker-panel:1 eaeoz/protonvpn-docker-panel:latest
docker tag eaeoz/protonvpn-docker-proof:1 eaeoz/protonvpn-docker-proof:latest

# 5. Push all tags to Docker Hub
docker push eaeoz/protonvpn-docker:1
docker push eaeoz/protonvpn-docker:latest
docker push eaeoz/protonvpn-docker-panel:1
docker push eaeoz/protonvpn-docker-panel:latest
docker push eaeoz/protonvpn-docker-proof:1
docker push eaeoz/protonvpn-docker-proof:latest
```

> **Clean republish:** when the remote tags are wiped first (all old tags removed
> via the Docker Hub API before pushing), only `1` and `latest` remain as the
> published tags for all three images (`protonvpn-docker`,
> `protonvpn-docker-panel` and `protonvpn-docker-proof`).

---

## 🔒 Security Best Practices

- `config/login.conf` and real `.ovpn` files are excluded by default in [`.gitignore`](.gitignore).
- Do not commit your credentials or personal VPN profiles to public git repositories.
- The control panel runs locally on port 8000 by default. Protect with basic authentication or reverse proxy if binding to public network interfaces.
