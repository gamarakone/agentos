#!/usr/bin/env bash
#
# Phase 03: Configure system services
# Sets up systemd units, AppArmor profiles, credential vault, and audit logging
#
set -euo pipefail

log "Configuring system services..."

# ── systemd service for OpenClaw Gateway ───────────────────────────
log "Creating OpenClaw gateway systemd service..."
cat > "${ROOTFS}/etc/systemd/system/agentos-gateway.service" <<'EOF'
[Unit]
Description=AgentOS OpenClaw Gateway
Documentation=https://docs.openclaw.ai
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=agentos
Group=agentos
WorkingDirectory=/home/agentos/workspace

# Load credentials from vault via broker
EnvironmentFile=-/etc/agentos/env

# Start the OpenClaw gateway
ExecStart=/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789
ExecReload=/bin/kill -USR1 $MAINPID

# Restart policy
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/agentos /var/log/agentos /tmp
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
MemoryDenyWriteExecute=no
LockPersonality=yes

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=agentos-gateway

[Install]
WantedBy=multi-user.target
EOF

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
cat > "${ROOTFS}/etc/systemd/system/agentos-broker.service" <<'EOF'
[Unit]
Description=AgentOS Credential Broker
Before=agentos-gateway.service

[Service]
Type=simple
ExecStart=/opt/agentos/bin/credential-broker.sh
Restart=on-failure
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# ── AppArmor profile for OpenClaw ──────────────────────────────────
log "Creating AppArmor profile..."
cat > "${ROOTFS}/etc/apparmor.d/agentos-openclaw" <<'APPARMOR'
#include <tunables/global>

profile agentos-openclaw /usr/bin/node flags=(enforce) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/ssl_certs>

  # Node.js binary and libraries
  /usr/bin/node ix,
  /usr/lib/node_modules/** r,
  /usr/lib/node_modules/openclaw/** r,

  # OpenClaw workspace (read/write)
  /home/agentos/ r,
  /home/agentos/** rw,
  /home/agentos/workspace/** rwk,
  /home/agentos/.openclaw/** rw,

  # Logging
  /var/log/agentos/** rw,

  # Temp files
  /tmp/** rw,
  /tmp/ r,

  # Network access (required for LLM APIs and messaging)
  network inet stream,
  network inet dgram,
  network inet6 stream,
  network inet6 dgram,
  network unix stream,

  # Credential broker socket (read-only access)
  /run/agentos/credentials.sock rw,

  # DENY access to sensitive system areas
  deny /etc/agentos/vault/** rw,
  deny /etc/shadow r,
  deny /etc/passwd w,
  deny /etc/sudoers* rw,
  deny /root/** rw,
  deny /boot/** rw,
  deny /usr/sbin/** x,

  # Allow Docker socket for sandbox execution
  /var/run/docker.sock rw,

  # Proc and sys (limited)
  /proc/*/status r,
  /proc/meminfo r,
  /proc/cpuinfo r,
  /sys/devices/system/cpu/** r,
}
APPARMOR

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

# ── Environment file template ──────────────────────────────────────
log "Creating environment file template..."
cat > "${ROOTFS}/etc/agentos/env" <<'ENV'
# AgentOS Environment Configuration
# This file is managed by the setup wizard and owned by root.
# The agentos service user cannot modify this file.
#
# Model provider (set during first-run wizard)
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# OPENROUTER_API_KEY=
#
# Gateway configuration
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_GATEWAY_AUTH=token
OPENCLAW_HOME=/home/agentos/.openclaw
OPENCLAW_WORKSPACE=/home/agentos/workspace
#
# Security
OPENCLAW_SANDBOX=docker
OPENCLAW_EXECUTION_POLICY=ask
ENV

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
