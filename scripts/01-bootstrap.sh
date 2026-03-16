#!/usr/bin/env bash
#
# Phase 01: Bootstrap Ubuntu base system
# Creates a minimal Ubuntu rootfs using debootstrap
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/build-vm.sh" 2>/dev/null || true

log "Bootstrapping Ubuntu ${UBUNTU_RELEASE} (${ARCH})..."

# ── Create rootfs ──────────────────────────────────────────────────
if [[ -d "${ROOTFS}" ]]; then
    warn "Rootfs already exists at ${ROOTFS}, removing..."
    rm -rf "${ROOTFS}"
fi

mkdir -p "${ROOTFS}"

# ── Run debootstrap ────────────────────────────────────────────────
log "Running debootstrap (this takes 3-5 minutes)..."
debootstrap \
    --arch="${ARCH}" \
    --variant=minbase \
    --include=\
apt-utils,\
ca-certificates,\
curl,\
gnupg,\
locales,\
sudo,\
systemd,\
systemd-sysv,\
dbus,\
networkmanager,\
iproute2,\
iputils-ping,\
wget,\
git,\
vim-tiny,\
openssh-server,\
linux-image-generic,\
grub-pc,\
initramfs-tools \
    "${UBUNTU_RELEASE}" \
    "${ROOTFS}" \
    "${UBUNTU_MIRROR}"

ok "Debootstrap complete"

# ── Mount virtual filesystems ──────────────────────────────────────
log "Mounting virtual filesystems in chroot..."
mount --bind /dev  "${ROOTFS}/dev"
mount --bind /dev/pts "${ROOTFS}/dev/pts"
mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sys "${ROOTFS}/sys"
mount --bind /run  "${ROOTFS}/run"

# ── Configure base system ─────────────────────────────────────────
log "Configuring base system inside chroot..."

# Set hostname
echo "agentos" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   agentos

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Configure locale
chroot "${ROOTFS}" locale-gen en_US.UTF-8
chroot "${ROOTFS}" update-locale LANG=en_US.UTF-8

# Configure timezone
chroot "${ROOTFS}" ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Add Ubuntu main + universe repos
cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${UBUNTU_MIRROR} ${UBUNTU_RELEASE} main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_RELEASE}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_RELEASE}-security main restricted universe multiverse
EOF

# Update package lists
chroot "${ROOTFS}" apt-get update

# ── Create the agentos system user ─────────────────────────────────
log "Creating agentos system user..."
chroot "${ROOTFS}" useradd \
    --uid 1100 \
    --create-home \
    --shell /bin/bash \
    --comment "AgentOS Service Account" \
    agentos

# Create a default human user for desktop login
chroot "${ROOTFS}" useradd \
    --uid 1000 \
    --create-home \
    --shell /bin/bash \
    --groups sudo,docker \
    --comment "AgentOS User" \
    user

# Set default password (user will be prompted to change on first login)
echo "user:agentos" | chroot "${ROOTFS}" chpasswd
chroot "${ROOTFS}" chage -d 0 user  # Force password change at first login

# ── Create AgentOS directory structure ─────────────────────────────
log "Creating AgentOS directory structure..."
mkdir -p "${ROOTFS}/etc/agentos/vault"
mkdir -p "${ROOTFS}/var/log/agentos"
mkdir -p "${ROOTFS}/opt/agentos/skills"
mkdir -p "${ROOTFS}/opt/agentos/bin"
mkdir -p "${ROOTFS}/home/agentos/.openclaw"
mkdir -p "${ROOTFS}/home/agentos/workspace"

# Set permissions
chroot "${ROOTFS}" chown -R agentos:agentos /home/agentos
chroot "${ROOTFS}" chown -R root:root /etc/agentos/vault
chroot "${ROOTFS}" chmod 700 /etc/agentos/vault
chroot "${ROOTFS}" chown -R agentos:agentos /var/log/agentos
chroot "${ROOTFS}" chown -R agentos:agentos /opt/agentos/skills

# ── Set up fstab ───────────────────────────────────────────────────
cat > "${ROOTFS}/etc/fstab" <<EOF
# <file system>  <mount point>  <type>  <options>         <dump>  <pass>
/dev/sda1        /              ext4    errors=remount-ro  0       1
EOF

# ── Configure networking ───────────────────────────────────────────
log "Configuring NetworkManager..."
chroot "${ROOTFS}" systemctl enable NetworkManager

# ── Configure SSH ──────────────────────────────────────────────────
log "Configuring SSH..."
chroot "${ROOTFS}" systemctl enable ssh
# Disable root login over SSH
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "${ROOTFS}/etc/ssh/sshd_config"

# ── LSB release branding ──────────────────────────────────────────
cat > "${ROOTFS}/etc/lsb-release" <<EOF
DISTRIB_ID=AgentOS
DISTRIB_RELEASE=${AGENTOS_VERSION}
DISTRIB_CODENAME=pioneer
DISTRIB_DESCRIPTION="AgentOS ${AGENTOS_VERSION} (Pioneer)"
EOF

cat > "${ROOTFS}/etc/os-release" <<EOF
PRETTY_NAME="AgentOS ${AGENTOS_VERSION} (Pioneer)"
NAME="AgentOS"
VERSION_ID="${AGENTOS_VERSION}"
VERSION="${AGENTOS_VERSION} (Pioneer)"
ID=agentos
ID_LIKE=ubuntu debian
HOME_URL="https://github.com/user/agentos"
BUG_REPORT_URL="https://github.com/user/agentos/issues"
UBUNTU_CODENAME=${UBUNTU_RELEASE}
EOF

ok "Base system bootstrapped and configured"
