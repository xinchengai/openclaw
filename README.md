# OpenClaw Setup Scripts

This repository contains helper scripts for configuring OpenClaw on a server.

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
