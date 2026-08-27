# `ox` — Claude Code on an OpenRouter model

`ox` runs Claude Code against an OpenRouter-hosted model (`stealth/ox-alpha`
by default) without touching the normal `claude` command, its settings, or
your login.

## Quick setup (do this once)

```powershell
cd C:\Users\<you>\ox
.\setup.ps1 -ApiKey "sk-or-v1-...your OpenRouter key..."
```

Open a **new** terminal (PATH changes don't apply to the current one) and run:

```
ox
```

That's it. Everything below is *why* the launcher is shaped the way it is —
read it before changing anything, because each piece works around a specific,
non-obvious failure that has no error message pointing at its real cause.

## What `setup.ps1` does

1. Stores your key as the user environment variable `OPENROUTER_API_KEY`
   (Windows Credential-style env var, not written into any file or repo).
2. Writes three files to this folder: `ox.ps1` (the launcher), `ox_proxy.js`
   (a small local proxy — see Bug 3), `ox.cmd` (a one-line wrapper so the
   bare word `ox` works from `cmd.exe` too).
3. Adds this folder to your user `PATH` if it isn't already there.
4. Checks the key against OpenRouter's `/v1/auth/key` endpoint.

Re-running `setup.ps1` is safe — it overwrites its own files and won't
duplicate the PATH entry.

## The three bugs, and why the fix looks the way it does

Getting from "point Claude Code at an OpenRouter model" to a working reply
took finding three independent, silent failure modes. Each one produced a
generic, misleading error — `[claude-code:unrecognized_model]` / *"There's an
issue with the selected model... it may not exist or you may not have
access to it"* — regardless of which of the three was actually the cause.
**That error message means "one of the three bugs below," not "the model
name is wrong."**

### Bug 1 — `ANTHROPIC_MODEL` alone isn't enough

Claude Code validates the model name client-side before ever sending a
request. Any model ID that doesn't contain `claude` or `anthropic` gets
rejected, *unless* you also set:

```
ANTHROPIC_CUSTOM_MODEL_OPTION = <same model id>
```

This is a real, documented option (`code.claude.com/docs/en/model-config.md`,
"Add a custom model option") — verified by finding the literal string and the
`if (n === m.ANTHROPIC_CUSTOM_MODEL_OPTION) return {valid: true}` check inside
the installed `claude.exe` binary itself, not just trusting a doc page.

### Bug 2 — `CLAUDE_CODE_MAX_CONTEXT_TOKENS` silently mangles the model name

Setting `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (e.g. to advertise a 1M-token
context window) makes Claude Code **append `[1m]` to the model name** before
sending it upstream — it's mimicking Anthropic's real naming convention for
their own 1M-context beta models (e.g. `claude-sonnet-4-5-20250929[1m]`).
For a non-Anthropic model this just produces a string OpenRouter has never
heard of (`stealth/ox-alpha[1m]`), and the failure looks identical to Bug 1
and Bug 3. **Don't set this variable for a custom/gateway model.** Confirmed
by finding the exact append logic (`return {kind:"ok", model: a+"[1m]"}`) in
the binary, and by reproducing the exact `[1m]`-suffixed model name in a real
error message.

### Bug 3 — a stale login credential leaks into every request (the proxy exists because of this one)

Even with Bugs 1 and 2 fixed, real requests still failed with a fast, 100%
reproducible 404. The cause: if you (or whoever's account this is) have ever
run `claude login` / hold an active Claude subscription login on this
machine, Claude Code attaches that account's **real Anthropic API key** to
the `x-api-key` header on every request — *in addition to* the correct
`Authorization: Bearer <your OpenRouter key>` header built from
`ANTHROPIC_AUTH_TOKEN`. This happens **regardless of `ANTHROPIC_API_KEY`**
being set to an empty string or fully unset — neither stops it. (There's a
documented `CLAUDE_CODE_SIMPLE=1` / `--bare` mode that skips this stored
credential entirely, but it also disables CLAUDE.md auto-loading, hooks, and
auto-memory — too heavy a trade-off for normal use, so we didn't take it.)

OpenRouter's gateway then honors that stray `x-api-key` header, and the
request ends up rejected as if the model doesn't exist — a real Anthropic
credential has no idea what `stealth/ox-alpha` is.

This was confirmed, not guessed: a local loopback-only logging proxy was
inserted between `claude` and OpenRouter for one diagnostic run (with
explicit consent, since redirecting your own CLI's real traffic through an
intercepting proxy is a meaningful thing to approve first). The captured
request showed both headers side by side — the correct OpenRouter Bearer
token, and a `sk-ant-api03-...` key that had no business being there.

**The fix:** `ox.ps1` starts `ox_proxy.js` — a tiny Node process listening
only on `127.0.0.1` on an OS-assigned free port — before every `claude`
invocation, points `ANTHROPIC_BASE_URL` at it, and kills it when `claude`
exits. The proxy does exactly one thing: forwards every byte to OpenRouter
unchanged **except deleting the `x-api-key` header**. It logs nothing —
no request or response content ever touches disk. This was chosen over the
simpler `CLAUDE_CODE_SIMPLE=1` fix specifically to keep CLAUDE.md
auto-loading, hooks, and auto-memory working normally.

### Bug 4 — undocumented env vars broke model discovery (found after initial write-up)

`ox.ps1` originally also set `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`,
`DISABLE_COMPACT=1`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. These 
were never validated the way Bugs 1-3 were and turned out to cause a fourth,
separate failure: `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` makes Claude
Code call a model-discovery endpoint against `ANTHROPIC_BASE_URL` *before*
the actual message request, expecting an Anthropic-shaped model list. The
proxy forwards that straight to OpenRouter's own `/api/v1/models`, which
returns OpenRouter's own JSON schema (an array of `{id, pricing,
context_length, ...}`), not an Anthropic-shaped response — producing
"API returned an empty or malformed response (HTTP 200)" and "0 stream
events received" on the very first call. **Fix:** all three lines were
removed from `ox.ps1` and from `setup.ps1`'s generated template.

### Not a bug — "model may not exist" can mean the model was actually retired

If you get *"There's an issue with the selected model... it may not exist
or you may not have access to it"* and Bugs 1-4 are all confirmed fixed
(check `ox.ps1` doesn't have the Bug 4 lines and none of the Bug 1/2 vars
are overridden elsewhere), **check whether OpenRouter simply pulled the
model.** `stealth/ox-alpha` is a cloaked testing slug; OpenRouter retires
these on a schedule ("Stealth Ox Alpha testing period... this model will be
revealed today"). Confirm by calling OpenRouter directly, bypassing Claude
Code entirely:

```powershell
$k = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY','User')
Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/chat/completions' -Method Post `
  -Headers @{ Authorization = "Bearer $k"; 'Content-Type' = 'application/json' } `
  -Body (@{ model = 'stealth/ox-alpha'; messages = @(@{role='user'; content='hi'}) } | ConvertTo-Json)
```

A 404 with a message like `"...testing period...revealed today"` (rather
than a generic "model not found") confirms it's a retirement, not a config
issue. Fix: find the model's new/real name and re-run `setup.ps1 -Model
"<new-name>"` — everything else in this setup is model-agnostic.

## Files in this folder

| File | Purpose |
|---|---|
| `setup.ps1` | Run once (or to reconfigure). Writes everything else. |
| `ox.ps1` | The actual launcher `ox` resolves to. Starts the proxy, sets env vars, runs `claude`, cleans up. |
| `ox_proxy.js` | The header-stripping proxy (Bug 3 fix). Requires Node.js on PATH. |
| `ox.cmd` | One-line wrapper so `ox` also works from `cmd.exe`. |
| `README.md` | This file. |

## Troubleshooting

- **`[claude-code:unrecognized_model]` or "There's an issue with the selected
  model"** — this is the generic error for all four bugs above, *and* for
  plain model retirement (see "Not a bug" above). If you hit it after using
  `setup.ps1` as-is, check in this order: (1) none of the Bug 1/2 env vars
  are being overridden elsewhere (another launcher, a global `.env`, a shell
  profile); (2) `ox.ps1` doesn't have the three Bug 4 lines back in it;
  (3) the model still exists on OpenRouter at all.
- **`ox` not found in a new terminal** — PATH changes only apply to
  terminals opened *after* `setup.ps1` ran. Close and reopen.
- **"Node.js is required" error from `setup.ps1`** — install Node.js first;
  the proxy needs it.
- **429 / "temporarily rate-limited upstream"** — this is OpenRouter's own
  shared free-tier pool for the model being busy, not a config problem.
  Retry in a bit.
- **Want a different OpenRouter model?** Re-run `setup.ps1` with
  `-Model "some/other-model"`. Bugs 1 and 2's fixes apply to any non-Anthropic
  model name; Bug 3's fix (the proxy) is unconditional and harmless to keep
  either way.
- **Verifying the key by hand:**
  ```powershell
  $k = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY','User')
  Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/auth/key' -Headers @{ Authorization = "Bearer $k" }
  ```

## What this deliberately does not touch

- The normal `claude` command and its behavior are untouched — `ox` is a
  separate entry point.
- Nothing under `~/.claude` is read or modified.
- `/logout` is never run, so your normal Claude subscription login (the
  thing Bug 3 works around) stays intact for normal `claude` use.
- The proxy never persists request or response content to disk.
