#!/bin/sh
# Runs inside the nginx container, which shares the OpenVPN network namespace
# (network_mode: "service:vpn"). Every request it makes goes through the
# ProtonVPN tunnel — this is what the "proof" page shows.

HTML=/usr/share/nginx/html
STATE_DIR=/site/state

(
    # wait until the tunnel device exists (shared netns = we see it too)
    while ! grep -q tun0 /proc/net/dev 2>/dev/null; do
        sleep 1
    done

    echo '{"ip":"loading...","country":"Detecting...","city":"","org":""}' > "$HTML/ipinfo.json"
    echo "loading..." > "$HTML/ip.txt"

    while true; do
        profile="$(cat "$STATE_DIR/current-profile" 2>/dev/null | tr -d '\r' || echo unknown)"
        printf '%s\n' "$profile" > "$HTML/profile.txt"

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

        sleep 20

        # Watchdog: if we lost the netns (e.g. the vpn container was recreated and
        # we were not), tun0 disappears from /proc/net/dev *and stays gone* even
        # after a new tunnel is up somewhere else. Exit -> compose restart policy
        # brings this container back and it re-attaches to the vpn netns.
        n=0
        while ! grep -q tun0 /proc/net/dev 2>/dev/null; do
            n=$((n + 1))
            [ "$n" -gt 60 ] && {
                echo "[ipupdate] tun0 gone for 60s - netns lost, exiting so we re-attach"
                exit 1
            }
            sleep 1
        done
    done
) &

exec nginx -g "daemon off;"
