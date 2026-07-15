#!/usr/bin/env bash
# common.sh — Shared helpers for Claude Code integration test cases

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="harbor.isuanova.com/yangle/claude-code"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Logging ─────────────────────────────────────────────────────────
# All log functions write to stderr so stdout stays clean for machine-parseable
# output (e.g. the PASS|model| line from claude_code_single.sh).
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
require_api_key() {
    load_env_file
    # Set defaults AFTER load_env_file so .env values take precedence
    BASE_URL="${BASE_URL:-https://cuberouter.cn}"
    if [ -z "${API_KEY:-}" ]; then
        log_fail "API_KEY is required."
        log_fail "Set it in ${SCRIPT_DIR}/.env as: API_KEY=your_key"
        log_fail "Or pass it inline: API_KEY=your_key bash $0"
        exit 1
    fi
}

# ── Build the Docker image ──────────────────────────────────────────
build_image() {
    log_step "Building Docker image: ${IMAGE_NAME}"
    docker build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile.claude-code" "${SCRIPT_DIR}"
    if [ $? -ne 0 ]; then
        log_fail "Docker build failed"
        exit 1
    fi
    log_info "Image built successfully"
}

# ── Run claude-code in a container and capture output ────────────────
# Usage: run_claude <extra_docker_args> -- <claude_args>
# The container will run claude with the given prompt and return stdout.
# The API key is always injected via ANTHROPIC_AUTH_TOKEN.
run_claude() {
    local docker_args=()
    local claude_args=()
    local found_separator=false

    # Split args into docker_args and claude_args at "--"
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            found_separator=true
            continue
        fi
        if [ "$found_separator" = false ]; then
            docker_args+=("$arg")
        else
            claude_args+=("$arg")
        fi
    done

    docker run --rm \
        -e ANTHROPIC_AUTH_TOKEN="${API_KEY}" \
        "${docker_args[@]}" \
        "${IMAGE_NAME}" \
        claude "${claude_args[@]}"
}

# ── Run claude-code with settings.json ──────────────────────────────
# Usage: run_claude_with_settings <settings_json_path> <prompt>
# Mounts the given settings.json into ~/.claude/settings.json and runs claude.
run_claude_with_settings() {
    local settings_path="$1"
    local prompt="$2"

    docker run --rm \
        -e ANTHROPIC_AUTH_TOKEN="${API_KEY}" \
        -v "${settings_path}:/root/.claude/settings.json:ro" \
        "${IMAGE_NAME}" \
        claude -p "${prompt}" --output-format text
}

# ── Run claude-code with env vars only ──────────────────────────────
# Usage: run_claude_with_env <prompt>
# Passes all guide env vars as Docker env vars (no settings.json).
run_claude_with_env() {
    local prompt="$1"

    docker run --rm \
        -e ANTHROPIC_AUTH_TOKEN="${API_KEY}" \
        -e ANTHROPIC_BASE_URL="${BASE_URL}" \
        -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        -e CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
        "${IMAGE_NAME}" \
        claude -p "${prompt}" --output-format text
}

# ── Assert that output contains non-empty content ───────────────────
# Usage: assert_response <output_file>
# Checks that the output is not empty and doesn't contain obvious error markers.
assert_response() {
    local output_file="$1"
    local output
    output="$(cat "${output_file}")"

    # Check non-empty
    if [ -z "${output}" ]; then
        log_fail "Response is empty"
        return 1
    fi

    # Check for error indicators
    if echo "${output}" | grep -qiE '(error|failed|unauthorized|401|403|404|500|invalid)'; then
        log_fail "Response contains error indicators: ${output}"
        return 1
    fi

    log_pass "Response received and valid"
    return 0
}

# ── Generate a settings.json file ──────────────────────────────────
# Usage: generate_settings_json <output_path> [base_url_override]
# The API key is read from $API_KEY and written into the file.
generate_settings_json() {
    local output_path="$1"
    local base_url="${2:-${BASE_URL}}"

    cat > "${output_path}" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${base_url}",
    "ANTHROPIC_AUTH_TOKEN": "${API_KEY}",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  }
}
EOF
    log_info "Generated settings.json at ${output_path}"
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
list_chat_models() {
    log_step "Fetching available models from CubeRouter"

    local models_json
    models_json="$(curl -s "${BASE_URL}/v1/models" \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01")"

    if [ -z "${models_json}" ]; then
        log_fail "Failed to fetch models from ${BASE_URL}/v1/models"
        exit 1
    fi

    local models_file dropped_file notfound_file whitelist_file whitelist_flag
    models_file="$(mktemp)"
    dropped_file="$(mktemp)"
    notfound_file="$(mktemp)"
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
        WHITELIST_FLAG="${whitelist_flag}" python3 -c "
import json, os, re, sys
data = json.load(sys.stdin)
EXCLUDE_PATTERNS = [
    r'-tts-', r'^tts-', r'-image-', r'^image-', r'dall-e',
    r'-video-', r'^video-', r'sora', r'seedance', r'embed', r'-vision',
]
def is_chat(m):
    mid = m['id'].lower()
    for pat in EXCLUDE_PATTERNS:
        if re.search(pat, mid):
            return False
    return True

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
     open(os.environ['NOTFOUND_FILE'], 'w') as notfound:
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

    local models
    models="$(cat "${models_file}")"
    LIST_CHAT_MODELS_COUNT="$(echo "${models}" | wc -l)"

    if [ -z "${models}" ]; then
        log_fail "No suitable models found"
        rm -f "${models_file}" "${dropped_file}" "${notfound_file}"
        exit 1
    fi

    if [ "${whitelist_flag}" = "1" ]; then
        log_info "Whitelist active (${whitelist_file}) — testing ${LIST_CHAT_MODELS_COUNT} whitelisted model(s)"
    else
        log_info "Found ${LIST_CHAT_MODELS_COUNT} suitable (chat) models"
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

# ── Print a results summary table ───────────────────────────────────
# Usage: print_summary_table <results_file> <passed> <total> <summary_label>
# <summary_label> e.g. "models support Claude Code" or "models support chat completions"
print_summary_table() {
    local results_file="$1"
    local passed="$2"
    local total="$3"
    local summary_label="$4"
    local title="$5"

    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  ${title}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    python3 - "${results_file}" "${passed}" "${total}" "${summary_label}" <<'PYEOF'
import sys

GREEN = '\033[32m'
RED = '\033[31m'
BOLD = '\033[1m'
NC = '\033[0m'

results_file = sys.argv[1]
passed = int(sys.argv[2])
total = int(sys.argv[3])
summary_label = sys.argv[4]

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
print(f"\n  {BOLD}Summary: {passed}/{total} {summary_label}{NC}")
PYEOF

    echo ""
}
