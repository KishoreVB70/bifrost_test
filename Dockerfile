# Stage 1: Get Bifrost binary
FROM maximhq/bifrost:v1.4.7 AS bifrost

# Stage 2: Caddy + Bifrost
FROM caddy:2-alpine

COPY --from=bifrost /app/bifrost /app/bifrost
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

CMD ["/app/start.sh"]
