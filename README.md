# CubeRouter Model Tests

Test scripts that verify CubeRouter models work across the gateway's API endpoints — primarily the OpenAI-style **Chat Completions** API and the **Anthropic Messages** API — with an additional test that exercises the full **Claude Code** client path on top of the Messages API.

## Prerequisites

- Docker (with build & run permissions)
- A valid CubeRouter API key

## Quick Start

There are two ways to run the tests: via the prebuilt Docker image (API tests only) or locally (all tests, including Claude Code).

Either way, first export your API key in your shell — every command below picks it up automatically, so you can copy-paste them verbatim:

```bash
export API_KEY=sk-xxx
```

### Option A: Docker image (API tests only)

The runner image is published to the registry as `harbor.isuanova.com/yangle/model-tests` and bundles the chat completions + Anthropic Messages API test scripts, so you can run the full suite without installing anything on the host. The first `docker run` pulls it automatically (or `docker pull` it ahead of time):

```bash
# Pull the published image (optional — the first docker run pulls it automatically)
docker pull harbor.isuanova.com/yangle/model-tests

# Run all API tests (both chat + messages), default 1 round
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests

# 3 rounds
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests all 3

# Just one API, all models
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests chat
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests messages

# Single model
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests chat-single glm-5.1
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests messages-single glm-5.1

# Show help
docker run --rm harbor.isuanova.com/yangle/model-tests help
```

See the **Docker image** section below for the full subcommand reference.

### Option B: Local (API tests + optional Claude Code test)

The local scripts read `API_KEY` from the environment (or from a `.env` file — see below), so the `export API_KEY=sk-xxx` above is all you need.

```bash
# ── API tests (no Docker image build needed, just curl + python3) ──
# Chat completions, all models:
bash chat_api_all.sh
# Anthropic Messages API, all models:
bash messages_api_all.sh
# Both APIs, all models, multiple rounds, one combined table:
bash run_all_api_tests.sh          # default 1 round
bash run_all_api_tests.sh 3        # 3 rounds

# ── Claude Code test (additional; needs the local Claude Code image) ──
# Build the Claude Code image (first time only, needed for claude_code_* tests)
docker build -t harbor.isuanova.com/yangle/claude-code -f Dockerfile.claude-code .
bash run_claude_code_tests.sh
```

The local scripts (Option B) resolve the API key in this order:
1. `API_KEY` environment variable (e.g. from `export API_KEY=sk-xxx` above)
2. `API_KEY` in `.env` (in the script directory)

So the exported env var always takes precedence over the `.env` file. To use a `.env` file instead, `cp .env.example .env` and set `API_KEY=` in it — then you can skip the `export`.

## Test Cases

There are three test suites, each with a single-model and an all-models script:

| Suite | API | Client | Single-model | All-models |
|-------|-----|--------|--------------|------------|
| **Chat Completions** | OpenAI `/v1/chat/completions` | Direct curl | `chat_api_single.sh` | `chat_api_all.sh` |
| **Anthropic Messages** | `/v1/messages` | Direct curl | `messages_api_single.sh` | `messages_api_all.sh` |
| **Claude Code** (additional) | Anthropic `/v1/messages` | Claude Code (Docker) | `claude_code_single.sh` | `claude_code_all.sh` |

- **Chat Completions** (`chat_api_single.sh`) — tests the OpenAI-style chat completions endpoint (`POST /v1/chat/completions` with `Authorization: Bearer`) directly with curl.
- **Anthropic Messages** (`messages_api_single.sh`) — tests the raw Anthropic Messages API (`POST /v1/messages` with `x-api-key`) directly with curl, no Docker. Isolates the gateway/API layer from the Claude Code client.
- **Claude Code** (`claude_code_single.sh`) — additional test of the full Claude Code client path: mounts a `settings.json` into a Docker container and runs `claude -p ... --model <model>`. Proves the model works with Claude Code specifically.

All `*_all.sh` scripts share the same model filtering (drops TTS/image/video/embedding/vision), whitelist support, and summary table.

### Usage examples

```bash
# Chat completions — single model (defaults to glm-5.1 if no model given)
bash chat_api_single.sh glm-5.1
bash chat_api_single.sh            # → tests glm-5.1

# Anthropic Messages API — single model
bash messages_api_single.sh glm-5.1

# Any API suite — all suitable models (respects whitelist.txt if present)
bash chat_api_all.sh               # Chat completions API
bash messages_api_all.sh           # Anthropic Messages API

# Combined: both APIs, all models, multiple rounds, one table
bash run_all_api_tests.sh          # default 1 round per model per API
bash run_all_api_tests.sh 3        # 3 rounds

# Claude Code — additional, requires building the local Claude Code image first
bash claude_code_single.sh glm-5.1 # single model (build image via run_claude_code_tests.sh first)
bash claude_code_all.sh            # all models (builds Docker image first via run_claude_code_tests.sh)
bash run_claude_code_tests.sh      # build Docker image + full Claude Code sweep

# Key can also be passed inline for a single run (overrides both export and .env)
API_KEY=sk-xxx bash chat_api_single.sh glm-5.1
```

### `run_all_api_tests.sh` — combined multi-round test

Runs both the Chat Completions API and the Anthropic Messages API for every suitable model, across multiple rounds, and reports a single combined table. A model counts as **supporting** an API if it passes **at least once** across all rounds — so transient failures don't fail a model, but a model that never responds correctly is marked unsupported.

```
$ bash run_all_api_tests.sh 2
...
#    Model                              Chat Completions     Messages API
-------------------------------------------------------------------------------------
1    glm-5.1                            2/2  ✓               2/2  ✓
2    some-flaky-model                  1/2  ✓               0/2  ✗
-------------------------------------------------------------------------------------

  Summary (2 round(s) per API):
  Chat Completions API: 2/2 models support it (passed >= 1 round)
  Anthropic Messages API: 1/2 models support it (passed >= 1 round)
  Both APIs:              1/2 models
```

- **Argument:** number of rounds (default `1`). Each round runs both APIs for each model.
- **Per-round progress** streams to stderr (`API [Chat Completions] - round 1/2  PASS`); the final combined table goes to stdout.
- Respects `whitelist.txt` and `TEST_TIMEOUT` like the other scripts.

## Docker image

The runner image is published to the registry as `harbor.isuanova.com/yangle/model-tests` and bundles the API test scripts (chat completions + Anthropic Messages) so the suite runs anywhere with Docker — no host dependencies, no build step (the first `docker run` pulls it). Claude Code tests are local-only: they build and run a separate `harbor.isuanova.com/yangle/claude-code` image (see `Dockerfile.claude-code`) that isn't included in the runner image.

**Subcommands** (`docker run --rm -e API_KEY <image> <subcommand>` — requires `export API_KEY=sk-xxx` first):

```bash
docker run --rm -e API_KEY harbor.isuanova.com/yangle/model-tests <subcommand>
```

| Subcommand | Runs | Extra args |
|------------|------|------------|
| `all` (default) | `run_all_api_tests.sh` — both APIs, all models | `[rounds]` (default 1) |
| `chat` | `chat_api_all.sh` — chat completions, all models | — |
| `messages` | `messages_api_all.sh` — Anthropic Messages, all models | — |
| `chat-single` | `chat_api_single.sh` — chat completions, one model | `[model]` (default glm-5.1) |
| `messages-single` | `messages_api_single.sh` — Anthropic Messages, one model | `[model]` (default glm-5.1) |
| `help` | print usage | — |

Extra args after the subcommand are forwarded to the underlying script.

**Environment** (pass via `-e`):

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | (required) | Your CubeRouter API key |
| `BASE_URL` | `https://cuberouter.cn` | Gateway base URL |
| `TEST_TIMEOUT` | `30` | Per-model timeout in seconds |

The image does **not** bake in a whitelist — to restrict models, run locally or mount a `whitelist.txt`:

```bash
docker run --rm \
    -e API_KEY \
    -v "$PWD/whitelist.txt:/app/whitelist.txt:ro" \
    harbor.isuanova.com/yangle/model-tests \
    all 3
```

## Config

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | (required) | Your CubeRouter API key — set in `.env` or as an env var |
| `BASE_URL` | `https://cuberouter.cn` | Gateway base URL (can also be set in `.env`) |
| `TEST_TIMEOUT` | `30` | Per-model timeout in seconds (applies to all single-model tests: chat completions, Anthropic Messages, and Claude Code) |

## Whitelist (optional)

To test only a subset of models, create a `whitelist.txt` file in the script directory (one model ID per line, `#` for comments). All `*_all.sh` scripts and `run_all_api_tests.sh` respect it:

```bash
cp whitelist.txt.example whitelist.txt
# edit whitelist.txt, e.g.:
#   glm-5.1
#   kimi-k2.6
bash chat_api_all.sh
bash messages_api_all.sh
bash run_all_api_tests.sh 3
bash claude_code_all.sh
```

When `whitelist.txt` is present, only models in **both** the gateway list and the whitelist are tested. Any whitelisted model not found in the gateway is reported as skipped. If the file is absent, all suitable chat models are tested.

## File Structure

```
model-tests/
├── Dockerfile                # Runner image: bundles API test scripts → harbor.isuanova.com/yangle/model-tests
├── Dockerfile.claude-code    # Claude Code image: Ubuntu + Node 18 + claude-code → harbor.isuanova.com/yangle/claude-code (local use)
├── entrypoint.sh             # Docker entrypoint: maps subcommands (all/chat/messages/...) to scripts
├── common.sh                 # Shared helpers (.env loader, list_chat_models, summary table, settings.json)
├── run_all_api_tests.sh      # Combined: both APIs, all models, N rounds, one table
├── chat_api_single.sh        # Chat completions API: test one model (defaults to glm-5.1)
├── chat_api_all.sh           # Chat completions API: iterate all suitable models
├── messages_api_single.sh    # Anthropic Messages API: test one model (defaults to glm-5.1)
├── messages_api_all.sh       # Anthropic Messages API: iterate all suitable models
├── claude_code_single.sh     # Claude Code (additional): test one model (defaults to glm-5.1)
├── claude_code_all.sh        # Claude Code (additional): iterate all suitable models
├── run_claude_code_tests.sh  # Local orchestrator: build Claude Code image + run Claude Code sweep
├── .env.example              # Template — copy to .env and set your key
├── whitelist.txt.example     # Template — copy to whitelist.txt to restrict models
├── .gitignore                # Excludes .env and whitelist.txt from git
└── README.md                 # This file
```

## How it works

1. **Docker runner image** (`Dockerfile`) — a lean `python:3.11-slim` image with curl, bundling the API test scripts + `entrypoint.sh`, published to the registry as `harbor.isuanova.com/yangle/model-tests`. Run via `docker run -e API_KEY <image> <subcommand>` (pulled automatically on first run).
2. **Claude Code image** (`Dockerfile.claude-code`) — Ubuntu + Node 18 + the `claude` CLI, built locally as `harbor.isuanova.com/yangle/claude-code` and used by `claude_code_single.sh` (local use only; not in the runner image).
3. Each `*_all.sh` script calls the shared `list_chat_models` helper in `common.sh`, which fetches `/v1/models`, filters out non-chat models (TTS, image generation, video, embedding, vision-only), applies `whitelist.txt` if present, and prints the kept model IDs.
4. For each model, the corresponding `*_single.sh` script runs:
   - `chat_api_single.sh` — `POST /v1/chat/completions` (OpenAI format, `Authorization: Bearer` auth) with curl; checks `choices[0].message.content`.
   - `messages_api_single.sh` — `POST /v1/messages` (Anthropic format, `x-api-key` auth) with curl; checks `content[0].text`.
   - `claude_code_single.sh` — additional test: mounts a `settings.json` into a Docker container and runs `claude -p "Reply with exactly: HELLO" --output-format text --max-turns 1 --model <model>`.
5. Each single-model script prints a machine-parseable `PASS|<model>|<reply>` or `FAIL|<model>|<error>` line to stdout (the two API scripts include the model's reply after the final `|`; `claude_code_single.sh` checks only for errors, so its PASS line has an empty third field) and live `[PASS]`/`[FAIL]` logs to stderr.
6. The shared `print_summary_table` helper renders the final results table with the `n/m` count.
7. `run_all_api_tests.sh` runs both `chat_api_single.sh` and `messages_api_single.sh` for each model across N rounds and reports a combined table.

## Notes

- The runner image (`harbor.isuanova.com/yangle/model-tests`) is pulled from the registry and reused across all API model tests — no build needed. To update it, `docker pull` the latest tag. The Claude Code image (`harbor.isuanova.com/yangle/claude-code`) is built locally with `run_claude_code_tests.sh` (or the `docker build` line in Option B); rebuild it to pick up a newer `claude` CLI version.
- Each model test starts a fresh container (~1-2s startup) plus one API call (~5-30s).
- Non-chat models are auto-filtered (see `EXCLUDE_PATTERNS` in `common.sh`): `-tts-`/`^tts-`, `-image-`/`^image-`, `-video-`/`^video-`, `embed`, `-vision`, `dall-e`, `sora`, `seedance`.
