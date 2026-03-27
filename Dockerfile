FROM maximhq/bifrost:v1.4.7

# Switch to root to copy files (image runs as non-root 'appuser')
USER root
COPY config.json /app/data/config.json
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh && chown appuser:appuser /app/data/config.json /app/start.sh
USER appuser

# Render.com provides PORT=10000 by default; upstream entrypoint reads APP_PORT
ENV APP_PORT=10000
ENV APP_HOST=0.0.0.0
ENV LOG_LEVEL=info
ENV LOG_STYLE=json

ENTRYPOINT []
CMD ["/app/start.sh"]
