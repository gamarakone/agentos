#!/usr/bin/env bash
#
# Phase 03: Configure system services
# Sets up systemd units, AppArmor profiles, credential vault, and audit logging
#
set -euo pipefail

log "Configuring system services..."

# ── systemd service for OpenClaw Gateway ───────────────────────────
log "Installing OpenClaw gateway systemd service..."
cp "${PROJECT_ROOT}/config/systemd/agentos-gateway.service" \
   "${ROOTFS}/etc/systemd/system/agentos-gateway.service"

# ── Credential broker service ──────────────────────────────────────
log "Creating credential broker..."
cat > "${ROOTFS}/opt/agentos/bin/credential-broker.sh" <<'BROKER'
#!/usr/bin/env bash
#
# Credential Broker for AgentOS
# Reads secrets from /etc/agentos/vault/ and exposes them via a Unix socket.
# The agent process can request tokens but cannot read the vault directly.
#
set -euo pipefail

VAULT_DIR="/etc/agentos/vault"
SOCKET_PATH="/run/agentos/credentials.sock"
LOG="/var/log/agentos/broker.log"

mkdir -p "$(dirname "$SOCKET_PATH")"

log_broker() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [broker] $*" >> "$LOG"
}

# Clean up old socket
rm -f "$SOCKET_PATH"

log_broker "Credential broker starting on $SOCKET_PATH"

# Simple socket server using socat
# Accepts requests like: GET <key_name>
# Returns the contents of /etc/agentos/vault/<key_name>
socat UNIX-LISTEN:"$SOCKET_PATH",fork,mode=660,user=root,group=agentos EXEC:"/opt/agentos/bin/credential-handler.sh" &

log_broker "Broker listening"
wait
BROKER

cat > "${ROOTFS}/opt/agentos/bin/credential-handler.sh" <<'HANDLER'
#!/usr/bin/env bash
# Handles a single credential request from the broker socket
set -euo pipefail

VAULT_DIR="/etc/agentos/vault"
LOG="/var/log/agentos/broker.log"

read -r cmd key_name

log_request() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [broker] $*" >> "$LOG"
}

if [[ "$cmd" != "GET" ]]; then
    echo "ERROR: Unknown command"
    log_request "DENIED unknown command: $cmd"
    exit 1
fi

# Sanitize key name (alphanumeric, hyphens, underscores only)
clean_key=$(echo "$key_name" | tr -cd 'a-zA-Z0-9_-')
vault_file="${VAULT_DIR}/${clean_key}"

if [[ -f "$vault_file" ]]; then
    cat "$vault_file"
    log_request "OK served key: $clean_key"
else
    echo "ERROR: Key not found"
    log_request "NOTFOUND key: $clean_key"
fi
HANDLER

chroot "${ROOTFS}" chmod +x /opt/agentos/bin/credential-broker.sh
chroot "${ROOTFS}" chmod +x /opt/agentos/bin/credential-handler.sh

# Broker systemd service
cp "${PROJECT_ROOT}/config/systemd/agentos-broker.service" \
   "${ROOTFS}/etc/systemd/system/agentos-broker.service"

# ── AppArmor profiles ─────────────────────────────────────────────
log "Installing AppArmor profiles..."
cp "${PROJECT_ROOT}/config/apparmor/agentos-openclaw" \
   "${ROOTFS}/etc/apparmor.d/agentos-openclaw"
cp "${PROJECT_ROOT}/config/apparmor/agentos-broker" \
   "${ROOTFS}/etc/apparmor.d/agentos-broker"

# ── Audit logging configuration ───────────────────────────────────
log "Installing audit rules..."
cp "${PROJECT_ROOT}/config/audit/agentos.rules" \
   "${ROOTFS}/etc/audit/rules.d/agentos.rules"

# ── Log rotation ──────────────────────────────────────────────────
log "Installing logrotate configuration..."
cp "${PROJECT_ROOT}/config/logrotate/agentos" \
   "${ROOTFS}/etc/logrotate.d/agentos"

# ── Vault management CLI ─────────────────────────────────────────
log "Installing vault management CLI..."
cp "${PROJECT_ROOT}/scripts/agentos-vault.sh" \
   "${ROOTFS}/opt/agentos/bin/agentos-vault"
chroot "${ROOTFS}" chmod +x /opt/agentos/bin/agentos-vault
chroot "${ROOTFS}" ln -sf /opt/agentos/bin/agentos-vault /usr/local/bin/agentos-vault

# ── Audit query CLI ──────────────────────────────────────────────
log "Installing audit query CLI..."
cp "${PROJECT_ROOT}/scripts/agentos-audit.sh" \
   "${ROOTFS}/opt/agentos/bin/agentos-audit"
chroot "${ROOTFS}" chmod +x /opt/agentos/bin/agentos-audit
chroot "${ROOTFS}" ln -sf /opt/agentos/bin/agentos-audit /usr/local/bin/agentos-audit

# ── Channel pairing CLI ──────────────────────────────────────────
log "Installing channel pairing CLI..."
cp "${PROJECT_ROOT}/scripts/agentos-pair.sh" \
   "${ROOTFS}/opt/agentos/bin/agentos-pair"
chroot "${ROOTFS}" chmod +x /opt/agentos/bin/agentos-pair
chroot "${ROOTFS}" ln -sf /opt/agentos/bin/agentos-pair /usr/local/bin/agentos-pair

# Create channels directory for runtime config
mkdir -p "${ROOTFS}/home/agentos/.openclaw/channels"
chroot "${ROOTFS}" chown -R agentos:agentos /home/agentos/.openclaw/channels

# Install example channel configs for reference
cp "${PROJECT_ROOT}/config/channels/"*.example.json \
   "${ROOTFS}/opt/agentos/share/channel-examples/" 2>/dev/null || {
    mkdir -p "${ROOTFS}/opt/agentos/share/channel-examples"
    cp "${PROJECT_ROOT}/config/channels/"*.example.json \
       "${ROOTFS}/opt/agentos/share/channel-examples/"
}

# ── Environment file and default OpenClaw config ──────────────────
log "Installing environment template and default config..."
cp "${PROJECT_ROOT}/config/openclaw/env.template" "${ROOTFS}/etc/agentos/env"
cp "${PROJECT_ROOT}/config/openclaw/openclaw.defaults.json" \
   "${ROOTFS}/home/agentos/.openclaw/openclaw.json"
chroot "${ROOTFS}" chown agentos:agentos /home/agentos/.openclaw/openclaw.json

chroot "${ROOTFS}" chmod 600 /etc/agentos/env

# ── Server-specific config overrides ──────────────────────────────
if [[ "$EDITION" == "--server" ]]; then
    log "Applying server edition config overrides..."
    # Bind gateway to all interfaces (not just localhost)
    sed -i 's/^OPENCLAW_GATEWAY_HOST=127\.0\.0\.1/OPENCLAW_GATEWAY_HOST=0.0.0.0/' \
        "${ROOTFS}/etc/agentos/env"
    # Use auto execution policy (no interactive approval on headless server)
    sed -i 's/^OPENCLAW_EXECUTION_POLICY=ask/OPENCLAW_EXECUTION_POLICY=auto/' \
        "${ROOTFS}/etc/agentos/env"
    # Update the default OpenClaw JSON config to match
    sed -i 's/"host": "127\.0\.0\.1"/"host": "0.0.0.0"/' \
        "${ROOTFS}/home/agentos/.openclaw/openclaw.json"
    sed -i 's/"execution_policy": "ask"/"execution_policy": "auto"/' \
        "${ROOTFS}/home/agentos/.openclaw/openclaw.json"
fi

# ── Enable services ────────────────────────────────────────────────
log "Enabling systemd services..."
chroot "${ROOTFS}" systemctl enable agentos-gateway.service
chroot "${ROOTFS}" systemctl enable agentos-broker.service
chroot "${ROOTFS}" systemctl enable apparmor.service
chroot "${ROOTFS}" systemctl enable auditd.service

# ── Server: health check endpoint + cloud-init ────────────────────
if [[ "$EDITION" == "--server" ]]; then
    log "Installing health check endpoint..."

    cat > "${ROOTFS}/opt/agentos/bin/healthcheck.sh" <<'HEALTHCHECK'
#!/usr/bin/env bash
# AgentOS health check HTTP endpoint
# Listens on port 8080 and returns 200 OK when the gateway is running.
set -euo pipefail

PORT=8080

while true; do
    if systemctl is-active --quiet agentos-gateway 2>/dev/null; then
        STATUS="200 OK"
        BODY="OK"
    else
        STATUS="503 Service Unavailable"
        BODY="DOWN"
    fi
    printf 'HTTP/1.1 %s\r\nContent-Length: %d\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n%s' \
        "$STATUS" "${#BODY}" "$BODY" \
        | socat - "TCP-LISTEN:${PORT},reuseaddr" 2>/dev/null || true
done
HEALTHCHECK

    chroot "${ROOTFS}" chmod +x /opt/agentos/bin/healthcheck.sh

    cp "${PROJECT_ROOT}/config/systemd/agentos-healthcheck.service" \
       "${ROOTFS}/etc/systemd/system/agentos-healthcheck.service"
    chroot "${ROOTFS}" systemctl enable agentos-healthcheck.service

    log "Enabling cloud-init services..."
    chroot "${ROOTFS}" systemctl enable cloud-init-local.service || true
    chroot "${ROOTFS}" systemctl enable cloud-init.service || true
    chroot "${ROOTFS}" systemctl enable cloud-config.service || true
    chroot "${ROOTFS}" systemctl enable cloud-final.service || true

    # Install setup.conf example for operator reference
    cp "${PROJECT_ROOT}/config/cloud-init/setup.conf.example" \
       "${ROOTFS}/etc/agentos/setup.conf.example"
fi

# ── Install socat for credential broker ────────────────────────────
chroot "${ROOTFS}" apt-get update
chroot "${ROOTFS}" apt-get install -y socat
chroot "${ROOTFS}" apt-get clean

ok "System services configured"
