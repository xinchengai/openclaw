#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${CLAUDE_IROUTER_BASE_URL:-https://irouter.io}"
DEFAULT_MODEL="${CLAUDE_IROUTER_DEFAULT_MODEL:-MiniMax-M2.7}"
MODEL_ID="${CLAUDE_IROUTER_MODEL_ID:-}"
API_KEY="${CLAUDE_IROUTER_API_KEY:-}"
AUTH_HEADER="${CLAUDE_IROUTER_AUTH_HEADER:-auth-token}"
INSTALL_METHOD="${CLAUDE_CODE_INSTALL_METHOD:-npm}"
SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
CLAUDE_JSON_PATH="${CLAUDE_JSON_PATH:-$HOME/.claude.json}"
MAX_CONTEXT_TOKENS="${CLAUDE_CODE_MAX_CONTEXT_TOKENS_VALUE:-1000000}"
MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS_VALUE:-65536}"
RUN_SMOKE_TEST=0

usage() {
  cat <<'USAGE'
Usage:
  tools/claude_code_setup_irouter.sh [options]

Install Claude Code on a Linux server and configure it to use irouter.io
through Claude Code's ~/.claude/settings.json env block.

Interactive defaults:
  model: MiniMax-M2.7
  api key: prompted with hidden input

Options:
  --model MODEL              Model id. Default: MiniMax-M2.7
  --api-key KEY              irouter.io API key. Prefer CLAUDE_IROUTER_API_KEY for automation.
  --base-url URL             Anthropic-compatible gateway URL. Default: https://irouter.io
  --auth-header MODE         auth-token, api-key, or both. Default: auth-token
                            auth-token writes ANTHROPIC_AUTH_TOKEN (Bearer token)
                            api-key writes ANTHROPIC_API_KEY (X-Api-Key)
  --install-method METHOD    npm, native, auto, or none. Default: npm
                            npm avoids the common 403 from https://claude.ai/install.sh
  --settings PATH            Claude Code settings path. Default: ~/.claude/settings.json
  --max-context-tokens N     CLAUDE_CODE_MAX_CONTEXT_TOKENS. Default: 1000000
  --max-output-tokens N      CLAUDE_CODE_MAX_OUTPUT_TOKENS. Default: 65536
  --run-smoke-test           Run a small claude -p request after setup. This may spend tokens.
  -h, --help                 Show this help.

Environment variables:
  CLAUDE_IROUTER_API_KEY
  CLAUDE_IROUTER_MODEL_ID
  CLAUDE_IROUTER_BASE_URL
  CLAUDE_IROUTER_AUTH_HEADER
  CLAUDE_CODE_INSTALL_METHOD
  CLAUDE_SETTINGS_PATH
  CLAUDE_JSON_PATH

Examples:
  tools/claude_code_setup_irouter.sh
  CLAUDE_IROUTER_API_KEY="sk-..." tools/claude_code_setup_irouter.sh
  CLAUDE_IROUTER_API_KEY="sk-..." tools/claude_code_setup_irouter.sh --model "MiniMax-M2.7"
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

run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "sudo is not available; cannot run: $*"
  fi
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
    --auth-header)
      [[ $# -ge 2 ]] || die "--auth-header requires a value"
      AUTH_HEADER="$2"
      shift 2
      ;;
    --install-method)
      [[ $# -ge 2 ]] || die "--install-method requires a value"
      INSTALL_METHOD="$2"
      shift 2
      ;;
    --settings)
      [[ $# -ge 2 ]] || die "--settings requires a value"
      SETTINGS_PATH="$2"
      shift 2
      ;;
    --max-context-tokens)
      [[ $# -ge 2 ]] || die "--max-context-tokens requires a value"
      MAX_CONTEXT_TOKENS="$2"
      shift 2
      ;;
    --max-output-tokens)
      [[ $# -ge 2 ]] || die "--max-output-tokens requires a value"
      MAX_OUTPUT_TOKENS="$2"
      shift 2
      ;;
    --run-smoke-test)
      RUN_SMOKE_TEST=1
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

case "$AUTH_HEADER" in
  auth-token|api-key|both) ;;
  *) die "--auth-header must be auth-token, api-key, or both" ;;
esac

case "$INSTALL_METHOD" in
  npm|native|auto|none) ;;
  *) die "--install-method must be npm, native, auto, or none" ;;
esac

is_positive_integer "$MAX_CONTEXT_TOKENS" || die "--max-context-tokens must be a positive integer"
is_positive_integer "$MAX_OUTPUT_TOKENS" || die "--max-output-tokens must be a positive integer"

if [[ -z "$MODEL_ID" ]]; then
  read -r -p "Model id [$DEFAULT_MODEL]: " MODEL_ID
  MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL}"
fi

if [[ -z "$API_KEY" ]]; then
  read -r -s -p "irouter.io API key: " API_KEY
  echo
fi

[[ -n "$MODEL_ID" ]] || die "model id cannot be empty"
[[ -n "$API_KEY" ]] || die "api key cannot be empty"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.npm/bin:$PATH"

ensure_node_npm() {
  require_cmd node
  require_cmd npm

  local node_major
  node_major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
    die "Node.js 18+ is required for npm install. Current version: $(node -v 2>/dev/null || echo unknown)"
  fi
}

install_with_npm() {
  ensure_node_npm
  echo "Installing Claude Code with npm..."
  if npm install -g @anthropic-ai/claude-code; then
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    echo "npm global install failed without sudo; retrying with sudo..."
    run_sudo npm install -g @anthropic-ai/claude-code
    return 0
  fi

  return 1
}

install_with_native() {
  require_cmd curl
  echo "Installing Claude Code with the official native installer..."
  curl -fsSL https://claude.ai/install.sh | bash
}

install_claude_code() {
  if command -v claude >/dev/null 2>&1; then
    echo "Claude Code is already installed: $(command -v claude)"
    claude --version || true
    return 0
  fi

  case "$INSTALL_METHOD" in
    native)
      install_with_native
      ;;
    npm)
      install_with_npm
      ;;
    auto)
      if ! install_with_native; then
        echo "Native installer failed; falling back to npm install..."
        install_with_npm
      fi
      ;;
    none)
      die "claude is not installed or not on PATH; rerun without --install-method none"
      ;;
  esac

  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.npm/bin:$PATH"
  command -v claude >/dev/null 2>&1 || {
    echo "Claude Code was installed, but 'claude' is not on PATH yet."
    echo "Try opening a new shell, or add ~/.local/bin to PATH."
    return 0
  }

  claude --version || true
}

ensure_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing python3 with apt-get..."
    run_sudo apt-get update
    run_sudo apt-get install -y python3
  elif command -v yum >/dev/null 2>&1; then
    echo "Installing python3 with yum..."
    run_sudo yum install -y python3
  elif command -v dnf >/dev/null 2>&1; then
    echo "Installing python3 with dnf..."
    run_sudo dnf install -y python3
  else
    die "python3 is required to safely update $SETTINGS_PATH"
  fi
}

write_claude_settings() {
  ensure_python3

  export SETTINGS_PATH CLAUDE_JSON_PATH BASE_URL MODEL_ID API_KEY AUTH_HEADER MAX_CONTEXT_TOKENS MAX_OUTPUT_TOKENS
  python3 <<'PY'
import json
import os
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_PATH"]).expanduser()
settings_path.parent.mkdir(parents=True, exist_ok=True)

data = {}
if settings_path.exists() and settings_path.stat().st_size > 0:
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        backup = settings_path.with_suffix(settings_path.suffix + ".bak")
        backup.write_bytes(settings_path.read_bytes())
        data = {}
        print(f"Existing settings JSON was invalid; backed it up to {backup}")

if not isinstance(data, dict):
    data = {}

env = data.setdefault("env", {})
if not isinstance(env, dict):
    env = {}
    data["env"] = env

model_id = os.environ["MODEL_ID"]
auth_header = os.environ["AUTH_HEADER"]
api_key = os.environ["API_KEY"]

env["ANTHROPIC_BASE_URL"] = os.environ["BASE_URL"]
env["ANTHROPIC_MODEL"] = model_id
env["ANTHROPIC_SMALL_FAST_MODEL"] = model_id
env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model_id
env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model_id
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = model_id
env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = os.environ["MAX_CONTEXT_TOKENS"]
env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = os.environ["MAX_OUTPUT_TOKENS"]
env["API_TIMEOUT_MS"] = env.get("API_TIMEOUT_MS", "3000000")
env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"

if auth_header in ("auth-token", "both"):
    env["ANTHROPIC_AUTH_TOKEN"] = api_key
else:
    env.pop("ANTHROPIC_AUTH_TOKEN", None)

if auth_header in ("api-key", "both"):
    env["ANTHROPIC_API_KEY"] = api_key
else:
    env.pop("ANTHROPIC_API_KEY", None)

settings_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
settings_path.chmod(0o600)

claude_json_path = Path(os.environ["CLAUDE_JSON_PATH"]).expanduser()
claude_json_path.parent.mkdir(parents=True, exist_ok=True)
claude_data = {}
if claude_json_path.exists() and claude_json_path.stat().st_size > 0:
    try:
        claude_data = json.loads(claude_json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        backup = claude_json_path.with_suffix(claude_json_path.suffix + ".bak")
        backup.write_bytes(claude_json_path.read_bytes())
        print(f"Existing Claude JSON was invalid; backed it up to {backup}")
        claude_data = {}

if not isinstance(claude_data, dict):
    claude_data = {}

claude_data["hasCompletedOnboarding"] = True
claude_json_path.write_text(json.dumps(claude_data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
claude_json_path.chmod(0o600)
PY
}

echo "Setting up Claude Code for irouter.io..."
echo "  base url:    $BASE_URL"
echo "  model:       $MODEL_ID"
echo "  auth header: $AUTH_HEADER"
echo "  installer:   $INSTALL_METHOD"
echo "  settings:    $SETTINGS_PATH"

install_claude_code
write_claude_settings

echo
echo "Claude Code irouter.io config written to $SETTINGS_PATH"
echo "Run Claude Code with:"
echo "  claude"

if [[ "$RUN_SMOKE_TEST" -eq 1 ]]; then
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH; cannot run smoke test"
  echo
  echo "Running smoke test..."
  claude -p "Reply with exactly: irouter claude code ok"
fi

echo "Done."
