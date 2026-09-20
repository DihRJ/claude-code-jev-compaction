# Claude Code + Jev: relevance-based context compaction

[Português](README.pt-BR.md) · **English**

A practical guide to putting a LiteLLM gateway between Claude Code and the
Anthropic API, using the **Jev** model (TypeSafe AI) to drop tool results that
no longer serve the current task, before they reach the expensive model.

Originally written in Portuguese, because almost no material on this exists in
PT-BR. This English version is a full translation.

---

## The problem

In a long agent session, the history piles up tool results that are no longer
useful: a file read ten turns ago, a search that found nothing, a grep down a
path you abandoned.

That dead weight keeps being sent as input tokens on **every** following
request. You pay again, every turn, for information that is already spent.

## The solution

Jev is a model that reads text but never writes text back. It takes a state and
returns typed decisions with calibrated probability.

As a LiteLLM guardrail, it evaluates each completed tool exchange and answers a
binary question: **is this still needed to finish the current task?**

Anything below the threshold is replaced by a removal notice. The cut is all or
nothing per block: a result is either kept in full or erased. Nothing is
summarized or paraphrased, so whatever survives stays auditable.

```
Claude Code  ->  LiteLLM (localhost:4000)  ->  Anthropic API
                       |
                       v
                   Jev API
              (decides what to cut)
```

---

## Requirements

- macOS or Linux with Python 3.10 or newer
- An Anthropic API key
- A TypeSafe AI key (Jev access)
- Claude Code installed

---

## Step 1: install LiteLLM

> **Heads up:** the `typesafe` guardrail is not in the stable release yet.
> The `--pre` flag is mandatory.

```bash
mkdir -p ~/litellm-jev && cd ~/litellm-jev
python3 -m venv .venv
source .venv/bin/activate
pip install --pre -U 'litellm[proxy]'
```

Confirm the guardrail came along:

```bash
ls .venv/lib/python3.*/site-packages/litellm/proxy/guardrails/guardrail_hooks/ | grep -i typesafe
```

If it does not print `typesafe`, try the latest code from the repository:

```bash
pip install -U 'litellm[proxy] @ git+https://github.com/BerriAI/litellm.git@main'
```

## Step 2: environment variables

Add to your `~/.zshrc` (or `~/.bashrc`):

```bash
export TYPESAFE_API_KEY="your-typesafe-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
export LITELLM_MASTER_KEY="sk-generated-below"
```

To generate the master key:

```bash
echo "sk-$(openssl rand -hex 24)"
```

Then:

```bash
source ~/.zshrc
chmod 600 ~/.zshrc
```

## Step 3: config.yaml

Copy `config.yaml.example` from this repository to `~/litellm-jev/config.yaml`.

> **Do not use editors that turn straight quotes into curly ones** (macOS
> TextEdit, for one). It breaks the YAML silently. Prefer `cat > file` with a
> heredoc, VS Code, or nano.

What matters in that file:

- `mode: pre_call` is mandatory, because the guardrail only transforms the input
- `default_on: true` compacts every request, no opt-in
- The `model_name: "*"` block catches any Anthropic model, including Claude
  Code's background model and future releases
- `relevance_threshold: 0.2` is the cutoff, tune it later

## Step 4: start the proxy

First run in the foreground, so you can see errors:

```bash
litellm --config ~/litellm-jev/config.yaml
```

Look for the loaded models in the output and the line
`Uvicorn running on http://0.0.0.0:4000`.

For daily use, copy the functions from `zshrc-snippet.sh` in this repository.
After that, `jevup` is all you need.

## Step 5: point Claude Code at the proxy

The global `settings.json` applies to every project, current and future.

> **If the file already exists, back it up and merge.** Overwriting wipes
> `permissions`, `hooks`, `enabledPlugins`, and the rest of your configuration.

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null

python3 - << 'PY'
import json, pathlib, os
p = pathlib.Path.home() / ".claude"
bak = p / "settings.json.bak"
data = json.loads(bak.read_text()) if bak.exists() else {}
data["env"] = {
    "ANTHROPIC_BASE_URL": "http://0.0.0.0:4000",
    "ANTHROPIC_AUTH_TOKEN": os.environ["LITELLM_MASTER_KEY"],
}
(p / "settings.json").write_text(json.dumps(data, indent=2, ensure_ascii=False))
print("preserved keys:", list(data.keys()))
PY

chmod 600 ~/.claude/settings.json
```

## Step 6: verify

```bash
curl -i -s http://0.0.0.0:4000/v1/messages \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"sonnet","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
  | grep -i "guardrail\|HTTP/"
```

Expected:

```
HTTP/1.1 200 OK
x-litellm-applied-guardrails: jev-compaction
```

`/v1/messages` is the endpoint Claude Code actually uses. Validating only
`/v1/chat/completions` does not prove it works in the real flow.

## Step 7: use it

```bash
cd ~/any-project
claude
```

Nothing changes in your workflow. The compaction is invisible.

---

## Traps that cost time

**`API Error: 400 No connected db.`**
The message is misleading. With no database, the master key is the only accepted
credential, and any other key produces this error. Translated: the key the
client sent does not match the proxy's master key. There is already a PR in
LiteLLM to turn this into a 401.

**You rotated the master key and it still fails**
The proxy reads the master key only at startup. Restart it after changing.

**`Detected a custom API key in your environment`**
Claude Code asks whether it should use `ANTHROPIC_API_KEY` from the environment.
Answer **No**, otherwise it may talk to Anthropic directly and bypass the proxy.
If it still bypasses it:

```bash
env -u ANTHROPIC_API_KEY claude
```

**claude.ai connectors disabled**
Expected. With `ANTHROPIC_BASE_URL` pointing at a gateway, the session runs in
API Usage Billing mode and your claude.ai account connectors are unavailable.
For a project that needs them:

```bash
env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN claude
```

**A model with a suffix, like `opus[1m]`**
The wildcard `model_name: "*"` block in the config handles it. Without it, any
undeclared model breaks.

**The Admin UI at `/ui` opens empty**
It depends on a database. With no Postgres there are no spend logs and no
guardrail metrics. To measure the savings with real numbers, run with
`DATABASE_URL` pointing at a Postgres.

**A future update breaks everything silently**
A `pip install -U litellm` without `--pre` reinstalls the stable version, which
does not have the guardrail. The proxy starts up normally and the compaction
simply stops happening.

---

## Honest limitations

- **It only acts on completed tool exchanges.** System messages, the last user
  message, and the most recent exchange are never touched. A short conversation
  with no tool use has nothing to compact.
- **It does not measure itself.** With no database, there is no way to quantify
  the savings.
- **It fails open by default.** If TypeSafe is down, the request goes through
  uncompacted, with a warning in the log. To fail closed, use
  `unreachable_fallback: fail_closed`.
- **Pre-release.** The integration has not reached the stable channel yet.

---

## References

- [TypeSafe guardrail in LiteLLM](https://docs.litellm.ai/docs/proxy/guardrails/typesafe)
- [TypeSafe AI](https://typesafe.ai)

## License

MIT
