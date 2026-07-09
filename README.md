# OpenClaw Setup Scripts

This repository contains helper scripts for configuring OpenClaw and Claude Code on a server.

## Configure irouter.io

Run interactively:

```bash
chmod +x tools/openclaw_setup_irouter.sh
./tools/openclaw_setup_irouter.sh
```

The model prompt defaults to `MiniMax-M2.7`. The API key prompt is hidden.

Run non-interactively:

```bash
OPENCLAW_API_KEY="your-api-key" ./tools/openclaw_setup_irouter.sh
```

Override the model:

```bash
OPENCLAW_API_KEY="your-api-key" ./tools/openclaw_setup_irouter.sh --model "MiniMax-M2.7"
```

## Configure Claude Code with irouter.io

This script installs Claude Code through npm by default, because some servers
return `403` when downloading the official native installer from `claude.ai`.
Node.js 18+ and npm are required.

Run interactively:

```bash
chmod +x tools/claude_code_setup_irouter.sh
./tools/claude_code_setup_irouter.sh
```

The model prompt defaults to `MiniMax-M2.7`. The API key prompt is hidden.

Run non-interactively:

```bash
CLAUDE_IROUTER_API_KEY="your-api-key" ./tools/claude_code_setup_irouter.sh
```

Override the model:

```bash
CLAUDE_IROUTER_API_KEY="your-api-key" ./tools/claude_code_setup_irouter.sh --model "MiniMax-M2.7"
```

If your gateway expects `X-Api-Key` instead of `Authorization: Bearer`, use:

```bash
CLAUDE_IROUTER_API_KEY="your-api-key" ./tools/claude_code_setup_irouter.sh --auth-header api-key
```

Try the official native installer first, then fall back to npm:

```bash
CLAUDE_IROUTER_API_KEY="your-api-key" ./tools/claude_code_setup_irouter.sh --install-method auto
```

## Configure Feishu Multi-Agent

Download and run the Feishu multi-agent setup script:

```bash
curl -fsSL -o setup_feishu_multi_agent.sh https://raw.githubusercontent.com/xinchengai/openclaw/main/tools/setup_feishu_multi_agent.sh
chmod +x setup_feishu_multi_agent.sh
./setup_feishu_multi_agent.sh
```

The script configures one main Feishu app plus optional sub-agent Feishu apps. It uses WebSocket / persistent connection mode, so no public webhook URL is required.

Non-interactive example:

```bash
./setup_feishu_multi_agent.sh \
  --domain feishu \
  --group-id oc_xxx \
  --agent xiezuo:写作助理:cli_xiezuo:xiezuo_secret \
  --agent cehua:策划助理:cli_cehua:cehua_secret
```

The script inherits your Feishu user `open_id` from `channels.feishu.allowFrom[0]`. The main account is fixed as `main:主助理` and inherits the already-onboarded Feishu `appId` / `appSecret` from `~/.openclaw/openclaw.json`. Run this first if Feishu has not been onboarded yet:

```bash
openclaw channels login --channel feishu
```

Each run rebuilds the Feishu agents/accounts managed by this script, so sub bots omitted from the latest run are removed from the generated OpenClaw config.

Feishu-side requirements:

- Each Feishu app is published or available to your tenant.
- Each app subscribes to `im.message.receive_v1`.
- Event connection mode is WebSocket / persistent connection.
- Add the main bot and every sub bot to the target group.
- In the group, first `@` every sub bot with `ping` so OpenClaw can create group sessions.
