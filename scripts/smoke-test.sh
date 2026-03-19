#!/usr/bin/env bash
#
# Post-build smoke test for AgentOS rootfs
# Verifies the built image has all required components
#
# Usage: sudo ./scripts/smoke-test.sh [rootfs_path]
#
set -euo pipefail

ROOTFS="${1:-/tmp/agentos-build/rootfs}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ERRORS=0
pass() { echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; ERRORS=$((ERRORS + 1)); }

echo "AgentOS Smoke Test"
echo "==================="
echo "Rootfs: ${ROOTFS}"
echo ""

if [[ ! -d "$ROOTFS" ]]; then
    echo -e "${RED}ERROR: Rootfs not found at ${ROOTFS}${NC}"
    exit 1
fi

# ── System users ──────────────────────────────────────────────────
echo "Users:"
if grep -q 'agentos:.*:1100:' "${ROOTFS}/etc/passwd"; then
    pass "agentos user (uid 1100) exists"
else
    fail "agentos user missing"
fi
if grep -q 'user:.*:1000:' "${ROOTFS}/etc/passwd"; then
    pass "user account (uid 1000) exists"
else
    fail "user account missing"
fi
echo ""

# ── Directory structure ───────────────────────────────────────────
echo "Directory structure:"
for dir in \
    /etc/agentos/vault \
    /var/log/agentos \
    /opt/agentos/skills \
    /opt/agentos/bin \
    /home/agentos/workspace \
    /home/agentos/.openclaw; do
    if [[ -d "${ROOTFS}${dir}" ]]; then
        pass "$dir"
    else
        fail "$dir missing"
    fi
done
echo ""

# ── Permissions ───────────────────────────────────────────────────
echo "Permissions:"
vault_perms=$(stat -c '%a' "${ROOTFS}/etc/agentos/vault" 2>/dev/null || stat -f '%Lp' "${ROOTFS}/etc/agentos/vault" 2>/dev/null)
if [[ "$vault_perms" == "700" ]]; then
    pass "Vault directory has 700 permissions"
else
    fail "Vault directory has ${vault_perms} (expected 700)"
fi
echo ""

# ── Node.js ───────────────────────────────────────────────────────
echo "Runtime:"
if [[ -f "${ROOTFS}/usr/bin/node" ]]; then
    pass "Node.js binary present"
else
    fail "Node.js binary missing"
fi
echo ""

# ── Systemd services ─────────────────────────────────────────────
echo "Systemd services:"
for svc in agentos-gateway agentos-broker; do
    if [[ -f "${ROOTFS}/etc/systemd/system/${svc}.service" ]]; then
        pass "${svc}.service installed"
    else
        fail "${svc}.service missing"
    fi
done
echo ""

# ── AppArmor profiles ────────────────────────────────────────────
echo "Security:"
if [[ -f "${ROOTFS}/etc/apparmor.d/agentos-openclaw" ]]; then
    pass "AppArmor OpenClaw profile installed"
else
    fail "AppArmor OpenClaw profile missing"
fi
if [[ -f "${ROOTFS}/etc/apparmor.d/agentos-broker" ]]; then
    pass "AppArmor broker profile installed"
else
    fail "AppArmor broker profile missing"
fi
if [[ -f "${ROOTFS}/etc/audit/rules.d/agentos.rules" ]]; then
    pass "Audit rules installed"
    # Verify comprehensive coverage
    rule_count=$(grep -c '^-' "${ROOTFS}/etc/audit/rules.d/agentos.rules" 2>/dev/null || echo 0)
    if [[ "$rule_count" -ge 10 ]]; then
        pass "Audit rules comprehensive (${rule_count} rules)"
    else
        fail "Audit rules incomplete (${rule_count} rules, expected >= 10)"
    fi
else
    fail "Audit rules missing"
fi
if [[ -f "${ROOTFS}/etc/logrotate.d/agentos" ]]; then
    pass "Log rotation configured"
else
    fail "Log rotation config missing"
fi
echo ""

# ── OpenClaw config ───────────────────────────────────────────────
echo "OpenClaw:"
if [[ -f "${ROOTFS}/home/agentos/.openclaw/openclaw.json" ]]; then
    pass "Default config installed"
else
    fail "Default config missing"
fi
if [[ -f "${ROOTFS}/etc/agentos/env" ]]; then
    pass "Environment file installed"
else
    fail "Environment file missing"
fi
echo ""

# ── Credential broker and vault CLI ──────────────────────────────
echo "Credential management:"
if [[ -f "${ROOTFS}/opt/agentos/bin/credential-broker.sh" ]]; then
    pass "credential-broker.sh installed"
else
    fail "credential-broker.sh missing"
fi
if [[ -f "${ROOTFS}/opt/agentos/bin/credential-handler.sh" ]]; then
    pass "credential-handler.sh installed"
else
    fail "credential-handler.sh missing"
fi
if [[ -f "${ROOTFS}/opt/agentos/bin/agentos-vault" ]]; then
    pass "agentos-vault CLI installed"
else
    fail "agentos-vault CLI missing"
fi
if [[ -f "${ROOTFS}/opt/agentos/bin/agentos-audit" ]]; then
    pass "agentos-audit CLI installed"
else
    fail "agentos-audit CLI missing"
fi
if [[ -f "${ROOTFS}/opt/agentos/bin/agentos-pair" ]]; then
    pass "agentos-pair CLI installed"
else
    fail "agentos-pair CLI missing"
fi
echo ""

# ── Channel pairing infrastructure ───────────────────────────────
echo "Channel pairing:"
if [[ -d "${ROOTFS}/home/agentos/.openclaw/channels" ]]; then
    pass "Channels directory exists"
else
    fail "Channels directory missing"
fi
if [[ -d "${ROOTFS}/opt/agentos/share/channel-examples" ]]; then
    pass "Channel example configs installed"
else
    fail "Channel example configs missing"
fi
echo ""

# ── Setup wizard ──────────────────────────────────────────────────
echo "Setup wizard:"
if [[ -f "${ROOTFS}/opt/agentos/bin/setup-wizard.sh" ]]; then
    pass "setup-wizard.sh installed"
    if [[ -x "${ROOTFS}/opt/agentos/bin/setup-wizard.sh" ]]; then
        pass "setup-wizard.sh is executable"
    else
        fail "setup-wizard.sh is not executable"
    fi
else
    fail "setup-wizard.sh missing"
fi
echo ""

# ── Branding ──────────────────────────────────────────────────────
echo "Branding:"
if [[ -d "${ROOTFS}/usr/share/plymouth/themes/agentos" ]]; then
    pass "Plymouth theme installed"
else
    fail "Plymouth theme missing"
fi
if [[ -d "${ROOTFS}/boot/grub/themes/agentos" ]]; then
    pass "GRUB theme installed"
    if [[ -f "${ROOTFS}/boot/grub/themes/agentos/theme.txt" ]]; then
        pass "GRUB theme.txt present"
    else
        fail "GRUB theme.txt missing"
    fi
else
    fail "GRUB theme missing"
fi
if [[ -f "${ROOTFS}/usr/share/backgrounds/agentos-wallpaper.svg" ]]; then
    pass "Wallpapers installed"
else
    fail "Wallpapers missing"
fi
if [[ -f "${ROOTFS}/usr/share/icons/hicolor/scalable/apps/agentos.svg" ]]; then
    pass "Application icon installed"
else
    fail "Application icon missing"
fi
if [[ -f "${ROOTFS}/opt/agentos/share/welcome/index.html" ]]; then
    pass "Welcome app installed"
else
    fail "Welcome app missing"
fi
if [[ -f "${ROOTFS}/usr/share/applications/agentos-welcome.desktop" ]]; then
    pass "Welcome desktop entry installed"
else
    fail "Welcome desktop entry missing"
fi
echo ""

# ── Bootloader ────────────────────────────────────────────────────
echo "Boot:"
if [[ -d "${ROOTFS}/boot/grub" ]]; then
    pass "GRUB directory present"
else
    fail "GRUB directory missing"
fi
if ls "${ROOTFS}"/boot/vmlinuz-* &>/dev/null; then
    pass "Kernel image present"
else
    fail "Kernel image missing"
fi
if ls "${ROOTFS}"/boot/initrd.img-* &>/dev/null; then
    pass "initramfs present"
else
    fail "initramfs missing"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "==================="
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}: $ERRORS check(s) failed"
    exit 1
else
    echo -e "${GREEN}ALL SMOKE TESTS PASSED${NC}"
    exit 0
fi
