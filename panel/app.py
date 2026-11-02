"""ProtonVPN tunnel control panel.

Lists the .ovpn profiles in ./ovpn, lets the user pick which one is the
"default connection" (routes traffic till you change it), lets the user
upload new profiles, and restarts the vpn container so the new selection
takes effect.

OpenVPN credentials are NOT handled here - config/login.conf is shared by
all profiles automatically (injected by the vpn container entrypoint).
"""

import json
import os
import re
import pathlib
try:
    import docker
    from docker.errors import NotFound, DockerException
except ImportError:
    docker = None
    NotFound = Exception
    DockerException = Exception
from flask import Flask, request, redirect, url_for, render_template, flash

OVPN_DIR = pathlib.Path("/app/ovpn")
STATE_DIR = pathlib.Path("/app/state")
WWW_DIR = pathlib.Path("/app/www")
CONFIG_FILE = pathlib.Path("/app/config/login.conf")
SELECTED_FILE = STATE_DIR / "selected.ovpn"
RELOAD_FILE = STATE_DIR / "reload-request"   # tunnel reconnects when this appears
STOP_REQUEST_FILE = STATE_DIR / "tunnel-stop-request"
START_REQUEST_FILE = STATE_DIR / "tunnel-start-request"
STOPPED_FILE = STATE_DIR / "tunnel-stopped"  # persists "off" until Start is pressed

# Check if ovpn/state are mounted under /site (when running embedded in vpn container)
if not OVPN_DIR.is_dir() and pathlib.Path("/site/ovpn").is_dir():
    OVPN_DIR = pathlib.Path("/site/ovpn")
    STATE_DIR = pathlib.Path("/site/state")
    CONFIG_FILE = pathlib.Path("/site/config/login.conf")
    SELECTED_FILE = STATE_DIR / "selected.ovpn"
    RELOAD_FILE = STATE_DIR / "reload-request"
    STOP_REQUEST_FILE = STATE_DIR / "tunnel-stop-request"
    START_REQUEST_FILE = STATE_DIR / "tunnel-start-request"
    STOPPED_FILE = STATE_DIR / "tunnel-stopped"
DEFAULT_OVPN = os.environ.get("DEFAULT_OVPN", "")
VPN_CONTAINER = "protonvpn"

SAFE_NAME = re.compile(r"^[A-Za-z0-9._\- ]+\.ovpn$", re.IGNORECASE)
SAFE_NAME_SIMPLE = re.compile(r"^[A-Za-z0-9._\-]+$")

app = Flask(__name__)
app.secret_key = "local-tool-not-secret"

_client = None
if docker is not None:
    try:
        _client = docker.from_env()
    except DockerException:
        _client = None


def get_vpn_container():
    if _client is None:
        return None
    try:
        return _client.containers.get(VPN_CONTAINER)
    except (NotFound, DockerException):
        return None


def selected_profile():
    if SELECTED_FILE.is_file():
        name = SELECTED_FILE.read_text(encoding="utf-8", errors="replace").strip()
        if name:
            return name
    return DEFAULT_OVPN


def vpn_status():
    """(container_state, tunnel_state, error_msg)"""
    err = ""
    err_file = STATE_DIR / "tunnel-error.txt"
    if err_file.is_file():
        try:
            err = err_file.read_text(encoding="utf-8", errors="replace").strip()
        except Exception:
            pass

    # 1. Check if running inside the vpn container directly
    # In the embedded image, the entrypoint script always touches /run/embedded-vpn
    if pathlib.Path("/run/embedded-vpn").is_file():
        if pathlib.Path("/run/tunnel-up").is_file():
            return "running", "up", err
        elif pathlib.Path("/run/openvpn.pid").is_file():
            return "running", "connecting", err
        else:
            return "running", "down", err

    # 2. Otherwise query via docker client (when running as separate container)
    c = get_vpn_container()
    if c is None:
        return "not running", "down", err
    try:
        c.reload()
        state = c.status  # created | running | restarting | exited ...
        res = c.exec_run(
            "sh -c 'if [ -f /run/tunnel-up ]; then echo up;"
            " elif [ -e /site/state/tunnel-stopped ]; then echo down;"
            " else echo connecting; fi'"
        )
        tunnel = res.output.decode(errors="replace").strip() or "connecting"
        return state, tunnel, err
    except DockerException:
        return "unreachable", "?", err


def list_profiles():
    if not OVPN_DIR.is_dir():
        return []
    return sorted(p.name for p in OVPN_DIR.glob("*.ovpn") if p.is_file())


@app.route("/")
def index():
    state, tunnel, err = vpn_status()
    profiles = list_profiles()
    return render_template(
        "index.html",
        profiles=profiles,
        selected=selected_profile(),
        container_state=state,
        tunnel=tunnel,
        tunnel_error=err,
        cred_saved=credentials_configured(),
        no_profiles=(len(profiles) == 0),
    )


@app.post("/select")
def select():
    name = request.form.get("name", "")
    if not SAFE_NAME.match(name) or ".." in name:
        flash("Invalid profile name.", "error")
        return redirect(url_for("index"))
    files = list_profiles()
    if name not in files:
        flash(f"Profile {name} not found in the ovpn folder.", "error")
        return redirect(url_for("index"))

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    SELECTED_FILE.write_text(name + "\n", encoding="utf-8", newline="\n")
    # NOTE: no container restart needed anymore - the vpn container watches
    # state/selected.ovpn and hot-swaps the tunnel itself (keeps its network
    # namespace, so the nginx web container never loses the tunnel).
    flash(f"Default connection set to {name}. Switching to it (takes a few seconds)…", "ok")
    return redirect(url_for("index"))


@app.post("/upload")
def upload():
    files = [f for f in request.files.getlist("profile") if f and f.filename]
    if not files:
        flash("No file chosen.", "error")
        return redirect(url_for("index"))

    OVPN_DIR.mkdir(parents=True, exist_ok=True)
    uploaded, errors = [], []
    for f in files:
        name = pathlib.Path(f.filename).name
        if not SAFE_NAME.match(name) or "." == name[0] or ".." in name:
            errors.append(f"{name}: invalid file name")
            continue
        text = f.read().decode("utf-8", errors="replace")
        if "auth-user-pass" not in text or ("<ca>" not in text and "remote " not in text):
            errors.append(f"{name}: this does not look like an OpenVPN config file")
            continue
        (OVPN_DIR / name).write_text(text, encoding="utf-8", newline="\n")
        uploaded.append(name)

    for err in errors:
        flash(err, "error")
    if uploaded:
        flash(f"Uploaded {len(uploaded)} profile(s): {', '.join(uploaded)}. Pick one with 'Use as default'.", "ok")
    elif not errors:
        flash("No profile was uploaded.", "error")
    return redirect(url_for("index"))


@app.post("/delete")
def delete():
    """Delete one or more .ovpn profiles (multi-select from the panel table).
    The currently connected profile can NOT be deleted - switch first."""
    names = request.form.getlist("name")
    if not names:
        flash("No profile selected.", "error")
        return redirect(url_for("index"))

    files = list_profiles()
    selected = selected_profile()
    deleted, skipped = [], []
    for name in names:
        if name == selected:
            skipped.append(f"{name}: is the active connection - switch first, then delete")
        elif not SAFE_NAME.match(name) or ".." in name or name not in files:
            skipped.append(f"{name}: not found")
        else:
            try:
                (OVPN_DIR / name).unlink()
                deleted.append(name)
            except OSError as exc:
                skipped.append(f"{name}: {exc}")

    if deleted:
        flash(f"Deleted {len(deleted)} profile(s): {', '.join(deleted)}", "ok")
    for skip in skipped:
        flash(skip, "error")
    return redirect(url_for("index"))


def credentials_configured():
    return CONFIG_FILE.is_file() and CONFIG_FILE.stat().st_size > 0


@app.post("/restart")
def restart():
    """Force a tunnel reconnect (same hot path as a profile/credentials change).
    Deliberately NOT a container restart - the network namespace is preserved,
    so the proof page never goes down. If the tunnel was stopped, this
    effectively starts it again."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RELOAD_FILE.write_text("", encoding="utf-8", newline="\n")
    STOP_REQUEST_FILE.unlink(missing_ok=True)
    flash("Tunnel restart requested - reconnecting in a few seconds…", "ok")
    return redirect(url_for("index"))


@app.post("/stop")
def stop():
    """Take the tunnel down on purpose. Vpn container tears openvpn down and
    keeps it down (state/tunnel-stopped) until Start/Restart is pressed."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    START_REQUEST_FILE.unlink(missing_ok=True)
    STOP_REQUEST_FILE.write_text("", encoding="utf-8", newline="\n")
    flash("Tunnel stop requested - traffic will stop leaving through the VPN in a few seconds.", "ok")
    return redirect(url_for("index"))


@app.post("/start")
def start():
    """Bring the tunnel back up after a manual stop."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STOP_REQUEST_FILE.unlink(missing_ok=True)
    START_REQUEST_FILE.write_text("", encoding="utf-8", newline="\n")
    flash("Tunnel start requested - connecting in a few seconds…", "ok")
    return redirect(url_for("index"))


@app.post("/credentials")
def credentials():
    """Save OpenVPN credentials (login.conf) without ever echoing the old ones."""
    username = (request.form.get("username") or "").strip()
    password = request.form.get("password") or ""

    if not username:
        flash("Username may not be empty.", "error")
        return redirect(url_for("index"))

    if not password and credentials_configured():
        # keep the existing password (user only wanted to change the username)
        try:
            lines = CONFIG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
            password = lines[1] if len(lines) > 1 else ""
        except (OSError, IndexError):
            flash("Could not read the existing credentials file - retype the password.", "error")
            return redirect(url_for("index"))

    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(f"{username}\n{password}\n", encoding="utf-8", newline="\n")

    # tell the vpn watcher to reconnect (credentials only apply when openvpn starts)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RELOAD_FILE.write_text("", encoding="utf-8", newline="\n")

    flash("Credentials saved. The tunnel is reconnecting with them…", "ok")
    return redirect(url_for("index"))


@app.get("/health")
def health():
    """Lightweight probe endpoint for healthchecks/updaters."""
    return {"status": "ok"}


@app.get("/status")
def status():
    """JSON status for the auto-refresh in the UI (no flash session side effects)."""
    state, tunnel, err = vpn_status()
    profiles = list_profiles()
    selected = selected_profile()
    if selected not in profiles:
        selected = ""

    # Read IP info from state/ipinfo.json or www/ipinfo.json if available
    ipinfo = {}
    if profiles:
        for candidate in [STATE_DIR / "ipinfo.json", WWW_DIR / "ipinfo.json"]:
            if candidate.is_file():
                try:
                    ipinfo = json.loads(candidate.read_text(encoding="utf-8", errors="replace"))
                    if ipinfo and ipinfo.get("ip"):
                        break
                except Exception:
                    pass

    return {
        "container_state": state,
        "tunnel": tunnel,
        "selected": selected,
        "profiles": profiles,
        "error": err,
        "ipinfo": ipinfo,
        "wanted": "stopped" if STOPPED_FILE.is_file() else "auto",
    }


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
