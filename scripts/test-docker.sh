#!/usr/bin/env bash
#
# Test AgentOS build inside a Docker container
# Runs on any host with Docker (macOS, Linux, CI)
#
# Usage: ./scripts/test-docker.sh [--phases 01,02,03] [--skip-desktop] [--shell]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────
PHASES="01,02,03,05"
SKIP_DESKTOP=true
OPEN_SHELL=false
CONTAINER_NAME="agentos-build-test"
IMAGE_NAME="agentos-builder:test"

# ── Parse arguments ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phases)     PHASES="$2"; shift 2 ;;
        --with-desktop) SKIP_DESKTOP=false; PHASES="01,02,03,04,05"; shift ;;
        --shell)      OPEN_SHELL=true; shift ;;
        --clean)
            echo "Cleaning up test containers and images..."
            docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
            docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
            echo "Done."
            exit 0
            ;;
        --help|-h)
            echo "Usage: test-docker.sh [options]"
            echo ""
            echo "Options:"
            echo "  --phases 01,02,03   Comma-separated phases to run (default: 01,02,03,05)"
            echo "  --with-desktop      Include phase 04 (GNOME desktop — slow)"
            echo "  --shell             Drop into a shell after build for inspection"
            echo "  --clean             Remove test containers and images"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Preflight ─────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker is required but not installed.${NC}"
    echo "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo -e "${RED}Docker daemon is not running. Start Docker Desktop first.${NC}"
    exit 1
fi

echo -e "${BLUE}AgentOS Docker Build Test${NC}"
echo "========================="
echo -e "Phases: ${GREEN}${PHASES}${NC}"
echo -e "Desktop: $(${SKIP_DESKTOP} && echo "${YELLOW}skipped${NC}" || echo "${GREEN}included${NC}")"
echo ""

# ── Clean up previous run ─────────────────────────────────────────
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# ── Build the test Dockerfile ─────────────────────────────────────
echo -e "${BLUE}Building test container...${NC}"

DOCKERFILE=$(mktemp)
cat > "$DOCKERFILE" <<'DOCKER'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8

# Install build dependencies
RUN apt-get update && apt-get install -y \
    debootstrap \
    qemu-utils \
    parted \
    rsync \
    dosfstools \
    grub-pc-bin \
    squashfs-tools \
    systemd \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /agentos
DOCKER

docker build -t "$IMAGE_NAME" -f "$DOCKERFILE" . >/dev/null 2>&1
rm -f "$DOCKERFILE"

echo -e "${GREEN}Container image built${NC}"
echo ""

# ── Build the test script that runs inside the container ──────────
TEST_SCRIPT=$(mktemp)
cat > "$TEST_SCRIPT" <<INNERSCRIPT
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

export AGENTOS_VERSION="0.1.0-alpha"
export UBUNTU_RELEASE="noble"
export UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu/"
export ARCH="amd64"
export BUILD_DIR="/tmp/agentos-build"
export ROOTFS="\${BUILD_DIR}/rootfs"
export OUTPUT_DIR="\${BUILD_DIR}/output"
export EDITION="--lite"
export SCRIPT_DIR="/agentos/scripts"
export PROJECT_ROOT="/agentos"
export DISK_SIZE="20G"
export VM_NAME="agentos-lite"
export VM_RAM="4096"
export VM_CPUS="2"

mkdir -p "\$BUILD_DIR" "\$OUTPUT_DIR"

# Source the logging helpers from build-vm.sh
log()  { echo -e "\${BLUE}[AgentOS]\${NC} \$*"; }
ok()   { echo -e "\${GREEN}[  OK  ]\${NC} \$*"; }
warn() { echo -e "\${YELLOW}[ WARN ]\${NC} \$*"; }
err()  { echo -e "\${RED}[ERROR ]\${NC} \$*" >&2; }

export -f log ok warn err

PHASES="${PHASES}"
ERRORS=0

# ── Run validation first ──────────────────────────────────────────
echo ""
log "Running pre-build validation..."
bash /agentos/scripts/validate.sh || { err "Validation failed"; exit 1; }
echo ""

# ── Run selected phases ──────────────────────────────────────────
IFS=',' read -ra PHASE_LIST <<< "\$PHASES"

for phase_num in "\${PHASE_LIST[@]}"; do
    phase_num=\$(echo "\$phase_num" | tr -d ' ')

    # Map phase number to script name
    case "\$phase_num" in
        01) script="01-bootstrap.sh" ;;
        02) script="02-install-deps.sh" ;;
        03) script="03-configure.sh" ;;
        04) script="04-desktop.sh" ;;
        05) script="05-wizard.sh" ;;
        06) script="06-package.sh" ;;
        *)  err "Unknown phase: \$phase_num"; continue ;;
    esac

    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Phase \${phase_num}: \${script}"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if bash "/agentos/scripts/\${script}"; then
        ok "Phase \${phase_num} complete"
    else
        err "Phase \${phase_num} FAILED"
        ERRORS=\$((ERRORS + 1))
    fi
done

# ── Run smoke test ────────────────────────────────────────────────
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Smoke Test"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
bash /agentos/scripts/smoke-test.sh "\${ROOTFS}" || ERRORS=\$((ERRORS + 1))

# ── Summary ───────────────────────────────────────────────────────
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ \$ERRORS -gt 0 ]]; then
    err "BUILD TEST FAILED (\${ERRORS} error(s))"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
else
    ok "BUILD TEST PASSED"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Show rootfs size
    echo ""
    log "Rootfs size: \$(du -sh "\${ROOTFS}" | cut -f1)"
    log "Key paths:"
    for p in /usr/bin/node /etc/agentos/vault /home/agentos/.openclaw/openclaw.json \
             /opt/agentos/bin/agentos-vault /etc/apparmor.d/agentos-openclaw \
             /usr/share/plymouth/themes/agentos; do
        if [[ -e "\${ROOTFS}\${p}" ]]; then
            echo -e "  \${GREEN}exists\${NC}  \${p}"
        else
            echo -e "  \${YELLOW}absent\${NC}  \${p}"
        fi
    done
fi
INNERSCRIPT

# ── Run the test ──────────────────────────────────────────────────
echo -e "${BLUE}Starting build test...${NC}"
echo ""

DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    --privileged
    -v "${PROJECT_ROOT}:/agentos:ro"
    -v "$TEST_SCRIPT:/run-test.sh:ro"
    -e DEBIAN_FRONTEND=noninteractive
)

if $OPEN_SHELL; then
    # Run build then drop to shell
    docker run -it "${DOCKER_ARGS[@]}" "$IMAGE_NAME" \
        bash -c "bash /run-test.sh; echo ''; echo 'Dropping to shell — rootfs at /tmp/agentos-build/rootfs'; exec bash"
    EXIT_CODE=$?
else
    docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" bash /run-test.sh
    EXIT_CODE=$?
fi

rm -f "$TEST_SCRIPT"

# ── Cleanup container ─────────────────────────────────────────────
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "${GREEN}Build test passed!${NC}"
else
    echo -e "${RED}Build test failed (exit code: ${EXIT_CODE})${NC}"
fi

exit $EXIT_CODE
