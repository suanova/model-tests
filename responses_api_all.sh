#!/usr/bin/env bash
# responses_api_all.sh
# Iterates over all suitable (text/chat) models and runs
# responses_api_single.sh for each, testing the OpenAI Responses API
# (/v1/responses) directly with curl. Outputs a results table + summary.
#
# Excludes non-chat models: TTS, image generation, video, embedding.
# Respects whitelist.txt if present.
#
# Config:
#   TEST_TIMEOUT  per-model timeout in seconds (default 30)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

TEST_NAME="Responses API — all-models sweep"
log_info "${TEST_NAME}"
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
    # (the PASS|model|... line) is captured for the summary table.
    LINE_FILE="$(mktemp)"
    bash "${SCRIPT_DIR}/responses_api_single.sh" "${model}" > "${LINE_FILE}" || true
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
    "models support the Responses API" \
    "Responses API — Model Test Results" \
    "${TOTAL_MODELS_FETCHED}" "${TOTAL_MODELS_IGNORED}"

rm -f "${RESULTS_FILE}"

if [ "${PASSED}" -eq 0 ]; then
    log_fail "No models support the Responses API"
    exit 1
fi

log_info "${PASSED}/${TOTAL} models support the Responses API"
exit 0
