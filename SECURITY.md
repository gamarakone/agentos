# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest `main` | ✅ |
| Older releases | ❌ |

## Reporting a Vulnerability

**Please do not file public GitHub issues for security vulnerabilities.**

To report a vulnerability, email the maintainers directly or use [GitHub's private vulnerability reporting](https://github.com/SecureAgentOS/agentos/security/advisories/new).

Include:
- A description of the vulnerability and its potential impact
- Steps to reproduce
- Any suggested fixes or mitigations

You can expect an acknowledgement within 48 hours and a resolution plan within 7 days. We will credit you in the release notes unless you prefer to remain anonymous.

## Security Model

AgentOS is built with security as a first principle. Key protections include:

- **User isolation**: The `agentos` system account (UID 1100) runs agent processes without root
- **AppArmor profiles**: Restrict what files and syscalls the agent process can access
- **Credential vault**: API keys stored in `/etc/agentos/vault/` and accessed only via a Unix socket broker, never directly by the agent
- **Audit logging**: All agent actions logged to `/var/log/agentos/audit.log`
- **Docker sandboxing**: Shell-access skills run in isolated containers

If you find a bypass of any of these controls, please report it privately.
