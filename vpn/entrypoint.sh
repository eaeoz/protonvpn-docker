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

# Marker indicating this entrypoint is running inside this container
mkdir -p /run
touch /run/embedded-vpn

# Seed proof files into /site/www if /site/www is mounted
if [ -d /site/www ] && [ ! -f /site/www/index.html ] && [ -d /app/www_default ]; then
    echo "[vpn] seeding default proof page files into /site/www…"
    cp -r /app/www_default/* /site/www/ 2>/dev/null || true
fi

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

# Stop the previous tunnel session completely. Every profile switch / credential
# change passes through this, so leftover openvpn processes (and their tun
# devices + default routes) MUST die here. Otherwise the new session stacks on
# top of the old one: the stale instance keeps holding the default routes, so
# traffic keeps exiting through the OLD location, while extra tun devices
# (tun1, tun2, …) pile up - which also breaks every "tun0" check in the
# updaters / healthcheck watchdogs.
stop_tunnel() {
    [ -f /run/openvpn.pid ] && {
        OLD="$(cat /run/openvpn.pid 2>/dev/null || true)"
        [ -n "$OLD" ] && kill "$OLD" 2>/dev/null || true
        rm -f /run/openvpn.pid
    }
    # Belts and braces: kill ANY openvpn instance still alive in this netns
    # (strays from earlier stacks included).
    killall openvpn 2>/dev/null || true
    pkill -x openvpn 2>/dev/null || true

    # Wait for every tun device - and with them every stale route - to vanish.
    n=0
    while grep -qs 'tun[0-9]' /proc/net/dev 2>/dev/null && [ "$n" -lt 20 ]; do
        sleep 1
        n=$((n + 1))
    done
}

start_tunnel() {
    if ! pick_profile; then
        echo "[vpn] WARNING: No .ovpn profile found in $CONFIG_DIR."
        echo "      Web Control Panel is running at http://localhost:8000."
        echo "      Upload a .ovpn profile or save credentials from the UI to establish the tunnel."
        # No profile: clear runtime state left behind by a previous session so
        # the proof page no longer shows an old profile name or cached IP data.
        : > "$STATE_DIR/current-profile"
        rm -f "$TUNNEL_UP_MARKER"
        return 1
    fi

    echo "[vpn] using profile: $PROFILE"
    echo "$PROFILE" > "$STATE_DIR/current-profile"

    # Replace any `auth-user-pass ...` line (even the original Proton download,
    # which has no path) with our shared credentials file.
    awk -v cred="$CRED_FILE" '
        /^[ \t]*auth-user-pass/ { print "auth-user-pass " cred; if (!seen) { print "auth-nocache"; seen = 1 }; next }
        # Drop the dev directive of the profile - a PINNED device name is
        # appended below so the interface is always "tun0" (otherwise OpenVPN
        # grabs tun1/tun2 on every switch and every tun0-watcher breaks).
        /^[ \t]*dev([ \t].*)?$/ { next }
        { print }
    ' "$CONFIG_DIR/$PROFILE" > /tmp/client.conf

    # Pin the tun device name
    printf '\ndev tun0\n' >> /tmp/client.conf

    if [ ! -s /tmp/client.conf ]; then
        echo "[vpn] ERROR: failed to build client config"
        exit 1
    fi

    # tunnel is (re)connecting: drop the healthcheck marker until the new tun0 is up
    rm -f "$TUNNEL_UP_MARKER"
    rm -f "$STATE_DIR/tunnel-error.txt"

    # Kill any previous session FIRST (old instance must not keep tun0/routes)
    stop_tunnel

    openvpn --config /tmp/client.conf --verb 3 2>&1 | tee /tmp/openvpn.log &
    OVPN_PID=$!
    echo "$OVPN_PID" > /run/openvpn.pid
}

# ------------------------------------------------------- control watcher
# Handles: explicit stop/start requests from the panel, profile changes and
# credentials reloads. A controlled stop persists state/tunnel-stopped, which
# blocks the auto-restart loop below until an explicit start arrives.
(
    last="$(cat "$SELECTED" 2>/dev/null | tr -d '\r' || true)"
    while true; do
        sleep 5

        # ---- STOP request: take the tunnel down and remember we did it
        if [ -e "$STATE_DIR/tunnel-stop-request" ]; then
            rm -f "$STATE_DIR/tunnel-stop-request"
            touch "$STATE_DIR/tunnel-stopped"
            rm -f "$TUNNEL_UP_MARKER"
            rm -f "$STATE_DIR/ipinfo.json"
            echo "[vpn] stop requested - taking the tunnel down…"
            stop_tunnel
            # restore Docker's embedded DNS (the tunnel resolver is gone now)
            [ -f /run/resolv.conf.orig ] && cat /run/resolv.conf.orig > /etc/resolv.conf
            echo "[vpn] tunnel is stopped - start it from the control panel"
            continue
        fi

        action=""
        resume=""
        if [ -e "$STATE_DIR/tunnel-start-request" ]; then
            rm -f "$STATE_DIR/tunnel-start-request"
            action="start requested"
            resume=1
        fi
        if [ -e "$STATE_DIR/reload-request" ]; then
            rm -f "$STATE_DIR/reload-request"
            action="${action:+$action + }reload requested (credentials changed), reconnecting"
            resume=1
        fi
        now="$(cat "$SELECTED" 2>/dev/null | tr -d '\r' || true)"
        if [ -n "$now" ] && [ "$now" != "$last" ]; then
            last="$now"
            action="${action:+$action + }profile changed -> $now, switching"
            resume=1
        fi
        if [ -n "$resume" ]; then
            if [ -e "$STATE_DIR/tunnel-stopped" ]; then
                echo "[vpn] re-enabling previously stopped tunnel"
            fi
            rm -f "$STATE_DIR/tunnel-stopped"
            rm -f "$STATE_DIR/ipinfo.json"   # stale exit-IP data clears with the old session
            echo "[vpn] $action"
            stop_tunnel
            start_tunnel
        fi
    done
) &

# ------------------------------------------------------- tunnel-up & error monitoring
# When tun0 appears: switch DNS to the Proton tunnel resolver and drop the
# marker file the healthcheck / panel / proof page look for.
(
    while true; do
        if grep -qs 'tun[0-9]' /proc/net/dev 2>/dev/null; then
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
# Keep a pristine copy of Docker's embedded DNS config so a controlled stop
# can restore it (the Proton tunnel resolver only exists while tun0 is up).
cp /etc/resolv.conf /run/resolv.conf.orig 2>/dev/null || true

if [ -e "$STATE_DIR/tunnel-stopped" ]; then
    echo "[vpn] tunnel is stopped (state/tunnel-stopped) - start it from the control panel"
else
    start_tunnel || true
fi

# PID1 must NEVER exit: hot-swaps are done by the watcher (which kills/restarts
# openvpn), so waiting on the first openvpn pid would return and kill the
# container (breaking the netns of containers sharing it). Instead, stay
# resident and restart openvpn only if it dies on its own or profile appears.
while true; do
    sleep 15
    # Tunnel intentionally stopped from the panel: keep it down, never auto-restart
    if [ -e "$STATE_DIR/tunnel-stopped" ]; then
        continue
    fi
    if [ -f /run/openvpn.pid ]; then
        if ! kill -0 "$(cat /run/openvpn.pid 2>/dev/null)" 2>/dev/null; then
            echo "[vpn] openvpn exited unexpectedly, restarting tunnel…"
            start_tunnel || true
        fi
    else
        # If openvpn was not started yet (e.g. initial start with empty ovpn folder)
        if pick_profile 2>/dev/null; then
            echo "[vpn] profile detected, starting tunnel…"
            start_tunnel || true
        fi
    fi
done
