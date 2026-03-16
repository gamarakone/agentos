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
ENV_FILE="/etc/agentos/env"
LOG="/var/log/agentos/setup.log"

# Skip if already set up
if [[ -f "$SETUP_DONE_FLAG" ]]; then
    exit 0
fi

# ── Colors and helpers ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

# ── Step 1: Welcome ───────────────────────────────────────────────
print_header
echo -e "${BOLD}Let's set up your AI agent. This takes about 2 minutes.${NC}"
echo ""
echo "  You'll need:"
echo "    1. An API key from Anthropic, OpenAI, or OpenRouter"
echo "    2. (Optional) A messaging app to connect (Telegram, Discord, etc.)"
echo ""
echo -ne "Press ${BOLD}Enter${NC} to begin... "
read -r

# ── Step 2: Model provider ────────────────────────────────────────
print_header
echo -e "${BOLD}Step 1/4: Choose your AI model provider${NC}"
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
        ;;
    2)
        PROVIDER="openai"
        echo ""
        echo -e "${BLUE}Get your API key at: https://platform.openai.com/api-keys${NC}"
        echo ""
        prompt_secret API_KEY "Paste your OpenAI API key"
        KEY_VAR="OPENAI_API_KEY"
        ;;
    3)
        PROVIDER="openrouter"
        echo ""
        echo -e "${BLUE}Get your API key at: https://openrouter.ai/keys${NC}"
        echo ""
        prompt_secret API_KEY "Paste your OpenRouter API key"
        KEY_VAR="OPENROUTER_API_KEY"
        ;;
    4)
        PROVIDER="ollama"
        API_KEY=""
        KEY_VAR=""
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

# ── Step 3: Agent name ─────────────────────────────────────────────
print_header
echo -e "${BOLD}Step 2/4: Name your agent${NC}"
echo ""
prompt AGENT_NAME "What should your agent be called?" "Atlas"

# ── Step 4: Messaging channel ──────────────────────────────────────
print_header
echo -e "${BOLD}Step 3/4: Connect a messaging channel (optional)${NC}"
echo ""
echo "  You can message your agent from any of these platforms:"
echo ""
echo "  1) Telegram — easiest to set up"
echo "  2) Discord"
echo "  3) WhatsApp"
echo "  4) Skip for now — I'll use the web dashboard"
echo ""
prompt CHANNEL_CHOICE "Select channel (1-4)" "4"

CHANNEL_CONFIG=""
case "$CHANNEL_CHOICE" in
    1)
        echo ""
        echo -e "${BLUE}To set up Telegram:${NC}"
        echo "  1. Open Telegram and message @BotFather"
        echo "  2. Send /newbot and follow the prompts"
        echo "  3. Copy the bot token"
        echo ""
        prompt_secret TELEGRAM_TOKEN "Paste your Telegram bot token"
        CHANNEL_CONFIG="telegram"
        ;;
    2)
        echo ""
        echo -e "${BLUE}To set up Discord:${NC}"
        echo "  1. Go to https://discord.com/developers/applications"
        echo "  2. Create a new application and add a bot"
        echo "  3. Copy the bot token"
        echo ""
        prompt_secret DISCORD_TOKEN "Paste your Discord bot token"
        CHANNEL_CONFIG="discord"
        ;;
    3)
        echo ""
        echo -e "${YELLOW}WhatsApp requires additional setup after the wizard.${NC}"
        echo -e "${YELLOW}We'll configure this via the OpenClaw CLI.${NC}"
        CHANNEL_CONFIG="whatsapp-later"
        ;;
    *)
        CHANNEL_CONFIG="skip"
        ;;
esac

# ── Step 5: Confirmation ──────────────────────────────────────────
print_header
echo -e "${BOLD}Step 4/4: Confirm your setup${NC}"
echo ""
echo -e "  Provider:  ${GREEN}${PROVIDER}${NC}"
echo -e "  Agent:     ${GREEN}${AGENT_NAME}${NC}"
echo -e "  Channel:   ${GREEN}${CHANNEL_CONFIG}${NC}"
echo ""
prompt CONFIRM "Apply this configuration? (y/n)" "y"

if [[ "${CONFIRM,,}" != "y" ]]; then
    echo -e "${YELLOW}Setup cancelled. Run /opt/agentos/bin/setup-wizard.sh to try again.${NC}"
    exit 0
fi

# ── Apply configuration ───────────────────────────────────────────
echo ""
echo -e "${BLUE}Applying configuration...${NC}"

# Write API key to vault (requires sudo)
if [[ -n "$API_KEY" && -n "$KEY_VAR" ]]; then
    echo "$API_KEY" | sudo tee "/etc/agentos/vault/${KEY_VAR}" > /dev/null
    sudo chmod 600 "/etc/agentos/vault/${KEY_VAR}"

    # Also write to env file for OpenClaw
    sudo sed -i "s|^# *${KEY_VAR}=.*|${KEY_VAR}=$(cat /etc/agentos/vault/${KEY_VAR})|" "$ENV_FILE"
    echo -e "  ${GREEN}✓${NC} API key stored in vault"
fi

# Configure OpenClaw
sudo -u agentos bash -c "
    cd /home/agentos
    # Create basic openclaw config
    cat > /home/agentos/.openclaw/openclaw.json <<OCJSON
{
    \"name\": \"${AGENT_NAME}\",
    \"models\": {
        \"primary\": {
            \"provider\": \"${PROVIDER}\",
            \"model\": \"$([ "$PROVIDER" = "anthropic" ] && echo "claude-sonnet-4-20250514" || echo "gpt-4o")\"
        }
    },
    \"gateway\": {
        \"port\": 18789,
        \"auth\": \"token\"
    }
}
OCJSON
"
echo -e "  ${GREEN}✓${NC} OpenClaw configured"

# Restart the gateway
sudo systemctl restart agentos-gateway
echo -e "  ${GREEN}✓${NC} Gateway restarted"

# Mark setup as complete
sudo -u agentos touch "$SETUP_DONE_FLAG"

# Disable auto-login after first boot
sudo sed -i 's/^AutomaticLoginEnable=true/AutomaticLoginEnable=false/' /etc/gdm3/custom.conf 2>/dev/null || true

# Remove autostart entry
rm -f /etc/xdg/autostart/agentos-wizard.desktop 2>/dev/null || true

# ── Done ───────────────────────────────────────────────────────────
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

if [[ "$CHANNEL_CONFIG" == "telegram" ]]; then
    echo -e "  ${YELLOW}Next: Message your Telegram bot and pair it with:${NC}"
    echo -e "  ${BOLD}  openclaw pairing approve telegram <CODE>${NC}"
fi

echo ""
echo -ne "Press ${BOLD}Enter${NC} to close this wizard... "
read -r
WIZARD

chroot "${ROOTFS}" chmod +x /opt/agentos/bin/setup-wizard.sh

ok "Setup wizard installed"
