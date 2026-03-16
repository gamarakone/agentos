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

# ── AppArmor profile for OpenClaw ──────────────────────────────────
log "Installing AppArmor profile..."
cp "${PROJECT_ROOT}/config/apparmor/agentos-openclaw" \
   "${ROOTFS}/etc/apparmor.d/agentos-openclaw"

# ── Audit logging configuration ───────────────────────────────────
log "Configuring audit logging..."
cat > "${ROOTFS}/etc/audit/rules.d/agentos.rules" <<'AUDIT'
# AgentOS audit rules
# Log all commands executed by the agentos user (uid 1100)
-a always,exit -F arch=b64 -F uid=1100 -S execve -k agentos-exec

# Log file writes in sensitive directories
-w /etc/agentos/ -p wa -k agentos-config
-w /home/agentos/.openclaw/ -p wa -k agentos-openclaw

# Log network connections by agentos user
-a always,exit -F arch=b64 -F uid=1100 -S connect -k agentos-network
AUDIT

# ── Environment file and default OpenClaw config ──────────────────
log "Installing environment template and default config..."
cp "${PROJECT_ROOT}/config/openclaw/env.template" "${ROOTFS}/etc/agentos/env"
cp "${PROJECT_ROOT}/config/openclaw/openclaw.defaults.json" \
   "${ROOTFS}/home/agentos/.openclaw/openclaw.json"
chroot "${ROOTFS}" chown agentos:agentos /home/agentos/.openclaw/openclaw.json

chroot "${ROOTFS}" chmod 600 /etc/agentos/env

# ── Enable services ────────────────────────────────────────────────
log "Enabling systemd services..."
chroot "${ROOTFS}" systemctl enable agentos-gateway.service
chroot "${ROOTFS}" systemctl enable agentos-broker.service
chroot "${ROOTFS}" systemctl enable apparmor.service
chroot "${ROOTFS}" systemctl enable auditd.service

# ── Install socat for credential broker ────────────────────────────
chroot "${ROOTFS}" apt-get update
chroot "${ROOTFS}" apt-get install -y socat
chroot "${ROOTFS}" apt-get clean

ok "System services configured"
