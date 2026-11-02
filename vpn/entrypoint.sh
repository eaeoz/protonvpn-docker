#!/bin/sh
# ProtonVPN OpenVPN tunnel
#
# Profile selection precedence:
#   1. state/selected.ovpn   -> written by the panel ("use as default")
#   2. DEFAULT_OVPN env var  -> from .env
#   3. first *.ovpn found in the ovpn folder
#
# The credentials file (config/login.conf) is injected into whatever profile
# is used, so ALL profiles work with the same OpenVPN credentials.
#
# NOTE: the profile is hot-swapped *inside* this container (a watcher loop
# restarts openvpn when state/selected.ovpn changes). The container and its
# network namespace are intentionally NOT recreated, so other containers
# sharing this netns (the nginx "web" container) never lose the tunnel.

set -u

CONFIG_DIR="${OVPN_DIR:-/site/ovpn}"
CRED_FILE="${CRED_FILE:-/site/config/login.conf}"
STATE_DIR="/site/state"
SELECTED="$STATE_DIR/selected.ovpn"
TUNNEL_UP_MARKER="/run/tunnel-up"
TUNNEL_DNS="${TUNNEL_DNS:-10.96.0.1}"   # decimal resolver Proton PUSHes (dhcp-option DNS)

# ---------------------------------------------------------------- profile pick
# Strip \r: host-side (Windows) editors/write tools end lines with CRLF and the
# bind-mounted file carries it over, which breaks the -f file check below.
pick_profile() {
    PROFILE="$(cat "$SELECTED" 2>/dev/null | tr -d '\r' || true)"

    if [ -z "$PROFILE" ]; then
        PROFILE="${DEFAULT_OVPN:-}"
    fi

    if [ -z "$PROFILE" ] || [ ! -f "$CONFIG_DIR/$PROFILE" ]; then
        PROFILE="$(ls "$CONFIG_DIR" 2>/dev/null | grep '\.ovpn$' | head -n 1 || true)"
    fi

    [ -n "$PROFILE" ] && [ -f "$CONFIG_DIR/$PROFILE" ]
}

# ------------------------------------------------------- start/switch the tunnel
start_tunnel() {
    if ! pick_profile; then
        echo "[vpn] ERROR: no .ovpn profile found in $CONFIG_DIR"
        echo "      drop a profile there (or upload it at http://localhost:8000) and restart."
        exit 1
    fi

    echo "[vpn] using profile: $PROFILE"
    echo "$PROFILE" > "$STATE_DIR/current-profile"

    # Replace any `auth-user-pass ...` line (even the original Proton download,
    # which has no path) with our shared credentials file.
    awk -v cred="$CRED_FILE" '
        /^[ \t]*auth-user-pass/ { print "auth-user-pass " cred; if (!seen) { print "auth-nocache"; seen = 1 }; next }
        { print }
    ' "$CONFIG_DIR/$PROFILE" > /tmp/client.conf

    if [ ! -s /tmp/client.conf ]; then
        echo "[vpn] ERROR: failed to build client config"
        exit 1
    fi

    # tunnel is (re)connecting: drop the healthcheck marker until the new tun0 is up
    rm -f "$TUNNEL_UP_MARKER"
    rm -f "$STATE_DIR/tunnel-error.txt"

    openvpn --config /tmp/client.conf --verb 3 2>&1 | tee /tmp/openvpn.log &
    OVPN_PID=$!
    echo "$OVPN_PID" > /run/openvpn.pid
}

# ------------------------------------------------------- profile change watcher
(
    last="$(cat "$SELECTED" 2>/dev/null | tr -d '\r' || true)"
    while true; do
        sleep 5
        now="$(cat "$SELECTED" 2>/dev/null | tr -d '\r' || true)"
        switch_reason=""
        if [ -n "$now" ] && [ "$now" != "$last" ]; then
            last="$now"
            switch_reason="profile changed -> $now, switching tunnel…"
        fi
        if [ -e "$STATE_DIR/reload-request" ]; then
            rm -f "$STATE_DIR/reload-request"
            switch_reason="reload requested (credentials changed), reconnecting…"
        fi
        if [ -n "$switch_reason" ]; then
            echo "[vpn] $switch_reason"
            # kill the running openvpn (pid file: started by parent start_tunnel)
            if [ -f /run/openvpn.pid ]; then
                kill "$(cat /run/openvpn.pid 2>/dev/null)" 2>/dev/null || true
                # wait for the OLD tun0 to fully disappear before starting the
                # new session (starting too early triggers route-add races)
                n=0
                while grep -q tun0 /proc/net/dev 2>/dev/null && [ "$n" -lt 20 ]; do
                    sleep 1
                    n=$((n + 1))
                done
            fi
            start_tunnel
        fi
    done
) &

# ------------------------------------------------------- tunnel-up & error monitoring
# When tun0 appears: switch DNS to the Proton tunnel resolver and drop the
# marker file the healthcheck / panel / proof page look for.
(
    while true; do
        if grep -q tun0 /proc/net/dev 2>/dev/null; then
            if [ ! -f "$TUNNEL_UP_MARKER" ]; then
                echo "nameserver $TUNNEL_DNS" > /etc/resolv.conf
                touch "$TUNNEL_UP_MARKER"
                rm -f "$STATE_DIR/tunnel-error.txt"
                echo "[vpn] tunnel is up (tun0 present, DNS -> $TUNNEL_DNS)"
            fi
        else
            # Check log for explicit authentication or connection failures
            if [ -f /tmp/openvpn.log ] && [ ! -f "$TUNNEL_UP_MARKER" ]; then
                if grep -qi "AUTH_FAILED" /tmp/openvpn.log; then
                    echo "AUTH_FAILED: Authentication failed (wrong OpenVPN username or password)." > "$STATE_DIR/tunnel-error.txt"
                elif grep -qi "TLS Error: TLS key negotiation failed" /tmp/openvpn.log; then
                    echo "TLS_ERROR: Handshake timed out or certificate rejected." > "$STATE_DIR/tunnel-error.txt"
                fi
            fi
        fi
        sleep 2
    done
) &

# ------------------------------------------------------- start embedded web control panel
if [ -f /app/app.py ]; then
    echo "[vpn] starting embedded control panel on port 8000…"
    (cd /app && python3 -u app.py) &
fi

# ---------------------------------------------------------------- run
start_tunnel || exit 1

# PID1 must NEVER exit: hot-swaps are done by the watcher (which kills/restarts
# openvpn), so waiting on the first openvpn pid would return and kill the
# container (breaking the netns of containers sharing it). Instead, stay
# resident and restart openvpn only if it dies on its own.
while true; do
    sleep 15
    if ! kill -0 "$(cat /run/openvpn.pid 2>/dev/null)" 2>/dev/null; then
        echo "[vpn] openvpn exited unexpectedly, restarting tunnel…"
        start_tunnel
    fi
done
