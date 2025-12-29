# Minimal sandbox container for secure agent execution
#
# This image provides:
# - iptables for network lockdown (only proxy IP allowed)
# - Basic utilities for agent execution
# - Non-root user for safety
#
# Usage:
#   docker build -t strider/sandbox:latest priv/sandbox/
#   docker run -e STRIDER_PROXY_IP=192.168.1.100 strider/sandbox:latest <command>

FROM alpine:3.21

# Install minimal dependencies
RUN apk add --no-cache \
    iptables \
    ip6tables \
    bash \
    curl \
    ca-certificates \
    su-exec \
    # For running various agents
    nodejs \
    npm \
    python3 \
    py3-pip \
    git

# Create non-root user for agent execution
RUN addgroup -g 1000 sandbox && \
    adduser -u 1000 -G sandbox -h /workspace -s /bin/bash -D sandbox

# Create workspace directory
RUN mkdir -p /workspace && chown sandbox:sandbox /workspace

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default working directory
WORKDIR /workspace

# Run as root initially (needed for iptables), entrypoint drops to sandbox user
# Note: Fly machines can run with --cap-add NET_ADMIN for iptables

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
