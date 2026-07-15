#!/usr/bin/env bash
# claude_code_single.sh [model_name]
# Tests ONE model via Claude Code through the gateway using settings.json config.
# Defaults to glm-5.1 if no model is specified.
#
# Prints progress to stderr; prints a single machine-parseable result line to stdout:
#   PASS|<model>|
#   FAIL|<model>|<error message>
#
# Exits 0 on success, 1 on failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

# Default to glm-5.1 if no model is specified
MODEL="${1:-glm-5.1}"
# Per-model timeout in seconds (override with TEST_TIMEOUT env var)
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"
log_info "Testing model: ${MODEL} (timeout: ${TEST_TIMEOUT}s)"

# ── Generate settings.json ──────────────────────────────────────────
SETTINGS_FILE="$(mktemp)"
generate_settings_json "${SETTINGS_FILE}"

# ── Run Claude Code with this model ─────────────────────────────────
# --max-turns 1 keeps it to a single round-trip.
# `timeout` kills the docker run if it exceeds TEST_TIMEOUT seconds.
TIMED_OUT=0
OUTPUT="$(timeout "${TEST_TIMEOUT}" docker run --rm \
    -e ANTHROPIC_AUTH_TOKEN="${API_KEY}" \
    -v "${SETTINGS_FILE}:/root/.claude/settings.json:ro" \
    "${IMAGE_NAME}" \
    claude -p "Reply with exactly: HELLO" --output-format text --max-turns 1 --model "${MODEL}" 2>&1)" || TIMED_OUT=1

rm -f "${SETTINGS_FILE}"

# ── Handle timeout ──────────────────────────────────────────────────
if [ "${TIMED_OUT}" -ne 0 ] && [ -z "${OUTPUT}" ]; then
    log_fail "${MODEL}: timed out after ${TEST_TIMEOUT}s"
    echo "FAIL|${MODEL}|timed out after ${TEST_TIMEOUT}s"
    exit 1
fi

# ── Evaluate result ─────────────────────────────────────────────────
if [ -z "${OUTPUT}" ]; then
    log_fail "${MODEL}: empty response"
    echo "FAIL|${MODEL}|empty response"
    exit 1
fi

if echo "${OUTPUT}" | grep -qiE "(error|failed|403|401|500|unavailable|not in this user|no pricing)"; then
    ERROR_MSG="$(echo "${OUTPUT}" | head -3 | tr '\n' ' ' | sed 's/  */ /g')"
    log_fail "${MODEL}: ${ERROR_MSG}"
    echo "FAIL|${MODEL}|${ERROR_MSG}"
    exit 1
fi

log_pass "${MODEL}"
echo "PASS|${MODEL}|"
exit 0
