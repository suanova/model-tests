#!/usr/bin/env bash
# compare_gateways.sh [rounds]
#
# Compares the model offerings of two API gateways. Gateway A uses the
# existing API_KEY + BASE_URL config; gateway B uses the additional
# API_KEY_B + BASE_URL_B config.
#
# For each gateway, fetches /v1/models, filters for chat models, and
# computes three groups:
#   - Shared: models on both gateways  → tested on BOTH gateways
#   - A-only: models only on gateway A → tested on gateway A
#   - B-only: models only on gateway B → tested on gateway B
#
# Each model is tested across all three APIs (Chat Completions,
# Anthropic Messages, OpenAI Responses). Supports multiple rounds;
# a model "supports" an API if it passes at least once.
#
# Config (env / .env, with CLI overrides):
#   API_KEY        Gateway A API key (required; existing config)
#   BASE_URL       Gateway A base URL (default https://cuberouter.cn)
#   API_KEY_B      Gateway B API key (required; or --b-key flag)
#   BASE_URL_B     Gateway B base URL (required; or --b-url flag)
#   TEST_TIMEOUT   Per-model timeout in seconds (default 30)
#
# CLI flags (override env/.env values):
#   --b-key KEY    Gateway B API key
#   --b-url URL    Gateway B base URL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Parse arguments ──────────────────────────────────────────────────
ROUNDS=1
CLI_B_KEY=""
CLI_B_URL=""
remaining_args=()

for arg in "$@"; do
    case "$arg" in
        --b-key)
            shift; CLI_B_KEY="${1:-}"; if [ -z "${CLI_B_KEY}" ]; then log_fail "--b-key requires a value"; exit 1; fi
            ;;
        --b-key=*)
            CLI_B_KEY="${arg#--b-key=}"
            ;;
        --b-url)
            shift; CLI_B_URL="${1:-}"; if [ -z "${CLI_B_URL}" ]; then log_fail "--b-url requires a value"; exit 1; fi
            ;;
        --b-url=*)
            CLI_B_URL="${arg#--b-url=}"
            ;;
        *)
            if [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -ge 1 ]; then
                ROUNDS="$arg"
            else
                log_fail "Invalid argument: '${arg}'"
                exit 1
            fi
            ;;
    esac
done

# ── Resolve gateway A config (existing API_KEY + BASE_URL) ───────────
require_api_key

# ── Resolve gateway B config ─────────────────────────────────────────
load_env_file
BASE_URL_B="${BASE_URL_B:-}"
API_KEY_B="${API_KEY_B:-}"
if [ -n "${CLI_B_KEY}" ]; then API_KEY_B="${CLI_B_KEY}"; fi
if [ -n "${CLI_B_URL}" ]; then BASE_URL_B="${CLI_B_URL}"; fi
BASE_URL_B="${BASE_URL_B%/}"

if [ -z "${API_KEY_B}" ]; then
    log_fail "API_KEY_B is required for gateway B."
    log_fail "Set it in .env as: API_KEY_B=your_key"
    log_fail "Or pass it inline: API_KEY_B=your_key bash $0"
    log_fail "Or use the CLI flag: --b-key your_key"
    exit 1
fi
if [ -z "${BASE_URL_B}" ]; then
    log_fail "BASE_URL_B is required for gateway B."
    log_fail "Set it in .env as: BASE_URL_B=https://other-gateway.example.com"
    log_fail "Or pass it inline: BASE_URL_B=https://... bash $0"
    log_fail "Or use the CLI flag: --b-url https://..."
    exit 1
fi

# ── Derive short gateway labels from URLs ────────────────────────────
GW_A_LABEL="$(echo "${BASE_URL}" | sed -E 's|^https?://([^/]+).*$|\1|' | sed -E 's|^(api\.)?([^.]+).*$|\2|')"
GW_B_LABEL="$(echo "${BASE_URL_B}" | sed -E 's|^https?://([^/]+).*$|\1|' | sed -E 's|^(api\.)?([^.]+).*$|\2|')"

log_info "Gateway ${GW_A_LABEL}: ${BASE_URL} (key: ${API_KEY:0:8}...)"
log_info "Gateway ${GW_B_LABEL}: ${BASE_URL_B} (key: ${API_KEY_B:0:8}...)"
log_info "Rounds: ${ROUNDS}"
echo ""

# ── Fetch models from both gateways ──────────────────────────────────
MODELS_A_FILE="$(mktemp)"
MODELS_B_FILE="$(mktemp)"

WHITELIST_PATH="${SCRIPT_DIR}/whitelist.txt"
if [ -f "${WHITELIST_PATH}" ]; then
    WHITELIST_AVAILABLE="1"
else
    WHITELIST_AVAILABLE="0"
fi

fetch_model_list "${BASE_URL}" "${API_KEY}" "${GW_A_LABEL}" "${WHITELIST_PATH}" > "${MODELS_A_FILE}" || true
A_FETCH_OK=$?
A_COUNT="${FETCH_MODELS_COUNT:-0}"
A_TOTAL="${FETCH_TOTAL:-0}"
A_IGNORED="${FETCH_IGNORED:-0}"
A_NONCHAT="${FETCH_NONCHAT:-0}"
A_NOTWL="${FETCH_NOTWL:-0}"

fetch_model_list "${BASE_URL_B}" "${API_KEY_B}" "${GW_B_LABEL}" "${WHITELIST_PATH}" > "${MODELS_B_FILE}" || true
B_FETCH_OK=$?
B_COUNT="${FETCH_MODELS_COUNT:-0}"
B_TOTAL="${FETCH_TOTAL:-0}"
B_IGNORED="${FETCH_IGNORED:-0}"
B_NONCHAT="${FETCH_NONCHAT:-0}"
B_NOTWL="${FETCH_NOTWL:-0}"

if [ "${A_FETCH_OK}" -ne 0 ] && [ "${B_FETCH_OK}" -ne 0 ]; then
    log_fail "Both gateways failed to return model lists — cannot compare."
    rm -f "${MODELS_A_FILE}" "${MODELS_B_FILE}"
    exit 1
fi

echo ""

# ── Compute shared / A-only / B-only sets ────────────────────────────
SET_FILE="$(mktemp)"
python3 - "${MODELS_A_FILE}" "${MODELS_B_FILE}" "${SET_FILE}" <<'PYEOF'
import sys

a_file = sys.argv[1]
b_file = sys.argv[2]
out_file = sys.argv[3]

with open(a_file) as f:
    a_models = sorted(set(l.strip() for l in f if l.strip()))
with open(b_file) as f:
    b_models = sorted(set(l.strip() for l in f if l.strip()))

shared = sorted(set(a_models) & set(b_models))
a_only = sorted(set(a_models) - set(b_models))
b_only = sorted(set(b_models) - set(a_models))

with open(out_file, 'w') as out:
    out.write(f"SHARED:{len(shared)}\n")
    for m in shared:
        out.write(f"S:{m}\n")
    out.write(f"A_ONLY:{len(a_only)}\n")
    for m in a_only:
        out.write(f"A:{m}\n")
    out.write(f"B_ONLY:{len(b_only)}\n")
    for m in b_only:
        out.write(f"B:{m}\n")
PYEOF

SHARED_COUNT="$(grep '^SHARED:' "${SET_FILE}" | cut -d: -f2)"
A_ONLY_COUNT="$(grep '^A_ONLY:' "${SET_FILE}" | cut -d: -f2)"
B_ONLY_COUNT="$(grep '^B_ONLY:' "${SET_FILE}" | cut -d: -f2)"

SHARED_MODELS="$(grep '^S:' "${SET_FILE}" | cut -d: -f2)"
A_ONLY_MODELS="$(grep '^A:' "${SET_FILE}" | cut -d: -f2)"
B_ONLY_MODELS="$(grep '^B:' "${SET_FILE}" | cut -d: -f2)"

rm -f "${SET_FILE}" "${MODELS_A_FILE}" "${MODELS_B_FILE}"

# ── Test helper: run one API test for one model on one gateway ───────
run_single_test() {
    local script="$1"
    local model="$2"
    local gw_url="$3"
    local gw_key="$4"

    local line_file
    line_file="$(mktemp)"
    QUIET=1 API_KEY="${gw_key}" BASE_URL="${gw_url}" \
        bash "${SCRIPT_DIR}/${script}" "${model}" > "${line_file}" 2>/dev/null || true
    local result_line
    result_line="$(grep -E '^(PASS|FAIL)\|' "${line_file}" | tail -1)"
    rm -f "${line_file}"
    echo "${result_line}"
}

# ── Run tests ────────────────────────────────────────────────────────
# Result line format: <gateway>|<model>|<chat_passes>|<rounds>|<msg_passes>|<rounds>|<resp_passes>|<rounds>|<lat_conn>|<lat_ttfb>|<lat_tot>
RESULTS_FILE="$(mktemp)"

TEST_START_TIME="$(date +%s)"

test_model_on_gateway() {
    local model="$1"
    local gw_label="$2"
    local gw_url="$3"
    local gw_key="$4"

    local chat_passes=0 msg_passes=0 resp_passes=0
    local lat_conn_sum=0 lat_ttfb_sum=0 lat_tot_sum=0 lat_pass_count=0

    echo -e "  ${gw_label}:" >&2
    for round in $(seq 1 "${ROUNDS}"); do
        # Chat Completions
        local chat_line
        chat_line="$(run_single_test chat_api_single.sh "${model}" "${gw_url}" "${gw_key}")"
        if echo "${chat_line}" | grep -q "^PASS|"; then
            chat_passes=$((chat_passes + 1))
            _tc="$(extract_timing conn "${chat_line}")"; _tt="$(extract_timing ttfb "${chat_line}")"; _to="$(extract_timing tot "${chat_line}")"
            printf "    Chat Completions  %s/%s  ${GREEN}PASS${NC}  conn=%sms, ttfb=%sms, tot=%sms\n" "${round}" "${ROUNDS}" "${_tc:-0}" "${_tt:-0}" "${_to:-0}" >&2
            lat_conn_sum=$((lat_conn_sum + ${_tc:-0})); lat_ttfb_sum=$((lat_ttfb_sum + ${_tt:-0})); lat_tot_sum=$((lat_tot_sum + ${_to:-0}))
            lat_pass_count=$((lat_pass_count + 1))
        else
            local chat_err="$(printf '%s' "${chat_line}" | cut -d'|' -f4-)"
            printf "    Chat Completions  %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${chat_err}" >&2
        fi

        # Anthropic Messages
        local msg_line
        msg_line="$(run_single_test messages_api_single.sh "${model}" "${gw_url}" "${gw_key}")"
        if echo "${msg_line}" | grep -q "^PASS|"; then
            msg_passes=$((msg_passes + 1))
            _tc="$(extract_timing conn "${msg_line}")"; _tt="$(extract_timing ttfb "${msg_line}")"; _to="$(extract_timing tot "${msg_line}")"
            printf "    Messages API      %s/%s  ${GREEN}PASS${NC}  conn=%sms, ttfb=%sms, tot=%sms\n" "${round}" "${ROUNDS}" "${_tc:-0}" "${_tt:-0}" "${_to:-0}" >&2
            lat_conn_sum=$((lat_conn_sum + ${_tc:-0})); lat_ttfb_sum=$((lat_ttfb_sum + ${_tt:-0})); lat_tot_sum=$((lat_tot_sum + ${_to:-0}))
            lat_pass_count=$((lat_pass_count + 1))
        else
            local msg_err="$(printf '%s' "${msg_line}" | cut -d'|' -f4-)"
            printf "    Messages API      %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${msg_err}" >&2
        fi

        # OpenAI Responses
        local resp_line
        resp_line="$(run_single_test responses_api_single.sh "${model}" "${gw_url}" "${gw_key}")"
        if echo "${resp_line}" | grep -q "^PASS|"; then
            resp_passes=$((resp_passes + 1))
            _tc="$(extract_timing conn "${resp_line}")"; _tt="$(extract_timing ttfb "${resp_line}")"; _to="$(extract_timing tot "${resp_line}")"
            printf "    Responses API     %s/%s  ${GREEN}PASS${NC}  conn=%sms, ttfb=%sms, tot=%sms\n" "${round}" "${ROUNDS}" "${_tc:-0}" "${_tt:-0}" "${_to:-0}" >&2
            lat_conn_sum=$((lat_conn_sum + ${_tc:-0})); lat_ttfb_sum=$((lat_ttfb_sum + ${_tt:-0})); lat_tot_sum=$((lat_tot_sum + ${_to:-0}))
            lat_pass_count=$((lat_pass_count + 1))
        else
            local resp_err="$(printf '%s' "${resp_line}" | cut -d'|' -f4-)"
            printf "    Responses API     %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${resp_err}" >&2
        fi
    done

    local lat_conn="" lat_ttfb="" lat_tot=""
    if [ "${lat_pass_count}" -gt 0 ]; then
        lat_conn=$(( (lat_conn_sum + lat_pass_count / 2) / lat_pass_count ))
        lat_ttfb=$(( (lat_ttfb_sum + lat_pass_count / 2) / lat_pass_count ))
        lat_tot=$(( (lat_tot_sum + lat_pass_count / 2) / lat_pass_count ))
    fi

    echo "${gw_label}|${model}|${chat_passes}|${ROUNDS}|${msg_passes}|${ROUNDS}|${resp_passes}|${ROUNDS}|${lat_conn}|${lat_ttfb}|${lat_tot}"
}

# ── Parallel variant ────────────────────────────────────────────────
test_model_parallel() {
    local model="$1"
    local log_b="$(mktemp)"
    local result_a="$(mktemp)"
    local result_b="$(mktemp)"

    ( test_model_on_gateway "${model}" "${GW_B_LABEL}" "${BASE_URL_B}" "${API_KEY_B}" ) 2>"${log_b}" >"${result_b}" &
    local pid_b=$!

    test_model_on_gateway "${model}" "${GW_A_LABEL}" "${BASE_URL}" "${API_KEY}" >"${result_a}"

    wait "${pid_b}" 2>/dev/null
    cat "${log_b}" >&2

    cat "${result_a}" >> "${RESULTS_FILE}"
    cat "${result_b}" >> "${RESULTS_FILE}"

    rm -f "${log_b}" "${result_a}" "${result_b}"
}

MODEL_IDX=0
TOTAL_MODEL_COUNT=$((SHARED_COUNT + A_ONLY_COUNT + B_ONLY_COUNT))

# ── Shared models (tested on both gateways in parallel) ───────────────
for model in ${SHARED_MODELS}; do
    MODEL_IDX=$((MODEL_IDX + 1))
    echo -e "${BOLD}[${MODEL_IDX}/${TOTAL_MODEL_COUNT}] ${model}${NC}" >&2
    test_model_parallel "${model}"
    echo "" >&2
done

# ── A-only models ────────────────────────────────────────────────────
for model in ${A_ONLY_MODELS}; do
    MODEL_IDX=$((MODEL_IDX + 1))
    echo -e "${BOLD}[${MODEL_IDX}/${TOTAL_MODEL_COUNT}] ${model}  (${GW_A_LABEL}-only)${NC}" >&2
    test_model_on_gateway "${model}" "${GW_A_LABEL}" "${BASE_URL}" "${API_KEY}" >> "${RESULTS_FILE}"
    echo "" >&2
done

# ── B-only models ────────────────────────────────────────────────────
for model in ${B_ONLY_MODELS}; do
    MODEL_IDX=$((MODEL_IDX + 1))
    echo -e "${BOLD}[${MODEL_IDX}/${TOTAL_MODEL_COUNT}] ${model}  (${GW_B_LABEL}-only)${NC}" >&2
    test_model_on_gateway "${model}" "${GW_B_LABEL}" "${BASE_URL_B}" "${API_KEY_B}" >> "${RESULTS_FILE}"
    echo "" >&2
done

TEST_END_TIME="$(date +%s)"
TEST_ELAPSED=$((TEST_END_TIME - TEST_START_TIME))

# ── Output comparison table ─────────────────────────────────────────

python3 - "${RESULTS_FILE}" "${ROUNDS}" \
    "${A_TOTAL}" "${A_NONCHAT}" "${A_NOTWL}" "${A_COUNT}" \
    "${B_TOTAL}" "${B_NONCHAT}" "${B_NOTWL}" "${B_COUNT}" \
    "${GW_A_LABEL}" "${GW_B_LABEL}" "${WHITELIST_AVAILABLE}" \
    "${BASE_URL}" "${BASE_URL_B}" "${TEST_START_TIME}" "${TEST_ELAPSED}" <<'PYEOF'
import sys

GREEN = '\033[32m'
RED = '\033[31m'
BOLD = '\033[1m'
NC = '\033[0m'

results_file = sys.argv[1]
rounds = int(sys.argv[2])
a_total = sys.argv[3] if len(sys.argv) > 3 else ''
a_nonchat = sys.argv[4] if len(sys.argv) > 4 else ''
a_notwl = sys.argv[5] if len(sys.argv) > 5 else ''
a_count = sys.argv[6] if len(sys.argv) > 6 else ''
b_total = sys.argv[7] if len(sys.argv) > 7 else ''
b_nonchat = sys.argv[8] if len(sys.argv) > 8 else ''
b_notwl = sys.argv[9] if len(sys.argv) > 9 else ''
b_count = sys.argv[10] if len(sys.argv) > 10 else ''
gw_a = sys.argv[11] if len(sys.argv) > 11 else 'A'
gw_b = sys.argv[12] if len(sys.argv) > 12 else 'B'
wl_available = sys.argv[13] if len(sys.argv) > 13 else '0'
base_url_a = sys.argv[14] if len(sys.argv) > 14 else ''
base_url_b = sys.argv[15] if len(sys.argv) > 15 else ''
test_start_time = sys.argv[16] if len(sys.argv) > 16 else ''
test_elapsed = sys.argv[17] if len(sys.argv) > 17 else ''

# Format the start timestamp; test_start_time is a unix epoch from the shell.
import datetime
try:
    started_str = datetime.datetime.fromtimestamp(int(test_start_time)).strftime('%Y-%m-%d %H:%M:%S')
except (ValueError, TypeError):
    started_str = test_start_time

with open(results_file) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]

def parse_line(line):
    parts = line.split('|')
    gw = parts[0] if len(parts) > 0 else '?'
    model = parts[1] if len(parts) > 1 else '?'
    chat_p = int(parts[2]) if len(parts) > 2 else 0
    chat_r = int(parts[3]) if len(parts) > 3 else rounds
    msg_p = int(parts[4]) if len(parts) > 4 else 0
    msg_r = int(parts[5]) if len(parts) > 5 else rounds
    resp_p = int(parts[6]) if len(parts) > 6 else 0
    resp_r = int(parts[7]) if len(parts) > 7 else rounds
    lat_conn = parts[8] if len(parts) > 8 else ''
    lat_ttfb = parts[9] if len(parts) > 9 else ''
    lat_tot = parts[10] if len(parts) > 10 else ''
    return {'gw': gw, 'model': model,
            'chat_p': chat_p, 'chat_r': chat_r,
            'msg_p': msg_p, 'msg_r': msg_r,
            'resp_p': resp_p, 'resp_r': resp_r,
            'lat_conn': lat_conn, 'lat_ttfb': lat_ttfb, 'lat_tot': lat_tot}

parsed = [parse_line(l) for l in lines]

# Group by model: {model: {gw_label: {...}}}
by_model = {}
for p in parsed:
    m = p['model']
    if m not in by_model:
        by_model[m] = {}
    by_model[m][p['gw']] = p

# Classify models
shared = sorted([m for m in by_model if len(by_model[m]) > 1])
a_only = sorted([m for m in by_model if len(by_model[m]) == 1 and gw_a in by_model[m]])
b_only = sorted([m for m in by_model if len(by_model[m]) == 1 and gw_b in by_model[m]])

# Column widths
W_MODEL = 34
W_NUM = 4
W_GAP = 6

def fmt_ms(v):
    """Format milliseconds: <1000ms → '___ms', ≥1000ms → seconds."""
    if not v or v == '':
        return '    —'
    v = int(v)
    if v < 1000:
        return f'{v:>3}ms'
    else:
        return f'{v/1000:.2f}s'

def fmt_latency(conn, ttfb, tot):
    """Format combined latency: conn/ttfb/tot."""
    return f'{fmt_ms(conn)}/{fmt_ms(ttfb)}/{fmt_ms(tot)}'

def check_detail(p, p_key, rounds):
    ok = p[p_key] > 0
    color = GREEN if ok else RED
    return f'{color}{p[p_key]}/{rounds}{NC}'

def right_cell(content, visible_len, width):
    pad = width - visible_len
    return ' ' * pad + content

def dash_cell(width):
    return ' ' * (width - 2) + '—' + ' '

# ── Gateway info lines ──────────────────────────────────────────────
def fmt_gw_line(total, nonchat, notwl, kept, wl_available):
    parts = [f'{total} fetched, {nonchat} non-text dropped']
    if wl_available == '1':
        parts.append(f'{notwl} not in whitelist')
    parts.append(f'{kept} kept')
    return ', '.join(parts)

print(f"{BOLD}  {gw_a}: {fmt_gw_line(a_total, a_nonchat, a_notwl, a_count, wl_available)}{NC}")
print(f"{BOLD}  {gw_b}: {fmt_gw_line(b_total, b_nonchat, b_notwl, b_count, wl_available)}{NC}")
print(f"  Shared: {len(shared)}  |  {gw_a}-only: {len(a_only)}  |  {gw_b}-only: {len(b_only)}")
print()

api_names = ['Chat', 'Msg', 'Resp']
p_keys = ['chat_p', 'msg_p', 'resp_p']
stat_keys = ['chat', 'msg', 'resp']
lat_header = 'Latency(conn/ttfb/tot)'

# Each API column width: max(len(name), 6) — fits "2/2 ✓" (6 visible) or header name
api_widths = [max(len(name), 6) for name in api_names]
# Latency column width: max of header length and typical value length
# "42ms/1.20s/1.25s" → 17 chars, "    —/    —/    —" → 17 chars
W_LAT = max(len(lat_header), 17)

# Gateway span = Chat + Msg + Resp + Latency + 3 inter-column gaps (2 spaces each)
gw_span = sum(api_widths) + W_LAT + 2 * 4  # 4 gaps between 4 columns

left_width = W_NUM + 2 + W_MODEL
total_width = left_width + 2 + gw_span + W_GAP + gw_span

# ── Title block (sized to the table) ────────────────────────────────
border = '═' * total_width
print(f"{BOLD}{border}{NC}")
print(f"{BOLD}  Gateway Comparison Results ({rounds} round(s) per API){NC}")
print(f"{BOLD}  {gw_a}: {base_url_a}  |  {gw_b}: {base_url_b}{NC}")
print(f"{BOLD}  Started: {started_str}  |  Elapsed: {test_elapsed}s{NC}")
print(f"{BOLD}{border}{NC}")
print()

# ── Two-row header ──────────────────────────────────────────────────
row1_left = ' ' * (left_width + 2)
row1_gw_a = f'{BOLD}{"─" * 13 + " " + gw_a + " " + "─" * 13:^{gw_span}}{NC}'
row1_gap = ' ' * W_GAP
row1_gw_b = f'{BOLD}{"─" * 13 + " " + gw_b + " " + "─" * 13:^{gw_span}}{NC}'
row1 = row1_left + row1_gw_a + row1_gap + row1_gw_b

row2_cols = [f'{BOLD}{"#":<{W_NUM}}{NC}', f'{BOLD}{"Model":<{W_MODEL}}{NC}']
for i, name in enumerate(api_names):
    row2_cols.append(f'{BOLD}{name:>{api_widths[i]}}{NC}')
row2_cols.append(f'{BOLD}{lat_header:>{W_LAT}}{NC}')
row2_cols.append(' ' * W_GAP)
for i, name in enumerate(api_names):
    row2_cols.append(f'{BOLD}{name:>{api_widths[i]}}{NC}')
row2_cols.append(f'{BOLD}{lat_header:>{W_LAT}}{NC}')

print(row1)
print('  '.join(row2_cols))
print("─" * total_width)

# Stats accumulators — per gateway, for summary
stats = {gw_a: {'chat': 0, 'msg': 0, 'resp': 0, 'total': 0, 'passed': 0,
                'lat_conn_vals': [], 'lat_ttfb_vals': [], 'lat_tot_vals': []},
         gw_b: {'chat': 0, 'msg': 0, 'resp': 0, 'total': 0, 'passed': 0,
                'lat_conn_vals': [], 'lat_ttfb_vals': [], 'lat_tot_vals': []}}

all_ordered = shared + a_only + b_only
for idx, m in enumerate(all_ordered, 1):
    a_data = by_model[m].get(gw_a)
    b_data = by_model[m].get(gw_b)

    row_cols = [f'{idx:<{W_NUM}}', f'{m:<{W_MODEL}}']
    # gw_a columns: Chat, Msg, Resp, Latency
    for i, p_key in enumerate(p_keys):
        sk = stat_keys[i]
        if a_data:
            val = check_detail(a_data, p_key, rounds)
            row_cols.append(right_cell(val, 3, api_widths[i]))
            if a_data[p_key] > 0:
                stats[gw_a][sk] += 1
                stats[gw_a]['passed'] += a_data[p_key]
            stats[gw_a]['total'] += 1
        else:
            row_cols.append(dash_cell(api_widths[i]))
    # gw_a latency
    if a_data and (a_data['lat_conn'] or a_data['lat_ttfb'] or a_data['lat_tot']):
        lat_str = fmt_latency(a_data['lat_conn'], a_data['lat_ttfb'], a_data['lat_tot'])
        row_cols.append(right_cell(lat_str, len(lat_str), W_LAT))
        # Collect for gateway-wide average (only if there are values)
        if a_data['lat_conn']:
            stats[gw_a]['lat_conn_vals'].append(int(a_data['lat_conn']))
        if a_data['lat_ttfb']:
            stats[gw_a]['lat_ttfb_vals'].append(int(a_data['lat_ttfb']))
        if a_data['lat_tot']:
            stats[gw_a]['lat_tot_vals'].append(int(a_data['lat_tot']))
    elif a_data:
        row_cols.append(right_cell('—/—/—', 5, W_LAT))
    else:
        row_cols.append(right_cell('—/—/—', 5, W_LAT))
    row_cols.append(' ' * W_GAP)
    # gw_b columns: Chat, Msg, Resp, Latency
    for i, p_key in enumerate(p_keys):
        sk = stat_keys[i]
        if b_data:
            val = check_detail(b_data, p_key, rounds)
            row_cols.append(right_cell(val, 3, api_widths[i]))
            if b_data[p_key] > 0:
                stats[gw_b][sk] += 1
                stats[gw_b]['passed'] += b_data[p_key]
            stats[gw_b]['total'] += 1
        else:
            row_cols.append(dash_cell(api_widths[i]))
    # gw_b latency
    if b_data and (b_data['lat_conn'] or b_data['lat_ttfb'] or b_data['lat_tot']):
        lat_str = fmt_latency(b_data['lat_conn'], b_data['lat_ttfb'], b_data['lat_tot'])
        row_cols.append(right_cell(lat_str, len(lat_str), W_LAT))
        if b_data['lat_conn']:
            stats[gw_b]['lat_conn_vals'].append(int(b_data['lat_conn']))
        if b_data['lat_ttfb']:
            stats[gw_b]['lat_ttfb_vals'].append(int(b_data['lat_ttfb']))
        if b_data['lat_tot']:
            stats[gw_b]['lat_tot_vals'].append(int(b_data['lat_tot']))
    elif b_data:
        row_cols.append(right_cell('—/—/—', 5, W_LAT))
    else:
        row_cols.append(right_cell('—/—/—', 5, W_LAT))

    print('  '.join(row_cols))

print("─" * total_width)

# ── Summary ──────────────────────────────────────────────────────
print()
print(f"{BOLD}  Summary:{NC}")
a_tested = len([m for m in all_ordered if by_model[m].get(gw_a)])
b_tested = len([m for m in all_ordered if by_model[m].get(gw_b)])

# Gateway-wide average latency (over all models that had values)
def avg_lat(vals):
    if not vals:
        return '—'
    avg = sum(vals) / len(vals)
    return fmt_ms(str(int(avg + 0.5)))

for gw, tested, label in [(gw_a, a_tested, gw_a), (gw_b, b_tested, gw_b)]:
    print(f"    {label}:")
    print(f"      Chat {stats[gw]['chat']}/{tested} ✓  |  Messages {stats[gw]['msg']}/{tested} ✓  |  Responses {stats[gw]['resp']}/{tested} ✓")
    if stats[gw]['lat_conn_vals']:
        passed_calls = stats[gw]['passed']
        total_calls = tested * 3 * rounds
        print(f"      Average latency ({passed_calls} passed / {total_calls} total API calls):")
        print(f"        - connect (conn):            {avg_lat(stats[gw]['lat_conn_vals'])}")
        print(f"        - time to first byte (ttfb): {avg_lat(stats[gw]['lat_ttfb_vals'])}")
        print(f"        - total (tot):               {avg_lat(stats[gw]['lat_tot_vals'])}")
print()
PYEOF

rm -f "${RESULTS_FILE}"
exit 0
