#!/usr/bin/env bash
# run_all_api_tests.sh [rounds]
#
# Runs the Chat Completions API, Anthropic Messages API, and OpenAI Responses
# API tests for every suitable model, across multiple rounds. A model counts
# as "supporting" an API if it passes at least once across all rounds.
#
# Usage:
#   bash run_all_api_tests.sh              # default: 1 round, all three APIs
#   bash run_all_api_tests.sh 3            # 3 rounds, all three APIs
#   TEST_TIMEOUT=60 bash run_all_api_tests.sh 2
#
# Respects whitelist.txt if present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

# ── Parse arguments ──────────────────────────────────────────────────
ROUNDS=1
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -ge 1 ]; then
        ROUNDS="$arg"
    else
        log_fail "Invalid argument: '${arg}' (expected a positive integer)"
        exit 1
    fi
done

log_info "Combined API tests — ${ROUNDS} round(s) per model, per API (Chat + Messages + Responses)"
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
    LATENCY_CONN_SUM=0
    LATENCY_TTFB_SUM=0
    LATENCY_TOT_SUM=0
    LATENCY_PASS_COUNT=0

    for round in $(seq 1 "${ROUNDS}"); do
        # ── Chat completions API ──────────────────────────────────────
        CHAT_LINE_FILE="$(mktemp)"
        QUIET=1 bash "${SCRIPT_DIR}/chat_api_single.sh" "${model}" > "${CHAT_LINE_FILE}" 2>/dev/null || true
        CHAT_LINE="$(grep -E '^(PASS|FAIL)\|' "${CHAT_LINE_FILE}" | tail -1)"
        rm -f "${CHAT_LINE_FILE}"
        if echo "${CHAT_LINE}" | grep -q "^PASS|"; then
            CHAT_PASSES=$((CHAT_PASSES + 1))
            _tc="$(extract_timing conn "${CHAT_LINE}")"; _tt="$(extract_timing ttfb "${CHAT_LINE}")"; _to="$(extract_timing tot "${CHAT_LINE}")"
            printf "  API [Chat Completions] - round %s/%s  ${GREEN}PASS${NC}  conn=%sms, ttfb=%sms, tot=%sms\n" "${round}" "${ROUNDS}" "${_tc:-0}" "${_tt:-0}" "${_to:-0}" >&2
            LATENCY_CONN_SUM=$((LATENCY_CONN_SUM + ${_tc:-0})); LATENCY_TTFB_SUM=$((LATENCY_TTFB_SUM + ${_tt:-0})); LATENCY_TOT_SUM=$((LATENCY_TOT_SUM + ${_to:-0}))
            LATENCY_PASS_COUNT=$((LATENCY_PASS_COUNT + 1))
        else
            CHAT_ERR="$(printf '%s' "${CHAT_LINE}" | cut -d'|' -f4-)"
            printf "  API [Chat Completions] - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${CHAT_ERR}" >&2
        fi

        # ── Anthropic Messages API ────────────────────────────────────
        MSG_LINE_FILE="$(mktemp)"
        QUIET=1 bash "${SCRIPT_DIR}/messages_api_single.sh" "${model}" > "${MSG_LINE_FILE}" 2>/dev/null || true
        MSG_LINE="$(grep -E '^(PASS|FAIL)\|' "${MSG_LINE_FILE}" | tail -1)"
        rm -f "${MSG_LINE_FILE}"
        if echo "${MSG_LINE}" | grep -q "^PASS|"; then
            MSG_PASSES=$((MSG_PASSES + 1))
            _tc="$(extract_timing conn "${MSG_LINE}")"; _tt="$(extract_timing ttfb "${MSG_LINE}")"; _to="$(extract_timing tot "${MSG_LINE}")"
            printf "  API [Messages API]     - round %s/%s  ${GREEN}PASS${NC}  conn=%sms, ttfb=%sms, tot=%sms\n" "${round}" "${ROUNDS}" "${_tc:-0}" "${_tt:-0}" "${_to:-0}" >&2
            LATENCY_CONN_SUM=$((LATENCY_CONN_SUM + ${_tc:-0})); LATENCY_TTFB_SUM=$((LATENCY_TTFB_SUM + ${_tt:-0})); LATENCY_TOT_SUM=$((LATENCY_TOT_SUM + ${_to:-0}))
            LATENCY_PASS_COUNT=$((LATENCY_PASS_COUNT + 1))
        else
            MSG_ERR="$(printf '%s' "${MSG_LINE}" | cut -d'|' -f4-)"
            printf "  API [Messages API]     - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${MSG_ERR}" >&2
        fi

        # ── OpenAI Responses API ──────────────────────────────────────
        RESP_LINE_FILE="$(mktemp)"
        QUIET=1 bash "${SCRIPT_DIR}/responses_api_single.sh" "${model}" > "${RESP_LINE_FILE}" 2>/dev/null || true
        RESP_LINE="$(grep -E '^(PASS|FAIL)\|' "${RESP_LINE_FILE}" | tail -1)"
        rm -f "${RESP_LINE_FILE}"
        if echo "${RESP_LINE}" | grep -q "^PASS|"; then
            RESP_PASSES=$((RESP_PASSES + 1))
            _tc="$(extract_timing conn "${RESP_LINE}")"; _tt="$(extract_timing ttfb "${RESP_LINE}")"; _to="$(extract_timing tot "${RESP_LINE}")"
            printf "  API [Responses API]    - round %s/%s  ${GREEN}PASS${NC}  conn=%sms, ttfb=%sms, tot=%sms\n" "${round}" "${ROUNDS}" "${_tc:-0}" "${_tt:-0}" "${_to:-0}" >&2
            LATENCY_CONN_SUM=$((LATENCY_CONN_SUM + ${_tc:-0})); LATENCY_TTFB_SUM=$((LATENCY_TTFB_SUM + ${_tt:-0})); LATENCY_TOT_SUM=$((LATENCY_TOT_SUM + ${_to:-0}))
            LATENCY_PASS_COUNT=$((LATENCY_PASS_COUNT + 1))
        else
            RESP_ERR="$(printf '%s' "${RESP_LINE}" | cut -d'|' -f4-)"
            printf "  API [Responses API]    - round %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${RESP_ERR}" >&2
        fi
    done

    # Compute average latency (over PASS rounds only)
    LATENCY_CONN=""
    LATENCY_TTFB=""
    LATENCY_TOT=""
    if [ "${LATENCY_PASS_COUNT}" -gt 0 ]; then
        LATENCY_CONN=$(( (LATENCY_CONN_SUM + LATENCY_PASS_COUNT / 2) / LATENCY_PASS_COUNT ))
        LATENCY_TTFB=$(( (LATENCY_TTFB_SUM + LATENCY_PASS_COUNT / 2) / LATENCY_PASS_COUNT ))
        LATENCY_TOT=$(( (LATENCY_TOT_SUM + LATENCY_PASS_COUNT / 2) / LATENCY_PASS_COUNT ))
    fi

    echo "${model}|${CHAT_PASSES}|${ROUNDS}|${MSG_PASSES}|${ROUNDS}|${RESP_PASSES}|${ROUNDS}|${LATENCY_CONN}|${LATENCY_TTFB}|${LATENCY_TOT}" >> "${RESULTS_FILE}"
    echo "" >&2
done

# ── Output combined summary table ────────────────────────────────────
TABLE_WIDTH=$(python3 - "${RESULTS_FILE}" "${ROUNDS}" "${TOTAL_MODELS_FETCHED}" "${TOTAL_MODELS_IGNORED}" <<'INNEREOF'
import sys
results_file = sys.argv[1]
with open(results_file) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]
W_NUM = 4; W_MODEL = 38; W_API = 18; W_LAT = 18
print(W_NUM + 1 + W_MODEL + 1 + W_API + 1 + W_API + 1 + W_API + 1 + W_LAT)
INNEREOF
)
echo -e "${BOLD}$(printf '═%.0s' $(seq 1 ${TABLE_WIDTH}))${NC}"
echo -e "${BOLD}  Combined API Test Results (${ROUNDS} round(s))${NC}"
echo -e "${BOLD}$(printf '═%.0s' $(seq 1 ${TABLE_WIDTH}))${NC}"
echo ""

python3 - "${RESULTS_FILE}" "${ROUNDS}" "${TOTAL_MODELS_FETCHED}" "${TOTAL_MODELS_IGNORED}" <<'PYEOF'
import sys

GREEN = '\033[32m'
RED = '\033[31m'
BOLD = '\033[1m'
NC = '\033[0m'

results_file = sys.argv[1]
rounds = sys.argv[2]
fetched = sys.argv[3] if len(sys.argv) > 3 else ''
ignored = sys.argv[4] if len(sys.argv) > 4 else ''

with open(results_file) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]

# Column widths
W_NUM = 4
W_MODEL = 38
W_API = 18
W_LAT = 18   # "42ms/1.20s/1.25s" or "    —/    —/    —"

def fmt_ms(v):
    """Format milliseconds: <1000ms → '___ms', ≥1000ms → 'X.XXs'."""
    if not v or v == '':
        return '    —'
    v = int(v)
    if v < 1000:
        return f'{v:>3}ms'
    else:
        return f'{v/1000:.2f}s'

def fmt_latency(conn, ttfb, tot):
    """Format the combined latency cell: conn/ttfb/tot."""
    return f'{fmt_ms(conn)}/{fmt_ms(ttfb)}/{fmt_ms(tot)}'

header = f"{BOLD}{'#':<{W_NUM}} {'Model':<{W_MODEL}} {'Chat Complet.':<{W_API}} {'Messages API':<{W_API}} {'Responses API':<{W_API}} {'Latency(conn/ttfb/tot)':<{W_LAT}}{NC}"
sep_width = W_NUM + 1 + W_MODEL + 1 + W_API + 1 + W_API + 1 + W_API + 1 + W_LAT

print(header)
print("-" * sep_width)

chat_supported = 0
msg_supported = 0
resp_supported = 0
total_passed = 0

for idx, line in enumerate(lines, 1):
    parts = line.split('|')
    model = parts[0] if len(parts) > 0 else '?'
    chat_p = parts[1] if len(parts) > 1 else '0'
    chat_r = parts[2] if len(parts) > 2 else rounds
    msg_p = parts[3] if len(parts) > 3 else '0'
    msg_r = parts[4] if len(parts) > 4 else rounds
    resp_p = parts[5] if len(parts) > 5 else '0'
    resp_r = parts[6] if len(parts) > 6 else rounds
    lat_conn = parts[7] if len(parts) > 7 else ''
    lat_ttfb = parts[8] if len(parts) > 8 else ''
    lat_tot = parts[9] if len(parts) > 9 else ''

    chat_ok = int(chat_p) > 0
    msg_ok = int(msg_p) > 0
    resp_ok = int(resp_p) > 0
    if chat_ok: chat_supported += 1
    if msg_ok: msg_supported += 1
    if resp_ok: resp_supported += 1
    total_passed += int(chat_p) + int(msg_p) + int(resp_p)

    chat_str = f'{chat_p}/{chat_r}  {"✓" if chat_ok else "✗"}'
    msg_str = f'{msg_p}/{msg_r}  {"✓" if msg_ok else "✗"}'
    resp_str = f'{resp_p}/{resp_r}  {"✓" if resp_ok else "✗"}'
    chat_color = GREEN if chat_ok else RED
    msg_color = GREEN if msg_ok else RED
    resp_color = GREEN if resp_ok else RED

    lat_str = fmt_latency(lat_conn, lat_ttfb, lat_tot)

    print(f"{idx:<{W_NUM}} {model:<{W_MODEL}} {chat_color}{chat_str:<{W_API}}{NC} {msg_color}{msg_str:<{W_API}}{NC} {resp_color}{resp_str:<{W_API}}{NC} {lat_str:<{W_LAT}}")

print("-" * sep_width)
total = len(lines)
prefix = f"{fetched} fetched, {ignored} ignored, {total} tested" if fetched and ignored else f"{total} tested"
all_three = sum(1 for l in lines if int(l.split('|')[1]) > 0 and int(l.split('|')[3]) > 0 and int(l.split('|')[5]) > 0)
print(f"\n  {BOLD}Summary ({rounds} round(s) per API): {prefix}{NC}")
print(f"  {BOLD}- {chat_supported}/{total} support Chat Completions{NC}")
print(f"  {BOLD}- {msg_supported}/{total} support Messages API{NC}")
print(f"  {BOLD}- {resp_supported}/{total} support Responses API{NC}")
print(f"  All three APIs: {all_three}/{total} models")

# ── Average latency across all models (PASS rounds only) ────────────
lat_conn_vals = [int(p) for p in [l.split('|')[7] for l in lines] if p]
lat_ttfb_vals = [int(p) for p in [l.split('|')[8] for l in lines] if p]
lat_tot_vals  = [int(p) for p in [l.split('|')[9] for l in lines] if p]
if lat_conn_vals:
    avg_conn = sum(lat_conn_vals) / len(lat_conn_vals)
    avg_ttfb = sum(lat_ttfb_vals) / len(lat_ttfb_vals)
    avg_tot  = sum(lat_tot_vals)  / len(lat_tot_vals)
    print()
    print(f"  {BOLD}Average latency ({total_passed} passed / {total * 3 * int(rounds)} total API calls):{NC}")
    print(f"  {BOLD}- connect (conn):            {fmt_ms(str(int(avg_conn + 0.5)))}{NC}")
    print(f"  {BOLD}- time to first byte (ttfb): {fmt_ms(str(int(avg_ttfb + 0.5)))}{NC}")
    print(f"  {BOLD}- total (tot):               {fmt_ms(str(int(avg_tot  + 0.5)))}{NC}")
PYEOF

echo ""

rm -f "${RESULTS_FILE}"
exit 0
