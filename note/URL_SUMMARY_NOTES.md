# URL summary notes

## 2026-10-03 — no nested raid from summarize_url

Live hang on clawd: burt/treb froze after Ollama `/api/chat` returned when the
model called `summarize_url` for a gist URL. Root cause in-repo:
`Bot::Runtime::WebTools::summarize_url` called `$self->_raider->raid(...)`
while already inside an active raid/tool loop. That re-enters the
single-threaded POE/IO::Async stack and never returns.

Fix: `summarize_url` returns extractive page text only. The outer raid writes
the IRC answer. `RaidFlow` also refuses nested `do_raid` if `_raid_in_progress`.

## 2026-03-28 — curl 63 on large pages can still be acceptable

Observed case:
- Command: `:sum https://github.com/openclaw/openclaw/releases`
- Runtime log showed: `curl: (63) Exceeded the maximum allowed file size (786432) with 786432 bytes`
- User-facing result was still good enough to keep: concise, accurate release summary with useful highlights.

Interpretation:
- `curl` exit/status 63 here is a bounded-fetch warning, not automatically a feature failure.
- The current fetch cap is still doing useful safety work by preventing overly large page downloads.
- If enough page content is captured before the cap is hit, Treb may still produce a valid summary.

Current policy:
- Do not treat this case as urgent if the resulting summary quality is still acceptable.
- Keep the bounded fetch cap for now.
- Revisit only if this becomes noisy/frequent or starts degrading summary quality.

Future improvement ideas:
- Downgrade curl 63 to soft-warning semantics when partial content is already usable.
- Optionally raise cap modestly only if multiple real pages need it.
- Prefer smarter extraction over blunt cap increases if this becomes common.
