# DeepSeek Provider: Feasibility Research

Researched 2026-10-17 against the DeepSeek API docs, this Mac's pi logs, and OpenUsage's provider
conventions. Goal: a DeepSeek card showing **usage** and **output speed (tok/s)**.

> **Decision (2026-10-17):** ship **Output Speed only** — no spend estimate and no balance row, because
> DeepSeek's time-of-day pricing makes any locally imputed cost disagree with the bill. Implemented in
> `Sources/OpenUsage/Providers/DeepSeek/`; the sections below are kept as the research record.

## Verdict

Feasible, and cheaper than most providers, because **pi already records DeepSeek usage with per-reply
durations**. DeepSeek's own API has no usage or quota endpoint, so the card is a log-based provider (like
Grok) plus, optionally, a balance row from the one documented account endpoint.

| Question | Answer |
|---|---|
| Usage available from DeepSeek's API? | **No.** No usage, billing-history, or quota endpoint exists. |
| Usage available locally? | **Yes**, from pi's session logs (`provider: "deepseek"`). |
| Output speed available? | **Yes**, pi records `durationMs` for every DeepSeek reply. |
| Credentials already on the machine? | **Yes**, `~/.pi/agent/auth.json` → `deepseek` (`type: "api_key"`). |
| Any quota/subscription meter possible? | **No.** DeepSeek is prepaid balance, not a metered plan. |

## What DeepSeek officially exposes

The public [API reference](https://api-docs.deepseek.com/) lists 11 endpoints: chat completions,
responses, FIM, models, files, search/fetch, and **`GET /user/balance`**. There is no usage, invoice, or
limit endpoint, and the docs describe no subscription plan — billing is a prepaid balance
(topped-up + granted) that model usage is deducted from.

`GET /user/balance` (verified live with this Mac's pi key, read-only):

```json
{ "is_available": true,
  "balance_infos": [
    { "currency": "CNY", "total_balance": "32.85", "granted_balance": "1.33", "topped_up_balance": "31.52" },
    { "currency": "USD", "total_balance": "0.00",  "granted_balance": "0.00", "topped_up_balance": "0.00" } ] }
```

Amounts are strings; `balance_infos` can carry more than one currency. Only the funded currency is worth
showing.

### Pricing is time-of-day dependent

[Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing), per 1M tokens:

| Model | Cache hit (in) | Cache miss (in) | Output |
|---|---|---|---|
| `deepseek-flash` peak | $0.006 | $0.30 | $1.20 |
| `deepseek-v4-pro` peak | $0.044 | $1.32 | $3.96 |

Off-peak is **half** these rates. Peak is 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding
Chinese public holidays; everything else is off-peak.

## Where local usage lives

`pi` has DeepSeek configured (`pi --list-models` → `deepseek`, models `deepseek-flash` and
`deepseek-v4-pro`). Its key sits in `~/.pi/agent/auth.json` as `{"type": "api_key", "key": "…"}`.

Real data on this Mac (read-only scan of `~/.pi/agent/sessions`, snapshot 2026-10-17 18:46 UTC):

- **141 replies**, all `deepseek-flash`, one session window 18:16–18:46 UTC (all off-peak).
- **14.39M tokens** total, of which **13.98M were cache reads**; 74k output tokens.
- pi's own cost: **$0.2721** (peak rates). Off-peak actual is about **$0.136**.
- No DeepSeek usage in OpenCode (not installed here), Codex, or Claude Code logs — those cards would
  otherwise have absorbed it (see "Attribution" below).

Each assistant message carries `usage.input/output/cacheRead/cacheWrite`, `usage.cost.total`, `model`,
`stopReason`, and `durationMs`. That is exactly the shape `PiUsageScanner` already parses for Claude and
Codex, which is why no new log scanner is needed.

### Output speed from the same logs

Qualifying replies (≥50 output tokens, positive duration, not error/aborted): **140 of 141**.

- median **108.3 tok/s**, time-weighted **134.3 tok/s**, max ~213 tok/s.
- The existing five-minute window logic produces e.g. **150.6 tok/s** (16 replies) and **155.8 tok/s**
  (30 replies) in consecutive samples as the session continued, and already shows "· Nm ago" once idle.

`durationMs` is end-to-end (request sent → last token), including thinking mode and first-token wait, so
DeepSeek's number is comparable to Claude/Codex on the same card, and higher mainly because the model is
faster and its replies are shorter.

## What the card would show

Reusing existing pieces: `PiUsageScanner.shared.scan(cardID: "deepseek", …)` gives tokens, cost, trend,
and `responseTimings`; `OutputSpeedMapper` renders the speed row; `SpendTileMapper` renders the spend tiles.

| Row | Source | Notes |
|---|---|---|
| Output Speed | pi `durationMs` | same row as Claude/Codex |
| Today / Yesterday / Last 30 Days | pi usage + cost | cost is an estimate (see below) |
| Usage Trend | pi daily series | 30-day chart |
| Balance | `GET /user/balance` | optional; CNY today |

Default layout must be confirmed with the owner before implementing (per `AGENTS.md`): enabled,
Always Visible vs On Demand, pinned to the menu bar, and order. A reasonable proposal: Output Speed and
Today Always Visible, trend Always Visible, Yesterday / Last 30 Days on demand, Balance on demand, nothing
pinned.

## Credentials and enablement

- Auth store precedence: user-saved key (Settings → API Keys) → `DEEPSEEK_API_KEY` → pi's `auth.json`.
  Only the pi path needs writing; the first two come from `UserAPIKeyStore` if we also adopt
  `APIKeyManaging` (OpenRouter/Z.ai precedent).
- `hasLocalCredentials()` = the same three sources, locally. That is what auto-enables the card on the
  first launch after it ships (`NewProviderSeeder`), since a pi DeepSeek key exists on this Mac.
- Do **not** reuse `PiCodexLoginScanner`: it decodes OAuth logins. A ~30-line reader for the
  `{type: "api_key", key}` shape is enough.
- Provider id `deepseek`, registered between Copilot and Devin in `ProviderCatalog` (alphabetical tail).

## Design caveats worth deciding up front

1. **Cost is ~2× high off-peak.** pi's carried cost uses its catalog's peak rates and ignores DeepSeek's
   off-peak half price. Using it means the card matches pi's own footer but overstates off-peak spend
   (today: $0.272 vs ~$0.136). Options: accept and document; or compute cost in OpenUsage with the peak
   windows (needs a Chinese holiday calendar for exactness); or show tokens only. The bundled pricing
   snapshots don't fix this: `deepseek-flash` is absent, `deepseek/deepseek-v4-flash` is off-peak-priced,
   and `deepseek/deepseek-v4-pro` rates are stale versus the current price card.
2. **Balance is multi-currency.** `Formatters.currency` is USD-only. A CNY balance has to render as e.g.
   `32.85 CNY` (a `.values` row with a unit label) unless currency support is added to `MetricValue`.
3. **Attribution if DeepSeek is used through other CLIs.** DeepSeek documents configuring Codex CLI and
   Claude Code to point at its API. Those turns land in `~/.codex` / `~/.claude` with a `deepseek-*` model
   and would be counted (and priced at OpenAI/Anthropic rates) on the Codex/Claude cards, not on a
   DeepSeek card. No such usage exists on this Mac today; splitting by model slug is a separate change.
4. **Cache version bump required.** `PiUsageScanner.parseLine` drops pi providers missing from
   `PiProviderMapping`, and the parsed rows are cached persistently. Adding `"deepseek": "deepseek"` needs
   a schema bump (pi cache is already at 2 on `main`), otherwise cached files keep omitting DeepSeek.
5. **No quota meter is possible.** DeepSeek exposes no plan, window, or rate-limit consumption — rate
   limits are concurrency-based (2500 flash / 500 pro) and not reportable.

## Implementation sketch

No new log scanner, no OAuth, one small HTTP call:

| Piece | Estimate |
|---|---|
| `DeepSeekProvider.swift` (descriptors, refresh, enablement) | ~170 lines |
| `DeepSeekAuthStore.swift` (pi key, env, saved key) | ~90 lines |
| `DeepSeekUsageClient.swift` + mapper (balance) | ~110 lines |
| `PiProviderMapping` entry + pi cache schema bump | ~5 lines |
| `deepseek.svg` icon + symbol fallback | asset |
| `docs/providers/deepseek.md` | ~70 lines |
| Tests (mapper, auth precedence, pi mapping, speed window) | ~250 lines |

Roughly **600–700 lines including tests** — about the size of the Grok module minus its scanner. Because
it only reads pi logs plus one balance call, the refresh cost is negligible (pi's logs are parsed once for
all cards).

## Open questions for the owner

1. Show cost at all, or tokens only? (Cost is a peak-priced estimate today.)
2. Show the CNY balance row?
3. Confirm the four layout defaults above.
4. Should DeepSeek usage routed through Codex/Claude Code be split onto this card in the same change, or
   left as a follow-up?
