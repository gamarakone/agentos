#!/usr/bin/env bash
#
# AgentOS VM Image Builder
# Builds a complete VM image from an Ubuntu 24.04 base
#
# Usage: sudo ./build-vm.sh [--lite|--server] [--output-format ova|qcow2|both]
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
AGENTOS_VERSION="0.1.0-alpha"
UBUNTU_RELEASE="noble"
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu/"
ARCH="amd64"

BUILD_DIR="${BUILD_DIR:-/tmp/agentos-build}"
ROOTFS="${BUILD_DIR}/rootfs"
OUTPUT_DIR="${BUILD_DIR}/output"

EDITION="${1:---lite}"  # --lite or --server
OUTPUT_FORMAT="${2:-both}"  # ova, qcow2, or both

DISK_SIZE="20G"
if [[ "$EDITION" == "--server" ]]; then
    VM_NAME="agentos-server"
else
    VM_NAME="agentos-lite"
fi
VM_RAM="4096"
VM_CPUS="2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Colors ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[AgentOS]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
err()  { echo -e "${RED}[ERROR ]${NC} $*" >&2; }

# ── Preflight checks ──────────────────────────────────────────────
preflight() {
    log "Running preflight checks..."

    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo ./build-vm.sh)"
        exit 1
    fi

    local required_tools=(debootstrap chroot mount qemu-img)
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            err "Missing required tool: $tool"
            err "Install with: sudo apt install debootstrap qemu-utils"
            exit 1
        fi
    done

    local free_space
    free_space=$(df --output=avail /tmp | tail -1)
    if (( free_space < 20000000 )); then
        err "Need at least 20GB free in /tmp (or set BUILD_DIR)"
        exit 1
    fi

    ok "Preflight checks passed"
}

# ── Cleanup handler ────────────────────────────────────────────────
cleanup() {
    log "Cleaning up mount points..."
    for mp in "${ROOTFS}/dev/pts" "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/run"; do
        mountpoint -q "$mp" 2>/dev/null && umount -lf "$mp" || true
    done
    log "Cleanup complete. Build artifacts remain in ${BUILD_DIR}"
}
trap cleanup EXIT

# ── Phase execution ────────────────────────────────────────────────
run_phase() {
    local phase_num="$1"
    local phase_name="$2"
    local script="${SCRIPT_DIR}/${phase_num}-${phase_name}.sh"

    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Phase ${phase_num}: ${phase_name}"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ! -f "$script" ]]; then
        err "Phase script not found: $script"
        exit 1
    fi

    # Export vars so phase scripts can access them
    export AGENTOS_VERSION UBUNTU_RELEASE UBUNTU_MIRROR ARCH
    export BUILD_DIR ROOTFS OUTPUT_DIR
    export EDITION SCRIPT_DIR PROJECT_ROOT
    export DISK_SIZE VM_NAME VM_RAM VM_CPUS

    bash "$script"
    ok "Phase ${phase_num} complete"
}

# ── Main ───────────────────────────────────────────────────────────
main() {
    echo ""
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║         AgentOS VM Image Builder          ║"
    echo "  ║         v${AGENTOS_VERSION}                       ║"
    printf "  ║         Edition: %-25s║\n" "${EDITION}  "
    echo "  ╚═══════════════════════════════════════════╝"
    echo ""

    preflight

    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

    run_phase "01" "bootstrap"
    run_phase "02" "install-deps"
    run_phase "03" "configure"

    if [[ "$EDITION" == "--lite" ]]; then
        run_phase "04" "desktop"
    fi

    run_phase "05" "wizard"

    # Run smoke tests before packaging
    log "Running smoke tests on rootfs..."
    bash "${SCRIPT_DIR}/smoke-test.sh" "${ROOTFS}"

    run_phase "06" "package"

    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Build complete!"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    ok "Output: ${OUTPUT_DIR}/"
    ls -lh "${OUTPUT_DIR}/"
    echo ""
    log "Import with: VBoxManage import ${OUTPUT_DIR}/${VM_NAME}.ova"
    log "Or use QCOW2: qemu-system-x86_64 -hda ${OUTPUT_DIR}/${VM_NAME}.qcow2 -m ${VM_RAM}"
}

main "$@"
