# AgentOS

An Ubuntu-based operating system purpose-built for AI automation. Ships with [OpenClaw](https://openclaw.ai) as a first-class system service, hardened security defaults, and a setup wizard that gets you to a working AI agent in under 5 minutes.

## What is this?

AgentOS is a pre-configured VM image (OVA/QCOW2) that turns any virtualization platform into a dedicated AI agent appliance. Boot it up, connect your LLM provider, pair a messaging channel, and you have an always-on AI assistant running in a secure, isolated environment.

**This is not "Ubuntu with OpenClaw installed."** It's an opinionated, security-hardened environment where:
- The agent runs as a dedicated system user with no root access
- Every agent action is logged to an audit trail
- AppArmor profiles restrict what the agent process can touch
- Credentials are stored in a vault the agent process cannot read directly
- A setup wizard handles first-run configuration (model provider, channels, skills)

## Target users

| Edition | Who it's for | What ships |
|---------|-------------|------------|
| **Lite** (this repo) | Anyone who wants an AI agent appliance | GNOME desktop + OpenClaw + setup wizard |
| **Server** (planned) | Headless / cloud deployments | Minimal + systemd gateway + API |
| **Dev** (planned) | Agent developers | CLI-first + SDK + local model runtime |

## Quick start

### Option 1: VirtualBox / UTM / VMware
```bash
# Download the latest OVA
curl -LO https://github.com/SecureAgentOS/agentos/releases/latest/download/agentos-lite.ova

# Import into VirtualBox
VBoxManage import agentos-lite.ova
VBoxManage startvm agentos-lite
```

### Option 2: Build from scratch
```bash
git clone https://github.com/SecureAgentOS/agentos.git
cd agentos
make validate   # Check config before building
make build      # Build the Lite edition (requires Ubuntu 24.04 + sudo)
```

The build script requires Ubuntu 24.04 as the host (or any Debian-based system with debootstrap).

## Architecture

```
┌─────────────────────────────────────────────┐
│  Setup Wizard / Welcome App                 │
├─────────────────────────────────────────────┤
│  OpenClaw Gateway (systemd service)         │
│  ├── Skill marketplace                      │
│  ├── MCP server hub                         │
│  └── Sandbox / permissions                  │
├─────────────────────────────────────────────┤
│  Security layer                             │
│  ├── AppArmor profiles                      │
│  ├── Credential vault                       │
│  └── Audit logging                          │
├─────────────────────────────────────────────┤
│  Ubuntu 24.04 LTS (Noble Numbat)            │
│  Node.js 22 · Docker · GNOME (Lite only)    │
└─────────────────────────────────────────────┘
```

## Build requirements

- Ubuntu 24.04 host (for debootstrap compatibility)
- 20GB free disk space
- `sudo` access
- Internet connection (to pull packages)

## Project structure

```
agentos/
├── scripts/
│   ├── build-vm.sh          # Main build orchestrator
│   ├── 01-bootstrap.sh      # debootstrap base system
│   ├── 02-install-deps.sh   # Node.js, Docker, OpenClaw
│   ├── 03-configure.sh      # systemd units, AppArmor, users
│   ├── 04-desktop.sh        # GNOME + branding (Lite only)
│   ├── 05-wizard.sh         # First-run setup wizard
│   ├── 06-package.sh        # Export as OVA/QCOW2
│   ├── validate.sh          # Pre-build validation checks
│   └── smoke-test.sh        # Post-build rootfs verification
├── config/
│   ├── apparmor/
│   │   ├── agentos-openclaw       # AppArmor profile for OpenClaw agent
│   │   └── agentos-broker         # AppArmor profile for credential broker
│   ├── systemd/
│   │   ├── agentos-gateway.service
│   │   └── agentos-broker.service
│   ├── audit/
│   │   └── agentos.rules          # auditd rules for agent activity
│   ├── logrotate/
│   │   └── agentos                # Log rotation policy
│   ├── channels/
│   │   ├── telegram.example.json   # Telegram channel template
│   │   ├── discord.example.json    # Discord channel template
│   │   └── slack.example.json      # Slack channel template
│   └── openclaw/
│       ├── openclaw.defaults.json  # Default agent config
│       └── env.template            # Environment variable template
├── Makefile                  # Build convenience targets
├── branding/                 # Plymouth theme, wallpaper, icons (Phase 4)
├── docs/                     # User-facing documentation
└── README.md
```

## Security model

AgentOS follows the principle of **least privilege for autonomous agents**:

1. **Dedicated user**: OpenClaw runs as `agentos` (uid 1100), not root
2. **AppArmor confinement**: The agent process can only access its workspace, not system files
3. **Credential isolation**: API keys live in `/etc/agentos/vault/` owned by root; the agent requests tokens through a broker service
4. **Audit trail**: Every shell command, file write, and network request is logged to `/var/log/agentos/audit.log`
5. **Docker sandboxing**: Skills that need shell access run inside ephemeral containers

## Roadmap

- [x] Project scaffold and build scripts
- [x] Phase 1: Bootable VM image with OpenClaw pre-configured
- [x] Phase 2: AppArmor + credential vault + audit logging
- [x] Phase 3: First-run setup wizard with channel pairing
- [ ] Phase 4: Branding (Plymouth, GRUB, wallpaper, welcome app)
- [ ] Phase 5: Server edition (headless, no desktop)
- [ ] Phase 6: Dev edition (SDK, local model support)
- [ ] Future: Bootable ISO for bare-metal installation

## Contributing

This project is in early development. Issues and PRs welcome.

## License

MIT
