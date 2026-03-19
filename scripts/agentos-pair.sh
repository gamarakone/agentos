#!/usr/bin/env bash
#
# agentos-pair — Manage messaging channel integrations for AgentOS
#
# Usage:
#   agentos-pair add [telegram|discord|slack]   Pair a new channel
#   agentos-pair remove <channel>               Remove a channel
#   agentos-pair list                           List paired channels
#   agentos-pair test <channel>                 Test a channel connection
#   agentos-pair status                         Show channel status overview
#
set -euo pipefail

VAULT_DIR="/etc/agentos/vault"
CHANNELS_DIR="/home/agentos/.openclaw/channels"
OPENCLAW_CONFIG="/home/agentos/.openclaw/openclaw.json"
AUDIT_LOG="/var/log/agentos/audit.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────

audit() {
    local action="$1"
    local channel="$2"
    local status="$3"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"ts":"%s","component":"pair","action":"%s","key":"%s","status":"%s","user":"%s"}\n' \
        "$timestamp" "$action" "$channel" "$status" "$(whoami)" >> "$AUDIT_LOG" 2>/dev/null || true
}

die() {
    echo -e "${RED}error:${NC} $*" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This command must be run as root (sudo agentos-pair $*)"
    fi
}

prompt_secret() {
    local prompt_text="$1"
    local value
    echo -ne "${BOLD}${prompt_text}${NC}: "
    read -rs value
    echo ""
    echo "$value"
}

# ── Channel validation (same logic as wizard) ─────────────────────

validate_telegram() {
    local token="$1"
    local response
    response=$(curl -s "https://api.telegram.org/bot${token}/getMe" 2>/dev/null) || true
    if echo "$response" | grep -q '"ok":true'; then
        echo "$response" | grep -o '"username":"[^"]*"' | cut -d'"' -f4
        return 0
    fi
    return 1
}

validate_discord() {
    local token="$1"
    local response
    response=$(curl -s -w "\n%{http_code}" "https://discord.com/api/v10/users/@me" \
        -H "Authorization: Bot ${token}" 2>/dev/null) || true
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "200" ]]; then
        echo "$response" | head -1 | grep -o '"username":"[^"]*"' | cut -d'"' -f4
        return 0
    fi
    return 1
}

validate_slack() {
    local token="$1"
    local response
    response=$(curl -s "https://slack.com/api/auth.test" \
        -H "Authorization: Bearer ${token}" 2>/dev/null) || true
    if echo "$response" | grep -q '"ok":true'; then
        echo "$response" | grep -o '"user":"[^"]*"' | cut -d'"' -f4
        return 0
    fi
    return 1
}

# ── Update openclaw.json channels array ───────────────────────────

sync_openclaw_config() {
    if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
        return
    fi

    local channels_json="["
    local first=true
    for chfile in "${CHANNELS_DIR}"/*.json; do
        [[ -f "$chfile" ]] || continue
        local enabled
        enabled=$(grep -o '"enabled":[^,}]*' "$chfile" | cut -d':' -f2 | tr -d ' ')
        [[ "$enabled" == "true" ]] || continue

        $first || channels_json="${channels_json},"
        first=false
        local ch_type
        ch_type=$(grep -o '"type":"[^"]*"' "$chfile" | cut -d'"' -f4)
        local ch_ref
        ch_ref=$(grep -o '"token_ref":"[^"]*"' "$chfile" | cut -d'"' -f4)
        channels_json="${channels_json}{\"type\":\"${ch_type}\",\"token_ref\":\"${ch_ref}\",\"enabled\":true}"
    done
    channels_json="${channels_json}]"

    # Use python3 or jq to update the config if available, otherwise sed
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open('${OPENCLAW_CONFIG}', 'r') as f:
    cfg = json.load(f)
cfg['channels'] = json.loads('${channels_json}')
with open('${OPENCLAW_CONFIG}', 'w') as f:
    json.dump(cfg, f, indent=4)
" 2>/dev/null || true
    elif command -v jq &>/dev/null; then
        local tmp
        tmp=$(mktemp)
        jq --argjson ch "${channels_json}" '.channels = $ch' "$OPENCLAW_CONFIG" > "$tmp" && mv "$tmp" "$OPENCLAW_CONFIG"
    fi

    chown agentos:agentos "$OPENCLAW_CONFIG" 2>/dev/null || true
}

# ── Commands ──────────────────────────────────────────────────────

cmd_add() {
    local channel_type="${1:-}"
    require_root

    if [[ -z "$channel_type" ]]; then
        echo -e "${BOLD}Select a channel to pair:${NC}"
        echo ""
        echo "  1) Telegram"
        echo "  2) Discord"
        echo "  3) Slack"
        echo ""
        echo -ne "${BOLD}Choice (1-3):${NC} "
        read -r choice
        case "$choice" in
            1) channel_type="telegram" ;;
            2) channel_type="discord" ;;
            3) channel_type="slack" ;;
            *) die "Invalid choice" ;;
        esac
    fi

    # Normalize
    channel_type=$(echo "$channel_type" | tr '[:upper:]' '[:lower:]')

    # Check if already paired
    if [[ -f "${CHANNELS_DIR}/${channel_type}.json" ]]; then
        echo -e "${YELLOW}${channel_type} is already paired.${NC}"
        echo -ne "${BOLD}Replace existing pairing? (y/n):${NC} "
        read -r replace
        if [[ "${replace,,}" != "y" ]]; then
            exit 0
        fi
    fi

    local token=""
    local token_var=""
    local bot_name=""

    case "$channel_type" in
        telegram)
            echo ""
            echo -e "${BLUE}To set up Telegram:${NC}"
            echo "  1. Open Telegram and message @BotFather"
            echo "  2. Send /newbot and follow the prompts"
            echo "  3. Copy the bot token"
            echo ""
            token=$(prompt_secret "Paste your Telegram bot token")
            token_var="TELEGRAM_BOT_TOKEN"

            echo -ne "  Verifying..."
            if bot_name=$(validate_telegram "$token"); then
                echo -e "\r  ${GREEN}Connected to @${bot_name}${NC}              "
            else
                echo -e "\r  ${RED}Could not verify token${NC}              "
                echo -ne "${BOLD}Store anyway? (y/n):${NC} "
                read -r store
                [[ "${store,,}" == "y" ]] || exit 0
            fi
            ;;
        discord)
            echo ""
            echo -e "${BLUE}To set up Discord:${NC}"
            echo "  1. Go to https://discord.com/developers/applications"
            echo "  2. Create an application, add a bot, copy the token"
            echo "  3. Invite the bot to your server via OAuth2 URL Generator"
            echo ""
            token=$(prompt_secret "Paste your Discord bot token")
            token_var="DISCORD_BOT_TOKEN"

            echo -ne "  Verifying..."
            if bot_name=$(validate_discord "$token"); then
                echo -e "\r  ${GREEN}Connected to ${bot_name}${NC}              "
            else
                echo -e "\r  ${RED}Could not verify token${NC}              "
                echo -ne "${BOLD}Store anyway? (y/n):${NC} "
                read -r store
                [[ "${store,,}" == "y" ]] || exit 0
            fi
            ;;
        slack)
            echo ""
            echo -e "${BLUE}To set up Slack:${NC}"
            echo "  1. Go to https://api.slack.com/apps and create a new app"
            echo "  2. Add bot scopes: chat:write, app_mentions:read, im:history"
            echo "  3. Install to your workspace and copy the Bot OAuth Token"
            echo ""
            token=$(prompt_secret "Paste your Slack Bot User OAuth Token")
            token_var="SLACK_BOT_TOKEN"

            echo -ne "  Verifying..."
            if bot_name=$(validate_slack "$token"); then
                echo -e "\r  ${GREEN}Connected to ${bot_name}${NC}              "
            else
                echo -e "\r  ${RED}Could not verify token${NC}              "
                echo -ne "${BOLD}Store anyway? (y/n):${NC} "
                read -r store
                [[ "${store,,}" == "y" ]] || exit 0
            fi
            ;;
        *)
            die "Unknown channel type '${channel_type}'. Supported: telegram, discord, slack"
            ;;
    esac

    # Store token in vault
    echo -n "$token" | tee "${VAULT_DIR}/${token_var}" > /dev/null
    chmod 600 "${VAULT_DIR}/${token_var}"

    # Write channel config
    mkdir -p "$CHANNELS_DIR"
    cat > "${CHANNELS_DIR}/${channel_type}.json" <<CHCFG
{
    "type": "${channel_type}",
    "enabled": true,
    "bot_name": "${bot_name}",
    "token_ref": "${token_var}",
    "created": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
CHCFG
    chown -R agentos:agentos "$CHANNELS_DIR"

    # Sync openclaw config
    sync_openclaw_config

    audit "pair" "$channel_type" "ok"
    echo ""
    echo -e "${GREEN}${channel_type} channel paired successfully.${NC}"
    echo -e "${YELLOW}Restart the gateway to activate: sudo systemctl restart agentos-gateway${NC}"
}

cmd_remove() {
    local channel_type="${1:-}"
    require_root

    [[ -z "$channel_type" ]] && die "Usage: agentos-pair remove <telegram|discord|slack>"
    channel_type=$(echo "$channel_type" | tr '[:upper:]' '[:lower:]')

    local config_file="${CHANNELS_DIR}/${channel_type}.json"
    if [[ ! -f "$config_file" ]]; then
        die "${channel_type} is not paired."
    fi

    # Get token ref and remove from vault
    local token_var
    token_var=$(grep -o '"token_ref":"[^"]*"' "$config_file" | cut -d'"' -f4)
    if [[ -n "$token_var" && -f "${VAULT_DIR}/${token_var}" ]]; then
        shred -u "${VAULT_DIR}/${token_var}" 2>/dev/null || rm -f "${VAULT_DIR}/${token_var}"
    fi

    # Remove channel config
    rm -f "$config_file"

    # Sync openclaw config
    sync_openclaw_config

    audit "unpair" "$channel_type" "ok"
    echo -e "${GREEN}${channel_type} channel removed.${NC}"
    echo -e "${YELLOW}Restart the gateway to apply: sudo systemctl restart agentos-gateway${NC}"
}

cmd_list() {
    echo -e "${BOLD}Paired channels:${NC}"
    echo ""

    local count=0
    mkdir -p "$CHANNELS_DIR"
    for chfile in "${CHANNELS_DIR}"/*.json; do
        [[ -f "$chfile" ]] || continue
        local ch_type ch_bot ch_enabled ch_created
        ch_type=$(grep -o '"type":"[^"]*"' "$chfile" | cut -d'"' -f4)
        ch_bot=$(grep -o '"bot_name":"[^"]*"' "$chfile" | cut -d'"' -f4)
        ch_enabled=$(grep -o '"enabled":[^,}]*' "$chfile" | cut -d':' -f2 | tr -d ' ')
        ch_created=$(grep -o '"created":"[^"]*"' "$chfile" | cut -d'"' -f4)

        local status_color="$GREEN"
        local status_text="active"
        if [[ "$ch_enabled" != "true" ]]; then
            status_color="$YELLOW"
            status_text="disabled"
        fi

        printf "  %-12s  bot: %-20s  ${status_color}%s${NC}  paired: %s\n" \
            "$ch_type" "${ch_bot:-unknown}" "$status_text" "${ch_created:-unknown}"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  (no channels paired)"
        echo ""
        echo -e "  ${CYAN}Pair a channel with: sudo agentos-pair add${NC}"
    fi
    echo ""
    echo "${count} channel(s) paired."
}

cmd_test() {
    local channel_type="${1:-}"
    [[ -z "$channel_type" ]] && die "Usage: agentos-pair test <telegram|discord|slack>"
    channel_type=$(echo "$channel_type" | tr '[:upper:]' '[:lower:]')

    local config_file="${CHANNELS_DIR}/${channel_type}.json"
    if [[ ! -f "$config_file" ]]; then
        die "${channel_type} is not paired. Run 'agentos-pair add ${channel_type}' first."
    fi

    local token_var
    token_var=$(grep -o '"token_ref":"[^"]*"' "$config_file" | cut -d'"' -f4)
    local token=""

    # Read token from vault
    if [[ -f "${VAULT_DIR}/${token_var}" ]]; then
        token=$(cat "${VAULT_DIR}/${token_var}")
    else
        die "Token not found in vault for ${channel_type}. Re-pair with 'agentos-pair add ${channel_type}'."
    fi

    echo -ne "  Testing ${channel_type} connection..."

    case "$channel_type" in
        telegram)
            if bot_name=$(validate_telegram "$token"); then
                echo -e "\r  ${GREEN}Telegram OK${NC} — connected to @${bot_name}              "
                audit "test" "telegram" "ok"
            else
                echo -e "\r  ${RED}Telegram FAILED${NC} — token may be revoked              "
                audit "test" "telegram" "fail"
                exit 1
            fi
            ;;
        discord)
            if bot_name=$(validate_discord "$token"); then
                echo -e "\r  ${GREEN}Discord OK${NC} — connected to ${bot_name}              "
                audit "test" "discord" "ok"
            else
                echo -e "\r  ${RED}Discord FAILED${NC} — token may be revoked              "
                audit "test" "discord" "fail"
                exit 1
            fi
            ;;
        slack)
            if bot_name=$(validate_slack "$token"); then
                echo -e "\r  ${GREEN}Slack OK${NC} — connected to ${bot_name}              "
                audit "test" "slack" "ok"
            else
                echo -e "\r  ${RED}Slack FAILED${NC} — token may be revoked              "
                audit "test" "slack" "fail"
                exit 1
            fi
            ;;
        *)
            die "Unknown channel: ${channel_type}"
            ;;
    esac
}

cmd_status() {
    echo -e "${BOLD}Channel Status${NC}"
    echo "=============="
    echo ""

    mkdir -p "$CHANNELS_DIR"
    local has_channels=false
    for chfile in "${CHANNELS_DIR}"/*.json; do
        [[ -f "$chfile" ]] || continue
        has_channels=true
        local ch_type
        ch_type=$(grep -o '"type":"[^"]*"' "$chfile" | cut -d'"' -f4)
        local token_var
        token_var=$(grep -o '"token_ref":"[^"]*"' "$chfile" | cut -d'"' -f4)

        echo -ne "  ${ch_type}: "

        # Check if token exists in vault
        if [[ ! -f "${VAULT_DIR}/${token_var}" ]]; then
            echo -e "${RED}token missing from vault${NC}"
            continue
        fi

        # Validate live connection
        local token
        token=$(cat "${VAULT_DIR}/${token_var}" 2>/dev/null)
        case "$ch_type" in
            telegram)
                if validate_telegram "$token" >/dev/null 2>&1; then
                    echo -e "${GREEN}connected${NC}"
                else
                    echo -e "${RED}connection failed${NC}"
                fi
                ;;
            discord)
                if validate_discord "$token" >/dev/null 2>&1; then
                    echo -e "${GREEN}connected${NC}"
                else
                    echo -e "${RED}connection failed${NC}"
                fi
                ;;
            slack)
                if validate_slack "$token" >/dev/null 2>&1; then
                    echo -e "${GREEN}connected${NC}"
                else
                    echo -e "${RED}connection failed${NC}"
                fi
                ;;
            *)
                echo -e "${YELLOW}unknown type${NC}"
                ;;
        esac
    done

    if ! $has_channels; then
        echo "  No channels paired."
        echo ""
        echo -e "  ${CYAN}Pair a channel with: sudo agentos-pair add${NC}"
    fi
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────

cmd="${1:-help}"
shift || true

case "$cmd" in
    add)    cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    list)   cmd_list ;;
    test)   cmd_test "$@" ;;
    status) cmd_status ;;
    help|--help|-h)
        echo "Usage: agentos-pair <command> [args]"
        echo ""
        echo "Commands:"
        echo "  add [channel]       Pair a new messaging channel (telegram, discord, slack)"
        echo "  remove <channel>    Remove a paired channel"
        echo "  list                List all paired channels"
        echo "  test <channel>      Test a channel connection"
        echo "  status              Show live connection status for all channels"
        echo ""
        echo "Examples:"
        echo "  sudo agentos-pair add telegram"
        echo "  sudo agentos-pair test discord"
        echo "  agentos-pair list"
        echo ""
        ;;
    *)
        die "Unknown command '${cmd}'. Run 'agentos-pair help' for usage."
        ;;
esac
