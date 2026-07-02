# Critique: Hermes Agent Session Watching Plan

## 1. Top 3 under-specified seams
1. **Hermes SQLite schema boundary** (`docs/plans/hermes-agent-session-watching-2026-06-28.md:18`, `:26`, `:36`). The plan says to read `~/.hermes/state.db` read-only, but does not define the minimum schema contract needed before implementation starts. Clarify the required tables/columns and timestamp/status derivation first; otherwise parser work may churn.
2. **Rust-vs-Swift integration decision** (`docs/plans/hermes-agent-session-watching-2026-06-28.md:21`, `:30`, `:37`). “Either wire Rust FFI… or add a temporary Swift Hermes provider” is the main order-changing seam. The plan should make this a gate, not leave both paths live through implementation.
3. **Fallback/export semantics** (`docs/plans/hermes-agent-session-watching-2026-06-28.md:19`, `:28`, `:32`). The export JSONL path is described as both test fixture support and a user fallback, but the plan does not specify whether Floaty will invoke `hermes sessions export`, read a user-supplied file, or only parse committed redacted fixtures. That affects dependencies, privacy, failure handling, and UI configuration.

## 2. Contradictions or missing dependencies
- The goal says “local, read-only session watching,” but fallback export support may require executing Hermes or depending on a pre-generated export file. Pick one dependency model.
- The plan warns not to rely on legacy `~/.hermes/sessions/*.jsonl`, yet proposes JSONL as a fallback without distinguishing documented export output from filesystem watching.
- SQLite/WAL support implies a Rust SQLite dependency and test fixture strategy, but no dependency choice or fixture redaction rule is called out before parser work.

## 3. Risk of over-planning — cut or simplify
- Cut UI styling/rendering detail from this plan (`:30-31`). “Existing model renders Hermes like any other source” is enough unless a real display bug appears.
- Defer actual watching/debounce entirely (`:23`). Keep v1 as polling-only; do not mention future watcher work except as explicitly out of scope.
- Collapse safeguards (`:32`) into parser acceptance criteria: no writes, short reads, warnings on missing/locked/schema-mismatched sources, no transcript retention.

## 4. Questions that would change implementation order
1. Is fastest visible Hermes support more important than keeping all discovery in Rust? If yes, Swift temporary provider comes first; if no, Rust FFI/snapshot plumbing comes first.
2. Is export JSONL a runtime fallback or only a fixture/test input? Runtime fallback adds CLI/config/error-surface work before UI exposure.
3. What exact installed Hermes version/schema is the target for v1? If unknown, schema capture must precede all parser and test work.
