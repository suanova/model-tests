# Dockerfile — runner image for CubeRouter API tests
#
# Bundles the chat completions + Anthropic Messages API test scripts so the
# full suite can be run via `docker run` without installing anything on the host.
# The API key is passed at runtime via -e API_KEY=... (or baked into .env).
#
# Build:
#   docker build -t harbor.isuanova.com/yangle/model-tests .
# Run:
#   docker run --rm -e API_KEY=sk-... harbor.isuanova.com/yangle/model-tests
#   docker run --rm -e API_KEY=sk-... harbor.isuanova.com/yangle/model-tests all 3
#   docker run --rm -e API_KEY=sk-... harbor.isuanova.com/yangle/model-tests chat
#   docker run --rm -e API_KEY=sk-... harbor.isuanova.com/yangle/model-tests messages-single glm-5.1

FROM python:3.11-slim

# Avoid interactive prompts during apt operations
ENV DEBIAN_FRONTEND=noninteractive

# Install curl (python3 + bash are already in the slim image)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the test scripts and shared helpers
COPY common.sh \
     chat_api_single.sh \
     chat_api_all.sh \
     messages_api_single.sh \
     messages_api_all.sh \
     run_all_api_tests.sh \
     entrypoint.sh \
     .env.example \
     whitelist.txt.example \
     /app/

# Make scripts executable
RUN chmod +x /app/*.sh

ENTRYPOINT ["/app/entrypoint.sh"]
