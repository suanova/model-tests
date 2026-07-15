#!/usr/bin/env bash
# entrypoint.sh — maps docker run subcommands to the test scripts.
#
# Usage:
#   docker run --rm -e API_KEY=sk-... <image> [subcommand] [args...]
#
# Subcommands:
#   all [rounds]          Run both APIs across all models (default). Rounds default to 1.
#   chat                  Run chat completions API across all models.
#   messages              Run Anthropic Messages API across all models.
#   chat-single [model]   Run chat completions API for one model (defaults to glm-5.1).
#   messages-single [model]  Run Anthropic Messages API for one model (defaults to glm-5.1).
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
  all [rounds]              Run both APIs (chat + messages) across all models.
                            Rounds default to 1. A model "supports" an API if it
                            passes at least once across all rounds.
  chat                      Run chat completions API (/v1/chat/completions) across all models.
  messages                  Run Anthropic Messages API (/v1/messages) across all models.
  chat-single [model]       Run chat completions API for one model (defaults to glm-5.1).
  messages-single [model]   Run Anthropic Messages API for one model (defaults to glm-5.1).
  help                      Show this help.

Environment:
  API_KEY        Required. Your API key (pass via -e API_KEY=...).
  BASE_URL       Optional. Gateway base URL (defaults to https://cuberouter.cn).
  TEST_TIMEOUT   Optional. Per-model timeout in seconds (defaults to 30).

Examples:
  docker run --rm -e API_KEY=sk-... <image>
  docker run --rm -e API_KEY=sk-... <image> all 3
  docker run --rm -e API_KEY=sk-... <image> chat
  docker run --rm -e API_KEY=sk-... <image> messages-single glm-5.1
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
    chat-single)
        exec bash "$SCRIPT_DIR/chat_api_single.sh" "$@"
        ;;
    messages-single)
        exec bash "$SCRIPT_DIR/messages_api_single.sh" "$@"
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
