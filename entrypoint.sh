#!/usr/bin/env bash
# entrypoint.sh — maps docker run subcommands to the test scripts.
#
# Usage:
#   docker run --rm -e API_KEY=sk-... <image> [subcommand] [args...]
#
# Subcommands:
#   all [rounds]           Run all APIs across all models (default). Rounds default to 1.
#   chat                   Run chat completions API across all models.
#   messages               Run Anthropic Messages API across all models.
#   responses              Run OpenAI Responses API across all models.
#   compare [rounds]       Compare two gateways: shared, A-only, B-only models across all 3 APIs.
#                         Requires API_KEY_B and BASE_URL_B (or --b-key/--b-url flags).
#   chat-single [model]   Run chat completions API for one model (defaults to glm-5.1).
#   messages-single [model]  Run Anthropic Messages API for one model (defaults to glm-5.1).
#   responses-single [model]  Run OpenAI Responses API for one model (defaults to glm-5.1).
#   help                  Show this help.

set -uo pipefail

SCRIPT_DIR="/app"

# If no subcommand, default to "all"
SUBCMD="${1:-all}"
if [ "$#" -gt 0 ]; then
    shift
fi

print_help() {
    cat <<'EOF'
API model test runner

Usage: docker run --rm -e API_KEY=sk-... <image> [subcommand] [args...]

Subcommands:
  all [rounds]           Run Chat + Messages + Responses APIs across all models.
                         Rounds default to 1. A model "supports" an API if it
                         passes at least once across all rounds.
  chat                      Run chat completions API (/v1/chat/completions) across all models.
  messages                  Run Anthropic Messages API (/v1/messages) across all models.
  responses                 Run OpenAI Responses API (/v1/responses) across all models.
  compare [rounds] [--b-key KEY] [--b-url URL]
                            Compare two gateways (A = API_KEY/BASE_URL, B = API_KEY_B/BASE_URL_B).
                            Tests shared models on both gateways, A-only/B-only on their own.
                            Rounds default to 1.
  chat-single [model]       Run chat completions API for one model (defaults to glm-5.1).
  messages-single [model]   Run Anthropic Messages API for one model (defaults to glm-5.1).
  responses-single [model]  Run OpenAI Responses API for one model (defaults to glm-5.1).
  help                      Show this help.

Environment:
  API_KEY        Required. Your API key for gateway A (pass via -e API_KEY=...).
  BASE_URL       Optional. Gateway A base URL (defaults to https://cuberouter.cn).
  API_KEY_B      Required for "compare". API key for gateway B.
  BASE_URL_B     Required for "compare". Base URL for gateway B.
  TEST_TIMEOUT   Optional. Per-model timeout in seconds (defaults to 30).

  Instead of passing multiple -e flags, you can mount a .env file:
    docker run --rm -v "$PWD/.env:/app/.env:ro" <image> compare

Examples:
  docker run --rm -e API_KEY=sk-... <image>
  docker run --rm -e API_KEY=sk-... <image> all 3
  docker run --rm -e API_KEY=sk-... <image> chat
  docker run --rm -e API_KEY=sk-... <image> messages
  docker run --rm -e API_KEY=sk-... <image> responses
  docker run --rm -v .env:/app/.env:ro <image> compare
  docker run --rm -e API_KEY=sk-... <image> responses-single glm-5.1
EOF
}

case "$SUBCMD" in
    all)
        exec bash "$SCRIPT_DIR/run_all_api_tests.sh" "$@"
        ;;
    chat)
        exec bash "$SCRIPT_DIR/chat_api_all.sh" "$@"
        ;;
    messages)
        exec bash "$SCRIPT_DIR/messages_api_all.sh" "$@"
        ;;
    responses)
        exec bash "$SCRIPT_DIR/responses_api_all.sh" "$@"
        ;;
    compare)
        exec bash "$SCRIPT_DIR/compare_gateways.sh" "$@"
        ;;
    chat-single)
        exec bash "$SCRIPT_DIR/chat_api_single.sh" "$@"
        ;;
    messages-single)
        exec bash "$SCRIPT_DIR/messages_api_single.sh" "$@"
        ;;
    responses-single)
        exec bash "$SCRIPT_DIR/responses_api_single.sh" "$@"
        ;;
    help|-h|--help)
        print_help
        exit 0
        ;;
    *)
        echo "Unknown subcommand: $SUBCMD" >&2
        echo "" >&2
        print_help >&2
        exit 1
        ;;
esac
