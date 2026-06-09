#!/bin/bash
# egpu-postmortem.sh — retrospective analysis of past eGPU sessions
#
# Looks across recent boots and surfaces:
#   - eGPU plug/unplug events (via NVIDIA + pciehp logs)
#   - Xid 79 / RmInitAdapter failures
#   - Phoenix x1-Gen1 bug occurrences (PCIe link "limited by 2.5 GT/s x1")
#   - shutdown-helper.sh execution and unload status
#   - unmount failures / stop-job-running messages at shutdown
#   - boot duration (very short boots can indicate cascade-then-reboot)
#   - nvidia-persistenced failures
#
# Usage:
#   ./egpu-postmortem.sh                  # summary table, last 10 boots
#   ./egpu-postmortem.sh --last N         # last N boots
#   ./egpu-postmortem.sh --boot N         # detailed view of boot -N (or 0 = current)
#   ./egpu-postmortem.sh --since EXPR     # boots whose start is after EXPR (date(1) syntax)
#   ./egpu-postmortem.sh --csv            # machine-readable output (no colors, no header art)

set -u

LAST_N=10
SPECIFIC_BOOT=""
SINCE=""
CSV=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)  LAST_N="$2"; shift 2 ;;
        --boot)  SPECIFIC_BOOT="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --csv)   CSV=true; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ANSI colors (skipped if non-tty or CSV)
if [[ -t 1 ]] && ! $CSV; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; D=""; B=""; N=""
fi

# ---------- data helpers ----------

count_kernel() {
    # count_kernel <boot-idx> <ERE-pattern>
    local boot="$1" pattern="$2"
    journalctl -k -b "$boot" --no-pager 2>/dev/null | grep -cE "$pattern" || true
}

count_unit() {
    # count_unit <boot-idx> <ERE-pattern>
    local boot="$1" pattern="$2"
    journalctl -b "$boot" --no-pager 2>/dev/null | grep -cE "$pattern" || true
}

boot_start_epoch() {
    # boot_start_epoch <boot-idx>  → unix epoch of boot start
    local boot="$1"
    # --list-boots output:  -1 <id> <day> <date> <time> <tz> <day> <date> <time> <tz>
    journalctl --list-boots --no-pager 2>/dev/null \
      | awk -v b="$boot" '$1 == b { print $4" "$5" "$6 }' \
      | xargs -I{} date -d "{}" +%s 2>/dev/null
}

boot_end_epoch() {
    local boot="$1"
    journalctl --list-boots --no-pager 2>/dev/null \
      | awk -v b="$boot" '$1 == b { print $8" "$9" "$10 }' \
      | xargs -I{} date -d "{}" +%s 2>/dev/null
}

human_duration() {
    local sec="$1"
    if [[ -z "$sec" || "$sec" -lt 0 ]]; then echo "?"; return; fi
    local h=$((sec/3600)) m=$(((sec%3600)/60)) s=$((sec%60))
    if (( h > 0 )); then printf "%dh%02dm" "$h" "$m"
    elif (( m > 0 )); then printf "%dm%02ds" "$m" "$s"
    else printf "%ds" "$s"; fi
}

# ---------- per-boot analysis ----------

# Returns a tab-separated row: plugs unplugs xids rminit phoenix shutdown_ok unmount_fails persist_fails
analyze_boot() {
    local boot="$1"

    # Each eGPU plug yields a single "nvidia 0000:XX:00.0: enabling device" line.
    local plugs;  plugs=$(count_kernel "$boot" 'nvidia 0000:[0-9a-f]+:[0-9a-f]+\.0: enabling device')
    # Each surprise hot-unplug fires a pciehp Slot Link Down.
    local unplugs; unplugs=$(count_kernel "$boot" 'pciehp.*Slot.*Link Down')
    local xids;    xids=$(count_kernel "$boot" 'NVRM: Xid')
    local rminit;  rminit=$(count_kernel "$boot" 'RmInitAdapter failed|Cannot attach gpu')
    # Each fresh enum on Phoenix x1-Gen1 prints "limited by 2.5 GT/s PCIe x1".
    local phoenix; phoenix=$(count_kernel "$boot" 'limited by 2\.5 GT/s PCIe x1')

    # Shutdown helper success = "shutdown-helper.sh done" syslog message.
    local shutdown_ok; shutdown_ok=$(count_unit "$boot" 'nvidia-egpu-shutdown.*shutdown-helper\.sh done')

    local unmount_fails; unmount_fails=$(count_unit "$boot" 'Failed unmounting|A stop job is running')

    # nvidia-persistenced fail patterns. The drop-in skip ("Triggering condition failed")
    # is normal, not counted.
    local persist_fails; persist_fails=$(count_unit "$boot" \
        'nvidia-persistenced.*Start request repeated too quickly|nvidia-persistenced.*Failed to query NVIDIA devices')

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${plugs:-0}" "${unplugs:-0}" "${xids:-0}" "${rminit:-0}" \
        "${phoenix:-0}" "${shutdown_ok:-0}" "${unmount_fails:-0}" "${persist_fails:-0}"
}

# Verdict color: red if Xid/RmInit/unmount, yellow if Phoenix or persistenced fails, green clean
row_color() {
    local xids="$1" rminit="$2" phoenix="$3" unmount="$4" persist="$5" duration="$6"
    if (( xids > 0 || rminit > 0 || unmount > 0 )); then echo "$R"
    elif (( phoenix > 0 || persist > 0 )); then echo "$Y"
    elif [[ -n "$duration" && "$duration" -gt 0 && "$duration" -lt 120 ]]; then echo "$Y"  # very short boot
    else echo "$G"; fi
}

# ---------- summary mode ----------

print_summary() {
    local boots=()

    if [[ -n "$SINCE" ]]; then
        local since_epoch
        since_epoch=$(date -d "$SINCE" +%s 2>/dev/null) || { echo "Bad --since: $SINCE" >&2; exit 1; }
        while read -r line; do
            local idx start_epoch
            idx=$(echo "$line" | awk '{print $1}')
            start_epoch=$(boot_start_epoch "$idx")
            if [[ -n "$start_epoch" && "$start_epoch" -ge "$since_epoch" ]]; then
                boots+=("$idx")
            fi
        done < <(journalctl --list-boots --no-pager 2>/dev/null)
    else
        while read -r line; do
            boots+=("$(echo "$line" | awk '{print $1}')")
        done < <(journalctl --list-boots --no-pager 2>/dev/null | tail -n "$LAST_N")
    fi

    if (( ${#boots[@]} == 0 )); then
        echo "No boots match the filter." >&2
        exit 0
    fi

    $CSV || printf "${B}eGPU postmortem — %d boot(s)${N}\n\n" "${#boots[@]}"

    if $CSV; then
        echo "boot,started,duration_s,plug,unplug,xid,rminit,phoenix,shutdown_ok,unmount_fails,persist_fails"
    else
        printf "${B}%-5s %-19s %-9s | %-4s %-4s | %-3s %-6s %-3s | %-6s %-5s %-7s${N}\n" \
            "Boot" "Started" "Duration" "Plug" "Unpl" "Xid" "RmInit" "Phx" "ShutOK" "Unmnt" "PersFl"
        printf "${D}%-5s %-19s %-9s   %-4s %-4s   %-3s %-6s %-3s   %-6s %-5s %-7s${N}\n" \
            "----" "-------------------" "---------" "----" "----" "---" "------" "---" "------" "-----" "-------"
    fi

    local idx
    for idx in "${boots[@]}"; do
        local start_epoch end_epoch duration_s start_str
        start_epoch=$(boot_start_epoch "$idx")
        end_epoch=$(boot_end_epoch "$idx")
        if [[ -n "$start_epoch" && -n "$end_epoch" ]]; then
            duration_s=$((end_epoch - start_epoch))
        else
            duration_s=""
        fi
        start_str=$(date -d "@${start_epoch:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

        local row plugs unplugs xids rminit phoenix shutdown_ok unmount_fails persist_fails
        row=$(analyze_boot "$idx")
        IFS=$'\t' read -r plugs unplugs xids rminit phoenix shutdown_ok unmount_fails persist_fails <<<"$row"

        if $CSV; then
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                "$idx" "$start_str" "${duration_s:-}" \
                "$plugs" "$unplugs" "$xids" "$rminit" "$phoenix" \
                "$shutdown_ok" "$unmount_fails" "$persist_fails"
        else
            local color
            color=$(row_color "$xids" "$rminit" "$phoenix" "$unmount_fails" "$persist_fails" "$duration_s")
            printf "${color}%-5s %-19s %-9s | %-4s %-4s | %-3s %-6s %-3s | %-6s %-5s %-7s${N}\n" \
                "$idx" "$start_str" "$(human_duration "${duration_s:-0}")" \
                "$plugs" "$unplugs" "$xids" "$rminit" "$phoenix" \
                "$shutdown_ok" "$unmount_fails" "$persist_fails"
        fi
    done

    $CSV && return
    echo ""
    cat <<EOF
${D}Legend:${N}
  Plug/Unpl    eGPU PCI enable / pciehp link-down events
  Xid          NVRM Xid events (typically 79 on eGPU)
  RmInit       RmInitAdapter / 'Cannot attach gpu' silent failures
  Phx          PCIe link negotiated to 2.5 GT/s × 1 (AMD Phoenix bug fired)
  ShutOK       shutdown-helper.sh ran to completion that boot
  Unmnt        'Failed unmounting' / 'A stop job is running' messages
  PersFl       nvidia-persistenced failures (rate-limit, query failures)

${D}Colors:${N}
  ${G}green${N}    clean session
  ${Y}yellow${N}   Phoenix bug fired, or persistenced failed, or very short boot
  ${R}red${N}      Xid / RmInit / unmount failure → driver / shutdown issue

For details on a specific boot:  $0 --boot <idx>
EOF
}

# ---------- detail mode ----------

print_detail() {
    local boot="$1"

    local start_epoch end_epoch duration_s
    start_epoch=$(boot_start_epoch "$boot")
    end_epoch=$(boot_end_epoch "$boot")
    [[ -n "$start_epoch" && -n "$end_epoch" ]] && duration_s=$((end_epoch - start_epoch)) || duration_s=""

    printf "${B}== Boot %s — %s (%s) ==${N}\n\n" \
        "$boot" \
        "$(date -d "@${start_epoch:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
        "$(human_duration "${duration_s:-0}")"

    show_section() {
        local title="$1" pattern="$2" kernel_only="${3:-false}"
        local cmd_args
        if $kernel_only; then cmd_args=(-k); else cmd_args=(); fi
        local out
        out=$(journalctl "${cmd_args[@]}" -b "$boot" --no-pager 2>/dev/null \
              | grep -E "$pattern" || true)
        if [[ -n "$out" ]]; then
            printf "${B}${title}${N}\n%s\n\n" "$out"
        fi
    }

    show_section "Thunderbolt / eGPU enumeration" \
        'thunderbolt [0-9]-.*Razer|thunderbolt [0-9]-.*Core X|pciehp.*Slot.*Link Up|pciehp.*Slot.*Link Down|limited by .* PCIe x1|available PCIe bandwidth' \
        true

    show_section "NVIDIA driver lifecycle" \
        'nvidia [0-9a-f]+:.*enabling device|NVRM: loading|NVRM: Xid|RmInitAdapter failed|Cannot attach gpu|nvidia 0000:.*remove' \
        true

    show_section "nvidia-persistenced" \
        'nvidia-persistenced'

    show_section "Shutdown helper (nvidia-egpu-shutdown)" \
        'nvidia-egpu-shutdown'

    show_section "Shutdown failures" \
        'Failed unmounting|A stop job is running|Failed to unmount|systemd-shutdown.*Sending SIGTERM'

    show_section "Other notable kernel events" \
        'amdgpu.*reset|amdgpu.*hang|hardlockup|softlockup|---\[ cut here|BUG:|WARNING:' \
        true
}

# ---------- entry ----------

if [[ -n "$SPECIFIC_BOOT" ]]; then
    print_detail "$SPECIFIC_BOOT"
else
    print_summary
fi
