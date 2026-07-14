#!/usr/bin/env bash
# claude_code_all.sh
# Iterates over all suitable (text/chat) models from CubeRouter and runs
# claude_code_single.sh for each, testing Claude Code support (Anthropic
# /v1/messages via the Claude Code client in Docker). Outputs a results table
# + summary.
#
# Excludes non-chat models: TTS, image generation, video, embedding.
# Respects whitelist.txt if present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

log_info "Claude Code support — all-models sweep"
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

TOTAL="$(echo "${MODELS}" | wc -l)"
echo ""

# ── Run single-model test for each, collect results ─────────────────
RESULTS_FILE="$(mktemp)"
PASSED=0
FAILED=0
i=0

for model in ${MODELS}; do
    i=$((i + 1))
    echo -e "${BOLD}[${i}/${TOTAL}] ${model}${NC}" >&2

    # Run single-model case. Stderr (live logs) streams to terminal; stdout
    # (the machine-parseable PASS|model|... line) is captured for the summary table.
    LINE_FILE="$(mktemp)"
    bash "${SCRIPT_DIR}/claude_code_single.sh" "${model}" > "${LINE_FILE}" || true
    RESULT_LINE="$(grep -E '^(PASS|FAIL)\|' "${LINE_FILE}" | tail -1)"
    rm -f "${LINE_FILE}"
    echo "${RESULT_LINE}" >> "${RESULTS_FILE}"

    if echo "${RESULT_LINE}" | grep -q "^PASS|"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    echo "" >&2
done

# ── Output summary table ────────────────────────────────────────────
print_summary_table "${RESULTS_FILE}" "${PASSED}" "${TOTAL}" \
    "models support Claude Code" \
    "Claude Code Compatibility — Model Test Results"

rm -f "${RESULTS_FILE}"

if [ "${PASSED}" -eq 0 ]; then
    log_fail "No models support Claude Code"
    exit 1
fi

log_info "${PASSED}/${TOTAL} models support Claude Code"
exit 0
