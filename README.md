# Model Tests

Test scripts that verify models work across a gateway's API endpoints — the OpenAI-style **Chat Completions** API, the **Anthropic Messages** API, and the **OpenAI Responses** API.

## Prerequisites

- Docker (with build & run permissions)
- A valid API key

## Quick Start

There are two ways to run the tests: via the prebuilt Docker image or locally.

Either way, first export your API key in your shell — every command below picks it up automatically, so you can copy-paste them verbatim:

```bash
export API_KEY=sk-xxx
```

### Option A: Docker image

The runner image is published to the registry as `harbor.isuanova.com/suanova/model-tests` and bundles the chat completions + Anthropic Messages + OpenAI Responses API test scripts, so you can run the full suite without installing anything on the host. The first `docker run` pulls it automatically (or `docker pull` it ahead of time):

```bash
# Pull the published image (optional — the first docker run pulls it automatically)
docker pull harbor.isuanova.com/suanova/model-tests

# Run all API tests (chat + messages + responses, default 1 round)
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests

# 3 rounds
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests all 3

# Just one API, all models
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests chat
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests messages
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests responses

# Single model
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests chat-single glm-5.1
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests messages-single glm-5.1
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests responses-single glm-5.1

# Show help
docker run --rm harbor.isuanova.com/suanova/model-tests help
```

See the **Docker image** section below for the full subcommand reference.

### Option B: Local

The local scripts read `API_KEY` from the environment (or from a `.env` file — see below), so the `export API_KEY=sk-xxx` above is all you need.

```bash
# Chat completions, all models:
bash chat_api_all.sh
# Anthropic Messages API, all models:
bash messages_api_all.sh
# Responses API, all models:
bash responses_api_all.sh
# All three APIs (chat + messages + responses), all models, multiple rounds, one combined table:
bash run_all_api_tests.sh          # default 1 round
bash run_all_api_tests.sh 3        # 3 rounds
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
| **OpenAI Responses** | `/v1/responses` | Direct curl | `responses_api_single.sh` | `responses_api_all.sh` |

- **Chat Completions** (`chat_api_single.sh`) — sends `POST /v1/chat/completions` with `Authorization: Bearer`, a single user message (`"Reply with exactly: HELLO"`), and `max_tokens: 500`. A PASS means the response parsed successfully and contained non-empty text in `choices[0].message.content` (or `reasoning_content` if present).
- **Anthropic Messages** (`messages_api_single.sh`) — sends `POST /v1/messages` with `x-api-key` auth, a single user message, and `max_tokens: 500`. A PASS means the response contained non-empty text in `content[0].text`.
- **OpenAI Responses** (`responses_api_single.sh`) — sends `POST /v1/responses` with `Authorization: Bearer`, using `input` (instead of `messages`) and `max_output_tokens` (instead of `max_tokens`). A PASS means the response had `status: "completed"` and contained non-empty text in `output[].content[].text` (where `type == "output_text"`).

> **⚠️ Important:** These are **smoke tests**, not strict API compatibility tests. A PASS only indicates that the specific request we sent (a single prompt with minimal parameters) was handled successfully — it does **not** mean the model fully supports every feature of that API (streaming, function calling, multi-turn conversations, vision input, etc.). A model that passes may still fail on more complex or edge-case requests.

All `*_all.sh` scripts share the same model filtering (drops TTS/image/video/embedding/vision), whitelist support, and summary table.

### Usage examples

```bash
# Chat completions — single model (defaults to glm-5.1 if no model given)
bash chat_api_single.sh glm-5.1
bash chat_api_single.sh            # → tests glm-5.1

# Anthropic Messages API — single model
bash messages_api_single.sh glm-5.1

# Responses API — single model
bash responses_api_single.sh glm-5.1

# Any API suite — all suitable models (respects whitelist.txt if present)
bash chat_api_all.sh               # Chat completions API
bash messages_api_all.sh           # Anthropic Messages API
bash responses_api_all.sh          # Responses API

# Combined: chat + messages + responses APIs, all models, multiple rounds, one table
bash run_all_api_tests.sh          # default 1 round per model per API
bash run_all_api_tests.sh 3        # 3 rounds

# Key can also be passed inline for a single run (overrides both export and .env)
API_KEY=sk-xxx bash chat_api_single.sh glm-5.1
```

### `run_all_api_tests.sh` — combined multi-round test

Runs the Chat Completions API, Anthropic Messages API, and OpenAI Responses API for every suitable model, across multiple rounds, and reports a single combined table.

A model counts as **supporting** an API if it passes **at least once** across all rounds — so transient failures don't fail a model, but a model that never responds correctly is marked unsupported.

```
$ bash run_all_api_tests.sh 2
...
#    Model                              Chat Completions     Messages API          Responses API
-----------------------------------------------------------------------------------------------
1    glm-5.1                            2/2  ✓               2/2  ✓               2/2  ✓
2    some-flaky-model                  1/2  ✓               0/2  ✗               0/2  ✗
-----------------------------------------------------------------------------------------------

  Summary (2 round(s) per API):
  Chat Completions API:   2/2 models support it (passed >= 1 round)
  Anthropic Messages API: 1/2 models support it (passed >= 1 round)
  Responses API:          1/2 models support it (passed >= 1 round)
  All three APIs:         1/2 models
```

- **Arguments:** number of rounds (default `1`). Each round runs all three APIs for each model.
- **Per-round progress** streams to stderr (`API [Chat Completions] - round 1/2  PASS`); the final combined table goes to stdout.
- Respects `whitelist.txt` and `TEST_TIMEOUT` like the other scripts.

## Docker image

The runner image is published to the registry as `harbor.isuanova.com/suanova/model-tests` and bundles the API test scripts (chat completions + Anthropic Messages + OpenAI Responses) so the suite runs anywhere with Docker — no host dependencies, no build step (the first `docker run` pulls it).

**Subcommands** (`docker run --rm -e API_KEY <image> <subcommand>` — requires `export API_KEY=sk-xxx` first):

```bash
docker run --rm -e API_KEY harbor.isuanova.com/suanova/model-tests <subcommand>
```

| Subcommand | Runs | Extra args |
|------------|------|------------|
| `all` (default) | `run_all_api_tests.sh` — chat + messages + responses APIs, all models | `[rounds]` (default 1 round) |
| `chat` | `chat_api_all.sh` — chat completions, all models | — |
| `messages` | `messages_api_all.sh` — Anthropic Messages, all models | — |
| `responses` | `responses_api_all.sh` — Responses API, all models | — |
| `compare` | `compare_gateways.sh` — compare two gateways (shared, A-only, B-only) | `[rounds]` `[--b-key KEY]` `[--b-url URL]` |
| `chat-single` | `chat_api_single.sh` — chat completions, one model | `[model]` (default glm-5.1) |
| `messages-single` | `messages_api_single.sh` — Anthropic Messages, one model | `[model]` (default glm-5.1) |
| `responses-single` | `responses_api_single.sh` — Responses API, one model | `[model]` (default glm-5.1) |
| `help` | print usage | — |

Extra args after the subcommand are forwarded to the underlying script.

**Environment** (pass via `-e`):

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | (required) | Your API key |
| `BASE_URL` | `https://cuberouter.cn` | Gateway base URL |
| `API_KEY_B` | (required for compare) | Gateway B API key |
| `BASE_URL_B` | (required for compare) | Gateway B base URL |
| `TEST_TIMEOUT` | `30` | Per-model timeout in seconds |

The image does **not** bake in a whitelist — to restrict models, run locally or mount a `whitelist.txt`:

```bash
docker run --rm \
    -e API_KEY \
    -v "$PWD/whitelist.txt:/app/whitelist.txt:ro" \
    harbor.isuanova.com/suanova/model-tests \
    all 3
```

## Config

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | (required) | Your API key — set in `.env` or as an env var |
| `BASE_URL` | `https://cuberouter.cn` | Gateway base URL (can also be set in `.env`) |
| `API_KEY_B` | (required for compare) | Gateway B API key — set in `.env` or via `--b-key` |
| `BASE_URL_B` | (required for compare) | Gateway B base URL — set in `.env` or via `--b-url` |
| `TEST_TIMEOUT` | `30` | Per-model timeout in seconds (applies to all single-model tests) |

## Gateway Comparison

`compare_gateways.sh` compares the model offerings of **two** API gateways and tests their overlap. It uses the existing `API_KEY` + `BASE_URL` as **gateway A**, and adds `API_KEY_B` + `BASE_URL_B` for **gateway B**.

For each gateway it fetches `/v1/models`, filters for chat models, and computes three groups:

| Group | Tested on | APIs tested |
|-------|-----------|-------------|
| **Shared** (models on both gateways) | Both A and B | Chat + Messages + Responses (6 tests per model) |
| **A-only** (models only on A) | Gateway A only | Chat + Messages + Responses (3 tests per model) |
| **B-only** (models only on B) | Gateway B only | Chat + Messages + Responses (3 tests per model) |

A model counts as **supporting** an API on a gateway if it passes at least once across all rounds — same rule as `run_all_api_tests.sh`.

### Usage

```bash
# Via .env — add API_KEY_B and BASE_URL_B alongside your existing API_KEY/BASE_URL:
#   API_KEY_B=sk-other-key
#   BASE_URL_B=https://other-gateway.example.com
bash compare_gateways.sh           # 1 round
bash compare_gateways.sh 3         # 3 rounds

# Via env vars:
API_KEY_B=sk-... BASE_URL_B=https://... bash compare_gateways.sh

# Via CLI flags (override env/.env):
bash compare_gateways.sh --b-key sk-... --b-url https://... 3

# Via Docker:
docker run --rm \
    -e API_KEY -e API_KEY_B -e BASE_URL_B \
    harbor.isuanova.com/suanova/model-tests compare

docker run --rm \
    -e API_KEY \
    -e API_KEY_B=sk-... -e BASE_URL_B=https://... \
    harbor.isuanova.com/suanova/model-tests compare 3 --b-key sk-alt --b-url https://alt.example.com
```

### Output

The comparison prints three tables:

1. **Shared models** — each model row shows Chat A/B, Messages A/B, Responses A/B side by side, so you can see whether a model works on both gateways or just one.
2. **A-only models** — standard 3-API table tested against gateway A.
3. **B-only models** — standard 3-API table tested against gateway B.

Followed by a grand-total summary line.

### Config

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | (required) | Gateway A API key — existing config |
| `BASE_URL` | `https://cuberouter.cn` | Gateway A base URL — existing config |
| `API_KEY_B` | (required for compare) | Gateway B API key — set in `.env` or via `--b-key` |
| `BASE_URL_B` | (required for compare) | Gateway B base URL — set in `.env` or via `--b-url` |
| `TEST_TIMEOUT` | `30` | Per-model timeout in seconds |

CLI flags override env/.env values: `--b-key <key>` and `--b-url <url>`.

## Whitelist (optional)

To test only a subset of models, create a `whitelist.txt` file in the script directory (one model ID per line, `#` for comments). All `*_all.sh` scripts, `run_all_api_tests.sh`, and `compare_gateways.sh` respect it:

```bash
cp whitelist.txt.example whitelist.txt
# edit whitelist.txt, e.g.:
#   glm-5.1
#   kimi-k2.6
bash chat_api_all.sh
bash messages_api_all.sh
bash responses_api_all.sh
bash run_all_api_tests.sh 3
```

When `whitelist.txt` is present, only models in **both** the gateway list and the whitelist are tested. Any whitelisted model not found in the gateway is reported as skipped. If the file is absent, all suitable chat models are tested.

## File Structure

```
model-tests/
├── Dockerfile                # Runner image: bundles API test scripts → harbor.isuanova.com/suanova/model-tests
├── entrypoint.sh             # Docker entrypoint: maps subcommands (all/chat/messages/responses/...) to scripts
├── common.sh                 # Shared helpers (.env loader, list_chat_models, summary table)
├── run_all_api_tests.sh      # Combined: chat + messages + responses APIs, all models, N rounds, one table
├── compare_gateways.sh       # Compare two gateways: shared, A-only, B-only models across 3 APIs
├── chat_api_single.sh        # Chat completions API: test one model (defaults to glm-5.1)
├── chat_api_all.sh           # Chat completions API: iterate all suitable models
├── messages_api_single.sh    # Anthropic Messages API: test one model (defaults to glm-5.1)
├── messages_api_all.sh       # Anthropic Messages API: iterate all suitable models
├── responses_api_single.sh   # OpenAI Responses API: test one model (defaults to glm-5.1)
├── responses_api_all.sh      # OpenAI Responses API: iterate all suitable models
├── .env.example              # Template — copy to .env and set your key
├── whitelist.txt.example     # Template — copy to whitelist.txt to restrict models
├── .gitignore                # Excludes .env and whitelist.txt from git
└── README.md                 # This file
```

## How it works

1. **Docker runner image** (`Dockerfile`) — a lean `python:3.11-slim` image with curl, bundling the API test scripts + `entrypoint.sh`, published to the registry as `harbor.isuanova.com/suanova/model-tests`. Run via `docker run -e API_KEY <image> <subcommand>` (pulled automatically on first run).
2. Each `*_all.sh` script calls the shared `list_chat_models` helper in `common.sh`, which fetches `/v1/models`, filters out non-chat models (TTS, image generation, video, embedding, vision-only), applies `whitelist.txt` if present, and prints the kept model IDs.
3. For each model, the corresponding `*_single.sh` script runs:
   - `chat_api_single.sh` — `POST /v1/chat/completions` (OpenAI format, `Authorization: Bearer` auth) with curl; checks `choices[0].message.content`.
   - `messages_api_single.sh` — `POST /v1/messages` (Anthropic format, `x-api-key` auth) with curl; checks `content[0].text`.
   - `responses_api_single.sh` — `POST /v1/responses` (OpenAI Responses format, `Authorization: Bearer` auth) with curl; uses `input` instead of `messages` and `max_output_tokens` instead of `max_tokens`; checks `output[0].content[0].text` (where `type == "output_text"`).
4. Each single-model script prints a machine-parseable `PASS|<model>|<reply>` or `FAIL|<model>|<error>` line to stdout (the model's reply after the final `|`) and live `[PASS]`/`[FAIL]` logs to stderr.
5. The shared `print_summary_table` helper renders the final results table with the `n/m` count.
6. `run_all_api_tests.sh` runs `chat_api_single.sh`, `messages_api_single.sh`, and `responses_api_single.sh` for each model across N rounds and reports a combined table.

## Notes

- The runner image (`harbor.isuanova.com/suanova/model-tests`) is pulled from the registry and reused across all API model tests — no build needed. To update it, `docker pull` the latest tag.
- Each model test starts a fresh container (~1-2s startup) plus one API call (~5-30s).
