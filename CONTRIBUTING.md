# Contributing to AgentOS

Thanks for your interest in contributing to AgentOS! This guide will help you get started.

## Quick Start

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/agentos.git`
3. Create a branch: `git checkout -b my-feature`
4. Make your changes
5. Run validation: `make validate`
6. Commit and push
7. Open a pull request against `main`

## Development Environment

### Requirements

- Ubuntu 24.04 (native or in a VM)
- 20 GB free disk space
- `sudo` access
- Internet connection

### Building from Source

```bash
cd agentos
make validate    # Check scripts and configs
make build       # Build the Lite edition VM image
```

Build artifacts land in `/tmp/agentos-build/output/` by default. Override with `BUILD_DIR`:

```bash
make build BUILD_DIR=/path/to/your/build
```

### Project Structure

```
agentos/
├── .github/workflows/   # CI/CD pipelines
├── config/
│   ├── apparmor/        # AppArmor security profiles
│   ├── systemd/         # Service unit files
│   └── openclaw/        # OpenClaw agent configuration
├── scripts/
│   ├── build-vm.sh      # Main build orchestrator
│   ├── 01-bootstrap.sh  # System bootstrap (debootstrap)
│   ├── 02-install-deps.sh  # Dependency installation
│   ├── 03-configure.sh  # Service and security configuration
│   ├── 04-desktop.sh    # GNOME desktop setup
│   ├── 05-wizard.sh     # First-run setup wizard
│   ├── 06-package.sh    # VM image export (OVA/QCOW2)
│   ├── validate.sh      # Pre-build validation
│   └── smoke-test.sh    # Post-build verification
├── Makefile
└── README.md
```

## What to Work On

### Good First Issues

Look for issues labeled [`good first issue`](https://github.com/SecureAgentOS/agentos/labels/good%20first%20issue). These are scoped, well-defined tasks suitable for newcomers.

### Areas We Need Help

- **Shell scripting**: Improving build scripts, error handling, idempotency
- **Security hardening**: AppArmor profiles, audit rules, credential isolation
- **Testing**: Expanding smoke tests, adding integration tests
- **Documentation**: Tutorials, architecture deep-dives, troubleshooting guides
- **Packaging**: Server and Dev edition builds
- **Desktop**: Setup wizard UX, GNOME customization

## Coding Standards

### Shell Scripts

- Use `set -euo pipefail` at the top of every script
- Quote all variable expansions: `"${VAR}"` not `$VAR`
- Use `#!/usr/bin/env bash` as the shebang
- Add comments explaining *why*, not *what*
- Functions should be lowercase with underscores: `install_deps()`
- Log meaningful progress messages with `echo ">>> Step description"`

### Commit Messages

Use conventional-style messages:

```
feat: add credential rotation to vault broker
fix: resolve NetworkManager race condition on first boot
docs: add architecture diagram to README
chore: update Node.js to v22.x in dependency script
```

Keep the first line under 72 characters. Add a blank line and then a longer description if needed.

### Configuration Files

- AppArmor profiles: follow the existing deny-by-default pattern
- Systemd units: include `[Unit]`, `[Service]`, and `[Install]` sections
- JSON configs: validate with `jq` or `python3 -m json.tool`

## Pull Request Process

1. **One concern per PR.** Don't mix a bug fix with a new feature.
2. **Run `make validate`** before pushing. CI will catch failures, but catching them locally is faster.
3. **Describe what and why** in the PR body. Link to the relevant issue if one exists.
4. **Add or update tests** if you're changing build behavior.
5. **Be patient with review.** Maintainers may request changes — this is collaborative, not adversarial.

### PR Review Criteria

- Does `make validate` pass?
- Are shell scripts following the coding standards above?
- Is the change scoped appropriately?
- Are security implications considered? (Especially for changes to AppArmor profiles, vault access, or user permissions.)

## Reporting Bugs

Use the [Bug Report](https://github.com/SecureAgentOS/agentos/issues/new?template=bug_report.yml) issue template. Include:

- Host OS and version
- Hypervisor (VirtualBox, VMware, UTM, etc.)
- Steps to reproduce
- Expected vs. actual behavior
- Relevant logs (build output, journal logs, etc.)

## Security Vulnerabilities

**Do not file public issues for security vulnerabilities.** See [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
