# AGENTS.md

Guide for AI agents working in `elfeed-translate`.

## Project

`elfeed-translate` is a six-file Emacs Lisp package that translates Elfeed
entry titles and/or content through an OpenAI-compatible
`/chat/completions` API. It writes separate local RSS 2.0 feeds so original
subscriptions and Elfeed entries remain untouched.

- Emacs >= 29.1, Elfeed >= 3.0.
- Lexical binding is enabled.
- SQLite stores translations incrementally.
- There is no build system, CI, or Makefile. Offline ERT tests live in `test/`.
- `README.org` is user-facing; `DEVELOPER.org` is the authoritative architecture
  and protocol document. Read `DEVELOPER.org` before non-trivial changes.

The dispatch engine is isolated in `elfeed-translate-engine.el`; the public
facade should remain thin.

## Design Invariants

1. One installation has one global target language. Per-feed language and
   runtime language switching are out of scope. A deliberate language change
   requires an explicit cache clear.
2. Title and content translation are independent feed-tag capabilities.
3. Batch input/output uses id-bearing JSON. Every expected id must occur exactly
   once before any result is cached.
4. Transport failures use a consecutive-fatal circuit breaker and HTTP 429 a
   throttle pause; only validly delivered requests with unusable translation
   results are retried. See DEVELOPER.org. A batch is cached only when every
   expected id is returned exactly once.
5. API credentials must never be logged or written to diagnostic buffers.

## Repository Layout

```text
elfeed-translate.el          public facade, setup and global mode
elfeed-translate-core.el     customization and result helpers
elfeed-translate-cache.el    SQLite persistence
elfeed-translate-api.el      HTTP and translation protocol
elfeed-translate-elfeed.el   Elfeed DB adapter and RSS rendering
elfeed-translate-engine.el   collection, dispatch, retry and update hooks
test/                        offline ERT suites and batch runner
README.org                   installation, configuration and behavior
DEVELOPER.org                architecture, protocol, retry policy and gotchas
LICENSE                      GPL-3.0-or-later
screenshots/                 user-facing images
```

## Validation

- Load: put the repository and Elfeed on `load-path`, then evaluate
  `(require 'elfeed-translate)`.
- Parentheses: run `check-parens` in every source and test buffer.
- Tests: `emacs --batch -Q -L . -L test -L /path/to/straight/build/elfeed
  -l test/run-tests.el`.
- Byte compile all six source files and tests with Elfeed on `load-path`.
- `emacsclient` smoke tests should use a temporary named daemon rather than
  loading test code into the user's active Emacs server.
- Live API: enable `elfeed-translate-debug`, then run
  `M-x elfeed-translate-test-api`.
- Interactive workflow: open Elfeed, update once to translate, inspect
  `elfeed-translate-output-dir`, and update again to verify cache hits.

The committed tests use synthetic buffers and callbacks for request encoding,
id-JSON parsing, `finish_reason`, SQLite, RSS and module boundaries. They do not
call a real provider.

## Architecture Summary

```text
global mode -> elfeed-search-mode-hook -> setup
setup -> SQLite + initial RSS + update hooks
elfeed-update -> wait for all feeds -> collect uncached title/content
  -> split and merge queues
  -> validated unibyte HTTP request
  -> structured API result
  -> id validation
  -> transactional cache write
  -> regenerate affected local RSS
```

Important structures:

- Cache: `elfeed-translate-cache-file`, independent of RSS output; key
  `MD5(source-text)`, value raw translation.
- Local feed: `MD5(feed-url).xml`.
- Local entry GUID: `MD5(feed-url):original-entry-id`.
- Queue item: `(:call-fn :texts :prompt :retries)`.
- API success: `(:ok t :pairs ... :http-status ... :finish-reason ... :protocol ...)`.
- API failure: `(:ok nil :kind ... :message ... :retryable ...)`.
- Dispatch state includes `:queue`, `:in-flight`, `:retry-waiting`,
  `:completed`, `:total`, `:consecutive-fatal`, `:fatal-limit` and
  `:throttle-until`. Queue elements carry `:heal-retries` and
  `:throttle-retries` alongside `:retries`.

Module boundaries:

- Only the cache module computes MD5 keys. API success pairs contain source
  text, not cache keys.
- The API module performs one request and must not touch the cycle-level busy
  state.
- The Elfeed adapter accepts a translation lookup function when rendering RSS;
  it must not require the cache module.
- The engine owns cross-module orchestration, collection and retry dispatch;
  the facade owns public commands and mode lifecycle.

## Naming and File Conventions

- Public symbols: `elfeed-translate-<name>`.
- Private symbols: `elfeed-translate--<name>`.
- Every `defun`, `defcustom`, and `defvar` needs a docstring.
- Keep all `defcustom` values in the `elfeed-translate` group.
- Preserve `;;;###autoload` cookies on interactive commands and mode entry points.
- Match the existing Unicode box-drawing section headers.
- Every internal file provides its matching feature and can be byte-compiled
  independently with dependencies on `load-path`.
- Preserve unrelated user changes in a dirty worktree.

## Critical Gotchas

1. Pass `:object-type`, `:array-type`, `:null-object`, and `:false-object`
   directly to every `json-parse-string` call. Do not rely on dynamic JSON
   variables.
2. `elfeed-translate--build-request` must keep the outer JSON body UTF-8
   unibyte and every HTTP header ASCII unibyte. A multibyte Authorization value
   can make Emacs reject the request before sending it.
3. The prompt templates have exactly one `%s`, for the global target language.
4. Batch ids are generated as `item-0001`, `item-0002`, ... for each request.
   Pair by id, never by returned array order.
5. JSON source/output text may contain quotes, newlines, backslashes, HTML and
   literal `---`. The separator parser is compatibility-only.
6. `finish_reason=stop` (or a missing field for compatible providers) permits
   output parsing. Truncation and other incomplete model completions are
   structured translation failures; filters are non-retryable.
7. Do not use `url-queue-retrieve`. It loses the dynamic request bindings when
   actual retrieval is deferred. Use direct `url-retrieve` with the package's
   own concurrency limiter.
8. Preserve the timeout `done` guard. A late response must not invoke a callback
   after the watchdog has completed the request.
9. The dispatcher holds the cycle-level busy lock while retry timers are
   pending. Finalization must also check `:retry-waiting`.
10. Keep dispatch callback/timer state in top-level functions and the global
    state plist; interpreted `eval-buffer` has historically been unreliable for
    self-referential local async closures.
11. Title display style is applied during RSS generation and does not invalidate
    cached raw translations.
12. Feed autotag checks use symbols and `memq`; retain compatibility with
    elfeed-org underscore tags.
13. RSS declares UTF-8 and must bind `coding-system-for-write` to `utf-8-unix`.
14. An `;;;###autoload` cookie must immediately precede its intended public
    definition. Never leave one before a module `provide`: Straight would put
    that `provide` in the generated autoload file and short-circuit `require`.
15. Transport failures self-heal once and increment a consecutive-fatal
    circuit; HTTP 429 throttles dispatch until `Retry-After` (clamped)
    expires. When the circuit trips or a non-transport fatal occurs, dispatch
    callbacks must drain requests already in flight, finalize RSS exactly
    once, and ignore stale callbacks from an older state object.
16. `elfeed-translate-output-dir` follows `elfeed-db-directory` by default.
    Warn when configured translated `file:///` feeds still point elsewhere.
17. `elfeed-translate-cache-file` is durable user data and must stay independent
    of output directories and Straight build artifacts. Legacy SQLite imports
    use ordered `INSERT OR IGNORE` and retain every source database.

## Elfeed Integration

| API/hook | Use |
|----------|-----|
| `elfeed-feeds` / `elfeed-feed-autotags` | Find title/content tagged feeds |
| `elfeed-db-entries` / `elfeed-db-get-feed` | Read entries and feed metadata |
| `elfeed-update-init-hooks` | Reset expected-feed counter |
| `elfeed-update-hooks` | Count completed feed retrievals |
| `elfeed-search-mode-hook` | Run setup when global mode is enabled |
| Entry/feed accessors | Generate local RSS metadata and content |

## Dependencies

Built into Emacs 29.1: `url`, `json`, `sqlite`, `xml`, `subr-x`, `cl-lib`, and
`seq`. External: `elfeed` and `elfeed-db`.
