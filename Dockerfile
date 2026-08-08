# syntax=docker/dockerfile:1

# ── Runtime base: PHP 8.4 CLI + coqui extension set (parity with install.sh) ──
FROM php:8.4-cli-bookworm

ARG COQUI_VERSION
LABEL org.opencontainers.image.title="coqui" \
      org.opencontainers.image.source="https://github.com/carmelosantana/coqui-installer" \
      org.opencontainers.image.description="Coqui CAP API + Flutter web UI (single container)"

# System deps: build headers for the PHP extensions + tools for fetch/verify.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl coreutils supervisor \
        libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
        libxml2-dev libsqlite3-dev libonig-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" dom xml pdo_sqlite mbstring gd pcntl posix; \
    rm -rf /var/lib/apt/lists/*

# Caddy reverse proxy (single-origin front for web UI + /api proxy).
COPY --from=caddy:2 /usr/bin/caddy /usr/bin/caddy

# Assemble the coqui server from its prebuilt release (fail-closed checksum verify).
COPY docker/fetch-coqui.sh /usr/local/bin/fetch-coqui.sh
RUN chmod +x /usr/local/bin/fetch-coqui.sh \
    && /usr/local/bin/fetch-coqui.sh "${COQUI_VERSION}" /srv/coqui

# Record the server version so AppVersion reports it at runtime.
ENV COQUI_VERSION=${COQUI_VERSION}

# Web bundle: fetched by release tag, overridable via WEB_TARBALL_URL, or stubbed for CI.
ARG COQUI_APP_VERSION=""
ARG WEB_TARBALL_URL=""
ARG COQUI_WEB_STUB=""
LABEL org.opencontainers.image.app_version=${COQUI_APP_VERSION}

COPY docker/fetch-web.sh /usr/local/bin/fetch-web.sh
RUN chmod +x /usr/local/bin/fetch-web.sh \
    && COQUI_WEB_STUB="${COQUI_WEB_STUB}" WEB_TARBALL_URL="${WEB_TARBALL_URL}" \
       /usr/local/bin/fetch-web.sh "${COQUI_APP_VERSION}" /srv/web

COPY docker/Caddyfile /etc/caddy/Caddyfile

WORKDIR /srv/coqui

# ── Process supervision, first-run config scaffold, health & entry ──
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/openclaw.default.json /srv/defaults/openclaw.default.json
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV COQUI_CONFIG_DIR=/config \
    COQUI_DATA_DIR=/data \
    COQUI_DEFAULT_CONFIG=/srv/defaults/openclaw.default.json \
    CADDY_PORT=8080

EXPOSE 8080
VOLUME ["/config", "/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3300/api/v1/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
