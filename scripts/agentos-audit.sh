#!/usr/bin/env bash
#
# agentos-audit — Query and filter AgentOS audit logs
#
# Usage:
#   agentos-audit                          Show last 50 entries
#   agentos-audit --tail                   Follow log in real-time
#   agentos-audit --since "1 hour ago"     Filter by time
#   agentos-audit --type exec              Filter by event type
#   agentos-audit --key vault-access       Filter by audit key
#   agentos-audit --json                   Output raw JSON lines
#   agentos-audit --summary                Show event count summary
#
set -euo pipefail

AUDIT_LOG="/var/log/agentos/audit.log"
SYSTEM_AUDIT_LOG="/var/log/audit/audit.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────
MODE="recent"
LINES=50
FILTER_TYPE=""
FILTER_KEY=""
FILTER_SINCE=""
OUTPUT_JSON=false

# ── Parse arguments ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tail|-f)
            MODE="tail"
            shift ;;
        --since)
            FILTER_SINCE="$2"
            shift 2 ;;
        --type)
            FILTER_TYPE="$2"
            shift 2 ;;
        --key|-k)
            FILTER_KEY="$2"
            shift 2 ;;
        --lines|-n)
            LINES="$2"
            shift 2 ;;
        --json)
            OUTPUT_JSON=true
            shift ;;
        --summary)
            MODE="summary"
            shift ;;
        --help|-h)
            echo "Usage: agentos-audit [options]"
            echo ""
            echo "Options:"
            echo "  --tail, -f             Follow log in real-time"
            echo "  --since <timespec>     Show entries since time (e.g. '1 hour ago', '2024-01-15')"
            echo "  --type <type>          Filter by action type (exec, network, vault, config)"
            echo "  --key <audit-key>      Filter by audit key (e.g. agentos-exec)"
            echo "  --lines, -n <count>    Number of recent entries (default: 50)"
            echo "  --json                 Output raw JSON lines"
            echo "  --summary              Show event count summary"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

# ── Application-level audit log (JSON) ───────────────────────────

format_json_entry() {
    local line="$1"
    if $OUTPUT_JSON; then
        echo "$line"
        return
    fi

    # Parse JSON fields using shell-friendly extraction
    local ts action key status user
    ts=$(echo "$line" | grep -o '"ts":"[^"]*"' | cut -d'"' -f4)
    action=$(echo "$line" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)
    key=$(echo "$line" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
    status=$(echo "$line" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    user=$(echo "$line" | grep -o '"user":"[^"]*"' | cut -d'"' -f4)

    local status_color="$GREEN"
    [[ "$status" == "fail" || "$status" == "denied" ]] && status_color="$RED"
    [[ "$status" == "warn" ]] && status_color="$YELLOW"

    printf "${CYAN}%s${NC}  %-10s  %-24s  ${status_color}%-6s${NC}  %s\n" \
        "$ts" "$action" "$key" "$status" "$user"
}

query_app_log() {
    if [[ ! -f "$AUDIT_LOG" ]]; then
        echo "No application audit log found at ${AUDIT_LOG}"
        return
    fi

    local filter_cmd="cat"

    # Time filter
    if [[ -n "$FILTER_SINCE" ]]; then
        local since_epoch
        since_epoch=$(date -d "$FILTER_SINCE" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$FILTER_SINCE" +%s 2>/dev/null || echo "0")
        filter_cmd="awk -v since=$since_epoch '{
            match(\$0, /\"ts\":\"([^\"]+)\"/, m);
            cmd = \"date -d \" m[1] \" +%s\";
            cmd | getline epoch; close(cmd);
            if (epoch >= since) print
        }'"
    fi

    # Type filter
    if [[ -n "$FILTER_TYPE" ]]; then
        filter_cmd="${filter_cmd} | grep '\"action\":\"${FILTER_TYPE}\"'"
    fi

    # Key filter
    if [[ -n "$FILTER_KEY" ]]; then
        filter_cmd="${filter_cmd} | grep '\"key\":\"${FILTER_KEY}\"'"
    fi

    eval "${filter_cmd} < ${AUDIT_LOG}" | tail -n "$LINES" | while IFS= read -r line; do
        format_json_entry "$line"
    done
}

# ── System audit log (auditd) ────────────────────────────────────

query_system_audit() {
    if ! command -v ausearch &>/dev/null; then
        echo "(ausearch not available — install auditd for system-level audit queries)"
        return
    fi

    echo ""
    echo -e "${BOLD}System audit events (auditd):${NC}"
    echo ""

    local ausearch_args=()

    if [[ -n "$FILTER_KEY" ]]; then
        ausearch_args+=(-k "$FILTER_KEY")
    else
        ausearch_args+=(-k agentos-exec -k agentos-network -k agentos-vault-access -k agentos-priv-escalation -k agentos-docker)
    fi

    if [[ -n "$FILTER_SINCE" ]]; then
        ausearch_args+=(--start "$FILTER_SINCE")
    fi

    ausearch "${ausearch_args[@]}" 2>/dev/null | tail -n "$LINES" || echo "  (no matching system audit entries)"
}

# ── Summary mode ──────────────────────────────────────────────────

show_summary() {
    if [[ ! -f "$AUDIT_LOG" ]]; then
        echo "No audit log found."
        return
    fi

    echo -e "${BOLD}AgentOS Audit Summary${NC}"
    echo "====================="
    echo ""

    echo -e "${BOLD}Application events (by action):${NC}"
    grep -o '"action":"[^"]*"' "$AUDIT_LOG" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count action; do
        action=$(echo "$action" | cut -d'"' -f4)
        printf "  %-20s %s\n" "$action" "$count"
    done
    echo ""

    echo -e "${BOLD}Status breakdown:${NC}"
    grep -o '"status":"[^"]*"' "$AUDIT_LOG" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count status; do
        status=$(echo "$status" | cut -d'"' -f4)
        local color="$GREEN"
        [[ "$status" == "fail" || "$status" == "denied" ]] && color="$RED"
        printf "  ${color}%-12s${NC} %s\n" "$status" "$count"
    done
    echo ""

    local total
    total=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
    local failed
    failed=$(grep -c '"status":"fail"' "$AUDIT_LOG" 2>/dev/null || echo 0)
    local denied
    denied=$(grep -c '"status":"denied"' "$AUDIT_LOG" 2>/dev/null || echo 0)

    echo "Total events: ${total}"
    echo -e "Failed: ${RED}${failed}${NC}  Denied: ${RED}${denied}${NC}"

    if command -v ausearch &>/dev/null; then
        echo ""
        echo -e "${BOLD}System audit keys:${NC}"
        ausearch -k agentos-exec --raw 2>/dev/null | wc -l | xargs printf "  agentos-exec:            %s\n"
        ausearch -k agentos-network --raw 2>/dev/null | wc -l | xargs printf "  agentos-network:         %s\n"
        ausearch -k agentos-vault-access --raw 2>/dev/null | wc -l | xargs printf "  agentos-vault-access:    %s\n"
        ausearch -k agentos-priv-escalation --raw 2>/dev/null | wc -l | xargs printf "  agentos-priv-escalation: %s\n"
        ausearch -k agentos-docker --raw 2>/dev/null | wc -l | xargs printf "  agentos-docker:          %s\n"
    fi
}

# ── Main ──────────────────────────────────────────────────────────

case "$MODE" in
    tail)
        echo -e "${BOLD}Following AgentOS audit log (Ctrl+C to stop)${NC}"
        echo ""
        tail -f "$AUDIT_LOG" 2>/dev/null | while IFS= read -r line; do
            format_json_entry "$line"
        done
        ;;
    summary)
        show_summary
        ;;
    recent)
        echo -e "${BOLD}AgentOS Audit Log (last ${LINES} entries)${NC}"
        echo ""
        query_app_log
        if [[ -z "$FILTER_TYPE" ]] && ! $OUTPUT_JSON; then
            query_system_audit
        fi
        ;;
esac
