#!/usr/bin/env bash
# common.sh — Shared helpers for API model test scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Logging ─────────────────────────────────────────────────────────
# All log functions write to stderr so stdout stays clean for machine-parseable output.
log_info()  { echo -e "${CYAN}[INFO]${NC}  $1" >&2; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $1" >&2; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $1" >&2; }
log_step()  { echo -e "${YELLOW}[STEP]${NC} $1" >&2; }

# ── Load .env file ──────────────────────────────────────────────────
# Looks for a .env file in the script directory. If present, exports its
# variables (KEY=VALUE lines) into the environment, but only if not already
# set — so explicit env vars always take precedence over the file.
#
# IMPORTANT: This must be called BEFORE any defaults are set, so that .env
# values override hardcoded defaults. The call order is:
#   1. source common.sh  (no defaults yet)
#   2. require_api_key   → load_env_file  → exports from .env
#   3. Then set defaults for anything still unset (BASE_URL, etc.)
load_env_file() {
    local env_file="${SCRIPT_DIR}/.env"
    if [ -f "${env_file}" ]; then
        while IFS='=' read -r key value || [ -n "${key}" ]; do
            # Skip blank lines and comments
            [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
            # Trim surrounding whitespace/quotes from key and value
            key="${key%%[[:space:]]}"
            value="${value#[[:space:]]}"
            # Strip surrounding single or double quotes
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            # Don't override an already-set env var
            if [ -z "${!key:-}" ]; then
                export "${key}=${value}"
            fi
        done < "${env_file}"
    fi
}

# ── Require API key ─────────────────────────────────────────────────
# Optionally logs config info (API key source, base URL, whitelist status).
# Set QUIET=1 to suppress the config info log — used when a single-model
# script is invoked by an *_all.sh parent so the info isn't repeated N times.
require_api_key() {
    # Track where API_KEY came from before .env loading
    local api_key_source="environment variable"
    local api_key_was_set=0
    if [ -n "${API_KEY:-}" ]; then
        api_key_was_set=1
    fi

    load_env_file
    # Set defaults AFTER load_env_file so .env values take precedence
    BASE_URL="${BASE_URL:-https://cuberouter.cn}"
    # Strip trailing slash so ${BASE_URL}/v1/models never becomes a double-slash
    BASE_URL="${BASE_URL%/}"

    # Determine API key source after loading
    if [ "${api_key_was_set}" -eq 1 ]; then
        api_key_source="environment variable"
    elif [ -f "${SCRIPT_DIR}/.env" ]; then
        api_key_source=".env file"
    fi

    if [ -z "${API_KEY:-}" ]; then
        log_fail "API_KEY is required."
        log_fail "Set it in ${SCRIPT_DIR}/.env as: API_KEY=your_key"
        log_fail "Or pass it inline: API_KEY=your_key bash $0"
        exit 1
    fi

    # Log configuration info (only when not running as a child process)
    if [ "${QUIET:-0}" -eq 0 ]; then
        log_info "API key loaded from: ${api_key_source}"
        log_info "Base URL: ${BASE_URL}"
        if [ -f "${SCRIPT_DIR}/whitelist.txt" ]; then
            log_info "Whitelist: ${SCRIPT_DIR}/whitelist.txt (active)"
        fi
    fi
}

# ── Timing helpers (curl write-out → result line) ──────────────────
# Each single-model script captures curl's time_connect, time_starttransfer,
# and time_total, and appends a timing field to its result line so the
# aggregating scripts (run_all_api_tests.sh, compare_gateways.sh) can average
# latency across rounds.
#
# Result line format: STATUS|MODEL|TIMING|DETAIL
#   TIMING = conn=<ms>;ttfb=<ms>;tot=<ms>   (raw integer milliseconds)
#   conn  ← time_connect         (TCP connect)
#   ttfb  ← time_starttransfer   (time to first byte)
#   tot   ← time_total           (end-to-end)

# Convert a curl seconds-float to integer milliseconds (locale-safe).
_to_ms() {
    awk -v t="${1:-0}" 'BEGIN{
        if (t ~ /^[0-9]*\.?[0-9]+$/) printf "%d", (t * 1000) + 0.5;
        else print 0
    }'
}

# Build the TIMING field from curl's three timing values (seconds, floats).
# Usage: build_timing_field <time_connect> <time_starttransfer> <time_total>
build_timing_field() {
    local conn ttfb tot
    conn="$(_to_ms "${1:-0}")"
    ttfb="$(_to_ms "${2:-0}")"
    tot="$(_to_ms "${3:-0}")"
    echo "conn=${conn};ttfb=${ttfb};tot=${tot}"
}

# Extract a timing metric (ms) from a single-script result line.
# Usage: extract_timing <conn|ttfb|tot> <line>
# Prints the ms integer, or empty if absent (e.g. no timing on the line).
extract_timing() {
    printf '%s' "$2" | grep -oE "$1=[0-9]+" | head -n1 | cut -d= -f2
}

# ── List chat models from the gateway ───────────────────────────────
# Fetches /v1/models, filters out non-chat models (TTS, image, video, embedding,
# vision-only), and applies the whitelist (whitelist.txt) if present.
#
# Prints the kept model IDs to stdout (one per line).
# Logs skipped and not-found models to stderr.
#
# Usage: list_chat_models
# Sets global: LIST_CHAT_MODELS_COUNT (number of kept models)
#             TOTAL_MODELS_FETCHED (total from gateway)
#             TOTAL_MODELS_IGNORED (filtered out as non-chat)
list_chat_models() {
    log_step "Fetching available models from the gateway"

    local http_code models_json
    models_json="$(curl -s -w "\n__HTTP_CODE__%{http_code}" "${BASE_URL}/v1/models" \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01")"

    # Split the appended HTTP status code from the response body
    http_code="$(echo "${models_json}" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')"
    models_json="$(echo "${models_json}" | sed '/__HTTP_CODE__/d')"

    if [ -z "${models_json}" ]; then
        log_fail "Failed to fetch models from ${BASE_URL}/v1/models (HTTP ${http_code:-unknown})"
        exit 1
    fi

    # Verify the response looks like JSON — if not, log a snippet and exit
    local first_char
    first_char="$(printf '%s' "${models_json}" | head -c 1)"
    if [ "${first_char}" != "{" ] && [ "${first_char}" != "[" ]; then
        log_fail "Response from ${BASE_URL}/v1/models is not JSON (HTTP ${http_code:-unknown})"
        log_fail "Response snippet: $(printf '%s' "${models_json}" | head -c 300)"
        exit 1
    fi

    local models_file dropped_file notfound_file whitelist_file whitelist_flag total_file
    models_file="$(mktemp)"
    dropped_file="$(mktemp)"
    notfound_file="$(mktemp)"
    total_file="$(mktemp)"
    whitelist_file="${SCRIPT_DIR}/whitelist.txt"
    whitelist_flag="0"
    if [ -f "${whitelist_file}" ]; then
        whitelist_flag="1"
    fi

    local json_file
    json_file="$(mktemp)"
    printf '%s' "${models_json}" > "${json_file}"

    MODELS_FILE="${models_file}" DROPPED_FILE="${dropped_file}" \
        NOTFOUND_FILE="${notfound_file}" WHITELIST_FILE="${whitelist_file}" \
        WHITELIST_FLAG="${whitelist_flag}" TOTAL_FILE="${total_file}" \
        python3 -c "
import json, os, re, sys
data = json.load(sys.stdin)
EXCLUDE_PATTERNS = [
    r'-tts-', r'^tts-', r'-image-', r'^image-', r'dall-e',
    r'-video-', r'^video-', r'sora', r'seedance', r'embed', r'-vision',
    r'-ocr-', r'^ocr-', r'-asr-', r'^asr-', r'-audio-', r'^audio-',
]
def is_chat(m):
    mid = m['id'].lower()
    for pat in EXCLUDE_PATTERNS:
        if re.search(pat, mid):
            return False
    return True

total = len(data.get('data', []))
chat_models = [m['id'] for m in data.get('data', []) if is_chat(m)]

whitelist = None
if os.environ.get('WHITELIST_FLAG') == '1':
    wl_path = os.environ['WHITELIST_FILE']
    whitelist = set()
    with open(wl_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                whitelist.add(line)

with open(os.environ['MODELS_FILE'], 'w') as kept, \
     open(os.environ['DROPPED_FILE'], 'w') as dropped, \
     open(os.environ['NOTFOUND_FILE'], 'w') as notfound, \
     open(os.environ['TOTAL_FILE'], 'w') as total_file:
    total_file.write(str(total) + '\n')
    for m in data.get('data', []):
        if not is_chat(m):
            dropped.write(m['id'] + '\n')
            continue
        if whitelist is not None:
            if m['id'] in whitelist:
                kept.write(m['id'] + '\n')
            else:
                dropped.write(m['id'] + '\n')
        else:
            kept.write(m['id'] + '\n')
    if whitelist is not None:
        found = set(chat_models)
        for wl in sorted(whitelist):
            if wl not in found:
                notfound.write(wl + '\n')
" < "${json_file}"

    rm -f "${json_file}"

    local models total_fetched dropped_count
    models="$(cat "${models_file}")"
    total_fetched="$(cat "${total_file}")"
    rm -f "${total_file}"
    LIST_CHAT_MODELS_COUNT="$(echo "${models}" | wc -l)"
    dropped_count="$(wc -l < "${dropped_file}" | tr -d ' ')"
    TOTAL_MODELS_FETCHED="${total_fetched}"
    TOTAL_MODELS_IGNORED="${dropped_count}"

    if [ -z "${models}" ]; then
        log_fail "No suitable models found"
        rm -f "${models_file}" "${dropped_file}" "${notfound_file}"
        exit 1
    fi

    if [ "${whitelist_flag}" = "1" ]; then
        log_info "Whitelist active (${whitelist_file}) — testing ${LIST_CHAT_MODELS_COUNT} whitelisted model(s)"
    else
        log_info "${total_fetched} models fetched, ${dropped_count} ignored, ${LIST_CHAT_MODELS_COUNT} kept for testing"
    fi
    if [ -s "${dropped_file}" ]; then
        log_info "Skipped models:"
        sed 's/^/  - /' "${dropped_file}" >&2
    fi
    if [ -s "${notfound_file}" ]; then
        log_info "Whitelisted models NOT found in gateway (skipped):"
        sed 's/^/  - /' "${notfound_file}" >&2
    fi

    rm -f "${dropped_file}" "${notfound_file}"
    # NOTE: models_file is kept; caller must rm it. But since we echo models to
    # stdout, the caller doesn't need the file.
    rm -f "${models_file}"

    echo "${models}"
}

# ── Fetch model list from an arbitrary gateway ──────────────────────
# Like list_chat_models but takes base_url and api_key as explicit
# arguments (no reliance on globals). Applies the same non-chat filtering.
# Optionally applies a whitelist if whitelist_file is provided.
# Does not exit on failure; returns non-zero so the caller can decide.
#
# Usage: fetch_model_list <base_url> <api_key> [label] [whitelist_file]
#   label          — optional display name for logs (e.g. "Gateway A")
#   whitelist_file — optional path to whitelist.txt; if provided and the
#                    file exists, only whitelisted chat models are kept
# Prints kept model IDs to stdout (one per line).
# Sets global: FETCH_MODELS_COUNT, FETCH_TOTAL, FETCH_IGNORED
fetch_model_list() {
    local base_url="$1"
    local api_key="$2"
    local label="${3:-gateway}"
    local whitelist_file="${4:-}"
    # Strip trailing slash
    base_url="${base_url%/}"

    log_step "Fetching models from ${label} (${base_url})"

    local http_code models_json
    models_json="$(curl -s -w "\n__HTTP_CODE__%{http_code}" "${base_url}/v1/models" \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01")"

    http_code="$(echo "${models_json}" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')"
    models_json="$(echo "${models_json}" | sed '/__HTTP_CODE__/d')"

    if [ -z "${models_json}" ]; then
        log_fail "Failed to fetch models from ${base_url}/v1/models (HTTP ${http_code:-unknown})"
        return 1
    fi

    local first_char
    first_char="$(printf '%s' "${models_json}" | head -c 1)"
    if [ "${first_char}" != "{" ] && [ "${first_char}" != "[" ]; then
        log_fail "Response from ${base_url}/v1/models is not JSON (HTTP ${http_code:-unknown})"
        log_fail "Response snippet: $(printf '%s' "${models_json}" | head -c 300)"
        return 1
    fi

    local models_file dropped_file notfound_file total_file json_file
    models_file="$(mktemp)"
    dropped_file="$(mktemp)"
    notfound_file="$(mktemp)"
    total_file="$(mktemp)"
    json_file="$(mktemp)"
    printf '%s' "${models_json}" > "${json_file}"

    # Determine whitelist flag: 1 if whitelist_file is provided AND exists
    local whitelist_flag="0"
    if [ -n "${whitelist_file}" ] && [ -f "${whitelist_file}" ]; then
        whitelist_flag="1"
    fi

    MODELS_FILE="${models_file}" DROPPED_FILE="${dropped_file}" \
        NOTFOUND_FILE="${notfound_file}" WHITELIST_FILE="${whitelist_file}" \
        WHITELIST_FLAG="${whitelist_flag}" TOTAL_FILE="${total_file}" \
        python3 -c "
import json, os, re, sys
data = json.load(sys.stdin)
EXCLUDE_PATTERNS = [
    r'-tts-', r'^tts-', r'-image-', r'^image-', r'dall-e',
    r'-video-', r'^video-', r'sora', r'seedance', r'embed', r'-vision',
    r'-ocr-', r'^ocr-', r'-asr-', r'^asr-', r'-audio-', r'^audio-',
]
def is_chat(m):
    mid = m['id'].lower()
    for pat in EXCLUDE_PATTERNS:
        if re.search(pat, mid):
            return False
    return True

total = len(data.get('data', []))
chat_models = [m['id'] for m in data.get('data', []) if is_chat(m)]
nonchat_count = len(data.get('data', [])) - len(chat_models)

whitelist = None
notwl_count = 0
if os.environ.get('WHITELIST_FLAG') == '1':
    wl_path = os.environ['WHITELIST_FILE']
    whitelist = set()
    with open(wl_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                whitelist.add(line)
    notwl_count = len(chat_models) - sum(1 for m in chat_models if m in whitelist)

with open(os.environ['MODELS_FILE'], 'w') as kept, \
     open(os.environ['DROPPED_FILE'], 'w') as dropped, \
     open(os.environ['NOTFOUND_FILE'], 'w') as notfound, \
     open(os.environ['TOTAL_FILE'], 'w') as total_file:
    total_file.write(str(total) + '\n')
    for m in data.get('data', []):
        if not is_chat(m):
            dropped.write(m['id'] + '\n')
            continue
        if whitelist is not None:
            if m['id'] in whitelist:
                kept.write(m['id'] + '\n')
            else:
                dropped.write(m['id'] + '\n')
        else:
            kept.write(m['id'] + '\n')
    if whitelist is not None:
        found = set(chat_models)
        for wl in sorted(whitelist):
            if wl not in found:
                notfound.write(wl + '\n')

# Write breakdown counts to separate env-passthrough files
with open(os.environ['TOTAL_FILE'] + '_nonchat', 'w') as f:
    f.write(str(nonchat_count) + '\n')
if whitelist is not None:
    with open(os.environ['TOTAL_FILE'] + '_notwl', 'w') as f:
        f.write(str(notwl_count) + '\n')
else:
    with open(os.environ['TOTAL_FILE'] + '_notwl', 'w') as f:
        f.write('0\n')
" < "${json_file}"

    rm -f "${json_file}"

    local models total_fetched dropped_count
    models="$(cat "${models_file}")"
    total_fetched="$(cat "${total_file}")"
    rm -f "${total_file}"
    dropped_count="$(wc -l < "${dropped_file}" | tr -d ' ')"
    FETCH_NONCHAT="$(cat "${dropped_file}_nonchat" 2>/dev/null || echo "${dropped_count}")"
    rm -f "${dropped_file}_nonchat"
    FETCH_NOTWL="$(cat "${dropped_file}_notwl" 2>/dev/null || echo "0")"
    rm -f "${dropped_file}_notwl"
    FETCH_MODELS_COUNT=0
    FETCH_TOTAL="${total_fetched}"
    FETCH_IGNORED="${dropped_count}"

    if [ -z "${models}" ]; then
        log_fail "No suitable models found on ${label}"
        rm -f "${models_file}" "${dropped_file}" "${notfound_file}"
        return 1
    fi

    FETCH_MODELS_COUNT="$(echo "${models}" | wc -l)"

    if [ "${whitelist_flag}" = "1" ]; then
        log_info "Whitelist active (${whitelist_file}) — ${label}: ${FETCH_MODELS_COUNT} whitelisted model(s)"
    else
        log_info "${label}: ${total_fetched} models fetched, ${dropped_count} ignored, ${FETCH_MODELS_COUNT} kept for testing"
    fi
    if [ -s "${dropped_file}" ]; then
        log_info "${label} — Skipped models:"
        sed 's/^/  - /' "${dropped_file}" >&2
    fi
    if [ -s "${notfound_file}" ]; then
        log_info "${label} — Whitelisted models NOT found (skipped):"
        sed 's/^/  - /' "${notfound_file}" >&2
    fi

    rm -f "${dropped_file}" "${notfound_file}" "${models_file}"

    echo "${models}"
    return 0
}

# ── Print a results summary table ───────────────────────────────────
# Usage: print_summary_table <results_file> <passed> <tested> <summary_label> <title> [<fetched> <ignored>]
# <fetched> and <ignored> are optional; when provided, the summary line
# includes "N fetched, M ignored, K tested, P/N support …".
print_summary_table() {
    local results_file="$1"
    local passed="$2"
    local tested="$3"
    local summary_label="$4"
    local title="$5"
    local fetched="${6:-}"
    local ignored="${7:-}"

    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  ${title}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    python3 - "${results_file}" "${passed}" "${tested}" "${summary_label}" "${fetched}" "${ignored}" <<'PYEOF'
import sys

GREEN = '\033[32m'
RED = '\033[31m'
BOLD = '\033[1m'
NC = '\033[0m'

results_file = sys.argv[1]
passed = int(sys.argv[2])
tested = int(sys.argv[3])
summary_label = sys.argv[4]
fetched = sys.argv[5] if len(sys.argv) > 5 else ''
ignored = sys.argv[6] if len(sys.argv) > 6 else ''

with open(results_file) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]

print(f"{BOLD}{'#':<4} {'Model':<42} {'Result':<8} {'Reply / Error'}{NC}")
print("-" * 85)

for idx, line in enumerate(lines, 1):
    parts = line.split('|', 2)
    status = parts[0] if len(parts) > 0 else '?'
    model = parts[1] if len(parts) > 1 else '?'
    detail = parts[2] if len(parts) > 2 else ''
    if status == 'PASS':
        result_str = f'{GREEN}{"PASS":<8}{NC}'
    else:
        result_str = f'{RED}{"FAIL":<8}{NC}'
    if len(detail) > 45:
        detail = detail[:42] + '...'
    print(f"{idx:<4} {model:<42} {result_str} {detail}")

print("-" * 85)
if fetched and ignored:
    print(f"\n  {BOLD}Summary: {fetched} fetched, {ignored} ignored, {tested} tested — {passed}/{tested} {summary_label}{NC}")
else:
    print(f"\n  {BOLD}Summary: {passed}/{tested} {summary_label}{NC}")
PYEOF

    echo ""
}
