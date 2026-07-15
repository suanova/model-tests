#!/usr/bin/env bash
# messages_api_single.sh [model_name]
# Tests ONE model via the Anthropic Messages API (/v1/messages) through the gateway.
# This is the same API that Claude Code uses, but tested directly with curl (no Docker)
# to isolate the gateway/API layer from the Claude Code client.
#
# Prints progress to stderr; prints a single machine-parseable result line to stdout:
#   PASS|<model>|<reply>
#   FAIL|<model>|<error message>
#
# Exits 0 on success, 1 on failure.
#
# Config:
#   TEST_TIMEOUT  per-model timeout in seconds (default 30)
#   BASE_URL      gateway base URL (default https://cuberouter.cn)
#   API_KEY  API key (from env or .env)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

# Default to glm-5.1 if no model is specified
MODEL="${1:-glm-5.1}"
# Per-model timeout in seconds (override with TEST_TIMEOUT env var)
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"
log_info "Testing model (Anthropic Messages API): ${MODEL} (timeout: ${TEST_TIMEOUT}s)"

# ── Call the Anthropic Messages API ─────────────────────────────────
RESPONSE_FILE="$(mktemp)"
HTTP_CODE="$(curl -s -o "${RESPONSE_FILE}" -w "%{http_code}" \
    --max-time "${TEST_TIMEOUT}" \
    -X POST "${BASE_URL}/v1/messages" \
    -H "x-api-key: ${API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"max_tokens\":200,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: HELLO\"}]}")"
CURL_EXIT=$?

RESPONSE="$(cat "${RESPONSE_FILE}")"
rm -f "${RESPONSE_FILE}"

# ── Handle curl failure (timeout, connection error) ─────────────────
if [ "${CURL_EXIT}" -ne 0 ]; then
    if [ "${CURL_EXIT}" -eq 28 ]; then
        log_fail "${MODEL}: timed out after ${TEST_TIMEOUT}s"
        echo "FAIL|${MODEL}|timed out after ${TEST_TIMEOUT}s"
    else
        log_fail "${MODEL}: curl error (exit ${CURL_EXIT})"
        echo "FAIL|${MODEL}|curl error (exit ${CURL_EXIT})"
    fi
    exit 1
fi

# ── Parse the response ──────────────────────────────────────────────
# Anthropic Messages API response shape:
#   success: {"content": [{"type":"text","text":"..."}], ...}
#   error:   {"type":"error","error":{"type":"...","message":"..."}} or {"error":...}
PARSED="$(printf '%s' "${RESPONSE}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print('PARSE_ERROR||' + str(e))
    sys.exit(0)

# Check for error object (Anthropic-style or generic)
if data.get('type') == 'error' and 'error' in data:
    err = data['error']
    msg = err.get('message', str(err)) if isinstance(err, dict) else str(err)
    print('API_ERROR||' + str(msg).replace('\n', ' '))
    sys.exit(0)
if 'error' in data:
    err = data['error']
    msg = err.get('message', str(err)) if isinstance(err, dict) else str(err)
    print('API_ERROR||' + str(msg).replace('\n', ' '))
    sys.exit(0)

# Extract text from content[0].text
content = data.get('content', [])
if not content:
    print('FAIL||empty content')
    sys.exit(0)

# content is a list of blocks; find the first text block
text = ''
for block in content:
    if isinstance(block, dict) and block.get('type') == 'text':
        text = block.get('text', '')
        break
if not text:
    print('FAIL||no text block in content')
    sys.exit(0)

# Success — single line, pipe-safe
print('OK||' + str(text).replace('\n', ' '))
" 2>&1)"

STATUS="$(printf '%s' "${PARSED}" | cut -d'|' -f1)"
DETAIL="$(printf '%s' "${PARSED}" | cut -d'|' -f3-)"

# ── Evaluate result ─────────────────────────────────────────────────
case "${STATUS}" in
    OK)
        log_pass "${MODEL}"
        echo "PASS|${MODEL}|${DETAIL}"
        exit 0
        ;;
    PARSE_ERROR)
        log_fail "${MODEL}: invalid JSON response"
        echo "FAIL|${MODEL}|invalid JSON: ${DETAIL}"
        exit 1
        ;;
    API_ERROR)
        log_fail "${MODEL}: ${DETAIL}"
        echo "FAIL|${MODEL}|${DETAIL}"
        exit 1
        ;;
    FAIL)
        log_fail "${MODEL}: ${DETAIL}"
        echo "FAIL|${MODEL}|${DETAIL}"
        exit 1
        ;;
    *)
        # Non-200 HTTP with an unparseable/empty body
        if [ "${HTTP_CODE}" != "200" ]; then
            ERR_SNIPPET="$(printf '%s' "${RESPONSE}" | head -c 200 | tr '\n' ' ')"
            log_fail "${MODEL}: HTTP ${HTTP_CODE}"
            echo "FAIL|${MODEL}|HTTP ${HTTP_CODE}: ${ERR_SNIPPET}"
        else
            log_fail "${MODEL}: unexpected response"
            echo "FAIL|${MODEL}|unexpected response: ${PARSED}"
        fi
        exit 1
        ;;
esac
