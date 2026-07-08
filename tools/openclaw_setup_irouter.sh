#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${OPENCLAW_CUSTOM_BASE_URL:-https://irouter.io}"
DEFAULT_MODEL="${OPENCLAW_DEFAULT_MODEL:-MiniMax-M2.7}"
MODEL_ID="${OPENCLAW_MODEL_ID:-}"
API_KEY="${OPENCLAW_API_KEY:-}"
PROVIDER_ID="${OPENCLAW_PROVIDER_ID:-custom-irouter-io}"
CONTEXT_WINDOW="${OPENCLAW_CONTEXT_WINDOW:-1000000}"
MAX_TOKENS="${OPENCLAW_MAX_TOKENS:-65536}"
SKIP_RESTART=0

usage() {
  cat <<'USAGE'
Usage:
  tools/openclaw_setup_irouter.sh [options]

This script configures OpenClaw to use irouter.io with a custom API key,
then updates the generated provider model limits and restarts the gateway.

Interactive defaults:
  model: MiniMax-M2.7
  api key: prompted with hidden input

Options:
  --model MODEL           Custom model id. Default: MiniMax-M2.7
  --api-key KEY           Custom API key. Prefer OPENCLAW_API_KEY when automating.
  --base-url URL          Custom base URL. Default: https://irouter.io
  --provider-id ID        Provider id in OpenClaw config. Default: custom-irouter-io
  --context-window N      Context window. Default: 1000000
  --max-tokens N          Max tokens. Default: 65536
  --skip-restart          Do not run: openclaw gateway restart
  -h, --help              Show this help.

Environment variables:
  OPENCLAW_API_KEY
  OPENCLAW_MODEL_ID
  OPENCLAW_CUSTOM_BASE_URL
  OPENCLAW_PROVIDER_ID
  OPENCLAW_CONTEXT_WINDOW
  OPENCLAW_MAX_TOKENS

Example:
  OPENCLAW_API_KEY="sk-..." tools/openclaw_setup_irouter.sh
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed or not on PATH"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || die "--model requires a value"
      MODEL_ID="$2"
      shift 2
      ;;
    --api-key)
      [[ $# -ge 2 ]] || die "--api-key requires a value"
      API_KEY="$2"
      shift 2
      ;;
    --base-url)
      [[ $# -ge 2 ]] || die "--base-url requires a value"
      BASE_URL="$2"
      shift 2
      ;;
    --provider-id)
      [[ $# -ge 2 ]] || die "--provider-id requires a value"
      PROVIDER_ID="$2"
      shift 2
      ;;
    --context-window)
      [[ $# -ge 2 ]] || die "--context-window requires a value"
      CONTEXT_WINDOW="$2"
      shift 2
      ;;
    --max-tokens)
      [[ $# -ge 2 ]] || die "--max-tokens requires a value"
      MAX_TOKENS="$2"
      shift 2
      ;;
    --skip-restart)
      SKIP_RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_cmd openclaw
is_positive_integer "$CONTEXT_WINDOW" || die "--context-window must be a positive integer"
is_positive_integer "$MAX_TOKENS" || die "--max-tokens must be a positive integer"

if [[ -z "$MODEL_ID" ]]; then
  read -r -p "Model id [$DEFAULT_MODEL]: " MODEL_ID
  MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL}"
fi

if [[ -z "$API_KEY" ]]; then
  read -r -s -p "Custom API key: " API_KEY
  echo
fi

[[ -n "$MODEL_ID" ]] || die "model id cannot be empty"
[[ -n "$API_KEY" ]] || die "api key cannot be empty"

echo "Configuring OpenClaw custom provider..."
echo "  base url: $BASE_URL"
echo "  provider: $PROVIDER_ID"
echo "  model:    $MODEL_ID"

openclaw onboard \
  --non-interactive \
  --auth-choice custom-api-key \
  --custom-base-url "$BASE_URL" \
  --custom-model-id "$MODEL_ID" \
  --custom-api-key "$API_KEY" \
  --secret-input-mode plaintext \
  --custom-compatibility anthropic \
  --accept-risk \
  --skip-health

echo "Updating model limits..."
openclaw config set "models.providers.${PROVIDER_ID}.models[0].contextWindow" "$CONTEXT_WINDOW" --strict-json
openclaw config set "models.providers.${PROVIDER_ID}.models[0].maxTokens" "$MAX_TOKENS" --strict-json

if [[ "$SKIP_RESTART" -eq 0 ]]; then
  echo "Restarting OpenClaw gateway..."
  openclaw gateway restart
else
  echo "Skipped gateway restart. Run manually when ready:"
  echo "  openclaw gateway restart"
fi

echo "Done."
