# Claude Code + Jev: relevance-based context compaction

[Português](README.pt-BR.md) · **English**

A practical guide to putting a LiteLLM gateway between Claude Code and the
Anthropic API, using the **Jev** model (TypeSafe AI) to drop tool results that
no longer serve the current task, before they reach the expensive model.

Originally written in Portuguese, because almost no material on this exists in
PT-BR. This English version is a full translation.

> [!WARNING]
> **This setup takes your session off the Pro or Max subscription and starts
> billing per token against your API account.** If you use Claude Code inside a
> subscription, it will likely **raise** your cost, not cut it. Read
> [Who pays the bill](#who-pays-the-bill) before Step 1.

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

## Who pays the bill

Step 5 points Claude Code at the gateway with its own credential
(`ANTHROPIC_AUTH_TOKEN`). From that moment on, **your claude.ai subscription is
no longer used in that session**: the credential replaces the login, the plan's
usage limits no longer apply, and usage is billed per token to whoever owns the
key the gateway forwards, which here is your Claude Console account.

Anthropic's documentation says it outright:

> While a gateway credential variable or `apiKeyHelper` is active, a developer's
> claude.ai subscription isn't used: the credential replaces the subscription
> login for that session, and the subscription's usage limits don't apply. That
> traffic is billed per token to whoever owns the credential the gateway
> forwards.
>
> ([Other LLM gateways](https://code.claude.com/docs/en/llm-gateway))

At [list price](https://platform.claude.com/docs/en/about-claude/pricing), that
is **$5 / $25 per million tokens** (input / output) on Claude Opus 5 and
**$2 / $10** on Claude Sonnet 5.

**What that means in practice:**

- **The savings land on the API bill, never on the subscription.** If you run
  Claude Code inside Pro or Max today, this setup trades zero marginal cost for
  per-token billing. Cutting 30% off a number that used to be zero is still more
  than zero.
- **Jev is a second meter.** Every request that goes through the guardrail is a
  billed call to TypeSafe, and it reads the whole history to decide what to cut.
  Add both up before concluding it came out cheap.
- **Set a ceiling before you start the proxy.** Set a workspace spend limit in
  the Claude Console
  ([how](https://platform.claude.com/docs/en/build-with-claude/workspaces#workspace-limits)).
  It is the only protection that does not depend on you remembering to check.
- **With no database you measure nothing.** Without `DATABASE_URL` the proxy
  writes no spend logs, so the savings stay a guess while the invoice does not.

`ANTHROPIC_BASE_URL` on its own does **not** change the billing. The credential
does.

### Keeping the subscription: one credential per header

**It works.** Claude Code sends its subscription OAuth token in `Authorization`,
and LiteLLM forwards it upstream, so Anthropic bills the Claude Max or Pro plan.
The catch is that the proxy also needs its own key to authenticate the caller,
and `Authorization` holds only one credential. The proxy key goes in a separate
header, `x-litellm-api-key`.

Diagnosed in [BerriAI/litellm#42170](https://github.com/BerriAI/litellm/issues/42170);
[#42219](https://github.com/BerriAI/litellm/pull/42219) makes the error say so.
Tested on LiteLLM `1.103.0rc1`.

**Proxy config**, with no `api_key` on any model:

```yaml
model_list:
  - model_name: "*"
    litellm_params:
      model: anthropic/*

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  forward_client_headers_to_llm_api: true
```

**Proxy environment.** `ANTHROPIC_API_KEY` must be absent, or LiteLLM uses it
upstream and bypasses the subscription silently:

```bash
env -u ANTHROPIC_API_KEY litellm --config config.yaml
```

**Client side.** Only the base URL and the proxy key in its own header, with no
credential of Claude Code's own:

```bash
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  ANTHROPIC_BASE_URL="http://127.0.0.1:4000" \
  ANTHROPIC_CUSTOM_HEADERS="x-litellm-api-key: $LITELLM_MASTER_KEY" \
  claude
```

**How to tell it worked.** `/status` shows `Login method: Claude Max account`
together with `Anthropic base URL`, and the proxy log shows `POST /v1/messages`
returning `200` with no `credit balance`, `invalid x-api-key` or
`No connected db` errors. `/status` alone is not proof: it looked right in the
broken setups too.

**What changes in this mode:**

- The plan's usage limits apply, not API spend. Expect the occasional `429` on
  heavy models, which Claude Code retries.
- Jev is still a separate meter billed by TypeSafe, at a fraction of a cent per
  request.
- Remote managed settings and organization policy are not fetched while a
  custom `ANTHROPIC_BASE_URL` is set.

**Why the earlier attempts failed.** Removing `master_key` to free
`Authorization` left the proxy unable to authenticate the caller, and a
`LITELLM_MASTER_KEY` or `ANTHROPIC_API_KEY` in the proxy's environment kept
overriding the config. Both traps are listed below.

To go back to the subscription for one project, use `claudeoff` from
`zshrc-snippet.sh`.

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

> **This is the step that switches the billing.** After it, the session leaves
> the subscription and starts spending API credits. See
> [Who pays the bill](#who-pays-the-bill).

> **If the file already exists, back it up and merge.** Overwriting wipes
> `permissions`, `hooks`, `enabledPlugins`, and the rest of your configuration.

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null

python3 - << 'PY'
import json, pathlib, os
p = pathlib.Path.home() / ".claude"
bak = p / "settings.json.bak"
data = json.loads(bak.read_text()) if bak.exists() else {}
env = data.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:4000"
env["ANTHROPIC_AUTH_TOKEN"] = os.environ["LITELLM_MASTER_KEY"]
(p / "settings.json").write_text(json.dumps(data, indent=2, ensure_ascii=False))
print("preserved keys:", list(data.keys()), "| env:", list(env))
PY

chmod 600 ~/.claude/settings.json
```

## Step 6: verify

```bash
curl -i -s http://127.0.0.1:4000/v1/messages \
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
Expected, and it is the visible symptom of the switch described in
[Who pays the bill](#who-pays-the-bill): the gateway credential replaces the
claude.ai login, so the account connectors are unavailable and the session is
billed per token. For a project that needs them:

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

**Environment variables leak into the proxy through a side door**
Two of them override your config without saying so, because LiteLLM reads them
straight from the environment of the process you started it in. If you launch
the proxy from a shell that sourced your `.zshrc`, they are there:

- `LITELLM_MASTER_KEY` re-enables master-key auth even after you removed
  `master_key` from `config.yaml`. Symptom: `400 No connected db.`
- `ANTHROPIC_API_KEY` is used to call Anthropic even with no `api_key` on the
  models, so it silently bills your API account. Symptom: `Your credit balance
  is too low` while you believed you were on the subscription.

Launch the proxy with `env -u VAR` for whichever one must not apply.

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
- **It is not free.** The setup trades the subscription for per-token billing
  and adds the TypeSafe bill on top. See [Who pays the bill](#who-pays-the-bill).
- **Pre-release.** The integration has not reached the stable channel yet.

---

## References

- [TypeSafe guardrail in LiteLLM](https://docs.litellm.ai/docs/proxy/guardrails/typesafe)
- [TypeSafe AI](https://typesafe.ai)

## License

MIT
