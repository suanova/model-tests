#!/usr/bin/env bash
# run_all_api_tests.sh [rounds] [--responses]
#
# Runs the Chat Completions API and Anthropic Messages API tests for every
# suitable model, across multiple rounds. The OpenAI Responses API is NOT
# included by default (most models don't support it) — pass --responses to
# add it. A model counts as "supporting" an API if it passes at least once
# across all rounds.
#
# Usage:
#   bash run_all_api_tests.sh              # default: 1 round, chat + messages
#   bash run_all_api_tests.sh 3            # 3 rounds, chat + messages
#   bash run_all_api_tests.sh --responses  # 1 round, chat + messages + responses
#   bash run_all_api_tests.sh 3 --responses
#   TEST_TIMEOUT=60 bash run_all_api_tests.sh 2 --responses
#
# Respects whitelist.txt if present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

# ── Parse arguments ──────────────────────────────────────────────────
ROUNDS=1
INCLUDE_RESPONSES=0
for arg in "$@"; do
    if [ "$arg" = "--responses" ]; then
        INCLUDE_RESPONSES=1
    elif [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -ge 1 ]; then
        ROUNDS="$arg"
    else
        log_fail "Invalid argument: '${arg}' (expected a positive integer or --responses)"
        exit 1
    fi
done

if [ "${INCLUDE_RESPONSES}" -eq 1 ]; then
    log_info "Combined API tests — ${ROUNDS} round(s) per model, per API (including Responses API)"
else
    log_info "Combined API tests — ${ROUNDS} round(s) per model, per API (Chat + Messages only; pass --responses to add Responses API)"
fi
echo ""

# ── Fetch and filter models ──────────────────────────────────────────
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
RESULTS_FILE="$(mktemp)"

MODEL_IDX=0
for model in ${MODELS}; do
    MODEL_IDX=$((MODEL_IDX + 1))
    echo -e "${BOLD}[model ${MODEL_IDX}/${TOTAL_MODELS}] ${model}${NC}" >&2

    CHAT_PASSES=0
    MSG_PASSES=0
    RESP_PASSES=0

    for round in $(seq 1 "${ROUNDS}"); do
        # ── Chat completions API ──────────────────────────────────────
        CHAT_LINE_FILE="$(mktemp)"
        QUIET=1 bash "${SCRIPT_DIR}/chat_api_single.sh" "${model}" > "${CHAT_LINE_FILE}" 2>/dev/null || true
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
        QUIET=1 bash "${SCRIPT_DIR}/messages_api_single.sh" "${model}" > "${MSG_LINE_FILE}" 2>/dev/null || true
        MSG_LINE="$(grep -E '^(PASS|FAIL)\|' "${MSG_LINE_FILE}" | tail -1)"
        rm -f "${MSG_LINE_FILE}"
        if echo "${MSG_LINE}" | grep -q "^PASS|"; then
            MSG_PASSES=$((MSG_PASSES + 1))
            printf "  API [Messages API]     - round %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
        else
            MSG_ERR="$(printf '%s' "${MSG_LINE}" | cut -d'|' -f3-)"
            printf "  API [Messages API]     - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${MSG_ERR}" >&2
        fi

        # ── OpenAI Responses API (opt-in) ─────────────────────────────
        if [ "${INCLUDE_RESPONSES}" -eq 1 ]; then
            RESP_LINE_FILE="$(mktemp)"
            QUIET=1 bash "${SCRIPT_DIR}/responses_api_single.sh" "${model}" > "${RESP_LINE_FILE}" 2>/dev/null || true
            RESP_LINE="$(grep -E '^(PASS|FAIL)\|' "${RESP_LINE_FILE}" | tail -1)"
            rm -f "${RESP_LINE_FILE}"
            if echo "${RESP_LINE}" | grep -q "^PASS|"; then
                RESP_PASSES=$((RESP_PASSES + 1))
                printf "  API [Responses API]    - round %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
            else
                RESP_ERR="$(printf '%s' "${RESP_LINE}" | cut -d'|' -f3-)"
                printf "  API [Responses API]    - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${RESP_ERR}" >&2
            fi
        fi
    done

    echo "${model}|${CHAT_PASSES}|${ROUNDS}|${MSG_PASSES}|${ROUNDS}|${RESP_PASSES}|${ROUNDS}" >> "${RESULTS_FILE}"
    echo "" >&2
done

# ── Output combined summary table ────────────────────────────────────
echo -e "${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
if [ "${INCLUDE_RESPONSES}" -eq 1 ]; then
    echo -e "${BOLD}  Combined API Test Results (${ROUNDS} round(s), including Responses API)${NC}"
else
    echo -e "${BOLD}  Combined API Test Results (${ROUNDS} round(s))${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

python3 - "${RESULTS_FILE}" "${ROUNDS}" "${INCLUDE_RESPONSES}" "${TOTAL_MODELS_FETCHED}" "${TOTAL_MODELS_IGNORED}" <<'PYEOF'
import sys

GREEN = '\033[32m'
RED = '\033[31m'
BOLD = '\033[1m'
NC = '\033[0m'

results_file = sys.argv[1]
rounds = sys.argv[2]
include_responses = sys.argv[3] == '1'
fetched = sys.argv[4] if len(sys.argv) > 4 else ''
ignored = sys.argv[5] if len(sys.argv) > 5 else ''

with open(results_file) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]

if include_responses:
    header = f"{BOLD}{'#':<4} {'Model':<40} {'Chat Completions':<20} {'Messages API':<20} {'Responses API':<20}{NC}"
    sep_width = 104
else:
    header = f"{BOLD}{'#':<4} {'Model':<40} {'Chat Completions':<20} {'Messages API':<20}{NC}"
    sep_width = 86

print(header)
print("-" * sep_width)

chat_supported = 0
msg_supported = 0
resp_supported = 0

for idx, line in enumerate(lines, 1):
    parts = line.split('|')
    model = parts[0] if len(parts) > 0 else '?'
    chat_passes = parts[1] if len(parts) > 1 else '0'
    chat_rounds = parts[2] if len(parts) > 2 else rounds
    msg_passes = parts[3] if len(parts) > 3 else '0'
    msg_rounds = parts[4] if len(parts) > 4 else rounds
    resp_passes = parts[5] if len(parts) > 5 else '0'
    resp_rounds = parts[6] if len(parts) > 6 else rounds

    chat_ok = int(chat_passes) > 0
    msg_ok = int(msg_passes) > 0
    resp_ok = int(resp_passes) > 0
    if chat_ok:
        chat_supported += 1
    if msg_ok:
        msg_supported += 1
    if resp_ok:
        resp_supported += 1

    chat_str = f'{chat_passes}/{chat_rounds}  {"✓" if chat_ok else "✗"}'
    msg_str = f'{msg_passes}/{msg_rounds}  {"✓" if msg_ok else "✗"}'
    resp_str = f'{resp_passes}/{resp_rounds}  {"✓" if resp_ok else "✗"}'
    chat_color = GREEN if chat_ok else RED
    msg_color = GREEN if msg_ok else RED
    resp_color = GREEN if resp_ok else RED

    if include_responses:
        print(f"{idx:<4} {model:<40} {chat_color}{chat_str:<20}{NC} {msg_color}{msg_str:<20}{NC} {resp_color}{resp_str:<20}{NC}")
    else:
        print(f"{idx:<4} {model:<40} {chat_color}{chat_str:<20}{NC} {msg_color}{msg_str:<20}{NC}")

print("-" * sep_width)
total = len(lines)
prefix = f"{fetched} fetched, {ignored} ignored, {total} tested — " if fetched and ignored else ""
if include_responses:
    print(f"\n  {BOLD}Summary ({rounds} round(s) per API): {prefix}{chat_supported}/{total} support Chat Completions, {msg_supported}/{total} support Messages API, {resp_supported}/{total} support Responses API{NC}")
    print(f"  All three APIs:         {sum(1 for l in lines if int(l.split('|')[1]) > 0 and int(l.split('|')[3]) > 0 and int(l.split('|')[5]) > 0)}/{total} models")
else:
    print(f"\n  {BOLD}Summary ({rounds} round(s) per API): {prefix}{chat_supported}/{total} support Chat Completions, {msg_supported}/{total} support Messages API{NC}")
    print(f"  Both APIs:              {sum(1 for l in lines if int(l.split('|')[1]) > 0 and int(l.split('|')[3]) > 0)}/{total} models")
    print(f"  Tip: pass --responses to include the OpenAI Responses API (/v1/responses)")
PYEOF

echo ""

rm -f "${RESULTS_FILE}"
exit 0
