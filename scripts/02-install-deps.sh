#!/usr/bin/env bash
#
# Phase 02: Install dependencies
# Installs Node.js 22, Docker, and OpenClaw into the rootfs
#
set -euo pipefail

log "Installing dependencies..."

# ── Install Node.js 22 ────────────────────────────────────────────
log "Installing Node.js 22..."
chroot "${ROOTFS}" bash -c '
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    node --version
    npm --version
'
ok "Node.js $(chroot "${ROOTFS}" node --version) installed"

# ── Install Docker ─────────────────────────────────────────────────
log "Installing Docker..."
chroot "${ROOTFS}" bash -c '
    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repo
    echo "deb [arch='"${ARCH}"' signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu '"${UBUNTU_RELEASE}"' stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable Docker
    systemctl enable docker
    systemctl enable containerd

    # Add agentos and human user to docker group for sandbox execution
    usermod -aG docker agentos
    usermod -aG docker user
'
ok "Docker installed"

# ── Install OpenClaw ───────────────────────────────────────────────
log "Installing OpenClaw..."
chroot "${ROOTFS}" bash -c '
    # Install OpenClaw globally
    npm install -g openclaw@latest

    # Verify installation
    openclaw --version || echo "OpenClaw installed (version check may need gateway)"
'
ok "OpenClaw installed"

# ── Install additional useful tools ────────────────────────────────
log "Installing utility packages..."
chroot "${ROOTFS}" apt-get install -y --no-install-recommends \
    htop \
    jq \
    tmux \
    unzip \
    net-tools \
    lsof \
    strace \
    apparmor \
    apparmor-utils \
    auditd

ok "Utility packages installed"

# ── Install Chromium for browser automation ────────────────────────
log "Installing Chromium for browser automation skills..."
chroot "${ROOTFS}" bash -c '
    apt-get install -y --no-install-recommends chromium-browser || \
    apt-get install -y --no-install-recommends chromium || \
    echo "WARN: Chromium not available, browser skills will need manual setup"
'

# ── Clean up apt cache ─────────────────────────────────────────────
log "Cleaning apt cache..."
chroot "${ROOTFS}" apt-get clean
chroot "${ROOTFS}" rm -rf /var/lib/apt/lists/*

ok "All dependencies installed"
