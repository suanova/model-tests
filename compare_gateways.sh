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
# Load .env first (so .env values fill in anything not yet set), then
# apply CLI overrides. API_KEY_B / BASE_URL_B are NOT part of the
# existing require_api_key flow, so we load the env file ourselves.
load_env_file
BASE_URL_B="${BASE_URL_B:-}"
API_KEY_B="${API_KEY_B:-}"
# CLI overrides take precedence
if [ -n "${CLI_B_KEY}" ]; then API_KEY_B="${CLI_B_KEY}"; fi
if [ -n "${CLI_B_URL}" ]; then BASE_URL_B="${CLI_B_URL}"; fi
# Strip trailing slash
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
# Extract the domain keyword (e.g. "cuberouter" from https://cuberouter.cn,
# "modelverse" from https://api.modelverse.cn).
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

# Parse the set file
SHARED_COUNT="$(grep '^SHARED:' "${SET_FILE}" | cut -d: -f2)"
A_ONLY_COUNT="$(grep '^A_ONLY:' "${SET_FILE}" | cut -d: -f2)"
B_ONLY_COUNT="$(grep '^B_ONLY:' "${SET_FILE}" | cut -d: -f2)"

SHARED_MODELS="$(grep '^S:' "${SET_FILE}" | cut -d: -f2)"
A_ONLY_MODELS="$(grep '^A:' "${SET_FILE}" | cut -d: -f2)"
B_ONLY_MODELS="$(grep '^B:' "${SET_FILE}" | cut -d: -f2)"

rm -f "${SET_FILE}" "${MODELS_A_FILE}" "${MODELS_B_FILE}"

# ── Test helper: run one API test for one model on one gateway ───────
# Invokes the single-model script with the gateway's url/key injected
# via env vars. Returns a PASS/FAIL result line.
run_single_test() {
    local script="$1"     # e.g. chat_api_single.sh
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
# Result line format: <gateway>|<model>|<chat_passes>|<rounds>|<msg_passes>|<rounds>|<resp_passes>|<rounds>
RESULTS_FILE="$(mktemp)"

TEST_START_TIME="$(date +%s)"

test_model_on_gateway() {
    local model="$1"
    local gw_label="$2"    # e.g. "cuberouter" or "modelverse"
    local gw_url="$3"
    local gw_key="$4"

    local chat_passes=0 msg_passes=0 resp_passes=0

    echo -e "  ${gw_label}:" >&2
    for round in $(seq 1 "${ROUNDS}"); do
        # Chat Completions
        local chat_line
        chat_line="$(run_single_test chat_api_single.sh "${model}" "${gw_url}" "${gw_key}")"
        if echo "${chat_line}" | grep -q "^PASS|"; then
            chat_passes=$((chat_passes + 1))
            printf "    Chat Completions  %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
        else
            local chat_err="$(printf '%s' "${chat_line}" | cut -d'|' -f3-)"
            printf "    Chat Completions  %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${chat_err}" >&2
        fi

        # Anthropic Messages
        local msg_line
        msg_line="$(run_single_test messages_api_single.sh "${model}" "${gw_url}" "${gw_key}")"
        if echo "${msg_line}" | grep -q "^PASS|"; then
            msg_passes=$((msg_passes + 1))
            printf "    Messages API      %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
        else
            local msg_err="$(printf '%s' "${msg_line}" | cut -d'|' -f3-)"
            printf "    Messages API      %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${msg_err}" >&2
        fi

        # OpenAI Responses
        local resp_line
        resp_line="$(run_single_test responses_api_single.sh "${model}" "${gw_url}" "${gw_key}")"
        if echo "${resp_line}" | grep -q "^PASS|"; then
            resp_passes=$((resp_passes + 1))
            printf "    Responses API     %s/%s  ${GREEN}PASS${NC}\n" "${round}" "${ROUNDS}" >&2
        else
            local resp_err="$(printf '%s' "${resp_line}" | cut -d'|' -f3-)"
            printf "    Responses API     %s/%s  ${RED}FAIL${NC}  %s\n" "${round}" "${ROUNDS}" "${resp_err}" >&2
        fi
    done

    echo "${gw_label}|${model}|${chat_passes}|${ROUNDS}|${msg_passes}|${ROUNDS}|${resp_passes}|${ROUNDS}"
}

# ── Parallel variant: runs same model on both gateways simultaneously ──
# Gateway A's progress streams to stderr live (in real time).
# Gateway B's progress is buffered to a temp file and printed only
# after gateway A finishes — so the user sees A's output immediately,
# then B's output appears all at once once both are done.
test_model_parallel() {
    local model="$1"
    local log_b="$(mktemp)"
    local result_a="$(mktemp)"
    local result_b="$(mktemp)"

    # Launch gateway B in background — progress buffered, results to temp file
    ( test_model_on_gateway "${model}" "${GW_B_LABEL}" "${BASE_URL_B}" "${API_KEY_B}" ) 2>"${log_b}" >"${result_b}" &
    local pid_b=$!

    # Run gateway A in foreground — progress streams live to stderr, result to temp file
    test_model_on_gateway "${model}" "${GW_A_LABEL}" "${BASE_URL}" "${API_KEY}" >"${result_a}"

    # Gateway A is done; now wait for gateway B (if still running)
    wait "${pid_b}" 2>/dev/null

    # Print gateway B's buffered progress now
    cat "${log_b}" >&2

    # Merge result lines into the shared RESULTS_FILE
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
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Gateway Comparison Results (${ROUNDS} round(s) per API)${NC}"
echo -e "${BOLD}  ${GW_A_LABEL}: ${BASE_URL}  |  ${GW_B_LABEL}: ${BASE_URL_B}${NC}"
echo -e "${BOLD}  Started: $(date -d @${TEST_START_TIME} '+%Y-%m-%d %H:%M:%S')  |  Elapsed: ${TEST_ELAPSED}s${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

python3 - "${RESULTS_FILE}" "${ROUNDS}" \
    "${A_TOTAL}" "${A_NONCHAT}" "${A_NOTWL}" "${A_COUNT}" \
    "${B_TOTAL}" "${B_NONCHAT}" "${B_NOTWL}" "${B_COUNT}" \
    "${GW_A_LABEL}" "${GW_B_LABEL}" "${WHITELIST_AVAILABLE}" <<'PYEOF'
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
    return {'gw': gw, 'model': model,
            'chat_p': chat_p, 'chat_r': chat_r,
            'msg_p': msg_p, 'msg_r': msg_r,
            'resp_p': resp_p, 'resp_r': resp_r}

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
W_GAP = 6   # spaces between the two gateway groups

def check_detail(p, p_key, rounds):
    """Return pass/total with color, e.g. '0/1' (red) or '2/3' (green)."""
    ok = p[p_key] > 0
    color = GREEN if ok else RED
    return f'{color}{p[p_key]}/{rounds}{NC}'

def right_cell(content, visible_len, width):
    """Right-align a cell whose visible characters are `visible_len` long within `width`.
    `content` may contain ANSI escape codes. Pads with spaces on the left."""
    pad = width - visible_len
    return ' ' * pad + content

def dash_cell(width):
    """Return '—' positioned at the same column as '/' in '1/1' (right-aligned)."""
    # '1/1' right-aligned in width W: the '/' is at offset W-2 (0-indexed).
    # Place '—' at that same offset.
    return ' ' * (width - 2) + '—' + ' '

# ── Single unified table ──────────────────────────────────────────
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

api_names = ['Chat', 'Messages', 'Responses']
p_keys = ['chat_p', 'msg_p', 'resp_p']
stat_keys = ['chat', 'msg', 'resp']

# Each API column must fit its header name AND the 3-char value ✓/1 (or ✗/0).
# We pad manually to avoid ANSI escape codes breaking Python's str formatting.
api_widths = [max(len(name), 6) for name in api_names]

gw_span = sum(api_widths) + 2 * (len(api_widths) - 1)  # same for both gateways
left_width = W_NUM + 2 + W_MODEL
total_width = left_width + 2 + gw_span + W_GAP + gw_span + 6

# ── Two-row header ──────────────────────────────────────────────────
row1_left = ' ' * (left_width + 2)
row1_gw_a = f'{BOLD}{"─ " + gw_a + " ─":^{gw_span}}{NC}'
row1_gap = ' ' * W_GAP
row1_gw_b = f'{BOLD}{"─ " + gw_b + " ─":^{gw_span}}{NC}'
row1 = row1_left + row1_gw_a + row1_gap + row1_gw_b

row2_cols = [f'{BOLD}{"#":<{W_NUM}}{NC}', f'{BOLD}{"Model":<{W_MODEL}}{NC}']
for i, name in enumerate(api_names):
    row2_cols.append(f'{BOLD}{name:>{api_widths[i]}}{NC}')
row2_cols.append(' ' * W_GAP)
for i, name in enumerate(api_names):
    row2_cols.append(f'{BOLD}{name:>{api_widths[i]}}{NC}')

print(row1)
print('  '.join(row2_cols))
print("─" * total_width)

# Stats accumulators
stats = {gw_a: {'chat': 0, 'msg': 0, 'resp': 0, 'total': 0},
         gw_b: {'chat': 0, 'msg': 0, 'resp': 0, 'total': 0}}

all_ordered = shared + a_only + b_only
for idx, m in enumerate(all_ordered, 1):
    a_data = by_model[m].get(gw_a)
    b_data = by_model[m].get(gw_b)

    row_cols = [f'{idx:<{W_NUM}}', f'{m:<{W_MODEL}}']
    # gw_a columns
    for i, p_key in enumerate(p_keys):
        sk = stat_keys[i]
        if a_data:
            val = check_detail(a_data, p_key, rounds)
            row_cols.append(right_cell(val, 3, api_widths[i]))  # 0/1 is 3 visible chars
            if a_data[p_key] > 0:
                stats[gw_a][sk] += 1
            stats[gw_a]['total'] += 1
        else:
            row_cols.append(dash_cell(api_widths[i]))
    row_cols.append(' ' * W_GAP)
    # gw_b columns
    for i, p_key in enumerate(p_keys):
        sk = stat_keys[i]
        if b_data:
            val = check_detail(b_data, p_key, rounds)
            row_cols.append(right_cell(val, 3, api_widths[i]))
            if b_data[p_key] > 0:
                stats[gw_b][sk] += 1
            stats[gw_b]['total'] += 1
        else:
            row_cols.append(dash_cell(api_widths[i]))

    print('  '.join(row_cols))

print("─" * total_width)

# ── Summary ──────────────────────────────────────────────────────
print()
print(f"{BOLD}  Summary:{NC}")
a_tested = len([m for m in all_ordered if by_model[m].get(gw_a)])
b_tested = len([m for m in all_ordered if by_model[m].get(gw_b)])
print(f"    {gw_a}:  Chat {stats[gw_a]['chat']}/{a_tested} ✓  |  Messages {stats[gw_a]['msg']}/{a_tested} ✓  |  Responses {stats[gw_a]['resp']}/{a_tested} ✓")
print(f"    {gw_b}:  Chat {stats[gw_b]['chat']}/{b_tested} ✓  |  Messages {stats[gw_b]['msg']}/{b_tested} ✓  |  Responses {stats[gw_b]['resp']}/{b_tested} ✓")
print()
PYEOF

rm -f "${RESULTS_FILE}"
exit 0
