#!/usr/bin/env bash
#
# Phase 05: Setup Wizard
# Installs the first-run setup wizard into the image
#
set -euo pipefail

log "Installing setup wizard..."

# ── Main setup wizard script ───────────────────────────────────────
cat > "${ROOTFS}/opt/agentos/bin/setup-wizard.sh" <<'WIZARD'
#!/usr/bin/env bash
#
# AgentOS First-Run Setup Wizard
# Guides the user through configuring their AI agent
#
set -euo pipefail

SETUP_DONE_FLAG="/home/agentos/.openclaw/.setup-complete"
SETUP_CONF="/etc/agentos/setup.conf"
ENV_FILE="/etc/agentos/env"
VAULT_DIR="/etc/agentos/vault"
CHANNELS_DIR="/home/agentos/.openclaw/channels"
AUDIT_LOG="/var/log/agentos/audit.log"
LOG="/var/log/agentos/setup.log"

# Skip if already set up
if [[ -f "$SETUP_DONE_FLAG" ]]; then
    exit 0
fi

# ── Non-interactive mode ───────────────────────────────────────────
# Triggered by /etc/agentos/setup.conf or AGENTOS_NONINTERACTIVE=true.
# Used by the Server edition for cloud-init / automated provisioning.
NONINTERACTIVE=false
if [[ -f "$SETUP_CONF" ]] || [[ "${AGENTOS_NONINTERACTIVE:-}" == "true" ]]; then
    NONINTERACTIVE=true
    [[ -f "$SETUP_CONF" ]] && source "$SETUP_CONF"
fi

# ── Colors and helpers ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_setup() {
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "${timestamp} [wizard] $*" >> "$LOG" 2>/dev/null || true
    printf '{"ts":"%s","component":"wizard","action":"%s","status":"info","user":"wizard"}\n' \
        "$timestamp" "$*" >> "$AUDIT_LOG" 2>/dev/null || true
}

print_header() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║                                                   ║"
    echo "  ║              Welcome to AgentOS                   ║"
    echo "  ║         Your AI, your machine                     ║"
    echo "  ║                                                   ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        echo -ne "${BOLD}${prompt_text}${NC} [${default}]: "
    else
        echo -ne "${BOLD}${prompt_text}${NC}: "
    fi
    read -r value
    value="${value:-$default}"
    eval "$var_name='$value'"
}

prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    local value

    echo -ne "${BOLD}${prompt_text}${NC}: "
    read -rs value
    echo ""
    eval "$var_name='$value'"
}

spinner() {
    local pid=$1
    local msg="$2"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${CYAN}${chars:$i:1}${NC} ${msg}"
        i=$(( (i + 1) % ${#chars} ))
        sleep 0.1
    done
    wait "$pid"
    return $?
}

# ── API key validation ────────────────────────────────────────────

validate_anthropic_key() {
    local key="$1"
    # Check format: should start with sk-ant-
    if [[ ! "$key" =~ ^sk-ant- ]]; then
        echo -e "  ${YELLOW}Warning: Key doesn't match expected Anthropic format (sk-ant-...)${NC}"
        echo -e "  ${YELLOW}Continuing anyway — the key will be tested when the gateway starts.${NC}"
        return 0
    fi
    # Test the key with a minimal API call
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: ${key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null) || true
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        return 0
    elif [[ "$http_code" == "401" ]]; then
        return 1
    fi
    # Other codes (rate limit, etc.) — key format is likely valid
    return 0
}

validate_openai_key() {
    local key="$1"
    if [[ ! "$key" =~ ^sk- ]]; then
        echo -e "  ${YELLOW}Warning: Key doesn't match expected OpenAI format (sk-...)${NC}"
        return 0
    fi
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://api.openai.com/v1/models" \
        -H "Authorization: Bearer ${key}" 2>/dev/null) || true
    if [[ "$http_code" == "401" ]]; then
        return 1
    fi
    return 0
}

validate_openrouter_key() {
    local key="$1"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://openrouter.ai/api/v1/auth/key" \
        -H "Authorization: Bearer ${key}" 2>/dev/null) || true
    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        return 1
    fi
    return 0
}

# ── Channel validation ────────────────────────────────────────────

validate_telegram_token() {
    local token="$1"
    local response
    response=$(curl -s "https://api.telegram.org/bot${token}/getMe" 2>/dev/null) || true
    if echo "$response" | grep -q '"ok":true'; then
        local bot_name
        bot_name=$(echo "$response" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
        echo "$bot_name"
        return 0
    fi
    return 1
}

validate_discord_token() {
    local token="$1"
    local response
    response=$(curl -s -w "\n%{http_code}" "https://discord.com/api/v10/users/@me" \
        -H "Authorization: Bot ${token}" 2>/dev/null) || true
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "200" ]]; then
        local bot_name
        bot_name=$(echo "$response" | head -1 | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
        echo "$bot_name"
        return 0
    fi
    return 1
}

validate_slack_token() {
    local token="$1"
    local response
    response=$(curl -s "https://slack.com/api/auth.test" \
        -H "Authorization: Bearer ${token}" 2>/dev/null) || true
    if echo "$response" | grep -q '"ok":true'; then
        local bot_name
        bot_name=$(echo "$response" | grep -o '"user":"[^"]*"' | cut -d'"' -f4)
        echo "$bot_name"
        return 0
    fi
    return 1
}

# ── Store channel config ──────────────────────────────────────────

store_channel_config() {
    local channel_type="$1"
    local token_var="$2"
    local token_value="$3"
    local bot_name="${4:-}"

    # Store token in vault
    echo -n "$token_value" | sudo tee "${VAULT_DIR}/${token_var}" > /dev/null
    sudo chmod 600 "${VAULT_DIR}/${token_var}"

    # Create channel config directory
    sudo -u agentos mkdir -p "$CHANNELS_DIR"

    # Write channel config
    sudo -u agentos bash -c "cat > ${CHANNELS_DIR}/${channel_type}.json" <<CHCFG
{
    "type": "${channel_type}",
    "enabled": true,
    "bot_name": "${bot_name}",
    "token_ref": "${token_var}",
    "created": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
CHCFG

    log_setup "Channel paired: ${channel_type} (bot: ${bot_name})"
}

# ── Step 1: Welcome ───────────────────────────────────────────────
log_setup "Setup wizard started"

if [[ "$NONINTERACTIVE" != "true" ]]; then
    print_header
    echo -e "${BOLD}Let's set up your AI agent. This takes about 2 minutes.${NC}"
    echo ""
    echo "  You'll need:"
    echo "    1. An API key from Anthropic, OpenAI, or OpenRouter"
    echo "    2. (Optional) A messaging channel (Telegram, Discord, Slack)"
    echo ""
    echo -ne "Press ${BOLD}Enter${NC} to begin... "
    read -r
fi

# ── Step 2: Model provider ────────────────────────────────────────
API_KEY=""
KEY_VAR=""
PROVIDER=""

if [[ "$NONINTERACTIVE" == "true" ]]; then
    # Non-interactive: read from setup.conf / env vars
    PROVIDER="${AGENTOS_PROVIDER:-anthropic}"
    API_KEY="${AGENTOS_API_KEY:-}"
    case "$PROVIDER" in
        anthropic)   KEY_VAR="ANTHROPIC_API_KEY" ;;
        openai)      KEY_VAR="OPENAI_API_KEY" ;;
        openrouter)  KEY_VAR="OPENROUTER_API_KEY" ;;
        ollama)      KEY_VAR="" ;;
        *)           KEY_VAR="ANTHROPIC_API_KEY"; PROVIDER="anthropic" ;;
    esac
    log_setup "Non-interactive provider: ${PROVIDER}"
else
    print_header
    echo -e "${BOLD}Step 1/5: Choose your AI model provider${NC}"
    echo ""
    echo "  1) Anthropic (Claude) — recommended"
    echo "  2) OpenAI (GPT)"
    echo "  3) OpenRouter (multi-provider)"
    echo "  4) Local model via Ollama (no API key needed)"
    echo ""
    prompt PROVIDER_CHOICE "Select provider (1-4)" "1"

    case "$PROVIDER_CHOICE" in
    1)
        PROVIDER="anthropic"
        echo ""
        echo -e "${BLUE}Get your API key at: https://console.anthropic.com${NC}"
        echo ""
        prompt_secret API_KEY "Paste your Anthropic API key"
        KEY_VAR="ANTHROPIC_API_KEY"

        echo ""
        echo -ne "  Validating API key..."
        if validate_anthropic_key "$API_KEY"; then
            echo -e "\r  ${GREEN}API key is valid${NC}              "
        else
            echo -e "\r  ${RED}API key appears invalid${NC}        "
            prompt CONTINUE "Continue anyway? (y/n)" "n"
            if [[ "${CONTINUE,,}" != "y" ]]; then
                echo -e "${YELLOW}Re-run the wizard: /opt/agentos/bin/setup-wizard.sh${NC}"
                exit 0
            fi
        fi
        ;;
    2)
        PROVIDER="openai"
        echo ""
        echo -e "${BLUE}Get your API key at: https://platform.openai.com/api-keys${NC}"
        echo ""
        prompt_secret API_KEY "Paste your OpenAI API key"
        KEY_VAR="OPENAI_API_KEY"

        echo ""
        echo -ne "  Validating API key..."
        if validate_openai_key "$API_KEY"; then
            echo -e "\r  ${GREEN}API key is valid${NC}              "
        else
            echo -e "\r  ${RED}API key appears invalid${NC}        "
            prompt CONTINUE "Continue anyway? (y/n)" "n"
            if [[ "${CONTINUE,,}" != "y" ]]; then
                exit 0
            fi
        fi
        ;;
    3)
        PROVIDER="openrouter"
        echo ""
        echo -e "${BLUE}Get your API key at: https://openrouter.ai/keys${NC}"
        echo ""
        prompt_secret API_KEY "Paste your OpenRouter API key"
        KEY_VAR="OPENROUTER_API_KEY"

        echo ""
        echo -ne "  Validating API key..."
        if validate_openrouter_key "$API_KEY"; then
            echo -e "\r  ${GREEN}API key is valid${NC}              "
        else
            echo -e "\r  ${RED}API key appears invalid${NC}        "
            prompt CONTINUE "Continue anyway? (y/n)" "n"
            if [[ "${CONTINUE,,}" != "y" ]]; then
                exit 0
            fi
        fi
        ;;
    4)
        PROVIDER="ollama"
        echo ""
        echo -e "${YELLOW}Ollama will be configured after setup.${NC}"
        echo -e "${YELLOW}You'll need to run: ollama pull mistral (or your preferred model)${NC}"
        ;;
    *)
        echo -e "${RED}Invalid choice, defaulting to Anthropic${NC}"
        PROVIDER="anthropic"
        prompt_secret API_KEY "Paste your Anthropic API key"
        KEY_VAR="ANTHROPIC_API_KEY"
        ;;
    esac
fi  # end interactive provider selection

log_setup "Provider selected: ${PROVIDER}"

# ── Step 3: Agent name ─────────────────────────────────────────────
if [[ "$NONINTERACTIVE" == "true" ]]; then
    AGENT_NAME="${AGENTOS_AGENT_NAME:-Atlas}"
else
    print_header
    echo -e "${BOLD}Step 2/5: Name your agent${NC}"
    echo ""
    prompt AGENT_NAME "What should your agent be called?" "Atlas"
fi
log_setup "Agent named: ${AGENT_NAME}"

# ── Step 4: Messaging channel ──────────────────────────────────────
CHANNEL_CONFIG="skip"
CHANNEL_BOT_NAME=""

if [[ "$NONINTERACTIVE" == "true" ]]; then
    # Non-interactive channel setup
    CHANNEL_CHOICE="${AGENTOS_CHANNEL:-skip}"
    CHANNEL_TOKEN="${AGENTOS_CHANNEL_TOKEN:-}"
    case "$CHANNEL_CHOICE" in
        telegram)
            if [[ -n "$CHANNEL_TOKEN" ]]; then
                if BOT_NAME=$(validate_telegram_token "$CHANNEL_TOKEN" 2>/dev/null); then
                    store_channel_config "telegram" "TELEGRAM_BOT_TOKEN" "$CHANNEL_TOKEN" "$BOT_NAME"
                    CHANNEL_CONFIG="telegram"
                    CHANNEL_BOT_NAME="$BOT_NAME"
                    log_setup "Telegram configured non-interactively"
                else
                    log_setup "WARN: Telegram token validation failed, skipping channel"
                fi
            fi
            ;;
        discord)
            if [[ -n "$CHANNEL_TOKEN" ]]; then
                if BOT_NAME=$(validate_discord_token "$CHANNEL_TOKEN" 2>/dev/null); then
                    store_channel_config "discord" "DISCORD_BOT_TOKEN" "$CHANNEL_TOKEN" "$BOT_NAME"
                    CHANNEL_CONFIG="discord"
                    CHANNEL_BOT_NAME="$BOT_NAME"
                    log_setup "Discord configured non-interactively"
                else
                    log_setup "WARN: Discord token validation failed, skipping channel"
                fi
            fi
            ;;
        slack)
            if [[ -n "$CHANNEL_TOKEN" ]]; then
                if BOT_NAME=$(validate_slack_token "$CHANNEL_TOKEN" 2>/dev/null); then
                    store_channel_config "slack" "SLACK_BOT_TOKEN" "$CHANNEL_TOKEN" "$BOT_NAME"
                    CHANNEL_CONFIG="slack"
                    CHANNEL_BOT_NAME="$BOT_NAME"
                    log_setup "Slack configured non-interactively"
                else
                    log_setup "WARN: Slack token validation failed, skipping channel"
                fi
            fi
            ;;
        *)
            CHANNEL_CONFIG="skip"
            ;;
    esac
else
    print_header
    echo -e "${BOLD}Step 3/5: Connect a messaging channel (optional)${NC}"
    echo ""
    echo "  You can message your agent from any of these platforms:"
    echo ""
    echo "  1) Telegram — easiest to set up"
    echo "  2) Discord"
    echo "  3) Slack"
    echo "  4) Skip for now — I'll use the web dashboard"
    echo ""
    echo -e "  ${CYAN}You can add more channels later with: agentos-pair add${NC}"
    echo ""
    prompt CHANNEL_CHOICE "Select channel (1-4)" "4"

    case "$CHANNEL_CHOICE" in
    1)
        echo ""
        echo -e "${BLUE}To set up Telegram:${NC}"
        echo "  1. Open Telegram and message @BotFather"
        echo "  2. Send /newbot and follow the prompts"
        echo "  3. Copy the bot token"
        echo ""
        prompt_secret TELEGRAM_TOKEN "Paste your Telegram bot token"

        echo ""
        echo -ne "  Verifying bot token..."
        if BOT_NAME=$(validate_telegram_token "$TELEGRAM_TOKEN"); then
            echo -e "\r  ${GREEN}Connected to Telegram bot: @${BOT_NAME}${NC}              "
            CHANNEL_CONFIG="telegram"
            CHANNEL_BOT_NAME="$BOT_NAME"
            log_setup "Telegram bot verified: @${BOT_NAME}"
        else
            echo -e "\r  ${RED}Could not verify Telegram bot token${NC}              "
            echo ""
            prompt CONTINUE "Continue without Telegram? (y/n)" "y"
            if [[ "${CONTINUE,,}" == "y" ]]; then
                CHANNEL_CONFIG="skip"
            else
                CHANNEL_CONFIG="telegram-unverified"
            fi
        fi
        ;;
    2)
        echo ""
        echo -e "${BLUE}To set up Discord:${NC}"
        echo "  1. Go to https://discord.com/developers/applications"
        echo "  2. Create a new application and add a bot"
        echo "  3. Under Bot settings, copy the bot token"
        echo "  4. Under OAuth2 > URL Generator, select 'bot' scope"
        echo "  5. Use the generated URL to invite the bot to your server"
        echo ""
        prompt_secret DISCORD_TOKEN "Paste your Discord bot token"

        echo ""
        echo -ne "  Verifying bot token..."
        if BOT_NAME=$(validate_discord_token "$DISCORD_TOKEN"); then
            echo -e "\r  ${GREEN}Connected to Discord bot: ${BOT_NAME}${NC}              "
            CHANNEL_CONFIG="discord"
            CHANNEL_BOT_NAME="$BOT_NAME"
            log_setup "Discord bot verified: ${BOT_NAME}"
        else
            echo -e "\r  ${RED}Could not verify Discord bot token${NC}              "
            echo ""
            prompt CONTINUE "Continue without Discord? (y/n)" "y"
            if [[ "${CONTINUE,,}" == "y" ]]; then
                CHANNEL_CONFIG="skip"
            else
                CHANNEL_CONFIG="discord-unverified"
            fi
        fi
        ;;
    3)
        echo ""
        echo -e "${BLUE}To set up Slack:${NC}"
        echo "  1. Go to https://api.slack.com/apps and create a new app"
        echo "  2. Add bot scopes: chat:write, app_mentions:read, im:history"
        echo "  3. Install the app to your workspace"
        echo "  4. Copy the Bot User OAuth Token (starts with xoxb-)"
        echo ""
        prompt_secret SLACK_TOKEN "Paste your Slack Bot User OAuth Token"

        echo ""
        echo -ne "  Verifying bot token..."
        if BOT_NAME=$(validate_slack_token "$SLACK_TOKEN"); then
            echo -e "\r  ${GREEN}Connected to Slack bot: ${BOT_NAME}${NC}              "
            CHANNEL_CONFIG="slack"
            CHANNEL_BOT_NAME="$BOT_NAME"
            log_setup "Slack bot verified: ${BOT_NAME}"
        else
            echo -e "\r  ${RED}Could not verify Slack bot token${NC}              "
            echo ""
            prompt CONTINUE "Continue without Slack? (y/n)" "y"
            if [[ "${CONTINUE,,}" == "y" ]]; then
                CHANNEL_CONFIG="skip"
            else
                CHANNEL_CONFIG="slack-unverified"
            fi
        fi
        ;;
    *)
        CHANNEL_CONFIG="skip"
        ;;
    esac
fi  # end interactive channel selection

# ── Step 5: Confirmation ──────────────────────────────────────────
if [[ "$NONINTERACTIVE" != "true" ]]; then
    print_header
    echo -e "${BOLD}Step 4/5: Confirm your setup${NC}"
    echo ""
    echo -e "  Provider:  ${GREEN}${PROVIDER}${NC}"
    echo -e "  Agent:     ${GREEN}${AGENT_NAME}${NC}"
    if [[ "$CHANNEL_CONFIG" != "skip" ]]; then
        echo -e "  Channel:   ${GREEN}${CHANNEL_CONFIG}${NC} (${CHANNEL_BOT_NAME})"
    else
        echo -e "  Channel:   ${YELLOW}none (use web dashboard)${NC}"
    fi
    echo ""
    prompt CONFIRM "Apply this configuration? (y/n)" "y"

    if [[ "${CONFIRM,,}" != "y" ]]; then
        echo -e "${YELLOW}Setup cancelled. Run /opt/agentos/bin/setup-wizard.sh to try again.${NC}"
        exit 0
    fi
fi  # end interactive confirmation

# ── Step 6: Apply configuration ──────────────────────────────────
if [[ "$NONINTERACTIVE" != "true" ]]; then
    print_header
    echo -e "${BOLD}Step 5/5: Applying configuration...${NC}"
    echo ""
fi

# Write API key to vault
if [[ -n "$API_KEY" && -n "$KEY_VAR" ]]; then
    echo -n "$API_KEY" | sudo tee "${VAULT_DIR}/${KEY_VAR}" > /dev/null
    sudo chmod 600 "${VAULT_DIR}/${KEY_VAR}"

    # Also write to env file for OpenClaw
    sudo sed -i "s|^# *${KEY_VAR}=.*|${KEY_VAR}=$(cat ${VAULT_DIR}/${KEY_VAR})|" "$ENV_FILE"
    echo -e "  ${GREEN}✓${NC} API key stored in vault"
    log_setup "API key stored: ${KEY_VAR}"
fi

# Store channel token and config
case "$CHANNEL_CONFIG" in
    telegram|telegram-unverified)
        store_channel_config "telegram" "TELEGRAM_BOT_TOKEN" "$TELEGRAM_TOKEN" "$CHANNEL_BOT_NAME"
        echo -e "  ${GREEN}✓${NC} Telegram channel configured"
        ;;
    discord|discord-unverified)
        store_channel_config "discord" "DISCORD_BOT_TOKEN" "$DISCORD_TOKEN" "$CHANNEL_BOT_NAME"
        echo -e "  ${GREEN}✓${NC} Discord channel configured"
        ;;
    slack|slack-unverified)
        store_channel_config "slack" "SLACK_BOT_TOKEN" "$SLACK_TOKEN" "$CHANNEL_BOT_NAME"
        echo -e "  ${GREEN}✓${NC} Slack channel configured"
        ;;
esac

# Determine model based on provider
MODEL_NAME="claude-sonnet-4-20250514"
case "$PROVIDER" in
    openai)    MODEL_NAME="gpt-4o" ;;
    openrouter) MODEL_NAME="anthropic/claude-sonnet-4-20250514" ;;
    ollama)    MODEL_NAME="mistral" ;;
esac

# Build channels array for openclaw config
CHANNELS_JSON="[]"
if [[ -d "$CHANNELS_DIR" ]]; then
    CHANNELS_JSON="["
    first=true
    for chfile in "${CHANNELS_DIR}"/*.json; do
        [[ -f "$chfile" ]] || continue
        $first || CHANNELS_JSON="${CHANNELS_JSON},"
        first=false
        local_type=$(grep -o '"type":"[^"]*"' "$chfile" | cut -d'"' -f4)
        local_ref=$(grep -o '"token_ref":"[^"]*"' "$chfile" | cut -d'"' -f4)
        CHANNELS_JSON="${CHANNELS_JSON}{\"type\":\"${local_type}\",\"token_ref\":\"${local_ref}\",\"enabled\":true}"
    done
    CHANNELS_JSON="${CHANNELS_JSON}]"
fi

# Configure OpenClaw
# Read gateway host and execution policy from env file (may have been overridden at build time)
GW_HOST=$(grep '^OPENCLAW_GATEWAY_HOST=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "127.0.0.1")
EXEC_POLICY=$(grep '^OPENCLAW_EXECUTION_POLICY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "ask")
sudo -u agentos bash -c "cat > /home/agentos/.openclaw/openclaw.json" <<OCJSON
{
    "name": "${AGENT_NAME}",
    "models": {
        "primary": {
            "provider": "${PROVIDER}",
            "model": "${MODEL_NAME}"
        }
    },
    "gateway": {
        "port": 18789,
        "host": "${GW_HOST}",
        "auth": "token"
    },
    "channels": ${CHANNELS_JSON},
    "sandbox": {
        "engine": "docker",
        "execution_policy": "${EXEC_POLICY}"
    }
}
OCJSON
echo -e "  ${GREEN}✓${NC} OpenClaw configured"

# Restart the gateway
sudo systemctl restart agentos-gateway
echo -e "  ${GREEN}✓${NC} Gateway restarted"

# Mark setup as complete
sudo -u agentos touch "$SETUP_DONE_FLAG"

# Disable auto-login and remove autostart entry (desktop only, non-fatal on server)
if [[ "$NONINTERACTIVE" != "true" ]]; then
    sudo sed -i 's/^AutomaticLoginEnable=true/AutomaticLoginEnable=false/' /etc/gdm3/custom.conf 2>/dev/null || true
    rm -f /etc/xdg/autostart/agentos-wizard.desktop 2>/dev/null || true
fi

log_setup "Setup complete"

# ── Done ───────────────────────────────────────────────────────────
if [[ "$NONINTERACTIVE" == "true" ]]; then
    echo "[AgentOS] Setup complete. Gateway listening on port 18789."
    log_setup "Non-interactive setup finished successfully"
else
    echo ""
    echo -e "${GREEN}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║                                                   ║"
    echo "  ║           AgentOS is ready!                       ║"
    echo "  ║                                                   ║"
    echo "  ║   Dashboard: http://localhost:18789               ║"
    echo "  ║   Logs:      journalctl -u agentos-gateway -f    ║"
    echo "  ║                                                   ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    case "$CHANNEL_CONFIG" in
        telegram)
            echo -e "  ${GREEN}✓${NC} Telegram bot @${CHANNEL_BOT_NAME} is paired."
            echo -e "    Send it a message to start chatting with your agent!"
            ;;
        discord)
            echo -e "  ${GREEN}✓${NC} Discord bot ${CHANNEL_BOT_NAME} is paired."
            echo -e "    Mention the bot in your server to start chatting!"
            ;;
        slack)
            echo -e "  ${GREEN}✓${NC} Slack bot ${CHANNEL_BOT_NAME} is paired."
            echo -e "    Mention the bot in a channel or DM it to start chatting!"
            ;;
        skip)
            echo -e "  ${CYAN}Tip: Add a messaging channel later with: agentos-pair add${NC}"
            ;;
    esac

    echo ""
    echo -ne "Press ${BOLD}Enter${NC} to close this wizard... "
    read -r
fi
WIZARD

chroot "${ROOTFS}" chmod +x /opt/agentos/bin/setup-wizard.sh

# ── Server: first-boot non-interactive setup service ──────────────
if [[ "$EDITION" == "--server" ]]; then
    log "Installing non-interactive first-boot setup service..."
    cat > "${ROOTFS}/etc/systemd/system/agentos-setup.service" <<'SVCEOF'
[Unit]
Description=AgentOS First-Run Setup (non-interactive)
After=network-online.target cloud-final.service
Wants=network-online.target
ConditionPathExists=!/home/agentos/.openclaw/.setup-complete

[Service]
Type=oneshot
Environment=AGENTOS_NONINTERACTIVE=true
ExecStart=/opt/agentos/bin/setup-wizard.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    chroot "${ROOTFS}" systemctl enable agentos-setup.service
fi

ok "Setup wizard installed"
