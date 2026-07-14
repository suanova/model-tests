#!/usr/bin/env bash
# run_all_api_tests.sh [rounds]
#
# Runs both the Chat Completions API and the Anthropic Messages API tests for
# every suitable model, across multiple rounds. A model counts as "supporting"
# an API if it passes at least once across all rounds.
#
# Usage:
#   bash run_all_api_tests.sh          # default 1 round
#   bash run_all_api_tests.sh 3        # 3 rounds
#   TEST_TIMEOUT=60 bash run_all_api_tests.sh 2
#
# Output: a combined table with per-model, per-API pass counts (X/Y) and a
# support indicator, plus a summary of how many models support each API.
#
# Respects whitelist.txt if present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

# Number of rounds (default 1)
ROUNDS="${1:-1}"
if ! [[ "${ROUNDS}" =~ ^[0-9]+$ ]] || [ "${ROUNDS}" -lt 1 ]; then
    log_fail "Invalid rounds argument: '${ROUNDS}' (must be a positive integer)"
    exit 1
fi

log_info "Combined API tests — ${ROUNDS} round(s) per model, per API"
echo ""

# ── Fetch and filter models ──────────────────────────────────────────
# list_chat_models prints kept model IDs to stdout (one per line) and logs
# skipped/not-found models to stderr. Exits on failure.
MODELS_FILE="$(mktemp)"
list_chat_models > "${MODELS_FILE}"
MODELS="$(cat "${MODELS_FILE}")"
rm -f "${MODELS_FILE}"

if [ -z "${MODELS}" ]; then
    log_fail "No models to test"
    exit 1
fi

TOTAL_MODELS="$(echo "${MODELS}" | wc -l)"
echo ""

# ── Run tests: for each model, N rounds of each API ──────────────────
# Results file format: model|chat_passes|chat_rounds|msg_passes|msg_rounds
RESULTS_FILE="$(mktemp)"

MODEL_IDX=0
for model in ${MODELS}; do
    MODEL_IDX=$((MODEL_IDX + 1))
    echo -e "${BOLD}[model ${MODEL_IDX}/${TOTAL_MODELS}] ${model}${NC}" >&2

    CHAT_PASSES=0
    MSG_PASSES=0

    for round in $(seq 1 "${ROUNDS}"); do
        # ── Chat completions API ──────────────────────────────────────
        CHAT_LINE_FILE="$(mktemp)"
        bash "${SCRIPT_DIR}/chat_api_single.sh" "${model}" > "${CHAT_LINE_FILE}" 2>/dev/null || true
        CHAT_LINE="$(grep -E '^(PASS|FAIL)\|' "${CHAT_LINE_FILE}" | tail -1)"
        rm -f "${CHAT_LINE_FILE}"
        if echo "${CHAT_LINE}" | grep -q "^PASS|"; then
            CHAT_PASSES=$((CHAT_PASSES + 1))
            printf "  API [Chat Completions] - round %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
        else
            CHAT_ERR="$(printf '%s' "${CHAT_LINE}" | cut -d'|' -f3-)"
            printf "  API [Chat Completions] - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${CHAT_ERR}" >&2
        fi

        # ── Anthropic Messages API ────────────────────────────────────
        MSG_LINE_FILE="$(mktemp)"
        bash "${SCRIPT_DIR}/messages_api_single.sh" "${model}" > "${MSG_LINE_FILE}" 2>/dev/null || true
        MSG_LINE="$(grep -E '^(PASS|FAIL)\|' "${MSG_LINE_FILE}" | tail -1)"
        rm -f "${MSG_LINE_FILE}"
        if echo "${MSG_LINE}" | grep -q "^PASS|"; then
            MSG_PASSES=$((MSG_PASSES + 1))
            printf "  API [Messages API]     - round %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
        else
            MSG_ERR="$(printf '%s' "${MSG_LINE}" | cut -d'|' -f3-)"
            printf "  API [Messages API]     - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${MSG_ERR}" >&2
        fi
    done

    echo "${model}|${CHAT_PASSES}|${ROUNDS}|${MSG_PASSES}|${ROUNDS}" >> "${RESULTS_FILE}"
    echo "" >&2
done

# ── Output combined summary table ────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Combined API Test Results (${ROUNDS} round(s))${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

python3 - "${RESULTS_FILE}" "${ROUNDS}" <<'PYEOF'
import sys

GREEN = '\033[32m'
RED = '\033[31m'
BOLD = '\033[1m'
NC = '\033[0m'

results_file = sys.argv[1]
rounds = sys.argv[2]

with open(results_file) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]

# Column widths
# # | Model (40) | Chat Completions (18) | Messages API (18)
header = f"{BOLD}{'#':<4} {'Model':<40} {'Chat Completions':<20} {'Messages API':<20}{NC}"
print(header)
print("-" * 86)

chat_supported = 0
msg_supported = 0

for idx, line in enumerate(lines, 1):
    parts = line.split('|')
    model = parts[0] if len(parts) > 0 else '?'
    chat_passes = parts[1] if len(parts) > 1 else '0'
    chat_rounds = parts[2] if len(parts) > 2 else rounds
    msg_passes = parts[3] if len(parts) > 3 else '0'
    msg_rounds = parts[4] if len(parts) > 4 else rounds

    # Support = passed at least once across all rounds
    chat_ok = int(chat_passes) > 0
    msg_ok = int(msg_passes) > 0
    if chat_ok:
        chat_supported += 1
    if msg_ok:
        msg_supported += 1

    chat_str = f'{chat_passes}/{chat_rounds}  {"✓" if chat_ok else "✗"}'
    msg_str = f'{msg_passes}/{msg_rounds}  {"✓" if msg_ok else "✗"}'
    chat_color = GREEN if chat_ok else RED
    msg_color = GREEN if msg_ok else RED

    print(f"{idx:<4} {model:<40} {chat_color}{chat_str:<20}{NC} {msg_color}{msg_str:<20}{NC}")

print("-" * 86)
total = len(lines)
print(f"\n  {BOLD}Summary ({rounds} round(s) per API):{NC}")
print(f"  Chat Completions API: {chat_supported}/{total} models support it (passed >= 1 round)")
print(f"  Anthropic Messages API: {msg_supported}/{total} models support it (passed >= 1 round)")
print(f"  Both APIs:              {sum(1 for l in lines if int(l.split('|')[1]) > 0 and int(l.split('|')[3]) > 0)}/{total} models")
PYEOF

echo ""

rm -f "${RESULTS_FILE}"
exit 0
