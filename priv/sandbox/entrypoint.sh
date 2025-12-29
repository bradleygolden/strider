#!/bin/bash
# Sandbox entrypoint script
#
# This script:
# 1. Sets up iptables based on network mode
# 2. Configures HTTP_PROXY/HTTPS_PROXY environment variables
# 3. Drops privileges to sandbox user
# 4. Executes the provided command
#
# Required environment variables:
#   STRIDER_PROXY_IP - IP address of the external proxy
#   STRIDER_PROXY_PORT - Port of the external proxy (default: 4000)
#
# Optional environment variables:
#   STRIDER_NETWORK_MODE - Network isolation mode:
#     "proxy_only" (default) - All traffic must go through proxy
#     "hybrid" - Proxy + direct external, block internal networks
#     "open" - No network restrictions (for testing only)
#   STRIDER_SKIP_IPTABLES - Set to "true" to skip iptables setup (for testing)
#   STRIDER_RUN_AS_ROOT - Set to "true" to run command as root (not recommended)

set -e

# Defaults
STRIDER_PROXY_PORT="${STRIDER_PROXY_PORT:-4000}"
STRIDER_NETWORK_MODE="${STRIDER_NETWORK_MODE:-proxy_only}"

# Validate required environment
if [ -z "$STRIDER_PROXY_IP" ]; then
    echo "ERROR: STRIDER_PROXY_IP environment variable is required"
    echo "This should be the private IP of the proxy service"
    exit 1
fi

# Setup iptables rules to restrict network access
setup_network_isolation() {
    if [ "$STRIDER_SKIP_IPTABLES" = "true" ]; then
        echo "[sandbox] Skipping iptables setup (STRIDER_SKIP_IPTABLES=true)"
        return 0
    fi

    echo "[sandbox] Setting up network isolation (mode: $STRIDER_NETWORK_MODE)..."

    # Flush existing rules
    iptables -F OUTPUT 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true

    # Allow loopback
    iptables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT

    # Allow established connections (for responses)
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    case "$STRIDER_NETWORK_MODE" in
        "open")
            echo "[sandbox] Open mode - no network restrictions"
            iptables -A OUTPUT -j ACCEPT
            ip6tables -A OUTPUT -j ACCEPT
            ;;

        "hybrid")
            echo "[sandbox] Hybrid mode - proxy + direct external, blocking internal"

            # Configure public DNS (required since we block internal DNS)
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 1.1.1.1" >> /etc/resolv.conf

            # Allow traffic to proxy
            if echo "$STRIDER_PROXY_IP" | grep -q ":"; then
                ip6tables -A OUTPUT -d "$STRIDER_PROXY_IP" -p tcp --dport "$STRIDER_PROXY_PORT" -j ACCEPT
            else
                iptables -A OUTPUT -d "$STRIDER_PROXY_IP" -p tcp --dport "$STRIDER_PROXY_PORT" -j ACCEPT
            fi

            # Allow DNS only to public resolvers (prevents internal DNS reconnaissance)
            # Google DNS
            iptables -A OUTPUT -d 8.8.8.8 -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d 8.8.4.4 -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d 8.8.8.8 -p tcp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d 8.8.4.4 -p tcp --dport 53 -j ACCEPT
            # Cloudflare DNS
            iptables -A OUTPUT -d 1.1.1.1 -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d 1.0.0.1 -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d 1.1.1.1 -p tcp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d 1.0.0.1 -p tcp --dport 53 -j ACCEPT
            # Google IPv6 DNS
            ip6tables -A OUTPUT -d 2001:4860:4860::8888 -p udp --dport 53 -j ACCEPT
            ip6tables -A OUTPUT -d 2001:4860:4860::8844 -p udp --dport 53 -j ACCEPT
            # Cloudflare IPv6 DNS
            ip6tables -A OUTPUT -d 2606:4700:4700::1111 -p udp --dport 53 -j ACCEPT
            ip6tables -A OUTPUT -d 2606:4700:4700::1001 -p udp --dport 53 -j ACCEPT

            # Block internal/private networks (before allowing HTTP - order matters!)
            iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
            iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
            iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
            iptables -A OUTPUT -d 169.254.0.0/16 -j DROP  # Link-local + cloud metadata
            ip6tables -A OUTPUT -d fc00::/7 -j DROP       # IPv6 private
            ip6tables -A OUTPUT -d fe80::/10 -j DROP      # IPv6 link-local

            # Allow external HTTP/HTTPS (internal already blocked above)
            iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
            iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
            ip6tables -A OUTPUT -p tcp --dport 80 -j ACCEPT
            ip6tables -A OUTPUT -p tcp --dport 443 -j ACCEPT

            # Drop everything else
            iptables -A OUTPUT -j DROP
            ip6tables -A OUTPUT -j DROP
            ;;

        "proxy_only"|*)
            echo "[sandbox] Proxy-only mode - all traffic through proxy"

            # Allow traffic to proxy IP
            if echo "$STRIDER_PROXY_IP" | grep -q ":"; then
                ip6tables -A OUTPUT -d "$STRIDER_PROXY_IP" -p tcp --dport "$STRIDER_PROXY_PORT" -j ACCEPT
            else
                iptables -A OUTPUT -d "$STRIDER_PROXY_IP" -p tcp --dport "$STRIDER_PROXY_PORT" -j ACCEPT
            fi

            # Allow DNS
            iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
            ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
            ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT

            # Drop everything else
            iptables -A OUTPUT -j DROP
            ip6tables -A OUTPUT -j DROP
            ;;
    esac

    echo "[sandbox] Network isolation configured"
}

# Set proxy environment variables (only in proxy_only mode)
setup_proxy_env() {
    if [ "$STRIDER_NETWORK_MODE" = "proxy_only" ]; then
        export HTTP_PROXY="http://$STRIDER_PROXY_IP:$STRIDER_PROXY_PORT"
        export HTTPS_PROXY="http://$STRIDER_PROXY_IP:$STRIDER_PROXY_PORT"
        export http_proxy="$HTTP_PROXY"
        export https_proxy="$HTTPS_PROXY"

        # Also set for npm/node
        export npm_config_proxy="$HTTP_PROXY"
        export npm_config_https_proxy="$HTTPS_PROXY"

        echo "[sandbox] Proxy configured: $HTTP_PROXY"
    else
        # Export proxy URL for sandbox client to use selectively
        export STRIDER_PROXY_URL="http://$STRIDER_PROXY_IP:$STRIDER_PROXY_PORT"
        echo "[sandbox] Proxy available at: $STRIDER_PROXY_URL (not forced)"
    fi
}

# Run the command
run_command() {
    if [ $# -eq 0 ]; then
        echo "ERROR: No command provided"
        echo "Usage: docker run strider/sandbox:latest <command> [args...]"
        exit 1
    fi

    if [ "$STRIDER_RUN_AS_ROOT" = "true" ]; then
        echo "[sandbox] Running as root (STRIDER_RUN_AS_ROOT=true)"
        exec "$@"
    else
        echo "[sandbox] Running as sandbox user"
        exec su-exec sandbox "$@"
    fi
}

# Main
echo "[sandbox] Strider Sandbox Container"
echo "[sandbox] Proxy IP: $STRIDER_PROXY_IP"
echo "[sandbox] Proxy Port: $STRIDER_PROXY_PORT"

# Setup network isolation (requires NET_ADMIN capability)
setup_network_isolation || {
    echo "WARNING: Failed to setup iptables. Container may need --cap-add NET_ADMIN"
    echo "Continuing without network isolation..."
}

# Setup proxy environment
setup_proxy_env

# Run the command
run_command "$@"
