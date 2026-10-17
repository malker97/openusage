# DeepSeek

Shows how fast DeepSeek's replies come back, in tokens per second (`108 tok/s`).

DeepSeek's API has no usage, quota, or history endpoint — and its billing is a prepaid balance, not a
plan with windows — so this card is deliberately one row. It reads the replies [pi](https://github.com/earendil-works/pi)
recorded when pi drives DeepSeek, and shows nothing else: no spend, no balance, and no network request.

## What it tracks

| Metric | Meaning |
|---|---|
| Output Speed | Median reply speed over the five minutes up to your latest reply, from pi's local logs |

The row follows the same rules as Claude's and Codex's: each reply is timed from the request being sent to
its last token (so it includes the wait for the first token, and reasoning counts as output), replies under
50 tokens are left out, and the median is shown so one stalled request can't drag it down. While you're
away it keeps the last session's reading and adds how long ago it was (`108 tok/s · 18m ago`). With no
timed DeepSeek replies in the last 30 days it reads **No data**. See the
[dashboard](../dashboard.md#rows) for the shared behavior.

## Where the data comes from

pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`): each assistant
message carries its provider, model, token usage, and how long the request took. OpenUsage reads the
DeepSeek ones and times them like any other pi reply. Nothing is sent anywhere, and no DeepSeek API key is
used by the app.

## Why there is no spend row

DeepSeek bills per token at time-of-day rates (peak hours cost double off-peak) from a prepaid balance,
and exposes no usage or history API. A spend estimate would have to be imputed from local logs and would
disagree with the actual bill, so this card intentionally shows only speed. Balance and spending live on
[platform.deepseek.com](https://platform.deepseek.com/usage), which the card links to.

## Enabling it

The card turns on by itself when pi has a DeepSeek API key saved (`~/.pi/agent/auth.json`), since that is
what produces the logged replies. Set up DeepSeek in pi (`pi`, then add the provider and key) and the card
appears after the next check; you can also enable it any time in **Customize**.

If pi has no DeepSeek key, the card stays off. A card that is on but has no pi DeepSeek replies in the last
30 days reads **No data**.

## Limitations

- **Only usage that goes through pi is counted.** DeepSeek used in the web app or another editor does not
  appear, because no local log records it.
- **DeepSeek routed through Codex or Claude Code is not counted here.** DeepSeek documents pointing those
  CLIs at its API; those turns are logged by Codex or Claude Code and show on those cards instead.
- **No quota or balance meter.** DeepSeek has no plan windows to display, and this card does not read the
  balance endpoint.
