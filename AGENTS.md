# AGENTS.md

Guide for AI agents working in the `elfeed-translate` repository.

## Project Type

Single-file Emacs Lisp package (`elfeed-translate.el`, ~920 lines) that
translates [Elfeed](https://github.com/skeeto/elfeed) RSS entry titles via any
OpenAI-compatible LLM API. It generates local RSS 2.0 XML files as *separate
subscription sources* so original feeds stay untouched and Elfeed's database
avoids duplicate-entry collisions.

- Emacs ≥ 27.1, Elfeed ≥ 3.0 (see `Package-Requires` header).
- Lexical binding (`lexical-binding: t`).
- No build system, no test suite, no CI, no Makefile. Testing is interactive
  (see **Testing** below).
- Documentation lives in `README.org` (user-facing) and `DEVELOPER.org`
  (architecture, data flow, historical bugs). **Read `DEVELOPER.org` first**
  before making non-trivial changes — it contains the full function call graph,
  data-flow diagram, and a record of subtle bugs that were fixed.

## Repository Layout

```
elfeed-translate.el   — the entire package (all logic, no submodules)
README.org            — user docs (install, config, commands, how-it-works)
DEVELOPER.org         — developer docs (architecture, gotchas, call graph)
LICENSE               — GPL-3.0-or-later
screenshots/display.png
```

There is exactly one source file. Do not split it unless explicitly asked;
the single-file layout is intentional and follows Emacs Lisp package
conventions.

## Essential Commands

There are no CLI build/test/lint commands. All work happens inside Emacs.

- Load/evaluate: `M-x eval-buffer` on `elfeed-translate.el`, or
  `eval-last-sexp` on the `(provide ...)` form.
- Byte-compile check (optional, catches warnings): `M-x emacs-lisp-byte-compile`
  on the buffer, or `emacs --batch -f batch-byte-compile elfeed-translate.el`
  from a shell if you have Emacs on PATH.
- Package-lint (if available): `M-x package-lint-current-buffer`.

### Interactive Testing (the only test method)

Per `DEVELOPER.org`:

1. `M-x eval-buffer` on `elfeed-translate.el`
2. `(setq elfeed-translate-debug t)` — enables detailed API request/response
   logging to `*Messages*`
3. `M-x elfeed` — verify the "Setup — N feed(s), M cached" message appears
4. `M-x elfeed-translate-stats` — verify feed list and cache counts
5. `M-x elfeed-update` — observe batch processing in `*Messages*`
6. Inspect `~/.elfeed/translated/*.xml` for correct generated content
7. `M-x elfeed-update` again — must report "All titles up to date" (cache hit)

There is no mock/stub harness. To test without real API calls you must set
`elfeed-translate-api-key` to a real OpenAI-compatible key (or point
`elfeed-translate-api-url` at a local LLM server).

## Architecture (summary — see DEVELOPER.org for full detail)

Sections in `elfeed-translate.el`, in file order:

| Section | Purpose |
|---|---|
| Customization (~42–191) | `defgroup` + 16 `defcustom` options (incl. parallel & timeout) |
| Translation Cache (~175–229) | Hash table with disk persistence |
| Utility Functions (~230–298) | Feed hashing, file paths, GUID gen, autotag helpers |
| RSS XML Generation (~299–370) | RSS 2.0 output + title formatting |
| API Client (~371–540) | HTTP request/response, JSON parse, batch translation, timeout watchdog |
| Core Translation (~563–578) | Collect untranslated titles across tagged feeds |
| Feed List Display (~579–665) | `show-feeds` buffer (org or Elisp format) |
| DB Update Handler (~666–871) | Hook integration, batch split, serial & parallel dispatch |
| Public Commands (~752–888) | `setup`, `teardown`, `update`, `clear-cache`, `stats` |
| Global Minor Mode (~889–915) | `global-elfeed-translate-mode` + `elfeed-search-mode-hook` |

### Control / data flow

```
M-x elfeed → elfeed-search-mode-hook → elfeed-translate-setup()
  (idempotent; first call loads cache + generates initial RSS, then
   adds #'elfeed-translate--on-db-update to elfeed-db-update-hook)

M-x elfeed-update → Elfeed fetches feeds → entries added to elfeed-db
  → elfeed-db-update-hook → elfeed-translate--on-db-update()
      ├─ if elfeed-translate--busy → skip
      ├─ collect untranslated titles (cache miss)
      ├─ split into batches (elfeed-translate-batch-size, default 30)
      └─ if elfeed-translate-parallel:
           elfeed-translate--process-batches-parallel
             submit all batches → url-queue-retrieve (async, capped at
               elfeed-translate-max-concurrent in-flight) → each callback
               cache-set → on last completion: save-cache + finalize
         else:
           elfeed-translate--process-batches  (recursive async chain)
             each batch → url-retrieve (async) → parse JSON → cache-set
             → recurse to next batch, or on last batch:
                save-cache + finalize (regenerate affected RSS files)
      [each request has a watchdog timer: elfeed-translate-request-timeout,
       default 60s — on expiry the request is aborted and callback nil]
      [--busy is held for the whole cycle in parallel mode, per-request in serial]

[user runs elfeed-update again] → Elfeed fetches local file:// feeds
  → translated titles appear with `translated` tag
```

### Key data structures

- **Translation cache** (`elfeed-translate--cache`): hash table, `:test 'equal`,
  key = original title string, value = translated title string. Persisted to
  `~/.elfeed/translated/translate-cache.el` as a printed hash-table read back
  with `read`. Saved *only after all batches complete* (crash mid-translation
  loses that cycle, re-translated next time).
- **Feed→file mapping**: `MD5(feed-url).xml` under
  `elfeed-translate-output-dir`. Stable hash so users can hard-code `file:///`
  URLs in their config.
- **title→feeds reverse index**: temporary hash table during batch processing,
  maps each original title to the list of feed URLs containing it (handles
  cross-posted articles); used by `--finalize` to regenerate only affected
  feeds' RSS.
- **Entry GUIDs in generated RSS**: `<MD5(feed-url)>:<original-entry-id>` —
  composite to avoid collisions since all translated feeds share the empty
  namespace (`file:///`).

## Naming Conventions

- Public functions / public customize vars: `elfeed-translate-<name>` (no
  double dash).
- Private functions / private vars: `elfeed-translate--<name>` (double dash).
- All `defcustom` belong to the `elfeed-translate` group (`:group 'elfeed`).
- `;;;###autoload` appears before `elfeed-translate-show-feeds`,
  `elfeed-translate-setup`, `elfeed-translate-teardown`, `elfeed-translate-update`,
  `elfeed-translate-clear-cache`, `elfeed-translate-stats`,
  `global-elfeed-translate-mode`, and the `add-hook` form. Preserve these when
  editing.
- File header uses Unicode box-drawing chars (`═`) to delimit sections — match
  this style when adding new sections.

## Critical Gotchas (non-obvious — read before touching API client / hooks)

These are documented in `DEVELOPER.org` as fixed historical bugs. They are easy
to regress:

1. **`json-parse-string` ignores dynamic vars when any keyword is passed.**
   Passing `:object-type` / `:array-type` / `:null-object` / `:false-object` /
   `:allow-trailing-content` as keyword args is *required* — do not rely on
   `let`-binding `json-object-type` etc. The parse path also retries with
   `:allow-trailing-content t` on first failure. See
   `elfeed-translate--parse-response`.

2. **`elfeed-translate--busy` must be cleared *before* invoking the callback**
   (serial mode). The callback triggers the next batch in the recursive chain,
   which checks `busy` and skips if still set. Clearing it only in the
   `unwind-protect` cleanup form (after the callback) causes a batch-chain
   deadlock. There is also a safety-net clear in the cleanup form in case the
   callback throws. In parallel mode `--busy` is held for the whole cycle and
   cleared once in `finalize-fn`; `--call-api` is called with `no-busy-guard`
   so it does not touch the lock per-request.

3. **Use `catch 'parse-error` / `throw 'parse-error`, not `cl-return-from`,
   inside `condition-case` handlers.** `cl-return-from` cannot find the
   `cl-block` established by `defun` from within a `condition-case` error
   handler.

4. **System prompt template has exactly one `%s`** (the target language).
   Earlier versions had three `%s` but only one `format` argument. If you add
   more placeholders, update the `format` call in `--call-api` accordingly.

5. **`elfeed-translate--cache-set` skips storing when translation equals
   original** (`(equal title translation)`). This avoids wasting entries on
   "already in target language" titles but means those titles are re-scanned
   every update. Known limitation; a sentinel value is a future improvement.

6. **Title style/separator changes do NOT require cache invalidation.** The
   cache stores raw translations; `elfeed-translate--format-title` applies
   `elfeed-translate-title-style` only at RSS generation time. Re-running
   `elfeed-translate-update` (or regenerating RSS) is sufficient.

7. **Feed tag matching uses `memq` on symbols**, so the autotag must be a
   symbol. `elfeed-feed-autotags` converts keyword (`:translate-title`) to plain
   symbol via `elfeed-keyword->symbol`, so both forms work. The default
   `elfeed-translate-feed-tag` is `translate_title` (underscore) to match
   `elfeed-org` colon-tag conventions; users on plain `elfeed-feeds` may set it
   to `translate-title`.

8. **`elfeed-translate-setup` is idempotent** via `elfeed-translate--setup-done`.
   Heavy one-time work (directory creation, cache load, RSS generation) runs
   once; subsequent calls only re-add the DB-update hook. Preserve this when
   modifying setup logic.

9. **Request timeout watchdog.** `elfeed-translate--call-api` arms a
   `run-at-time` timer (`elfeed-translate-request-timeout`, default 60s). On
   expiry it sets a shared `done` flag, kills the response-buffer process if
   available, clears `--busy` (serial mode), and invokes the callback with
   `nil`. The response callback checks `done` first and discards any late
   response if the watchdog already fired — do not remove this guard or a
   slow response arriving after timeout will double-invoke the callback and
   corrupt batch counters.

10. **Parallel mode sets `url-queue-max-threads` globally, not via `let`.**
    `url-queue` reads `url-queue-max-threads` both when submitting and when a
    request completes and the next queued item starts, so a `let`-bind would
    not cover completion-driven wakeups. `--process-batches-parallel` saves
    the old value, `setq`s the global, and `finalize-fn` restores it. If you
    refactor the finalize path, ensure the restore still runs or other
    `url-queue` users will see the altered limit.

11. **`--call-api` selects the transport by `elfeed-translate-parallel`.** It
    calls `url-queue-retrieve` in parallel mode and `url-retrieve` in serial
    mode. Both share the same watchdog + `done`-flag logic. The
    `no-busy-guard` optional arg lets the parallel dispatcher bypass the
    per-request busy lock so multiple requests can be in flight.

## Elfeed Integration Points

| Elfeed API | How this package uses it |
|---|---|
| `elfeed-feeds` | Iterated to find feeds with the translate tag |
| `elfeed-db-entries` | Scanned by `--entries-for-feed` (filters on `elfeed-entry-feed-id`) |
| `elfeed-db-get-feed` | Looks up feed struct by URL |
| `elfeed-feed-autotags` | Wrapped by `--feed-autotags` to check for translate tag |
| `elfeed-search-mode-hook` | Triggers `setup` when Elfeed opens |
| `elfeed-db-update-hook` | Triggers `--on-db-update` after each feed fetch |
| `elfeed-entry-title/link/date/id/feed-id` | Accessors used in RSS generation |
| `elfeed-feed-title` | Used in `show-feeds` org link description |

## Dependencies

All built into Emacs 27.1 except `elfeed` (declared in `Package-Requires`):
`elfeed`, `elfeed-db`, `url`, `json`, `xml`, `subr-x`, `cl-lib`, `seq`.

## When Making Changes

- **Read `DEVELOPER.org` first** — it has the authoritative architecture, call
  graph, and historical bug record.
- Keep the single-file structure; do not introduce subdirectories or split
  modules without an explicit request.
- Preserve `;;;###autoload` cookies on all interactive commands and the hook
  registration.
- Match the existing box-drawing section headers and double-dash private
  naming.
- After edits, byte-compile (`M-x emacs-lisp-byte-compile`) to catch warnings,
  then run the interactive test sequence above if API behavior changed.
- Emacs Lisp docstrings are mandatory for every `defun`/`defcustom`/`defvar` —
  the file follows this consistently.
