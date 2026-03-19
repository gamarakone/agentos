#!/usr/bin/env bash
#
# Phase 04: Desktop environment (Lite edition only)
# Installs GNOME, branding (Plymouth, GRUB, wallpapers), and welcome app
#
set -euo pipefail

log "Installing desktop environment..."

# ── Install GNOME minimal ─────────────────────────────────────────
log "Installing GNOME (this takes 5-10 minutes)..."
chroot "${ROOTFS}" bash -c '
    apt-get update
    apt-get install -y --no-install-recommends \
        ubuntu-desktop-minimal \
        gnome-terminal \
        nautilus \
        firefox \
        gdm3 \
        gnome-tweaks \
        dconf-cli \
        plymouth \
        plymouth-themes \
        librsvg2-bin

    # Enable display manager
    systemctl enable gdm3
'
ok "GNOME desktop installed"

# ── Configure auto-login for first boot ────────────────────────────
log "Configuring GDM for first-boot experience..."
mkdir -p "${ROOTFS}/etc/gdm3"
cat > "${ROOTFS}/etc/gdm3/custom.conf" <<'EOF'
[daemon]
# Auto-login on first boot; the setup wizard will disable this after
AutomaticLoginEnable=true
AutomaticLogin=user
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
EOF

# ── Plymouth boot splash ──────────────────────────────────────────
log "Installing Plymouth boot splash theme..."
PLYMOUTH_DIR="${ROOTFS}/usr/share/plymouth/themes/agentos"
mkdir -p "$PLYMOUTH_DIR"

# Copy theme definition and script
cp "${PROJECT_ROOT}/branding/plymouth/agentos.plymouth" "$PLYMOUTH_DIR/"
cp "${PROJECT_ROOT}/branding/plymouth/agentos.script" "$PLYMOUTH_DIR/"

# Generate and install image assets
log "Generating Plymouth assets..."
bash "${PROJECT_ROOT}/branding/plymouth/generate-assets.sh" "$PLYMOUTH_DIR" || {
    warn "Plymouth asset generation failed — installing SVG fallbacks"
    # Generate SVGs in-place if the converter isn't available on the host
    bash "${PROJECT_ROOT}/branding/plymouth/generate-assets.sh" "$PLYMOUTH_DIR"
}

# Set as default Plymouth theme
chroot "${ROOTFS}" bash -c '
    plymouth-set-default-theme agentos || true
    update-initramfs -u || true
'
ok "Plymouth theme installed"

# ── GRUB bootloader theme ────────────────────────────────────────
log "Installing GRUB theme..."
GRUB_THEME_DIR="${ROOTFS}/boot/grub/themes/agentos"
mkdir -p "$GRUB_THEME_DIR"

# Copy theme definition
cp "${PROJECT_ROOT}/branding/grub/theme.txt" "$GRUB_THEME_DIR/"

# Generate and install image assets
bash "${PROJECT_ROOT}/branding/grub/generate-assets.sh" "$GRUB_THEME_DIR" || {
    warn "GRUB asset generation used SVG fallback"
}

# Install DejaVu fonts for GRUB (needed by theme)
chroot "${ROOTFS}" bash -c '
    apt-get install -y --no-install-recommends fonts-dejavu-core || true

    # Convert TTF to GRUB PF2 format
    for ttf in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
               /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
               /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf; do
        if [[ -f "$ttf" ]]; then
            name=$(basename "$ttf" .ttf)
            grub-mkfont -s 16 -o "/boot/grub/themes/agentos/${name}-16.pf2" "$ttf" || true
            grub-mkfont -s 12 -o "/boot/grub/themes/agentos/${name}-12.pf2" "$ttf" || true
            grub-mkfont -s 28 -o "/boot/grub/themes/agentos/${name}-28.pf2" "$ttf" || true
        fi
    done
'
ok "GRUB theme installed"

# ── Wallpapers ────────────────────────────────────────────────────
log "Installing wallpapers..."
mkdir -p "${ROOTFS}/usr/share/backgrounds"

# Copy SVG wallpapers
cp "${PROJECT_ROOT}/branding/wallpapers/agentos-wallpaper.svg" \
   "${ROOTFS}/usr/share/backgrounds/"
cp "${PROJECT_ROOT}/branding/wallpapers/agentos-wallpaper-dark.svg" \
   "${ROOTFS}/usr/share/backgrounds/"

# Convert to PNG for compatibility
chroot "${ROOTFS}" bash -c '
    if command -v rsvg-convert &>/dev/null; then
        rsvg-convert -w 1920 -h 1080 \
            /usr/share/backgrounds/agentos-wallpaper.svg \
            -o /usr/share/backgrounds/agentos-wallpaper.png
        rsvg-convert -w 1920 -h 1080 \
            /usr/share/backgrounds/agentos-wallpaper-dark.svg \
            -o /usr/share/backgrounds/agentos-wallpaper-dark.png
    fi
'
ok "Wallpapers installed"

# ── Icons ─────────────────────────────────────────────────────────
log "Installing AgentOS icons..."
mkdir -p "${ROOTFS}/usr/share/icons/hicolor/128x128/apps"
mkdir -p "${ROOTFS}/usr/share/icons/hicolor/scalable/apps"

cp "${PROJECT_ROOT}/branding/icons/agentos-logo.svg" \
   "${ROOTFS}/usr/share/icons/hicolor/scalable/apps/agentos.svg"

# Convert to PNG for icon theme
chroot "${ROOTFS}" bash -c '
    if command -v rsvg-convert &>/dev/null; then
        rsvg-convert -w 128 -h 128 \
            /usr/share/icons/hicolor/scalable/apps/agentos.svg \
            -o /usr/share/icons/hicolor/128x128/apps/agentos.png
        # Also generate smaller sizes
        for size in 48 64 96; do
            mkdir -p /usr/share/icons/hicolor/${size}x${size}/apps
            rsvg-convert -w $size -h $size \
                /usr/share/icons/hicolor/scalable/apps/agentos.svg \
                -o /usr/share/icons/hicolor/${size}x${size}/apps/agentos.png
        done
        gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true
    fi
'
ok "Icons installed"

# ── Welcome app ───────────────────────────────────────────────────
log "Installing welcome app..."
WELCOME_DIR="${ROOTFS}/opt/agentos/share/welcome"
mkdir -p "$WELCOME_DIR"
cp "${PROJECT_ROOT}/branding/welcome/index.html" "$WELCOME_DIR/"

# Copy favicon
cp "${PROJECT_ROOT}/branding/icons/favicon.svg" "$WELCOME_DIR/" 2>/dev/null || true

# Desktop entry for welcome app
cat > "${ROOTFS}/usr/share/applications/agentos-welcome.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Welcome to AgentOS
Comment=Getting started with your AI agent
Icon=agentos
Exec=xdg-open /opt/agentos/share/welcome/index.html
Categories=System;
Terminal=false
StartupNotify=true
DESKTOP

# Desktop entry for dashboard
cat > "${ROOTFS}/usr/share/applications/agentos-dashboard.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=AgentOS Dashboard
Comment=Manage your AI agent
Icon=agentos
Exec=xdg-open http://localhost:18789
Categories=System;
Terminal=false
StartupNotify=true
DESKTOP

ok "Welcome app installed"

# ── GNOME desktop settings ────────────────────────────────────────
log "Configuring GNOME desktop settings..."

# Set GNOME settings via dconf defaults
mkdir -p "${ROOTFS}/etc/dconf/profile"
cat > "${ROOTFS}/etc/dconf/profile/user" <<'EOF'
user-db:user
system-db:agentos
EOF

mkdir -p "${ROOTFS}/etc/dconf/db/agentos.d"
cat > "${ROOTFS}/etc/dconf/db/agentos.d/00-agentos" <<'EOF'
[org/gnome/desktop/interface]
gtk-theme='Adwaita-dark'
color-scheme='prefer-dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/agentos-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/agentos-wallpaper-dark.png'
picture-options='zoom'
primary-color='#0f0c29'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/agentos-wallpaper-dark.png'

[org/gnome/shell]
favorite-apps=['agentos-welcome.desktop', 'agentos-dashboard.desktop', 'org.gnome.Terminal.desktop', 'firefox.desktop', 'org.gnome.Nautilus.desktop']

[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
background-color='#0f0c29'
foreground-color='#e0e0e0'
use-theme-colors=false
EOF

# Compile dconf database
chroot "${ROOTFS}" dconf update || true

# ── Autostart welcome app on first login ──────────────────────────
log "Configuring first-login autostart..."
mkdir -p "${ROOTFS}/etc/xdg/autostart"

# Welcome app opens in browser on first login
cat > "${ROOTFS}/etc/xdg/autostart/agentos-welcome.desktop" <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=AgentOS Welcome
Comment=Open the welcome guide
Exec=xdg-open /opt/agentos/share/welcome/index.html
Terminal=false
X-GNOME-Autostart-enabled=true
OnlyShowIn=GNOME;
AUTOSTART

# Setup wizard still runs in terminal on first boot
cat > "${ROOTFS}/etc/xdg/autostart/agentos-wizard.desktop" <<'WIZARD'
[Desktop Entry]
Type=Application
Name=AgentOS Setup
Comment=Configure your AI agent
Exec=/opt/agentos/bin/setup-wizard.sh
Terminal=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=GNOME;
WIZARD

ok "Desktop environment configured"
