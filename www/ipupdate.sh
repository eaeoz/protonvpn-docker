#!/bin/sh
# Runs inside the nginx container, which shares the OpenVPN network namespace
# (network_mode: "service:vpn"). Every request it makes goes through the
# ProtonVPN tunnel — this is what the "proof" page shows.
#
# IMPORTANT: this script IS pid 1. nginx runs as a background child. If the
# network namespace is lost (the vpn container was recreated without us), the
# watchdog exits - and because we are pid 1 the WHOLE CONTAINER restarts, so
# compose's restart policy re-attaches us to the new tunnel netns with a fresh
# updater. (A backgrounded subshell exiting would NOT restart anything.)

HTML="${HTML:-/usr/share/nginx/html}"
STATE_DIR="${STATE_DIR:-/site/state}"

nginx -g "daemon off;" &

tunnel_up() {
    grep -qs 'tun[0-9]' /proc/net/dev 2>/dev/null
}

reset_stale_data() {
    : > "$HTML/ip.txt"
    echo '{"ip":"no-profile","country_name":"No OpenVPN profile loaded","city":"","org":""}' > "$HTML/ipinfo.json"
    rm -f "$STATE_DIR/ipinfo.json"
}

# Updater loop in the background - pid1 (this shell) keeps a hold on it
(
    # Reset any proof data left behind by a previous session FIRST, so a fresh
    # start with an empty ovpn folder never serves a stale profile name or a
    # cached exit IP of an old connection.
    echo "no-profile" > "$HTML/profile.txt"
    reset_stale_data

    while true; do
        profile="$(cat "$STATE_DIR/current-profile" 2>/dev/null | tr -d '\r' || true)"
        printf '%s\n' "${profile:-unknown}" > "$HTML/profile.txt"

        if ! tunnel_up; then
            if [ -f "$STATE_DIR/tunnel-stopped" ]; then
                # Tunnel stopped on purpose from the panel: never show stale
                # exit-IP/geo data from the previous connection.
                echo "stopped" > "$HTML/ip.txt"
                echo '{"ip":"stopped","country_name":"Tunnel stopped","city":"","region":"","org":""}' > "$HTML/ipinfo.json"
                rm -f "$STATE_DIR/ipinfo.json"
            elif [ -z "$profile" ]; then
                # No profile loaded (fresh start / all profiles deleted):
                # keep placeholders and do NOT display any IP or geo data.
                rm -f "$STATE_DIR/ipinfo.json"
                echo "no-profile" > "$HTML/profile.txt"
                reset_stale_data
            else
                # Profile exists, tunnel not up yet: show "loading..." instead
                # of stale data while the connection comes up.
                echo "loading..." > "$HTML/ip.txt"
                echo '{"ip":"loading...","country":"Detecting...","country_name":"Detecting...","city":"","org":""}' > "$HTML/ipinfo.json"
            fi
        else
            # Tunnel up: fetch exit IP & geo data through it, then publish.

            # Fetch IP and geo information from ipapi.co (or fallback to ipwho.is / ipify)
            json="$(wget -q -O- --timeout=5 https://ipapi.co/json/ 2>/dev/null)"

            # Check if json contains "ip":
            case "$json" in
                *'"ip"'*)
                    echo "$json" > "$HTML/ipinfo.json"
                    echo "$json" > "$STATE_DIR/ipinfo.json" 2>/dev/null
                    ip="$(printf '%s' "$json" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
                    [ -n "$ip" ] && echo "$ip" > "$HTML/ip.txt"
                    ;;
                *)
                    # Fallback to ipwho.is
                    fallback="$(wget -q -O- --timeout=5 https://ipwho.is/ 2>/dev/null)"
                    case "$fallback" in
                        *'"ip"'*)
                            # Format as compatible JSON
                            echo "$fallback" > "$HTML/ipinfo.json"
                            echo "$fallback" > "$STATE_DIR/ipinfo.json" 2>/dev/null
                            ip="$(printf '%s' "$fallback" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
                            [ -n "$ip" ] && echo "$ip" > "$HTML/ip.txt"
                            ;;
                        *)
                            # Fallback just for IP if geo services are rate-limited
                            simple_ip="$(wget -q -O- --timeout=4 https://api.ipify.org 2>/dev/null)"
                            [ -z "$simple_ip" ] && simple_ip="$(wget -q -O- --timeout=4 https://icanhazip.com 2>/dev/null)"
                            if [ -n "$simple_ip" ]; then
                                echo "$simple_ip" > "$HTML/ip.txt"
                                printf '{"ip":"%s","country_name":"Unknown","city":"","org":""}\n' "$simple_ip" > "$HTML/ipinfo.json"
                                printf '{"ip":"%s","country_name":"Unknown","city":"","org":""}\n' "$simple_ip" > "$STATE_DIR/ipinfo.json" 2>/dev/null
                            else
                                echo "(could not fetch external ip - tunnel may be down)" > "$HTML/ip.txt"
                                echo '{"ip":"error","country_name":"Unavailable"}' > "$HTML/ipinfo.json"
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi

        sleep 20

        # Watchdog: if we lost the netns (e.g. the vpn container was recreated
        # and we were not), tun devices disappear from /proc/net/dev *and stay
        # gone* even after a new tunnel is up somewhere else. As pid 1, exiting
        # here restarts the container so we re-attach to the fresh netns.
        # A deliberately stopped tunnel does NOT count as netns loss.
        if ! tunnel_up && [ ! -f "$STATE_DIR/tunnel-stopped" ]; then
            n=0
            while ! tunnel_up; do
                n=$((n + 1))
                [ "$n" -gt 60 ] && {
                    echo "[ipupdate] tun device gone for 60s - netns lost, restarting container to re-attach"
                    exit 1
                }
                sleep 1
            done
        fi
    done
) &
UPD_PID=$!

# Stay resident as pid 1 while the updater runs. If the updater exits
# (netns loss watchdog dies), pid1 exits too -> container restarts -> re-attach.
while kill -0 "$UPD_PID" 2>/dev/null; do
    sleep 5
done
echo "[ipupdate] updater exited - restarting the container"
exit 1
