#!/usr/bin/env bash
# run_claude_code_tests.sh — Run the Claude Code model sweep.
# Usage: bash run_claude_code_tests.sh   (key from .env or API_KEY env var)
#
# Builds the Docker image, then runs claude_code_all.sh (all suitable models
# via the Claude Code client).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_api_key

# ── Build the Docker image ──────────────────────────────────────────
build_image

# ── Run the all-models sweep ────────────────────────────────────────
bash "${SCRIPT_DIR}/claude_code_all.sh"
