# Persona v2 candidate traits (from Treb/Burt harness work)

## Why this note exists
The deterministic and real IRC harness work exposed a few behavior dimensions that *might* deserve promotion into shared persona traits later.

This note is intentionally conservative: it records what we learned without forcing premature new knobs into the runtime.

## Current stable persona traits
These already exist and are the current shared control surface:

- `join_greet_pct`
- `ambient_public_reply_pct`
- `public_thread_window_seconds`
- `bot_reply_pct`
- `bot_reply_max_turns`
- `non_substantive_allow_pct`

These remain the canonical v1 trait set.

---

## Strongest candidate to promote later

### `human_address_priority`
**Status:** strongest v2 candidate

**Intent:**
When a human-addressed conversation lane is active, defer opportunistic side chatter so the addressed exchange gets first shot.

**Why it emerged:**
Real-model harness runs repeatedly showed that addressed-human turns are the most important lane for perceived quality. If side chatter competes too aggressively, both coherence and evaluator results degrade.

**Why this is a good candidate:**
- likely reusable across Treb, Burt, and a third bot like Astrid
- expresses a real shared-channel norm
- more general than a one-off workaround

**Open design question:**
Should this be:
- boolean (`on/off`), or
- percentage/strength-based (`0..100`)?

Current leaning: start boolean if promoted.

---

## Plausible later candidate

### `warm_human_turns`
**Status:** maybe later

**Intent:**
For the first N directly addressed human turns, bias toward substantive replies and reduce faux-silence / withdrawn behavior.

**Why it emerged:**
Treb especially benefited from a "warm-start" behavior in harness testing. Early addressed turns are disproportionately important for perceived responsiveness.

**Why not promote yet:**
- may be Treb-specific temperament tuning rather than shared runtime truth
- might be better implemented as local policy unless Astrid/Burt also want it

**If promoted later:**
- integer trait
- applied only to direct human-address lane
- should not force broken/garbage outputs to send

---

## Keep local-policy for now
These were useful ideas, but they do **not** feel mature enough to promote into shared persona traits yet.

### Addressed-other backoff
Examples:
- Burt should back off when Alice clearly addresses Treb
- opportunistic pile-on control during another bot's addressed turn

**Why keep local for now:**
- heavily bot/personality dependent
- may vary by channel culture
- better treated as runtime manners than persona truth

### Harness-specific timing accommodations
Examples:
- command-path ordering
- scenario-window timing
- deterministic fake-backend loop prevention

**Reason:** these are evaluator/harness concerns, not persona traits.

### Ultra-specific faux-silence controls
Examples:
- suppressing certain empty stage-direction outputs in particular lanes

**Reason:** these are output-policy details, not broad personality controls.

---

## Recommended posture right now

### Do now
- Keep current v1 trait set unchanged.
- Record this note and refer back to it as we continue extraction/refactor work.

### If we add exactly one trait next
Promote:
- `human_address_priority`

### Otherwise
Keep the rest as local runtime policy until:
- Astrid exists,
- we see the same need across multiple bots,
- and the abstraction proves reusable rather than Treb/Burt-shaped coincidence.

---

## Rule of thumb for future promotion
A behavior should become a shared persona trait only if it is:
1. meaningful across multiple bots,
2. understandable to a human operator,
3. stable enough to tune intentionally,
4. not just a workaround for one harness artifact or one model's weirdness.

If it fails those tests, keep it local.
