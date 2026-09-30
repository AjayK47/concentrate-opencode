# Concentrate for opencode

Use [Concentrate AI](https://concentrate.ai) as a model provider in [opencode](https://opencode.ai) — one API key for Claude, GPT, Gemini, Grok, Kimi, GLM, DeepSeek, Qwen and 150+ other models.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.sh | bash
```

You'll need:

1. A Concentrate API key (`sk-cn-...`) from [concentrate.ai/api-keys](https://concentrate.ai/api-keys)
2. [opencode](https://opencode.ai) installed
3. `curl` and `python3`

Then launch `opencode`, run `/models`, and pick any `concentrate/...` model.

### Options

```bash
# Non-interactive
curl -fsSL https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.sh | bash -s -- --key sk-cn-... --model claude-sonnet-5-5

# Add the provider without changing your default model
curl -fsSL https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.sh | bash -s -- --no-default
```

| Flag | Description |
|---|---|
| `--key`, `-k` | API key (otherwise read from `CONCENTRATE_API_KEY`, opencode's stored key, or a prompt) |
| `--model`, `-m` | Make `concentrate/<model>` opencode's default model |
| `--no-default` | Leave opencode's default model unchanged |

Re-run the script anytime to pick up newly added models.

## What it changes

- **`~/.config/opencode/opencode.json`** (or `opencode.jsonc` if you have one) — adds a `concentrate` provider with every model from `https://api.concentrate.ai/v1/models/`, including context limits, pricing and tool/vision/reasoning support. Other settings are kept.
- **`~/.local/share/opencode/auth.json`** — stores your API key, the same place `opencode auth login` does (file mode `600`).

Both files are backed up next to the original (`*.backup.<timestamp>`) before being changed. Comments in an `opencode.jsonc` are not preserved; the backup keeps them.

## Manual setup

Add this to `~/.config/opencode/opencode.json`, listing the models you want:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "concentrate": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Concentrate",
      "env": ["CONCENTRATE_API_KEY"],
      "options": { "baseURL": "https://api.concentrate.ai/v1" },
      "models": {
        "claude-sonnet-5-5": { "name": "Claude Sonnet 5.5", "tool_call": true },
        "gpt-5.5": { "name": "GPT-5.5", "tool_call": true }
      }
    }
  }
}
```

Then either `export CONCENTRATE_API_KEY=sk-cn-...` or run `opencode auth login`, choose **Other**, and enter `concentrate` as the provider ID.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/uninstall-opencode.sh | bash
```

Removes the `concentrate` provider, any `concentrate/...` default model, and the stored key. `CONCENTRATE_API_KEY` in your shell profile is left alone since other Concentrate integrations share it.

## Troubleshooting

- **Invalid API key** — check it starts with `sk-cn` and has no extra spaces.
- **No Concentrate models in `/models`** — run `opencode models concentrate`; if it's empty, re-run the setup script.
- **A model doesn't use tools** — a few models (e.g. `deepseek-r1`) don't support tool calling, so opencode's agent can only chat with them.

Support: support@concentrate.ai
