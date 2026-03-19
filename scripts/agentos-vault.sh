#!/usr/bin/env bash
#
# agentos-vault — Credential vault management for AgentOS
#
# Usage:
#   agentos-vault add <key-name>          Store a new secret (reads from stdin)
#   agentos-vault remove <key-name>       Remove a secret
#   agentos-vault list                    List stored key names (not values)
#   agentos-vault rotate <key-name>       Replace an existing secret
#   agentos-vault verify                  Check vault directory permissions
#
# All operations are logged to the audit trail.
#
set -euo pipefail

VAULT_DIR="/etc/agentos/vault"
AUDIT_LOG="/var/log/agentos/audit.log"
ENV_FILE="/etc/agentos/env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────

audit() {
    local action="$1"
    local key="$2"
    local status="$3"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local user
    user=$(whoami)
    printf '{"ts":"%s","component":"vault","action":"%s","key":"%s","status":"%s","user":"%s"}\n' \
        "$timestamp" "$action" "$key" "$status" "$user" >> "$AUDIT_LOG" 2>/dev/null || true
}

die() {
    echo -e "${RED}error:${NC} $*" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This command must be run as root (sudo agentos-vault $*)"
    fi
}

sanitize_key() {
    local key="$1"
    local clean
    clean=$(echo "$key" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$clean" || "$clean" != "$key" ]]; then
        die "Invalid key name '${key}'. Use only alphanumeric characters, hyphens, and underscores."
    fi
    echo "$clean"
}

# ── Commands ──────────────────────────────────────────────────────

cmd_add() {
    local key_name="${1:-}"
    [[ -z "$key_name" ]] && die "Usage: agentos-vault add <key-name>"
    require_root

    key_name=$(sanitize_key "$key_name")
    local vault_file="${VAULT_DIR}/${key_name}"

    if [[ -f "$vault_file" ]]; then
        die "Key '${key_name}' already exists. Use 'rotate' to replace it."
    fi

    echo -ne "${YELLOW}Enter secret value for '${key_name}': ${NC}"
    read -rs secret_value
    echo ""

    if [[ -z "$secret_value" ]]; then
        die "Secret value cannot be empty."
    fi

    echo -n "$secret_value" > "$vault_file"
    chmod 600 "$vault_file"
    chown root:root "$vault_file"

    audit "add" "$key_name" "ok"
    echo -e "${GREEN}Key '${key_name}' stored in vault.${NC}"
}

cmd_remove() {
    local key_name="${1:-}"
    [[ -z "$key_name" ]] && die "Usage: agentos-vault remove <key-name>"
    require_root

    key_name=$(sanitize_key "$key_name")
    local vault_file="${VAULT_DIR}/${key_name}"

    if [[ ! -f "$vault_file" ]]; then
        die "Key '${key_name}' not found in vault."
    fi

    # Securely wipe the file before removing
    shred -u "$vault_file" 2>/dev/null || rm -f "$vault_file"

    # Comment out the key in env file if present
    sed -i "s|^${key_name}=.*|# ${key_name}=|" "$ENV_FILE" 2>/dev/null || true

    audit "remove" "$key_name" "ok"
    echo -e "${GREEN}Key '${key_name}' removed from vault.${NC}"
}

cmd_list() {
    if [[ ! -d "$VAULT_DIR" ]]; then
        die "Vault directory not found at ${VAULT_DIR}"
    fi

    local count=0
    echo "Stored credentials:"
    echo ""
    for f in "${VAULT_DIR}"/*; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f")
        local perms
        perms=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)
        local modified
        modified=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1 || stat -f '%Sm' "$f" 2>/dev/null)
        printf "  %-30s  perms: %s  modified: %s\n" "$name" "$perms" "$modified"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  (no credentials stored)"
    fi
    echo ""
    echo "${count} key(s) in vault."

    audit "list" "-" "ok"
}

cmd_rotate() {
    local key_name="${1:-}"
    [[ -z "$key_name" ]] && die "Usage: agentos-vault rotate <key-name>"
    require_root

    key_name=$(sanitize_key "$key_name")
    local vault_file="${VAULT_DIR}/${key_name}"

    if [[ ! -f "$vault_file" ]]; then
        die "Key '${key_name}' not found. Use 'add' to create it."
    fi

    echo -ne "${YELLOW}Enter new secret value for '${key_name}': ${NC}"
    read -rs secret_value
    echo ""

    if [[ -z "$secret_value" ]]; then
        die "Secret value cannot be empty."
    fi

    # Wipe old value, write new one
    shred "$vault_file" 2>/dev/null || true
    echo -n "$secret_value" > "$vault_file"
    chmod 600 "$vault_file"
    chown root:root "$vault_file"

    # Update env file if the key is referenced there
    if grep -q "^${key_name}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key_name}=.*|${key_name}=${secret_value}|" "$ENV_FILE"
    fi

    audit "rotate" "$key_name" "ok"
    echo -e "${GREEN}Key '${key_name}' rotated successfully.${NC}"
    echo -e "${YELLOW}Restart the gateway to pick up the new value: sudo systemctl restart agentos-gateway${NC}"
}

cmd_verify() {
    echo "Vault integrity check:"
    echo ""

    local errors=0

    # Check vault directory
    if [[ -d "$VAULT_DIR" ]]; then
        local dir_perms
        dir_perms=$(stat -c '%a' "$VAULT_DIR" 2>/dev/null || stat -f '%Lp' "$VAULT_DIR" 2>/dev/null)
        local dir_owner
        dir_owner=$(stat -c '%U' "$VAULT_DIR" 2>/dev/null || stat -f '%Su' "$VAULT_DIR" 2>/dev/null)
        if [[ "$dir_perms" == "700" ]]; then
            echo -e "  ${GREEN}PASS${NC}  Vault directory permissions: $dir_perms"
        else
            echo -e "  ${RED}FAIL${NC}  Vault directory permissions: $dir_perms (expected 700)"
            errors=$((errors + 1))
        fi
        if [[ "$dir_owner" == "root" ]]; then
            echo -e "  ${GREEN}PASS${NC}  Vault directory owner: $dir_owner"
        else
            echo -e "  ${RED}FAIL${NC}  Vault directory owner: $dir_owner (expected root)"
            errors=$((errors + 1))
        fi
    else
        echo -e "  ${RED}FAIL${NC}  Vault directory missing"
        errors=$((errors + 1))
    fi

    # Check individual key files
    for f in "${VAULT_DIR}"/*; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f")
        local perms
        perms=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)
        if [[ "$perms" == "600" ]]; then
            echo -e "  ${GREEN}PASS${NC}  ${name}: permissions $perms"
        else
            echo -e "  ${RED}FAIL${NC}  ${name}: permissions $perms (expected 600)"
            errors=$((errors + 1))
        fi
    done

    echo ""
    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}${errors} issue(s) found. Run with sudo to fix.${NC}"
        audit "verify" "-" "fail"
        exit 1
    else
        echo -e "${GREEN}Vault integrity OK.${NC}"
        audit "verify" "-" "ok"
    fi
}

# ── Main ──────────────────────────────────────────────────────────

cmd="${1:-help}"
shift || true

case "$cmd" in
    add)    cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    list)   cmd_list ;;
    rotate) cmd_rotate "$@" ;;
    verify) cmd_verify ;;
    help|--help|-h)
        echo "Usage: agentos-vault <command> [args]"
        echo ""
        echo "Commands:"
        echo "  add <key>       Store a new secret"
        echo "  remove <key>    Remove a secret (secure wipe)"
        echo "  list            List stored key names"
        echo "  rotate <key>    Replace an existing secret"
        echo "  verify          Check vault permissions and integrity"
        echo ""
        ;;
    *)
        die "Unknown command '${cmd}'. Run 'agentos-vault help' for usage."
        ;;
esac
