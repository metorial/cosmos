# Build Caddy with layer4 plugin
FROM caddy:builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-l4

# Final image
FROM debian:bookworm-slim

# Install ca-certificates for HTTPS
RUN apt-get update && \
    apt-get install -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy the custom-built Caddy
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Copy Caddyfile
COPY Caddyfile /etc/caddy/Caddyfile

# Create caddy user
RUN groupadd -r caddy && \
    useradd -r -g caddy -s /sbin/nologin caddy && \
    mkdir -p /var/lib/caddy && \
    chown -R caddy:caddy /var/lib/caddy

# Expose all the ports we're proxying
EXPOSE 4646 5010 5020 8080 8081 8200 8500

# Run as caddy user
USER caddy

# Run Caddy
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
