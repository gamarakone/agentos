#!/usr/bin/env bash
#
# Validate AgentOS build scripts and configuration
# Run before building to catch errors early
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass() { echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $*"; WARNINGS=$((WARNINGS + 1)); }

echo "AgentOS Build Validation"
echo "========================"
echo ""

# ── Check build scripts exist ─────────────────────────────────────
echo "Build scripts:"
for phase in 01-bootstrap 02-install-deps 03-configure 04-desktop 05-wizard 06-package; do
    script="${SCRIPT_DIR}/${phase}.sh"
    if [[ -f "$script" ]]; then
        pass "$phase.sh exists"
    else
        fail "$phase.sh missing"
    fi
done

if [[ -f "${SCRIPT_DIR}/build-vm.sh" ]]; then
    pass "build-vm.sh exists"
else
    fail "build-vm.sh missing"
fi
echo ""

# ── Check config files ────────────────────────────────────────────
echo "Configuration files:"
for cfg in \
    config/apparmor/agentos-openclaw \
    config/apparmor/agentos-broker \
    config/systemd/agentos-gateway.service \
    config/systemd/agentos-broker.service \
    config/openclaw/openclaw.defaults.json \
    config/openclaw/env.template \
    config/audit/agentos.rules \
    config/logrotate/agentos; do
    if [[ -f "${PROJECT_ROOT}/${cfg}" ]]; then
        pass "$cfg"
    else
        fail "$cfg missing"
    fi
done
echo ""

# ── Validate JSON config ──────────────────────────────────────────
echo "JSON validation:"
if command -v python3 &>/dev/null; then
    if python3 -m json.tool "${PROJECT_ROOT}/config/openclaw/openclaw.defaults.json" >/dev/null 2>&1; then
        pass "openclaw.defaults.json is valid JSON"
    else
        fail "openclaw.defaults.json is invalid JSON"
    fi
elif command -v jq &>/dev/null; then
    if jq . "${PROJECT_ROOT}/config/openclaw/openclaw.defaults.json" >/dev/null 2>&1; then
        pass "openclaw.defaults.json is valid JSON"
    else
        fail "openclaw.defaults.json is invalid JSON"
    fi
else
    warn "No JSON validator available (install jq or python3)"
fi
echo ""

# ── Check shell scripts for syntax errors ──────────────────────────
echo "Shell syntax check:"
for script in "${SCRIPT_DIR}"/*.sh; do
    name=$(basename "$script")
    if bash -n "$script" 2>/dev/null; then
        pass "$name syntax OK"
    else
        fail "$name has syntax errors"
    fi
done
echo ""

# ── Validate systemd unit files ───────────────────────────────────
echo "Systemd unit validation:"
for unit in "${PROJECT_ROOT}"/config/systemd/*.service; do
    name=$(basename "$unit")
    # Check for required sections
    if grep -q '\[Unit\]' "$unit" && grep -q '\[Service\]' "$unit" && grep -q '\[Install\]' "$unit"; then
        pass "$name has required sections"
    else
        fail "$name missing required sections ([Unit], [Service], [Install])"
    fi
done
echo ""

# ── Verify AppArmor profile structure ─────────────────────────────
echo "AppArmor profiles:"
apparmor="${PROJECT_ROOT}/config/apparmor/agentos-openclaw"
if grep -q 'profile agentos-openclaw' "$apparmor"; then
    pass "OpenClaw profile name defined"
else
    fail "OpenClaw profile name not found"
fi
if grep -q 'deny /etc/agentos/vault' "$apparmor"; then
    pass "Vault access denied in OpenClaw profile"
else
    fail "Vault deny rule missing in OpenClaw profile"
fi
if grep -q 'deny /etc/shadow' "$apparmor"; then
    pass "Shadow file access denied"
else
    fail "Shadow deny rule missing"
fi

broker_apparmor="${PROJECT_ROOT}/config/apparmor/agentos-broker"
if grep -q 'profile agentos-broker' "$broker_apparmor"; then
    pass "Broker profile name defined"
else
    fail "Broker profile name not found"
fi
if grep -q 'deny network inet' "$broker_apparmor"; then
    pass "Broker network access denied (local-only)"
else
    fail "Broker should deny network access"
fi
if grep -q '/etc/agentos/vault/' "$broker_apparmor"; then
    pass "Broker has vault read access"
else
    fail "Broker missing vault access"
fi
echo ""

# ── Verify audit rules ───────────────────────────────────────────
echo "Audit rules:"
audit_rules="${PROJECT_ROOT}/config/audit/agentos.rules"
if grep -q 'agentos-exec' "$audit_rules"; then
    pass "Command execution auditing"
else
    fail "Missing exec audit rule"
fi
if grep -q 'agentos-vault-access' "$audit_rules"; then
    pass "Vault access auditing"
else
    fail "Missing vault access audit rule"
fi
if grep -q 'agentos-priv-escalation' "$audit_rules"; then
    pass "Privilege escalation auditing"
else
    fail "Missing privilege escalation audit rule"
fi
if grep -q 'agentos-docker' "$audit_rules"; then
    pass "Docker socket auditing"
else
    fail "Missing Docker audit rule"
fi
echo ""

# ── Verify CLI tools ─────────────────────────────────────────────
echo "CLI tools:"
for tool in agentos-vault.sh agentos-audit.sh; do
    if [[ -f "${SCRIPT_DIR}/${tool}" ]]; then
        pass "$tool exists"
        if [[ -x "${SCRIPT_DIR}/${tool}" ]]; then
            pass "$tool is executable"
        else
            fail "$tool is not executable"
        fi
    else
        fail "$tool missing"
    fi
done
echo ""

# ── Check CI workflow ──────────────────────────────────────────────
echo "CI/CD:"
if [[ -f "${PROJECT_ROOT}/.github/workflows/build.yml" ]]; then
    pass "GitHub Actions workflow exists"
else
    warn "No CI workflow found"
fi
echo ""

# ── Summary ────────────────────────────────────────────────────────
echo "========================"
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}: $ERRORS error(s), $WARNINGS warning(s)"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}PASSED${NC} with $WARNINGS warning(s)"
    exit 0
else
    echo -e "${GREEN}ALL CHECKS PASSED${NC}"
    exit 0
fi
