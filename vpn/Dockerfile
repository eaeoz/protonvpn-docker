FROM alpine:3.20

RUN apk add --no-cache openvpn python3 py3-pip py3-flask py3-requests wget ca-certificates

# Copy web panel and proof templates inside the VPN image
WORKDIR /app
COPY panel/app.py /app/app.py
COPY panel/templates /app/templates
COPY www /app/www_default

WORKDIR /
COPY vpn/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
