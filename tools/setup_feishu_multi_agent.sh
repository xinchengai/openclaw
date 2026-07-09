#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DOMAIN="feishu"
OWNER_OPEN_ID=""
GROUP_IDS=()
MAIN_CONFIG=""
AGENT_CONFIGS=()
NO_RESTART=0
DRY_RUN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

usage() {
  cat <<EOF
OpenClaw Feishu Multi-Agent setup v${SCRIPT_VERSION}

Usage:
  $0 [options]

Interactive mode:
  $0

Non-interactive example:
  $0 \\
    --domain feishu \\
    --owner-open-id ou_xxx \\
    --group-id oc_xxx \\
    --main main:主助手 \\
    --agent xiezuo:写作助理:cli_xiezuo:xiezuo_secret \\
    --agent cehua:策划助理:cli_cehua:cehua_secret

Options:
  --domain feishu|lark|https://...        Feishu/Lark API domain. Default: feishu
  --owner-open-id ou_xxx                  Your Feishu open_id.
  --group-id oc_xxx                       Allowed Feishu group chat_id. Can repeat.
  --main accountId:name                   Main Feishu account. Inherits existing onboarded appId/appSecret.
  --main accountId:appId:appSecret:name   Optional explicit main account override.
  --agent accountId:name:appId:appSecret
                                          Sub agent Feishu app/account. Can repeat.
  --no-restart                            Do not validate/restart/probe gateway.
  --dry-run                               Print redacted generated config only.
  -h, --help                              Show this help.

Notes:
  - Feishu bot events should use WebSocket / persistent connection.
  - Run OpenClaw Feishu onboarding first for the main bot: openclaw channels login --channel feishu
  - Each Feishu app should subscribe to im.message.receive_v1.
  - Add every bot app to the target Feishu group before testing.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed or not on PATH"
}

sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g;s/^-+//;s/-+$//'
}

validate_account_id() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "Invalid accountId '$value'. Use letters, numbers, _ or -."
}

parse_main_config() {
  local value="$1"
  local parts_count
  parts_count="$(awk -F: '{print NF}' <<<"$value")"
  local main_account_id main_name main_app_id main_app_secret extra
  case "$parts_count" in
    2)
      IFS=':' read -r main_account_id main_name <<<"$value"
      [[ -n "${main_account_id:-}" && -n "${main_name:-}" ]] || die "--main format must be accountId:name"
      ;;
    4)
      IFS=':' read -r main_account_id main_app_id main_app_secret main_name extra <<<"$value"
      [[ -z "${extra:-}" ]] || die "--main format must be accountId:name or accountId:appId:appSecret:name"
      [[ -n "${main_account_id:-}" && -n "${main_app_id:-}" && -n "${main_app_secret:-}" && -n "${main_name:-}" ]] || die "--main format must be accountId:appId:appSecret:name"
      ;;
    *)
      die "--main format must be accountId:name or accountId:appId:appSecret:name"
      ;;
  esac
  validate_account_id "$main_account_id"
}

parse_agent_config_line() {
  local value="$1"
  local account_id name app_id app_secret extra
  IFS=':' read -r account_id name app_id app_secret extra <<<"$value"
  [[ -z "${extra:-}" ]] || die "--agent format must be accountId:name:appId:appSecret"
  [[ -n "${account_id:-}" && -n "${name:-}" && -n "${app_id:-}" && -n "${app_secret:-}" ]] || die "--agent format must be accountId:name:appId:appSecret"
  validate_account_id "$account_id"
}

check_openclaw() {
  require_cmd openclaw
  local version
  version="$(openclaw --version 2>/dev/null || openclaw -v 2>/dev/null || true)"
  version="$(printf '%s' "$version" | head -1)"
  info "OpenClaw version: ${version:-unknown}"

  if [[ "$version" =~ ([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    if (( major < 6 || (major == 6 && minor < 10) )); then
      warn "OpenClaw Feishu channel requires a recent version. Your target version should be 6.10 or newer."
    fi
  else
    warn "Could not parse OpenClaw version; continuing."
  fi
}

ensure_feishu_plugin_hint() {
  info "Checking Feishu plugin availability..."
  if openclaw plugins install @openclaw/feishu >/dev/null 2>&1; then
    success "Feishu plugin is installed or already available."
    return 0
  fi

  warn "Could not install/check @openclaw/feishu automatically."
  warn "If gateway startup fails, run: openclaw channels login --channel feishu"
}

collect_interactive() {
  echo
  echo "============================================"
  echo "   OpenClaw Feishu Multi-Agent Setup"
  echo "============================================"
  echo

  read -r -p "Feishu domain [feishu]: " input_domain
  DOMAIN="${input_domain:-feishu}"

  read -r -p "Your Feishu open_id (ou_xxx): " OWNER_OPEN_ID
  read -r -p "Allowed group chat_id (oc_xxx): " input_group_id
  GROUP_IDS=("$input_group_id")

  echo
  echo "--- Main Feishu app ---"
  read -r -p "Main accountId [main]: " main_account_id
  main_account_id="${main_account_id:-main}"
  read -r -p "Main display name [主助手]: " main_name
  main_name="${main_name:-主助手}"
  MAIN_CONFIG="${main_account_id}:${main_name}"
  info "Main appId/appSecret will be inherited from the existing onboarded Feishu config."

  echo
  echo "--- Sub Feishu agents ---"
  echo "Format: accountId:name:appId:appSecret"
  echo "Example: xiezuo:写作助理:cli_xxx:secret_xxx"
  echo "Press Enter on an empty line to finish."
  while true; do
    read -r -p "Sub agent: " sub_agent_config
    [[ -n "$sub_agent_config" ]] || break
    parse_agent_config_line "$sub_agent_config"
    AGENT_CONFIGS+=("$sub_agent_config")
    local sub_account_id sub_name sub_app_id sub_app_secret
    IFS=':' read -r sub_account_id sub_name sub_app_id sub_app_secret <<<"$sub_agent_config"
    echo "  Added: $sub_account_id / $sub_name"
  done
}

validate_inputs() {
  [[ "$DOMAIN" == "feishu" || "$DOMAIN" == "lark" || "$DOMAIN" =~ ^https:// ]] || die "--domain must be feishu, lark, or an https:// URL"
  [[ "$OWNER_OPEN_ID" =~ ^ou_ ]] || die "owner open_id should look like ou_xxx"
  [[ "${#GROUP_IDS[@]}" -gt 0 ]] || die "At least one --group-id is required"
  local group_id
  for group_id in "${GROUP_IDS[@]}"; do
    [[ "$group_id" =~ ^oc_ ]] || die "group chat_id should look like oc_xxx: $group_id"
  done
  [[ -n "$MAIN_CONFIG" ]] || die "--main is required"
  parse_main_config "$MAIN_CONFIG"

  local main_account_id main_name main_app_id main_app_secret
  if [[ "$(awk -F: '{print NF}' <<<"$MAIN_CONFIG")" -eq 2 ]]; then
    IFS=':' read -r main_account_id main_name <<<"$MAIN_CONFIG"
  else
    IFS=':' read -r main_account_id main_app_id main_app_secret main_name <<<"$MAIN_CONFIG"
  fi
  local seen_accounts=" $main_account_id "
  local seen_agent_ids=" feishu-main "

  local agent
  for agent in "${AGENT_CONFIGS[@]}"; do
    parse_agent_config_line "$agent"
    local account_id name app_id app_secret agent_id
    IFS=':' read -r account_id name app_id app_secret <<<"$agent"
    agent_id="feishu-$(sanitize_id "$account_id")"
    [[ "$seen_accounts" != *" $account_id "* ]] || die "Duplicate accountId: $account_id"
    [[ "$seen_agent_ids" != *" $agent_id "* ]] || die "Duplicate generated agent id: $agent_id"
    seen_accounts="${seen_accounts}${account_id} "
    seen_agent_ids="${seen_agent_ids}${agent_id} "
  done
}

write_workspace_file() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

create_workspace_files() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0

  local main_account_id main_name main_app_id main_app_secret
  if [[ "$(awk -F: '{print NF}' <<<"$MAIN_CONFIG")" -eq 2 ]]; then
    IFS=':' read -r main_account_id main_name <<<"$MAIN_CONFIG"
  else
    IFS=':' read -r main_account_id main_app_id main_app_secret main_name <<<"$MAIN_CONFIG"
  fi
  local main_agent_id="feishu-main"
  local main_workspace="$OPENCLAW_HOME/workspace-$main_agent_id"
  local main_agent_dir="$OPENCLAW_HOME/agents/$main_agent_id/agent"
  mkdir -p "$main_workspace" "$main_agent_dir"

  local roster="无"
  if [[ "${#AGENT_CONFIGS[@]}" -gt 0 ]]; then
    roster=""
    local cfg account_id name app_id app_secret agent_id
    for cfg in "${AGENT_CONFIGS[@]}"; do
      IFS=':' read -r account_id name app_id app_secret <<<"$cfg"
      agent_id="feishu-$(sanitize_id "$account_id")"
      roster="${roster}- ${name} / agent id: ${agent_id} / accountId: ${account_id}
"
    done
  fi

  write_workspace_file "$main_workspace/IDENTITY.md" "# IDENTITY.md - Who Am I?

- Name: ${main_name}
- Channel: Feishu
- Account ID: ${main_account_id}
- Role: 主协调助手"

  write_workspace_file "$main_workspace/SOUL.md" "# SOUL.md - 我是谁与如何行为

## 身份
我是飞书主协调助手，负责理解用户需求并把任务分配给合适的子 agent。

## 可用子 agent
${roster}
## 协作规则
- 使用 sessions_list 查找子 agent 的可见会话。
- 使用 sessions_send 给子 agent 派发任务。
- sessions_send 的目标必须是 sessions_list 返回的 sessionKey 或 sessionId。
- 不要把飞书名称、群名、@用户名或 accountId 当作 sessions_send 目标。
- 优先选择和当前用户请求同一个飞书群对应的 group session。
- 如果找不到子 agent 的同群会话，提示用户先在该群 @对应子机器人发送 ping，建立群会话。
- 派单后告诉用户任务已安排即可，不要等待 sessions_send 的超时结果。

## 群聊规则
- 只在被 @mention 时响应。
- 当明显是 @其他子机器人 的问题时保持沉默，除非用户明确要求我协调。"

  local cfg account_id name app_id app_secret agent_id workspace agent_dir
  for cfg in "${AGENT_CONFIGS[@]}"; do
    IFS=':' read -r account_id name app_id app_secret <<<"$cfg"
    agent_id="feishu-$(sanitize_id "$account_id")"
    workspace="$OPENCLAW_HOME/workspace-$agent_id"
    agent_dir="$OPENCLAW_HOME/agents/$agent_id/agent"
    mkdir -p "$workspace" "$agent_dir"

    write_workspace_file "$workspace/IDENTITY.md" "# IDENTITY.md - Who Am I?

- Name: ${name}
- Channel: Feishu
- Account ID: ${account_id}
- Role: ${name}"

    write_workspace_file "$workspace/SOUL.md" "# SOUL.md - 我是谁与如何行为

## 身份
我是飞书 ${name}。

## 行为规则
- 群聊中只在被 @mention 时响应。
- 私聊中按访问控制响应。
- 收到主 agent 通过 sessions_send 发来的 inter-session task 时，按任务要求执行。

## 任务执行
- 读取任务里的原始用户需求和来源群说明。
- 优先把最终结果直接回复到来源飞书群会话。
- 如果当前没有可用的来源群会话，回复主 agent：没有可用的来源群会话，请先在群里 @我 发送 ping 建立会话。
- 完成任务后停止，不要等待进一步指令。"
  done
}

build_config() {
  export OPENCLAW_CONFIG OPENCLAW_HOME DOMAIN OWNER_OPEN_ID MAIN_CONFIG DRY_RUN
  export GROUP_IDS_JOINED="$(IFS=$'\n'; printf '%s' "${GROUP_IDS[*]}")"
  export AGENT_CONFIGS_JOINED="$(IFS=$'\n'; printf '%s' "${AGENT_CONFIGS[*]:-}")"

  python3 <<'PY'
import copy
import json
import os
import re
import shutil
from datetime import datetime
from pathlib import Path

config_path = Path(os.environ["OPENCLAW_CONFIG"]).expanduser()
openclaw_home = Path(os.environ["OPENCLAW_HOME"]).expanduser()
domain = os.environ["DOMAIN"]
owner_open_id = os.environ["OWNER_OPEN_ID"]
dry_run = os.environ["DRY_RUN"] == "1"

group_ids = [x for x in os.environ.get("GROUP_IDS_JOINED", "").splitlines() if x]
agent_lines = [x for x in os.environ.get("AGENT_CONFIGS_JOINED", "").splitlines() if x]

def sanitize_id(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9-]+", "-", value)
    return value.strip("-")

def parse_main(value: str) -> dict:
    parts = value.split(":")
    if len(parts) == 2:
        account_id, name = parts
        app_id = None
        app_secret = None
    elif len(parts) == 4:
        account_id, app_id, app_secret, name = parts
    else:
        raise SystemExit("--main format must be accountId:name or accountId:appId:appSecret:name")
    return {
        "accountId": account_id,
        "appId": app_id,
        "appSecret": app_secret,
        "name": name,
        "agentId": "feishu-main",
    }

def parse_agent(value: str) -> dict:
    account_id, name, app_id, app_secret = value.split(":", 3)
    return {
        "accountId": account_id,
        "appId": app_id,
        "appSecret": app_secret,
        "name": name,
        "agentId": f"feishu-{sanitize_id(account_id)}",
    }

main = parse_main(os.environ["MAIN_CONFIG"])
agents = [parse_agent(x) for x in agent_lines]
managed_agent_ids = [main["agentId"], *[a["agentId"] for a in agents]]
account_ids = [main["accountId"], *[a["accountId"] for a in agents]]

if config_path.exists() and config_path.stat().st_size > 0:
    with config_path.open("r", encoding="utf-8") as f:
        config = json.load(f)
else:
    config = {}

if not isinstance(config, dict):
    config = {}

original = copy.deepcopy(config)

config.setdefault("agents", {})
config["agents"].setdefault("defaults", {})
config["agents"]["defaults"].setdefault("thinkingDefault", "adaptive")
config["agents"]["defaults"].setdefault("workspace", str(openclaw_home / "workspace"))
existing_agents = config["agents"].get("list", [])
if not isinstance(existing_agents, list):
    existing_agents = []
existing_agents = [a for a in existing_agents if a.get("id") not in managed_agent_ids]

def agent_entry(agent_id: str) -> dict:
    return {
        "id": agent_id,
        "workspace": str(openclaw_home / f"workspace-{agent_id}"),
        "agentDir": str(openclaw_home / "agents" / agent_id / "agent"),
    }

main_entry = agent_entry(main["agentId"])
main_entry["subagents"] = {"allowAgents": [a["agentId"] for a in agents]}
existing_agents.append(main_entry)
for agent in agents:
    existing_agents.append(agent_entry(agent["agentId"]))
config["agents"]["list"] = existing_agents

bindings = config.get("bindings", [])
if not isinstance(bindings, list):
    bindings = []
bindings = [
    b for b in bindings
    if not (
        isinstance(b, dict)
        and b.get("match", {}).get("channel") == "feishu"
        and (
            b.get("agentId") in managed_agent_ids
            or b.get("match", {}).get("accountId") in account_ids
        )
    )
]
bindings.append({"agentId": main["agentId"], "match": {"channel": "feishu", "accountId": main["accountId"]}})
for agent in agents:
    bindings.append({"agentId": agent["agentId"], "match": {"channel": "feishu", "accountId": agent["accountId"]}})
config["bindings"] = bindings

config.setdefault("tools", {})
config["tools"]["sessions"] = {"visibility": "all"}
agent_to_agent = config["tools"].get("agentToAgent", {})
if not isinstance(agent_to_agent, dict):
    agent_to_agent = {}
agent_to_agent["enabled"] = True
allow = agent_to_agent.get("allow", [])
if not isinstance(allow, list):
    allow = []
for agent_id in managed_agent_ids:
    if agent_id not in allow:
        allow.append(agent_id)
agent_to_agent["allow"] = allow
config["tools"]["agentToAgent"] = agent_to_agent

config["session"] = config.get("session", {})
if not isinstance(config["session"], dict):
    config["session"] = {}
config["session"]["dmScope"] = "main"

config.setdefault("channels", {})
feishu = config["channels"].get("feishu", {})
if not isinstance(feishu, dict):
    feishu = {}

def inherit_main_credentials(feishu_config: dict, main_account_id: str) -> tuple:
    app_id = feishu_config.get("appId")
    app_secret = feishu_config.get("appSecret")
    accounts_config = feishu_config.get("accounts", {})
    if not isinstance(accounts_config, dict):
        accounts_config = {}

    default_account_id = feishu_config.get("defaultAccount")
    candidates = []
    for candidate in (main_account_id, default_account_id, "default", "main"):
        if candidate and candidate not in candidates:
            candidates.append(candidate)

    for candidate in candidates:
        account = accounts_config.get(candidate)
        if not isinstance(account, dict):
            continue
        app_id = app_id or account.get("appId")
        app_secret = app_secret or account.get("appSecret")
        if app_id and app_secret:
            return app_id, app_secret

    return app_id, app_secret

if not main.get("appId") or not main.get("appSecret"):
    inherited_app_id, inherited_app_secret = inherit_main_credentials(feishu, main["accountId"])
    main["appId"] = main.get("appId") or inherited_app_id
    main["appSecret"] = main.get("appSecret") or inherited_app_secret

if not main.get("appId") or not main.get("appSecret"):
    raise SystemExit(
        "Could not inherit main Feishu appId/appSecret from existing config. "
        "Run 'openclaw channels login --channel feishu' first, or pass "
        "--main accountId:appId:appSecret:name."
    )

accounts = {}
accounts[main["accountId"]] = {
    "appId": main["appId"],
    "appSecret": main["appSecret"],
    "name": main["name"],
    "enabled": True,
}
for agent in agents:
    accounts[agent["accountId"]] = {
        "appId": agent["appId"],
        "appSecret": agent["appSecret"],
        "name": agent["name"],
        "enabled": True,
    }

groups = feishu.get("groups", {})
if not isinstance(groups, dict):
    groups = {}
for group_id in group_ids:
    current = groups.get(group_id, {})
    if not isinstance(current, dict):
        current = {}
    current["requireMention"] = True
    current["allowFrom"] = [owner_open_id]
    groups[group_id] = current

feishu.update({
    "enabled": True,
    "connectionMode": "websocket",
    "domain": domain,
    "defaultAccount": main["accountId"],
    "accounts": accounts,
    "dmPolicy": "allowlist",
    "allowFrom": [owner_open_id],
    "groupPolicy": "allowlist",
    "groupAllowFrom": group_ids,
    "requireMention": True,
    "groups": groups,
    "streaming": True,
})
config["channels"]["feishu"] = feishu

def redact(value):
    if isinstance(value, dict):
        return {k: ("***REDACTED***" if k.lower() in {"appsecret", "botToken".lower()} else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value

if dry_run:
    print(json.dumps(redact(config), indent=2, ensure_ascii=False))
else:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    if config_path.exists():
        backup = config_path.with_name(config_path.name + f".backup-feishu-multiagent-{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        shutil.copy(config_path, backup)
        print(f"Backed up config to: {backup}")
    with config_path.open("w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"Wrote config to: {config_path}")
PY
}

run_post_checks() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  if [[ "$NO_RESTART" -eq 1 ]]; then
    warn "Skipped restart. Run manually:"
    echo "  openclaw config validate && openclaw gateway restart && openclaw channels status --probe"
    return 0
  fi

  info "Validating OpenClaw config..."
  openclaw config validate
  info "Restarting OpenClaw gateway..."
  openclaw gateway restart
  info "Checking channel status..."
  openclaw channels status --probe || warn "Channel probe reported a problem. Check: openclaw logs --follow"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain requires a value"
        DOMAIN="$2"
        shift 2
        ;;
      --owner-open-id)
        [[ $# -ge 2 ]] || die "--owner-open-id requires a value"
        OWNER_OPEN_ID="$2"
        shift 2
        ;;
      --group-id)
        [[ $# -ge 2 ]] || die "--group-id requires a value"
        GROUP_IDS+=("$2")
        shift 2
        ;;
      --main)
        [[ $# -ge 2 ]] || die "--main requires a value"
        MAIN_CONFIG="$2"
        shift 2
        ;;
      --agent)
        [[ $# -ge 2 ]] || die "--agent requires a value"
        AGENT_CONFIGS+=("$2")
        shift 2
        ;;
      --no-restart)
        NO_RESTART=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  require_cmd python3
  check_openclaw
  if [[ -z "$OWNER_OPEN_ID" || "${#GROUP_IDS[@]}" -eq 0 || -z "$MAIN_CONFIG" ]]; then
    collect_interactive
  fi
  validate_inputs
  if [[ "$DRY_RUN" -eq 0 ]]; then
    ensure_feishu_plugin_hint
  fi
  create_workspace_files
  build_config
  run_post_checks

  success "Feishu multi-agent setup complete."
  echo
  echo "Next Feishu-side checks:"
  echo "  1. Each app is published/available."
  echo "  2. Each app subscribes to im.message.receive_v1."
  echo "  3. Event connection uses WebSocket / persistent connection."
  echo "  4. Add every bot to the target group."
  echo "  5. In the group, @each sub bot with ping before asking the main bot to delegate."
}

main "$@"
