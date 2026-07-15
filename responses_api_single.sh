#!/usr/bin/env bash
# responses_api_single.sh [model_name]
# Tests ONE model via the OpenAI Responses API (/v1/responses) through the gateway.
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
log_info "Testing model (Responses API): ${MODEL} (timeout: ${TEST_TIMEOUT}s)"

# ── Call the Responses API ────────────────────────────────────────────
# Uses a timeout so a hanging model can't block the sweep.
RESPONSE_FILE="$(mktemp)"
HTTP_CODE="$(curl -s -o "${RESPONSE_FILE}" -w "%{http_code}" \
    --max-time "${TEST_TIMEOUT}" \
    -X POST "${BASE_URL}/v1/responses" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"input\":\"Reply with exactly: HELLO\",\"max_output_tokens\":500}")"
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
# OpenAI Responses API response shape:
#   success: {"id":"resp_...","object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"..."}]}],...}
#   error:   {"error":{"code":"...","message":"..."}}
PARSED="$(printf '%s' "${RESPONSE}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print('PARSE_ERROR||' + str(e))
    sys.exit(0)

# Check for error object (error can be null on success, so skip None)
if data.get('error') is not None:
    err = data['error']
    if isinstance(err, dict):
        msg = err.get('message', str(err))
    else:
        msg = str(err)
    print('API_ERROR||' + str(msg).replace('\n', ' '))
    sys.exit(0)

# Check for failed/incomplete status
status = data.get('status', '')
if status in ('failed', 'incomplete', 'cancelled'):
    err = data.get('error', {})
    msg = ''
    if isinstance(err, dict):
        msg = err.get('message', str(err))
    else:
        msg = str(err) if err else status
    print('API_ERROR||' + str(msg).replace('\n', ' '))
    sys.exit(0)

# Extract text from output[].content[].text (type == output_text)
output = data.get('output', [])
if not output:
    print('FAIL||empty output')
    sys.exit(0)

text = ''
for item in output:
    if isinstance(item, dict) and item.get('type') == 'message':
        content = item.get('content', [])
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'output_text':
                text = block.get('text', '')
                break
        if text:
            break

if not text:
    print('FAIL||no output_text in response')
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
