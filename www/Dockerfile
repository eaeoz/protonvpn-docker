FROM nginx:alpine

# The proof page is fully self-contained: index.html and the ip update loop
# are baked into the image, so it runs from ANY folder / machine with no
# host-side files. Only the optional ./state volume (for the live profile
# name) is mounted at runtime.

COPY index.html /usr/share/nginx/html/index.html
COPY ipupdate.sh /etc/ipupdate.sh
RUN chmod +x /etc/ipupdate.sh

EXPOSE 80

ENTRYPOINT ["/etc/ipupdate.sh"]
