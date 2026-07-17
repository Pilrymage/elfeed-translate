;;; elfeed-translate.el --- Translate Elfeed entry titles and content via LLM API -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (elfeed "3.0"))
;; Keywords: news, rss, translation
;; URL: https://github.com/pilrymage/elfeed-translate

;;; Commentary:

;; This package translates Elfeed RSS entry titles and content using
;; an LLM API (OpenAI-compatible).  It generates local RSS XML files
;; containing translated content, creating separate subscription
;; sources to avoid duplicate entry issues in Elfeed's database.
;;
;; Title translation and content translation are fully independent:
;; a feed can be tagged with `translate_title' only, `translate_content'
;; only, or both.  Each uses its own system prompt and batch size.
;; Content is truncated to a configurable maximum before translation.
;;
;; All translations are cached in an SQLite database, keyed by the
;; MD5 hash of the source text.  This provides crash-safe incremental
;; writes, efficient lookups, and a schema ready for future features
;; like article summarization.
;;
;; Usage:
;;   1. Tag the feeds you want translated in `elfeed-feeds':
;;        (setq elfeed-feeds
;;              \\='((\"https://example.com/en/rss\" translate_title translate_content)))
;;      Or in elfeed-org format:
;;        * English Blogs :translate_title:translate_content:
;;        ** https://example.com/en/rss
;;   2. Configure `elfeed-translate-api-key'
;;   3. M-x elfeed-translate-setup  (or enable `global-elfeed-translate-mode')
;;   4. M-x elfeed-translate-show-feeds  → copy the file:// URLs into your
;;      feed configuration (elfeed-org file or `elfeed-feeds')
;;   5. M-x elfeed-update  → titles/content get translated, RSS files regenerated
;;   6. Another M-x elfeed-update  → translated content appears

;;; Code:

(require 'elfeed)
(require 'elfeed-db)
(require 'url)
(require 'json)
(require 'xml)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'sqlite)

(declare-function org-fold-hide-drawers-all "org-fold")
(declare-function org-cycle-hide-drawers "org-cycle")

;; ═══════════════════════════════════════════════════════════════════════
;; Customization
;; ═══════════════════════════════════════════════════════════════════════

(defgroup elfeed-translate nil
  "Translate Elfeed entry titles and content using LLM APIs.
Generates local RSS files with translated content as separate
subscription sources."
  :group 'elfeed)

(defcustom elfeed-translate-api-key ""
  "API key for the LLM translation service.
Supports any OpenAI-compatible API (OpenAI, OpenRouter, local
LLM servers, etc.)."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-api-url "https://api.openai.com/v1/chat/completions"
  "API endpoint for chat completions.
Must implement the OpenAI /v1/chat/completions protocol."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-model "gpt-4o-mini"
  "Model name passed to the API for translation."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-target-lang "Chinese"
  "Target language for translation."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-feed-tag 'translate_title
  "Tag that marks a feed for title translation.
Any feed in `elfeed-feeds' (or `elfeed-org' configuration) that
has this autotag will have its entry titles translated.

Compatible with both `elfeed-feeds' format:
  (setq elfeed-feeds
        \\='((\"https://example.com/rss\" translate-title blog)))

and `elfeed-org' format:
  * Blogs :translate_title:
  ** https://example.com/rss"
  :type 'symbol
  :group 'elfeed-translate)

(defcustom elfeed-translate-content-tag 'translate_content
  "Tag that marks a feed for content translation.
Feeds with this autotag will have their entry content
(RSS <description> / Atom <content>) translated independently of
titles.  Can be used alone (title not translated) or together with
`elfeed-translate-feed-tag'.  Content is truncated to
`elfeed-translate-content-max-chars' characters before translation.

Compatible with both `elfeed-feeds' format:
  (setq elfeed-feeds
        \\='((\"https://example.com/rss\" translate_content)))

and `elfeed-org' format:
  * Blogs :translate_content:
  ** https://example.com/rss"
  :type 'symbol
  :group 'elfeed-translate)

(defcustom elfeed-translate-output-dir
  (expand-file-name "translated" elfeed-db-directory)
  "Directory where translated RSS files are stored.
Each configured feed gets its own file named <hash>.xml."
  :type 'directory
  :group 'elfeed-translate)

(defcustom elfeed-translate-system-prompt
  (concat
   "You are a translator. Translate each RSS feed title below into %s.\n\n"
   "CRITICAL OUTPUT FORMAT:\n"
   "- The input is a JSON array of objects with \"id\" and \"text\" fields\n"
   "- Return ONLY a valid JSON array; do not use Markdown code fences\n"
   "- Each output object must contain the unchanged \"id\" and a \"translation\" field\n"
   "- Return every input id exactly once; do not add, remove, or duplicate ids\n"
   "- Output order may differ because results are matched by id\n\n"
   "TRANSLATION RULES:\n"
   "- Preserve: technical terms, proper nouns, brand names, URLs, emoji\n"
   "- If a title is already in the target language, output it unchanged\n"
   "- Translate the MEANING, not word-for-word; make it sound natural\n\n"
   "EXAMPLE INPUT:\n"
   "[{\"id\":\"item-0001\",\"text\":\"Breaking News: OpenAI Announces GPT-5 Model\"},"
   "{\"id\":\"item-0002\",\"text\":\"今日天气\"}]\n\n"
   "EXAMPLE OUTPUT:\n"
   "[{\"id\":\"item-0001\",\"translation\":\"突发新闻：OpenAI 发布 GPT-5 模型\"},"
   "{\"id\":\"item-0002\",\"translation\":\"今日天气\"}]")
  "System prompt template for title translation.
%s is replaced with `elfeed-translate-target-lang'."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-content-system-prompt
  (concat
   "You are a translator. Translate each RSS feed content snippet below into %s.\n\n"
   "CRITICAL OUTPUT FORMAT:\n"
   "- The input is a JSON array of objects with \"id\" and \"text\" fields\n"
   "- Return ONLY a valid JSON array; do not use Markdown code fences\n"
   "- Each output object must contain the unchanged \"id\" and a \"translation\" field\n"
   "- Return every input id exactly once; do not add, remove, or duplicate ids\n"
   "- Output order may differ because results are matched by id\n\n"
   "TRANSLATION RULES:\n"
   "- Preserve all HTML tags as-is; only translate the text between tags\n"
   "- Preserve: technical terms, proper nouns, brand names, URLs, emoji, code blocks\n"
   "- If text is already in the target language, output it unchanged\n"
   "- Translate the MEANING, not word-for-word; make it sound natural\n\n"
   "EXAMPLE INPUT:\n"
   "[{\"id\":\"item-0001\",\"text\":\"<p>OpenAI has announced the release of GPT-5.</p>\"}]\n\n"
   "EXAMPLE OUTPUT:\n"
   "[{\"id\":\"item-0001\",\"translation\":\"<p>OpenAI 已发布 GPT-5 模型。</p>\"}]")
  "System prompt template for content translation.
Used when feeds are tagged with `elfeed-translate-content-tag'.
Each content snippet is treated as an independent translation unit,
identified by its JSON id.  %s is replaced with
`elfeed-translate-target-lang'."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-temperature 0.3
  "API temperature parameter for translation.
Lower values produce more consistent results."
  :type 'float
  :group 'elfeed-translate)

(defcustom elfeed-translate-tag 'translated
  "Tag applied to translated feed entries."
  :type 'symbol
  :group 'elfeed-translate)

(defcustom elfeed-translate-feed-title-prefix "[TL] "
  "Prefix added to translated feed titles."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-title-style 'replace
  "How to format translated entry titles in the generated RSS feed.

`replace'          Only the translated title is shown.
`target-first'     Translated title first, then original.
`original-first'   Original title first, then translated.

The separator between titles is controlled by
`elfeed-translate-title-separator'."
  :type '(choice (const :tag "Translated only" replace)
                 (const :tag "Translated :: Original" target-first)
                 (const :tag "Original :: Translated" original-first))
  :group 'elfeed-translate)

(defcustom elfeed-translate-title-separator " :: "
  "Separator string placed between original and translated titles.
Only used when `elfeed-translate-title-style' is not `replace'."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-debug nil
  "When non-nil, log detailed API request/response data to *Messages*.
Useful for diagnosing translation failures."
  :type 'boolean
  :group 'elfeed-translate)

(defcustom elfeed-translate-batch-size 30
  "Maximum number of titles sent in a single API request.
Titles exceeding this count are split into multiple batched
requests to keep each batch manageable for the model."
  :type 'integer
  :group 'elfeed-translate)

(defcustom elfeed-translate-content-batch-size 5
  "Maximum number of content snippets sent in a single API request.
Content is typically much longer than titles, so this should be
smaller than `elfeed-translate-batch-size'."
  :type 'integer
  :group 'elfeed-translate)

(defcustom elfeed-translate-content-max-chars 500
  "Maximum number of characters of entry content to translate.
Content longer than this is truncated to save tokens.  The
truncation keeps the first N characters, which usually covers the
opening paragraph(s) — enough to preview the article without
opening it."
  :type 'integer
  :group 'elfeed-translate)

(defcustom elfeed-translate-parallel nil
  "When non-nil, dispatch translation batches concurrently.
Parallel mode keeps at most `elfeed-translate-max-concurrent' API
requests in flight simultaneously, which is faster for AI endpoints
with quick responses.  When nil, batches are processed
sequentially: each request waits for the previous one to complete
before sending, which is safer for slow or rate-limited endpoints."
  :type 'boolean
  :group 'elfeed-translate)

(defcustom elfeed-translate-max-concurrent 4
  "Maximum number of API requests in flight simultaneously.
Used only in parallel mode.  Has no effect when
`elfeed-translate-parallel' is nil."
  :type 'integer
  :group 'elfeed-translate)

(defcustom elfeed-translate-request-timeout 60
  "Maximum seconds to wait for a single API response.
If the response does not arrive within this period the request is
aborted and treated as a failure, preventing a stalled network
connection from blocking translation indefinitely.  Set to nil or
0 to disable the timeout."
  :type '(choice (const :tag "No timeout" nil)
                 (integer :tag "Seconds"))
  :group 'elfeed-translate)

(defcustom elfeed-translate-max-retries 3
  "Maximum retries for an unusable model translation result.
Transport failures, timeouts and HTTP errors fail immediately.
Malformed translation JSON, incomplete ids, output mismatches and
retryable `finish_reason' values use this limit.  Set to 0 to
disable all retries."
  :type 'integer
  :group 'elfeed-translate)

(defcustom elfeed-translate-retry-base-delay 1.0
  "Initial delay in seconds before retrying a failed API batch.
Each subsequent retry doubles this delay, up to
`elfeed-translate-retry-max-delay'.  A small random jitter is added
to avoid immediately repeating requests alongside other clients."
  :type 'number
  :group 'elfeed-translate)

(defcustom elfeed-translate-retry-max-delay 30.0
  "Maximum client-side delay in seconds between API retry attempts.
Only translation-result failures are retried; transport and HTTP
failures stop immediately."
  :type 'number
  :group 'elfeed-translate)

(defcustom elfeed-translate-auto-refresh nil
  "When non-nil, automatically run `elfeed-update' after translation finishes.
This lets Elfeed fetch the newly generated translated RSS files so
translated titles/content appear in the search buffer without a
manual second update.  A flag prevents infinite recursion: the
auto-refresh update does not trigger another translation cycle."
  :type 'boolean
  :group 'elfeed-translate)

;; ═══════════════════════════════════════════════════════════════════════
;; Translation Cache (SQLite-backed)
;; ═══════════════════════════════════════════════════════════════════════

(defvar elfeed-translate--db nil
  "SQLite database connection for the translation cache.
Opened by `elfeed-translate--load-cache' and closed by
`elfeed-translate--close-cache'.  nil when not yet opened.")

(defun elfeed-translate--cache-file ()
  "Return the path to the SQLite cache database file."
  (expand-file-name "translate-cache.sqlite" elfeed-translate-output-dir))

(defun elfeed-translate--old-cache-file ()
  "Return the path to the legacy hash-table cache file."
  (expand-file-name "translate-cache.el" elfeed-translate-output-dir))

(defun elfeed-translate--cache-count ()
  "Return the number of cached translations in the database."
  (if (and elfeed-translate--db (sqlite-available-p))
      (let ((result (sqlite-select elfeed-translate--db
                                   "SELECT COUNT(*) FROM translations")))
        (if result
            (car (car result))
          0))
    0))

(defun elfeed-translate--cache-key (text)
  "Return the MD5 hash of TEXT for use as a cache key."
  (secure-hash 'md5 text))

(defun elfeed-translate--cache-get (text)
  "Return the cached translation for TEXT, or nil.
The cache key is the MD5 of TEXT."
  (when (and elfeed-translate--db (sqlite-available-p))
    (let ((result (sqlite-select elfeed-translate--db
                                 "SELECT value FROM translations WHERE key = ?"
                                 (list (elfeed-translate--cache-key text)))))
      (when result
        (car (car result))))))

(defun elfeed-translate--cache-set-batch (pairs)
  "Store multiple translations in a single transaction.
PAIRS is a list of (key . translation) cons cells, where key is an
MD5 hash string.  Uses BEGIN/COMMIT for atomicity and efficiency."
  (when (and elfeed-translate--db pairs (sqlite-available-p))
    (sqlite-execute elfeed-translate--db "BEGIN")
    (condition-case err
        (progn
          (dolist (pair pairs)
            (let ((key (car pair))
                  (translation (cdr pair)))
              (unless (equal key translation)
                (sqlite-execute
                 elfeed-translate--db
                 "INSERT OR REPLACE INTO translations (key, value) VALUES (?, ?)"
                 (list key translation)))))
          (sqlite-execute elfeed-translate--db "COMMIT"))
      (error
       (sqlite-execute elfeed-translate--db "ROLLBACK")
       (message "[elfeed-translate] Cache transaction failed: %s"
                (error-message-string err))))))

(defun elfeed-translate--cache-clear ()
  "Delete all cached translations from the database."
  (when (and elfeed-translate--db (sqlite-available-p))
    (sqlite-execute elfeed-translate--db "DELETE FROM translations")))

(defun elfeed-translate--migrate-old-cache ()
  "Migrate the legacy hash-table cache file to the SQLite database.
Reads `translate-cache.el' (a printed hash-table with title-string
keys), computes the MD5 of each key, and inserts it into the
translations table.  After migration the old file is renamed to
`translate-cache.el.migrated'."
  (let ((old-file (elfeed-translate--old-cache-file)))
    (when (file-exists-p old-file)
      (message "[elfeed-translate] Migrating legacy cache to SQLite...")
      (condition-case err
          (with-temp-buffer
            (insert-file-contents old-file)
            (goto-char (point-min))
            (let ((data (read (current-buffer))))
              (if (hash-table-p data)
                  (progn
                    (sqlite-execute elfeed-translate--db "BEGIN")
                    (maphash
                     (lambda (original translation)
                       (let ((key (elfeed-translate--cache-key original)))
                         (unless (equal key translation)
                           (sqlite-execute
                            elfeed-translate--db
                            "INSERT OR REPLACE INTO translations (key, value) VALUES (?, ?)"
                            (list key translation)))))
                     data)
                    (sqlite-execute elfeed-translate--db "COMMIT")
                    (let ((migrated (concat old-file ".migrated")))
                      (rename-file old-file migrated t)
                      (message "[elfeed-translate] Migrated %d entries to SQLite, old file renamed to %s"
                               (hash-table-count data) migrated)))
                (message "[elfeed-translate] Legacy cache is not a hash-table, skipping migration")))
            ;; Discard any remaining unread data
            nil)
      (error
       (message "[elfeed-translate] Migration failed: %s"
                (error-message-string err)))))))

(defun elfeed-translate--load-cache ()
  "Open the SQLite cache database and initialise tables.
If a legacy `translate-cache.el' exists, migrate it to SQLite."
  (make-directory elfeed-translate-output-dir t)
  (let ((db-file (elfeed-translate--cache-file)))
    (setq elfeed-translate--db (sqlite-open db-file))
    ;; Create schema if not exists
    (sqlite-execute elfeed-translate--db
                    "CREATE TABLE IF NOT EXISTS meta (
                      key   TEXT PRIMARY KEY,
                      value TEXT NOT NULL)")
    (sqlite-execute elfeed-translate--db
                    "CREATE TABLE IF NOT EXISTS translations (
                      key   TEXT PRIMARY KEY,
                      value TEXT NOT NULL)")
    ;; Record schema version
    (sqlite-execute elfeed-translate--db
                    "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '1')")
    ;; Migrate legacy cache if present
    (elfeed-translate--migrate-old-cache)
    (message "[elfeed-translate] Cache opened — %d cached translation(s)"
             (elfeed-translate--cache-count))))

(defun elfeed-translate--close-cache ()
  "Close the SQLite cache database connection."
  (when (and elfeed-translate--db (sqlite-available-p))
    (sqlite-close elfeed-translate--db)
    (setq elfeed-translate--db nil)))

;; ═══════════════════════════════════════════════════════════════════════
;; Utility Functions
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--feed-hash (feed-url)
  "Return a short hex hash of FEED-URL.
Used for naming local RSS files and generating unique entry GUIDs."
  (secure-hash 'md5 feed-url))

(defun elfeed-translate--local-feed-url (feed-url)
  "Return the file:// URL for the translated RSS file of FEED-URL."
  (concat "file:///"
          (elfeed-translate--local-feed-path feed-url)))

(defun elfeed-translate--local-feed-path (feed-url)
  "Return the absolute file path for the translated RSS file of FEED-URL."
  (let ((hash (elfeed-translate--feed-hash feed-url))
        (dir  (expand-file-name elfeed-translate-output-dir)))
    (expand-file-name (concat hash ".xml") dir)))

(defun elfeed-translate--rfc2822-date (timestamp)
  "Convert TIMESTAMP (float seconds since epoch) to RFC 2822 format.
Always produces English weekday/month abbreviations regardless of the
system locale or `system-time-locale', because some locales (e.g.
Chinese) cause `format-time-string' to emit non-standard names like
\"周二\" / \"6月\" that Elfeed cannot parse."
  (let ((system-time-locale "C"))
    (if (and timestamp (> timestamp 0))
        (format-time-string "%a, %d %b %Y %H:%M:%S %z"
                            (seconds-to-time timestamp))
      (format-time-string "%a, %d %b %Y %H:%M:%S %z"))))

(defun elfeed-translate--entry-guid (feed-url entry)
  "Build a unique GUID for ENTRY in the translated RSS file of FEED-URL.
Prefixes with the feed hash to avoid ID collisions between different
translated feeds when originals happen to share guids."
  (let ((hash (elfeed-translate--feed-hash feed-url))
        (eid  (elfeed-entry-id entry)))
    (concat hash ":" (cdr eid))))

(defun elfeed-translate--feed-autotags (feed-url)
  "Return the autotag symbols for FEED-URL from `elfeed-feeds'.
Returns nil for feeds without autotags.  Works with both plain
URL entries and (URL . TAGS) cons entries."
  (elfeed-feed-autotags feed-url))

(defun elfeed-translate--feed-has-title-tag-p (feed-url)
  "Return non-nil if FEED-URL has `elfeed-translate-feed-tag' in its autotags."
  (memq elfeed-translate-feed-tag
        (elfeed-translate--feed-autotags feed-url)))

(defun elfeed-translate--feed-has-content-tag-p (feed-url)
  "Return non-nil if FEED-URL has `elfeed-translate-content-tag' in its autotags."
  (memq elfeed-translate-content-tag
        (elfeed-translate--feed-autotags feed-url)))

(defun elfeed-translate--entry-content (entry)
  "Return the content string of ENTRY, or nil if it has no content.
Handles both string content and `elfeed-ref' objects (the latter
are dereferenced via `elfeed-deref').  The content is truncated to
`elfeed-translate-content-max-chars' characters."
  (let ((content (elfeed-entry-content entry)))
    (when content
      (let ((text
             (cond
              ((stringp content) content)
              ((elfeed-ref-p content) (elfeed-deref content))
              (t nil))))
        (when (and text (not (string-empty-p text)))
          (if (> (length text) elfeed-translate-content-max-chars)
              (substring text 0 elfeed-translate-content-max-chars)
            text))))))

(defun elfeed-translate--translatable-feeds ()
  "Return a list of all feed URLs that should be translated.
A feed is translatable if it has `elfeed-translate-feed-tag'
or `elfeed-translate-content-tag' as an autotag in `elfeed-feeds'."
  (let ((feeds '()))
    (dolist (f elfeed-feeds)
      (let ((url (if (consp f) (car f) f)))
        (when (or (elfeed-translate--feed-has-title-tag-p url)
                  (elfeed-translate--feed-has-content-tag-p url))
          (push url feeds))))
    (nreverse feeds)))

(defun elfeed-translate--entries-for-feed (feed-url)
  "Return all Elfeed entries belonging to FEED-URL, newest first."
  (let ((entries '()))
    (maphash
     (lambda (_id entry)
       (when (equal (elfeed-entry-feed-id entry) feed-url)
         (push entry entries)))
     elfeed-db-entries)
    (sort entries
          (lambda (a b)
            (> (elfeed-entry-date a) (elfeed-entry-date b))))))

;; ═══════════════════════════════════════════════════════════════════════
;; RSS XML Generation
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--format-title (original translated)
  "Format a translated title according to `elfeed-translate-title-style'.
ORIGINAL is the original-language title, TRANSLATED is the
translated title.  The separator is taken from
`elfeed-translate-title-separator'."
  (cl-case elfeed-translate-title-style
    (replace translated)
    (target-first (concat translated elfeed-translate-title-separator original))
    (original-first (concat original elfeed-translate-title-separator translated))
    (otherwise translated)))

(defun elfeed-translate--generate-rss (feed-url)
  "Generate a local RSS 2.0 XML file for FEED-URL.
Includes entries that have at least one cached translation (title
or content), OR any entry from the feed if the feed has a
translate tag — original content is always included in
<description>, translated only when `translate_content' is tagged
and the translation is cached.  Returns the path to the generated file."
  (let* ((feed (elfeed-db-get-feed feed-url))
         (feed-title (if feed
                         (or (elfeed-feed-title feed) feed-url)
                       feed-url))
         (translated-feed-title (concat elfeed-translate-feed-title-prefix
                                        feed-title))
         (has-title-tag (elfeed-translate--feed-has-title-tag-p feed-url))
         (has-content-tag (elfeed-translate--feed-has-content-tag-p feed-url))
         (entries (elfeed-translate--entries-for-feed feed-url))
         ;; Include an entry if it has any translation cached, OR if the
         ;; feed has any translate tag (so original content is carried over
         ;; even for entries whose translation hasn't completed yet).
         (translated-entries
          (seq-filter
           (lambda (e)
             (let ((title (elfeed-entry-title e))
                   (content (elfeed-translate--entry-content e)))
               (or (and has-title-tag
                        title
                        (not (string-empty-p title))
                        (elfeed-translate--cache-get title))
                   (and has-content-tag
                        content
                        (elfeed-translate--cache-get content))
                   has-title-tag
                   has-content-tag)))
           entries))
         (file (elfeed-translate--local-feed-path feed-url)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
      (insert "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">\n")
      (insert "  <channel>\n")
      ;; Channel metadata
      (insert (format "    <title>%s</title>\n"
                      (xml-escape-string translated-feed-title)))
      (insert (format "    <link>%s</link>\n"
                      (xml-escape-string feed-url)))
      (insert (format "    <description>Auto-translated RSS feed for %s</description>\n"
                      (xml-escape-string feed-url)))
      (insert (format "    <atom:link href=\"%s\" rel=\"self\" type=\"application/rss+xml\"/>\n"
                      (xml-escape-string (elfeed-translate--local-feed-url feed-url))))
      ;; Entries
      (dolist (entry translated-entries)
        (let* ((original-title (elfeed-entry-title entry))
               (raw-content (elfeed-translate--entry-content entry))
               (translated-title
                (when (and has-title-tag original-title
                           (not (string-empty-p original-title)))
                  (elfeed-translate--cache-get original-title)))
               (translated-content
                (when (and has-content-tag raw-content)
                  (elfeed-translate--cache-get raw-content)))
               ;; Decide display title
               (display-title
                (cond
                 ((and translated-title original-title)
                  (elfeed-translate--format-title original-title translated-title))
                 (translated-title translated-title)
                 (original-title original-title)
                 (t "")))
               ;; Description: use translated if available, else original
               (description
                (cond
                 (translated-content translated-content)
                 (raw-content raw-content)
                 (t nil)))
               (link (elfeed-entry-link entry))
               (guid (elfeed-translate--entry-guid feed-url entry))
               (date (elfeed-entry-date entry)))
          (insert "    <item>\n")
          (insert (format "      <title>%s</title>\n"
                          (xml-escape-string display-title)))
          (insert (format "      <link>%s</link>\n"
                          (xml-escape-string (or link ""))))
          (insert (format "      <guid isPermaLink=\"false\">%s</guid>\n"
                          (xml-escape-string guid)))
          (insert (format "      <pubDate>%s</pubDate>\n"
                          (elfeed-translate--rfc2822-date date)))
          (when description
            (insert (format "      <description>%s</description>\n"
                            (xml-escape-string description))))
          (insert "    </item>\n")))
      (insert "  </channel>\n")
      (insert "</rss>\n")
      (write-region (point-min) (point-max) file nil 'silent))
    file))

;; ═══════════════════════════════════════════════════════════════════════
;; API Client
;; ═══════════════════════════════════════════════════════════════════════

(defvar elfeed-translate--busy nil
  "Non-nil while a translation cycle is active.
In serial mode this is set per API request and cleared on completion.
In parallel mode it is held for the whole dispatch cycle and cleared
once every batch has completed.  `elfeed-translate--on-db-update'
checks this to avoid starting overlapping cycles.")

(defvar elfeed-translate--feed-update-completed 0
  "Counter: how many feeds have finished updating in the current cycle.
Incremented by `elfeed-translate--on-feed-updated' on each
`elfeed-update-hooks' callback.")

(defvar elfeed-translate--feed-update-total 0
  "Total number of feeds being updated in the current cycle.
Set when `elfeed-update' is detected (via `elfeed-update-init-hooks').")

(defvar elfeed-translate--auto-refreshing nil
  "Non-nil when the current `elfeed-update' was auto-triggered by translation.
Prevents infinite recursion: when auto-refresh's update completes,
`elfeed-translate--on-all-feeds-updated' does not start another
translation cycle.")

(defun elfeed-translate--success-result (pairs &rest metadata)
  "Return a structured successful API result for PAIRS.
METADATA is appended as plist entries such as :http-status."
  (append (list :ok t :pairs pairs) metadata))

(defun elfeed-translate--failure-result (kind message retryable &rest metadata)
  "Return a structured failed API result.
KIND identifies the failure stage, MESSAGE describes it, and
RETRYABLE says whether retrying may succeed.  METADATA is appended
as additional plist entries."
  (append (list :ok nil
                :kind kind
                :message message
                :retryable retryable)
          metadata))

(defun elfeed-translate--result-ok-p (result)
  "Return non-nil when RESULT represents a successful API call."
  (and result (plist-get result :ok)))

(defun elfeed-translate--failure-summary (result)
  "Return a concise human-readable summary of failed RESULT."
  (let ((kind (plist-get result :kind))
        (message-text (plist-get result :message))
        (http-status (plist-get result :http-status)))
    (string-join
     (delq nil
           (list (and kind (symbol-name kind))
                 (and http-status (format "HTTP %d" http-status))
                 message-text))
     ": ")))

(defun elfeed-translate--ascii-unibyte (string label &optional trim)
  "Return STRING as an ASCII unibyte string.
LABEL identifies the value in error messages.  When TRIM is
non-nil, remove surrounding whitespace first."
  (unless (stringp string)
    (error "%s must be a string" label))
  (let ((value (if trim (string-trim string) string)))
    (when (and trim (string-empty-p value))
      (error "%s is empty" label))
    (unless (seq-every-p (lambda (char) (< char 128)) value)
      (error "%s must contain ASCII characters only" label))
    (encode-coding-string value 'us-ascii)))

(defun elfeed-translate--batch-item-ids (count)
  "Return COUNT stable item identifiers for one API batch."
  (cl-loop for index from 1 to count
           collect (format "item-%04d" index)))

(defun elfeed-translate--batch-user-content (texts)
  "Encode TEXTS as the id-bearing JSON array sent to the model.
The returned value is a decoded multibyte Lisp string so the outer
OpenAI request serializer can encode it exactly once."
  (let* ((ids (elfeed-translate--batch-item-ids (length texts)))
         (items
          (vconcat
           (cl-mapcar (lambda (id text)
                        `((id . ,id) (text . ,text)))
                      ids texts))))
    (decode-coding-string (json-serialize items) 'utf-8)))

(defun elfeed-translate--build-request (texts system-prompt)
  "Build and validate the API request for TEXTS and SYSTEM-PROMPT.
Returns a plist containing :keys, :data and :headers.  The JSON body
is verified to be valid UTF-8 JSON in a unibyte string, and every
HTTP header is normalised to ASCII unibyte form before Emacs' URL
library concatenates it with the body."
  (let* ((prompt-template (or system-prompt
                              elfeed-translate-system-prompt))
         (system-prompt-str (format prompt-template
                                    elfeed-translate-target-lang))
         (user-content (elfeed-translate--batch-user-content texts))
         (keys (mapcar #'elfeed-translate--cache-key texts))
         (request-object
          `((model . ,elfeed-translate-model)
            (messages . [((role . "system")
                          (content . ,system-prompt-str))
                         ((role . "user")
                          (content . ,user-content))])
            (temperature . ,elfeed-translate-temperature)))
         (data (json-serialize request-object))
         (api-key (elfeed-translate--ascii-unibyte
                   elfeed-translate-api-key "API key" t)))
    ;; `json-serialize' promises a UTF-8 unibyte string.  Validate both
    ;; properties here because `url-http-create-request' rejects a request
    ;; when any multibyte header promotes the raw JSON bytes to multibyte.
    (when (multibyte-string-p data)
      (setq data (encode-coding-string data 'utf-8)))
    (unless (= (length data) (string-bytes data))
      (error "Serialized JSON body is not a unibyte byte sequence"))
    (condition-case err
        (json-parse-string data
                           :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object :json-false)
      (error
       (error "Serialized JSON body failed validation: %s"
              (error-message-string err))))
    (list
     :keys keys
     :data data
     :headers
     (list
      (cons (elfeed-translate--ascii-unibyte "Content-Type" "header name")
            (elfeed-translate--ascii-unibyte
             "application/json; charset=utf-8" "Content-Type"))
      (cons (elfeed-translate--ascii-unibyte "Accept" "header name")
            (elfeed-translate--ascii-unibyte "application/json" "Accept"))
      (cons (elfeed-translate--ascii-unibyte "Authorization" "header name")
            (elfeed-translate--ascii-unibyte
             (concat "Bearer " api-key) "Authorization"))))))

(defun elfeed-translate--call-api (texts callback &optional no-busy-guard system-prompt)
  "Translate TEXTS (list of strings) via the configured LLM API.
CALLBACK receives one structured result plist.  On success it has
:ok t and :pairs containing (cache-key . translated) pairs.  On
failure it has :ok nil plus :kind, :message and :retryable metadata.
Each cache-key is the MD5 of its input string.

The texts are sent as an id-bearing JSON array.  The API response is
expected to return each id exactly once with its translation; legacy
separator output remains a compatibility fallback.

SYSTEM-PROMPT is the prompt template (with %s for target language).
Defaults to `elfeed-translate-system-prompt'.

When NO-BUSY-GUARD is non-nil, neither check nor touch
`elfeed-translate--busy'.  Used by parallel dispatch
\(`elfeed-translate--process-batches-parallel') which manages the lock
at the cycle level and allows several requests in flight at once.

Always uses `url-retrieve' directly — never `url-queue-retrieve',
which defers the actual request to an idle timer and loses the
dynamic `url-request-method' / `url-request-extra-headers' /
`url-request-data' bindings."
  (cond
   ((and (not no-busy-guard) elfeed-translate--busy)
    (message "[elfeed-translate] API call already in progress, skipping")
    (when callback
      (funcall callback
               (elfeed-translate--failure-result
                'busy "API call already in progress" nil))))
   ((or (null elfeed-translate-api-key)
        (and (stringp elfeed-translate-api-key)
             (string-empty-p (string-trim elfeed-translate-api-key))))
    (message "[elfeed-translate] API key is not configured")
    (when callback
      (funcall callback
               (elfeed-translate--failure-result
                'configuration "API key is not configured" nil))))
   ((null texts)
    (when callback
      (funcall callback
               (elfeed-translate--failure-result
                'configuration "No input text was supplied" nil))))
   (t
    (unless no-busy-guard (setq elfeed-translate--busy t))
    (condition-case request-err
        (let* ((request (elfeed-translate--build-request texts system-prompt))
               (keys (plist-get request :keys))
               (url-request-method "POST")
               (url-request-extra-headers (plist-get request :headers))
               (url-request-data (plist-get request :data)))
          (when elfeed-translate-debug
            (message "[elfeed-translate] Sending API request:
  URL   : %s
  Model : %s
  Items : %d
  JSON  : %d bytes, multibyte=%s
  First : %s"
                     elfeed-translate-api-url
                     elfeed-translate-model
                     (length texts)
                     (string-bytes url-request-data)
                     (multibyte-string-p url-request-data)
                     (if texts
                         (substring (car texts) 0 (min 80 (length (car texts))))
                       "N/A")))
          (condition-case send-err
              (let ((done nil)
                    (timeout-timer nil)
                    (response-buffer nil))
                (when (and elfeed-translate-request-timeout
                           (> elfeed-translate-request-timeout 0))
                  (setq timeout-timer
                        (run-at-time
                         elfeed-translate-request-timeout nil
                         (lambda ()
                           (unless done
                             (setq done t)
                             (when (and response-buffer
                                        (buffer-live-p response-buffer))
                               (let ((proc (get-buffer-process response-buffer)))
                                 (when proc (delete-process proc))))
                             (message
                              "[elfeed-translate] Request timed out after %ds"
                              elfeed-translate-request-timeout)
                             (unless no-busy-guard
                               (setq elfeed-translate--busy nil))
                             (when callback
                               (funcall
                                callback
                                (elfeed-translate--failure-result
                                 'timeout
                                 (format "Request timed out after %ds"
                                         elfeed-translate-request-timeout)
                                 nil)))))))
                ;; Save the buffer returned by `url-retrieve' immediately;
                ;; the timeout can now terminate a request before its callback.
                (setq
                 response-buffer
                 (url-retrieve
                  elfeed-translate-api-url
                  (lambda (status)
                    (setq response-buffer (current-buffer))
                    (if done
                        (when timeout-timer
                          (cancel-timer timeout-timer)
                          (setq timeout-timer nil))
                      (unwind-protect
                          (let ((result
                                 (if-let ((transport-error
                                           (plist-get status :error)))
                                     (elfeed-translate--failure-result
                                      'network
                                      (format "%S" transport-error)
                                      nil
                                      :transport-status status)
                                   (condition-case parse-err
                                       (elfeed-translate--parse-response
                                        keys (current-buffer))
                                     (error
                                      (elfeed-translate--dump-failed-response
                                       (current-buffer) keys
                                       (format "parse error: %s"
                                               (error-message-string parse-err)))
                                      (elfeed-translate--failure-result
                                       'parse
                                       (error-message-string parse-err)
                                       nil))))))
                            (setq done t)
                            (when timeout-timer
                              (cancel-timer timeout-timer)
                              (setq timeout-timer nil))
                            (unless no-busy-guard
                              (setq elfeed-translate--busy nil))
                            (when elfeed-translate-debug
                              (message
                               "[elfeed-translate] API response: %s"
                               (if (elfeed-translate--result-ok-p result)
                                   (format "%d pairs"
                                           (length (plist-get result :pairs)))
                                 (elfeed-translate--failure-summary result))))
                            (when callback (funcall callback result)))
                        (unless done
                          (when timeout-timer
                            (cancel-timer timeout-timer)
                            (setq timeout-timer nil)))
                        (unless no-busy-guard
                          (setq elfeed-translate--busy nil)))))
                  nil 'silent))))
            (error
             (let ((result
                    (elfeed-translate--failure-result
                     'send (error-message-string send-err) nil)))
               (message "[elfeed-translate] Failed to send API request: %s"
                        (plist-get result :message))
               (unless no-busy-guard (setq elfeed-translate--busy nil))
               (when callback (funcall callback result))))))
      (error
       (let ((result
              (elfeed-translate--failure-result
               'request-validation
               (error-message-string request-err)
               nil)))
         (message "[elfeed-translate] Request validation failed: %s"
                  (plist-get result :message))
         (unless no-busy-guard (setq elfeed-translate--busy nil))
         (when callback (funcall callback result))))))))

(defun elfeed-translate--extract-body (buffer)
  "Extract the HTTP response body from BUFFER, skipping headers.
Returns the body as a trimmed string."
  (with-current-buffer buffer
    (goto-char (point-min))
    ;; Log HTTP status
    (let ((http-status nil))
      (when (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
        (setq http-status (string-to-number (match-string 1)))
        (when (>= http-status 400)
          (message "[elfeed-translate] API returned HTTP %d" http-status))))
    ;; Skip the blank line separating headers from body.
    ;; url-retrieve buffers use \n\n (unix) or \r\n\r\n as separator.
    (if (re-search-forward "^\r?\n" nil t)
        (let ((body (buffer-substring (point) (point-max))))
          (when elfeed-translate-debug
            (message "[elfeed-translate] Response body (%d chars): %s"
                     (length body)
                     (if (> (length body) 500)
                         (concat (substring body 0 500) "...")
                       body)))
          (string-trim body))
      ;; No header/body separator found — return everything
      (let ((body (buffer-substring (point-min) (point-max))))
        (message "[elfeed-translate] No header separator found, raw body: %s"
                 (if (> (length body) 200)
                     (concat (substring body 0 200) "...")
                   body))
        (string-trim body)))))

(defun elfeed-translate--http-status (buffer)
  "Return the HTTP status code from BUFFER as a number, or nil."
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
      (string-to-number (match-string 1)))))

(defun elfeed-translate--response-header (buffer name)
  "Return HTTP response header NAME from BUFFER, or nil.
Header matching is case-insensitive and stops at the end of the
response header block."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search t)
            (end (or (and (re-search-forward "^\r?$" nil t)
                          (match-beginning 0))
                     (point-max))))
        (goto-char (point-min))
        (when (re-search-forward
               (concat "^" (regexp-quote name) ":[ \t]*\\([^\r\n]*\\)")
               end t)
          (string-trim (match-string-no-properties 1)))))))

(defun elfeed-translate--retry-after-seconds (buffer)
  "Return Retry-After seconds from BUFFER for diagnostics, or nil.
Both delta-seconds and HTTP-date forms are supported.  HTTP failures
are not retried by the current policy."
  (when-let ((value (elfeed-translate--response-header buffer "Retry-After")))
    (cond
     ((string-match-p "\\`[0-9]+\\'" value)
      (string-to-number value))
     (t
      (condition-case nil
          (max 0 (float-time
                  (time-subtract (date-to-time value) (current-time))))
        (error nil))))))

(defun elfeed-translate--response-error-message (body)
  "Extract a concise provider error message from response BODY."
  (when (and body (not (string-empty-p body)))
    (or
     (condition-case nil
         (let* ((data (json-parse-string body
                                         :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object :json-false))
                (error-object (cdr (assoc 'error data))))
           (cond
            ((stringp error-object) error-object)
            ((listp error-object)
             (or (cdr (assoc 'message error-object))
                 (format "%S" error-object)))
            ((cdr (assoc 'message data)))
            (t nil)))
       (error nil))
     (let ((one-line (replace-regexp-in-string "[\r\n]+" " " body)))
       (substring one-line 0 (min 300 (length one-line)))))))

(defun elfeed-translate--dump-failed-response (buffer keys reason)
  "Write the full raw content of BUFFER to a debug buffer for inspection.
KEYS is the list of cache keys sent in the failed request.  REASON is a
short string describing the failure (e.g. \"HTTP 404\", \"empty body\",
\"parse error\").  The debug buffer `*elfeed-translate-debug*' is
created or appended to, with a separator line between entries."
  (let ((raw (if (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (buffer-substring-no-properties (point-min) (point-max)))
               "<buffer killed>")))
    (with-current-buffer (get-buffer-create "*elfeed-translate-debug*")
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n════════ FAILED RESPONSE: %s ════════\n" reason))
        (insert (format "Timestamp : %s\n"
                        (let ((system-time-locale "C"))
                          (format-time-string "%Y-%m-%d %H:%M:%S"))))
        (insert (format "Keys      : %d\n" (length keys)))
        (insert (format "Buffer    : %S (%d bytes)\n"
                        (buffer-name buffer) (length raw)))
        (insert "─── raw response start ───\n")
        (insert raw)
        (insert "\n─── raw response end ───\n")))
    (message "[elfeed-translate] Failed response dumped to *elfeed-translate-debug* (%s)"
             reason)))

(defun elfeed-translate--strip-json-code-fence (content)
  "Return CONTENT without a surrounding Markdown JSON code fence."
  (let ((trimmed (string-trim content)))
    (if (not (string-prefix-p "```" trimmed))
        trimmed
      (if-let ((newline (string-match "\n" trimmed)))
          (let ((body (string-trim (substring trimmed (1+ newline)))))
            (if (string-suffix-p "```" body)
                (string-trim (string-remove-suffix "```" body))
              body))
        trimmed))))

(defun elfeed-translate--finish-reason-failure (finish-reason http-status)
  "Return a failure result for unsuccessful FINISH-REASON, or nil.
HTTP-STATUS is attached as diagnostic metadata.  Missing finish
reasons are accepted for compatibility with OpenAI-like providers
that omit the field."
  (let ((reason (and finish-reason
                     (downcase (format "%s" finish-reason)))))
    (cond
     ((or (null reason) (string-empty-p reason) (equal reason "stop"))
      nil)
     ((member reason '("length" "max_tokens"))
      (elfeed-translate--failure-result
       'completion-truncated
       (format "Model stopped before completing the batch (%s)" reason)
       t :http-status http-status :finish-reason finish-reason))
     ((member reason '("content_filter" "safety"))
      (elfeed-translate--failure-result
       'completion-filtered
       (format "Model refused the batch (%s)" reason)
       nil :http-status http-status :finish-reason finish-reason))
     (t
      (elfeed-translate--failure-result
       'completion-incomplete
       (format "Model did not finish with stop (%s)" reason)
       t :http-status http-status :finish-reason finish-reason)))))

(defun elfeed-translate--parse-id-json-content
    (content keys http-status finish-reason)
  "Parse id-bearing translation JSON CONTENT and pair it with KEYS.
Returns nil only when CONTENT is not JSON, allowing the legacy parser
to run.  Structurally invalid JSON returns a retryable failure result."
  (let* ((candidate (elfeed-translate--strip-json-code-fence content))
         (data
          (condition-case nil
              (json-parse-string candidate
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object :json-false)
            (error :not-json))))
    (unless (eq data :not-json)
      (catch 'invalid-translation-json
        (let* ((items
                (cond
                 ((and (listp data) (assoc 'translations data))
                  (cdr (assoc 'translations data)))
                 ((listp data) data)
                 (t nil)))
               (expected-ids
                (elfeed-translate--batch-item-ids (length keys)))
               (seen (make-hash-table :test 'equal))
               (missing (make-symbol "missing")))
          (unless (listp items)
            (throw
             'invalid-translation-json
             (elfeed-translate--failure-result
              'translation-json "Translation output is not a JSON array"
              t :http-status http-status :finish-reason finish-reason)))
          (dolist (item items)
            (let ((id (and (listp item) (cdr (assoc 'id item))))
                  (translation
                   (and (listp item)
                        (or (cdr (assoc 'translation item))
                            (cdr (assoc 'text item))))))
              (unless (and (stringp id)
                           (stringp translation)
                           (not (string-empty-p translation)))
                (throw
                 'invalid-translation-json
                 (elfeed-translate--failure-result
                  'translation-json
                  "Every output item must contain string id and translation fields"
                  t :http-status http-status :finish-reason finish-reason)))
              (unless (member id expected-ids)
                (throw
                 'invalid-translation-json
                 (elfeed-translate--failure-result
                  'translation-json (format "Unknown translation id: %s" id)
                  t :http-status http-status :finish-reason finish-reason)))
              (unless (eq (gethash id seen missing) missing)
                (throw
                 'invalid-translation-json
                 (elfeed-translate--failure-result
                  'translation-json (format "Duplicate translation id: %s" id)
                  t :http-status http-status :finish-reason finish-reason)))
              (puthash id translation seen)))
          (dolist (id expected-ids)
            (when (eq (gethash id seen missing) missing)
              (throw
               'invalid-translation-json
               (elfeed-translate--failure-result
                'translation-json (format "Missing translation id: %s" id)
                t :http-status http-status :finish-reason finish-reason))))
          (elfeed-translate--success-result
           (cl-mapcar (lambda (key id) (cons key (gethash id seen)))
                      keys expected-ids)
           :http-status http-status
           :finish-reason finish-reason
           :protocol 'id-json))))))

(defun elfeed-translate--parse-legacy-content
    (content keys http-status finish-reason)
  "Parse legacy separator CONTENT as a compatibility fallback."
  (let ((translated (split-string content "---" t "[ \t\n\r]+")))
    (cond
     ((= (length translated) (length keys))
      (elfeed-translate--success-result
       (cl-mapcar #'cons keys translated)
       :http-status http-status :finish-reason finish-reason
       :protocol 'legacy-separator))
     (t
      (let ((lines (split-string content "\n" t "\\s-*")))
        (if (= (length lines) (length keys))
            (elfeed-translate--success-result
             (cl-mapcar #'cons keys lines)
             :http-status http-status :finish-reason finish-reason
             :protocol 'legacy-lines)
          (elfeed-translate--failure-result
           'output-mismatch
           (format "Expected %d translations, received %d"
                   (length keys) (length lines))
           t :http-status http-status :finish-reason finish-reason)))))))

(defun elfeed-translate--parse-response (keys buffer)
  "Parse the API response in BUFFER and pair with KEYS.
KEYS is a list of MD5 cache-key strings in the same order as the
texts sent.  Returns a structured success or failure result.  Uses
catch/throw for early exit instead of cl-return-from to avoid issues
with condition-case unwinding."
  (catch 'parse-error
    (let* ((http-status (elfeed-translate--http-status buffer))
           (response-text (elfeed-translate--extract-body buffer)))
      (when (and http-status (>= http-status 400))
        (let* ((provider-message
                (elfeed-translate--response-error-message response-text))
               (message-text
                (if provider-message
                    (format "Provider response: %s" provider-message)
                  "Provider returned an HTTP error")))
          (message "[elfeed-translate] HTTP %d: %s"
                   http-status message-text)
          (elfeed-translate--dump-failed-response
           buffer keys (format "HTTP %d" http-status))
          (throw
           'parse-error
           (elfeed-translate--failure-result
            'http message-text nil
            :http-status http-status
            :retry-after (elfeed-translate--retry-after-seconds buffer)))))
      (unless response-text
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response
         buffer keys "empty body")
        (throw
         'parse-error
         (elfeed-translate--failure-result
          'empty-response "Response body is missing" nil
          :http-status http-status)))
      (when (string-empty-p response-text)
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response buffer keys "empty body string")
        (throw
         'parse-error
         (elfeed-translate--failure-result
          'empty-response "Response body is empty" nil
          :http-status http-status)))

      ;; Parse JSON.  We pass :object-type / :array-type as keyword
      ;; arguments rather than relying on dynamic variable bindings,
      ;; because passing ANY keyword argument (e.g. :null-object) causes
      ;; json-parse-string to ignore the dynamic vars and use its
      ;; built-in defaults (hash-table / vector).
      (let* ((data
              (condition-case json-err
                  (json-parse-string response-text
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object :json-false)
                (error
                 (message "[elfeed-translate] JSON parse error: %s"
                          (error-message-string json-err))
                 (elfeed-translate--dump-failed-response
                  buffer keys (format "JSON parse: %s"
                                      (error-message-string json-err)))
                 (throw
                  'parse-error
                  (elfeed-translate--failure-result
                   'json
                   (format "Invalid JSON response: %s"
                           (error-message-string json-err))
                   t
                   :http-status http-status))))))
        (when elfeed-translate-debug
          (message "[elfeed-translate] Parsed JSON keys: %s"
                   (mapcar #'car data)))

        ;; Navigate: choices[0].message.content
        (let* ((choices (cdr (assoc 'choices data)))
               (first-choice (car choices))
               (message-obj (cdr (assoc 'message first-choice)))
               (content (cdr (assoc 'content message-obj)))
               (finish-reason (cdr (assoc 'finish_reason first-choice))))
          (unless content
            ;; Log the full response structure for debugging
            (message
             (concat "[elfeed-translate] Unexpected API response structure. "
                     "choices=%s, msg-keys=%s")
             (if choices "present" "missing")
             (if message-obj (mapcar #'car message-obj) "missing"))
            (elfeed-translate--dump-failed-response
             buffer keys "unexpected API structure")
            (throw
             'parse-error
             (elfeed-translate--failure-result
              'api-structure
              "Response is missing choices[0].message.content"
              nil
              :http-status http-status)))
          (when elfeed-translate-debug
            (message "[elfeed-translate] finish_reason=%S" finish-reason))
          (when-let ((finish-failure
                      (elfeed-translate--finish-reason-failure
                       finish-reason http-status)))
            (throw 'parse-error finish-failure))
          (or (elfeed-translate--parse-id-json-content
              content keys http-status finish-reason)
              (elfeed-translate--parse-legacy-content
               content keys http-status finish-reason)))))))

;; ═══════════════════════════════════════════════════════════════════════
;; Core Translation Logic
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--collect-untranslated ()
  "Scan all translatable feeds for untranslated titles and content.
Returns a plist with two lists:
  :title-items   — list of (feed-url . title) for title translation
  :content-items — list of (feed-url . content) for content translation
Title and content are collected independently: a feed with only
`translate_title' contributes to :title-items, a feed with only
`translate_content' contributes to :content-items, and a feed with
both contributes to both."
  (let ((title-items '())
        (content-items '()))
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (let ((has-title (elfeed-translate--feed-has-title-tag-p feed-url))
            (has-content (elfeed-translate--feed-has-content-tag-p feed-url)))
        (dolist (entry (elfeed-translate--entries-for-feed feed-url))
          (when has-title
            (let ((title (elfeed-entry-title entry)))
              (when (and title
                         (not (string-empty-p title))
                         (not (elfeed-translate--cache-get title)))
                (push (cons feed-url title) title-items))))
          (when has-content
            (let ((content (elfeed-translate--entry-content entry)))
              (when (and content
                         (not (string-empty-p content))
                         (not (elfeed-translate--cache-get content)))
                (push (cons feed-url content) content-items)))))))
    (list :title-items (nreverse title-items)
          :content-items (nreverse content-items))))

;; ═══════════════════════════════════════════════════════════════════════
;; Feed List Display
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--insert-org-format (feeds)
  "Insert translated feed URLs in elfeed-org compatible format.
FEEDS is a list of source feed URL strings.

Level-2 heading (\\*\\*) for the \"Translated feeds\" group so it can
sit under a user's existing level-1 feed group.  Each feed is a
level-3 heading (\\*\\*\\*) using an org link with the translated
feed title as the description."
  (insert "# Copy the headlines above into your elfeed-org file,\n")
  (insert "# then run M-x elfeed-org-reload (or restart Emacs).\n")
  (insert "** Translated feeds")
  (when elfeed-translate-tag
    (insert (format " :%s:" elfeed-translate-tag)))
  (insert "\n")
  (dolist (feed-url feeds)
    (let* ((local-url (elfeed-translate--local-feed-url feed-url))
           (feed (elfeed-db-get-feed feed-url))
           (display-title (concat elfeed-translate-feed-title-prefix
                                  (if feed
                                      (or (elfeed-feed-title feed) feed-url)
                                    feed-url))))
      (insert (format "*** [[%s][%s]]\n" local-url display-title))
      (insert (format "    :PROPERTIES:\n"))
      (insert (format "    :ORIGINAL-FEED: %s\n" feed-url))
      (insert (format "    :END:\n")))))

(defun elfeed-translate--insert-plain-format (feeds)
  "Insert translated feed URLs in `elfeed-feeds' compatible format.
FEEDS is a list of source feed URL strings."
  (insert ";; Translated feed URLs for `elfeed-feeds'.\n")
  (insert ";; Copy the lines below into your Elfeed configuration,\n")
  (insert ";; then run M-x elfeed-update.\n\n")
  (dolist (feed-url feeds)
    (let* ((local-url (elfeed-translate--local-feed-url feed-url))
           (feed (elfeed-db-get-feed feed-url))
           (title (if feed
                      (or (elfeed-feed-title feed) feed-url)
                    feed-url)))
      (insert (format ";; Original: %s\n" title))
      (insert (format "(\"%s\" %s)\n\n" local-url elfeed-translate-tag)))))

;;;###autoload
(defun elfeed-translate-show-feeds ()
  "Display translated feed URLs in a temporary buffer.

If `elfeed-org' is loaded, the buffer uses org-mode format
suitable for copying into your elfeed-org file.  Otherwise the
buffer shows Elisp forms suitable for `elfeed-feeds'.

RSS files are regenerated before displaying to ensure the local
file:// URLs point to up-to-date content."
  (interactive)
  (let ((feeds (elfeed-translate--translatable-feeds)))
    (unless feeds
      (user-error "No feeds tagged with `%s' or `%s' in `elfeed-feeds'"
                  elfeed-translate-feed-tag
                  elfeed-translate-content-tag))
    ;; Regenerate all RSS files first
    (dolist (feed-url feeds)
      (elfeed-translate--generate-rss feed-url))
    (let ((buf (get-buffer-create "*elfeed-translate-feeds*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (if (featurep 'elfeed-org)
              (elfeed-translate--insert-org-format feeds)
            (elfeed-translate--insert-plain-format feeds))
          (goto-char (point-min)))
        (if (featurep 'elfeed-org)
            (progn
              (org-mode)
              ;; Fold all drawers so only headlines are visible
              (condition-case nil
                  (org-fold-hide-drawers-all)   ; org 9.6+
                (error
                 (condition-case nil
                     (org-cycle-hide-drawers 'all) ; org 9.0–9.5
                   (error nil)))))
          (emacs-lisp-mode))
        (read-only-mode 1))
      (pop-to-buffer buf)
      (message "[elfeed-translate] %d feed URL(s) shown — copy into your feed configuration"
               (length feeds)))))

;; ═══════════════════════════════════════════════════════════════════════
;; DB Update Handler
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--split-into-batches (list batch-size)
  "Split LIST into sublists of at most BATCH-SIZE elements."
  (let ((batches '())
        (remaining list))
    (while remaining
      (let ((chunk (seq-take remaining batch-size)))
        (push chunk batches)
        (setq remaining (nthcdr batch-size remaining))))
    (nreverse batches)))

(defun elfeed-translate--finalize (affected-feeds)
  "After all batches complete: regenerate RSS files.
AFFECTED-FEEDS is a list of feed URLs whose entries were translated.
Regenerates the local XML files, then — if
`elfeed-translate-auto-refresh' is enabled — triggers
`elfeed-update' so Elfeed fetches the translated feeds.  The
auto-refresh flag prevents recursive translation."
  (dolist (feed-url affected-feeds)
    (elfeed-translate--generate-rss feed-url))
  (message "[elfeed-translate] All batches complete — %d feed(s) updated"
           (length affected-feeds))
  (when elfeed-translate-auto-refresh
    (message "[elfeed-translate] Auto-refresh: triggering elfeed-update")
    (setq elfeed-translate--auto-refreshing t)
    (elfeed-update)))

(defvar elfeed-translate--serial-completed nil
  "Counter for serial mode progress reporting.
Tracks how many batches have completed (including retries exhausted)
so that batch numbers stay consistent across retries.  Reset to nil
when the cycle finishes.")

(defvar elfeed-translate--serial-total nil
  "Total number of original batches in the active serial cycle.")

(defun elfeed-translate--retry-delay (result retries)
  "Return retry delay in seconds for RESULT after RETRIES failures.
Uses exponential backoff with jitter.  RESULT is accepted for the
dispatcher interface; only its :retryable classification is used by
the caller."
  (ignore result)
  (let* ((base (max 0.0 (float elfeed-translate-retry-base-delay)))
         (maximum (max base (float elfeed-translate-retry-max-delay)))
         (backoff (min maximum (* base (expt 2 retries))))
         (jitter (* backoff (/ (random 1000) 4000.0))))
    (+ backoff jitter)))

(defun elfeed-translate--process-batches (queue affected-feeds)
  "Process QUEUE sequentially, one API call per batch.
QUEUE is a list of plists: (:call-fn :texts :prompt :retries).
AFFECTED-FEEDS is a list of feed URLs to regenerate on completion.
Failed batches are re-enqueued with an incremented :retries counter,
up to `elfeed-translate-max-retries' attempts.  Only failures marked
:retryable are retried, after exponential backoff."
  (when queue
    (unless elfeed-translate--serial-total
      (setq elfeed-translate--serial-total (length queue))
      (setq elfeed-translate--serial-completed 0)
      (setq elfeed-translate--busy t))
    (let* ((element (car queue))
           (remaining (cdr queue))
           (call-fn (plist-get element :call-fn))
           (texts (plist-get element :texts))
           (prompt (plist-get element :prompt))
           (retries (plist-get element :retries))
           (done (or elfeed-translate--serial-completed 0))
           (total elfeed-translate--serial-total)
           (batch-num (1+ done)))
      (message "[elfeed-translate] Batch %d/%d: translating %d items..."
               batch-num total (length texts))
      (funcall
       call-fn
       texts
       (lambda (result)
         (let ((retry-scheduled nil))
           (if (elfeed-translate--result-ok-p result)
             (progn
               (let ((pairs (plist-get result :pairs)))
                 (elfeed-translate--cache-set-batch pairs)
                 (message "[elfeed-translate] Batch %d/%d: %d ok"
                          batch-num total (length pairs)))
               (setq elfeed-translate--serial-completed
                     (1+ (or elfeed-translate--serial-completed 0))))
             (if (and (plist-get result :retryable)
                      (< retries elfeed-translate-max-retries))
                 (let* ((delay (elfeed-translate--retry-delay result retries))
                        (retry-element
                         (plist-put (copy-sequence element)
                                    :retries (1+ retries))))
                   (setq retry-scheduled t)
                   (message
                    (concat "[elfeed-translate] Batch %d/%d: %s; "
                            "retry %d/%d in %.1fs")
                    batch-num total
                    (elfeed-translate--failure-summary result)
                    (1+ retries) elfeed-translate-max-retries delay)
                   (run-at-time
                    delay nil #'elfeed-translate--process-batches
                    (cons retry-element remaining) affected-feeds))
               (message
                "[elfeed-translate] Batch %d/%d: FAILED, not retrying: %s"
                batch-num total (elfeed-translate--failure-summary result))
               (setq elfeed-translate--serial-completed
                     (1+ (or elfeed-translate--serial-completed 0)))))
           (unless retry-scheduled
             (if remaining
                 (elfeed-translate--process-batches remaining affected-feeds)
               (setq elfeed-translate--serial-completed nil)
               (setq elfeed-translate--serial-total nil)
               (setq elfeed-translate--busy nil)
               (elfeed-translate--finalize affected-feeds)))))
       t  ; cycle-level busy guard is managed by this dispatcher
       prompt))))

(defvar elfeed-translate--parallel-state nil
  "Plist holding parallel-dispatch state between async callbacks.
Keys: :queue, :in-flight, :retry-waiting, :completed, :total,
:max-concurrent, :finalize-fn.  Queue elements are plists:
(:call-fn :texts :prompt :retries).  Bound by
`elfeed-translate--process-batches-parallel' and read by
`elfeed-translate--parallel-dispatch' and
`elfeed-translate--parallel-callback'.")

(defun elfeed-translate--parallel-maybe-finalize (state)
  "Finalize parallel STATE when no queued, active or delayed work remains."
  (when (and (eq state elfeed-translate--parallel-state)
             (null (plist-get state :queue))
             (= (plist-get state :in-flight) 0)
             (= (plist-get state :retry-waiting) 0))
    (funcall (plist-get state :finalize-fn))))

(defun elfeed-translate--parallel-requeue-retry (state element)
  "Put delayed retry ELEMENT back into parallel STATE's queue."
  (when (eq state elfeed-translate--parallel-state)
    (plist-put state :retry-waiting
               (max 0 (1- (plist-get state :retry-waiting))))
    (plist-put state :queue
               (append (plist-get state :queue) (list element)))
    (elfeed-translate--parallel-dispatch)
    (elfeed-translate--parallel-maybe-finalize state)))

(defun elfeed-translate--parallel-callback (element result)
  "Completion callback for one parallel API batch.
ELEMENT is the queue plist that was dispatched.  RESULT is a
structured API result.  Retryable failures are scheduled with
backoff; deterministic failures are not retried."
  (let* ((state elfeed-translate--parallel-state)
         (completed (plist-get state :completed))
         (total (plist-get state :total))
         (retries (plist-get element :retries)))
    (unwind-protect
        (progn
          (plist-put state :in-flight (1- (plist-get state :in-flight)))
          (if (elfeed-translate--result-ok-p result)
              (let ((pairs (plist-get result :pairs)))
                (elfeed-translate--cache-set-batch pairs)
                (plist-put state :completed (1+ completed))
                (message
                 "[elfeed-translate] Batch completed: %d ok (%d/%d)"
                 (length pairs) (1+ completed) total))
            ;; Failed — retry or give up
            (if (and (plist-get result :retryable)
                     (< retries elfeed-translate-max-retries))
                (let* ((delay (elfeed-translate--retry-delay result retries))
                       (retry-element
                        (plist-put (copy-sequence element)
                                   :retries (1+ retries))))
                  (plist-put state :retry-waiting
                             (1+ (plist-get state :retry-waiting)))
                  (message
                   (concat "[elfeed-translate] Batch failed: %s; "
                           "retry %d/%d in %.1fs")
                   (elfeed-translate--failure-summary result)
                   (1+ retries) elfeed-translate-max-retries delay)
                  (run-at-time
                   delay nil #'elfeed-translate--parallel-requeue-retry
                   state retry-element))
              (plist-put state :completed (1+ completed))
              (message "[elfeed-translate] Batch FAILED (%d/%d), not retrying: %s"
                       (1+ completed) total
                       (elfeed-translate--failure-summary result)))))
      (elfeed-translate--parallel-dispatch)
      (elfeed-translate--parallel-maybe-finalize state))))

(defun elfeed-translate--parallel-dispatch ()
  "Dispatch pending batches up to the concurrency limit.
Reads `elfeed-translate--parallel-state'.  Queue elements are
plists (:call-fn :texts :prompt :retries).  Calls
`elfeed-translate--call-api' with `no-busy-guard' t and passes the
element to `elfeed-translate--parallel-callback' via a closure."
  (let* ((state elfeed-translate--parallel-state)
         (queue (plist-get state :queue))
         (in-flight (plist-get state :in-flight))
         (max-concurrent (plist-get state :max-concurrent)))
    (while (and queue (< in-flight max-concurrent))
      (let* ((element (pop queue)))
        (plist-put state :queue queue)
        (plist-put state :in-flight (1+ in-flight))
        (setq in-flight (1+ in-flight))
        (let ((call-fn (plist-get element :call-fn))
              (texts (plist-get element :texts))
              (prompt (plist-get element :prompt))
              (retries (plist-get element :retries)))
          (message
           "[elfeed-translate] Dispatching batch (%d items, retries=%d)... (%d pending)"
           (length texts) retries (length queue))
          (funcall call-fn
                   texts
                   (lambda (result)
                     (elfeed-translate--parallel-callback element result))
                   t   ; no-busy-guard
                   prompt))))))

(defun elfeed-translate--process-batches-parallel (queue affected-feeds)
  "Process a QUEUE of batches concurrently with a self-managed limiter.
QUEUE is a list of plists (:call-fn :texts :prompt :retries).
At most `elfeed-translate-max-concurrent' API requests are in flight
at once.  Failed batches are re-enqueued with incremented :retries,
up to `elfeed-translate-max-retries'.  Translations are written to
the SQLite cache in per-batch transactions, and affected RSS files
are regenerated once every batch has completed.

AFFECTED-FEEDS is a list of feed URLs to regenerate on completion.

State is kept in `elfeed-translate--parallel-state' (a plist) rather
than in `let*' closures, because the Emacs Lisp interpreter does not
reliably capture `let*'-bound variables inside lambdas that are
invoked from process filters (async callbacks)."
  (if (null queue)
      (message "[elfeed-translate] No batches to process")
    (setq elfeed-translate--parallel-state
          (list :queue (copy-sequence queue)
                :in-flight 0
                :retry-waiting 0
                :completed 0
                :total (length queue)
                :max-concurrent (max 1 elfeed-translate-max-concurrent)
                :finalize-fn
                (lambda ()
                  (elfeed-translate--finalize affected-feeds)
                  (setq elfeed-translate--busy nil)
                  (setq elfeed-translate--parallel-state nil))))
    (setq elfeed-translate--busy t)
    (elfeed-translate--parallel-dispatch)))

(defun elfeed-translate--on-feed-update-init ()
  "Handle `elfeed-update-init-hooks': record the total feed count.
Called when `elfeed-update' begins (or when individual feed updates
are initiated outside a batch).  Sets the completion counter to 0
and the total to the number of feeds in `elfeed-feeds'."
  (setq elfeed-translate--feed-update-completed 0)
  (setq elfeed-translate--feed-update-total (length (elfeed-feed-list)))
  (when elfeed-translate-debug
    (message "[elfeed-translate] Feed update started — %d feed(s) pending"
             elfeed-translate--feed-update-total)))

(defun elfeed-translate--on-feed-updated (url)
  "Handle `elfeed-update-hooks': increment the completion counter.
URL is the feed that just finished.  When the counter
reaches the total, calls `elfeed-translate--on-all-feeds-updated'."
  (cl-incf elfeed-translate--feed-update-completed)
  (when elfeed-translate-debug
    (message "[elfeed-translate] Feed updated (%d/%d): %s"
             elfeed-translate--feed-update-completed
             elfeed-translate--feed-update-total url))
  (when (>= elfeed-translate--feed-update-completed
            elfeed-translate--feed-update-total)
    (elfeed-translate--on-all-feeds-updated)))

(defun elfeed-translate--on-all-feeds-updated ()
  "Called when all feeds have finished updating.
If this update was auto-triggered by translation (auto-refresh),
just reset the flag and return.  Otherwise, start a translation
cycle via `elfeed-translate--on-db-update'."
  (if elfeed-translate--auto-refreshing
      (progn
        (setq elfeed-translate--auto-refreshing nil)
        (message "[elfeed-translate] Auto-refresh update complete"))
    (message "[elfeed-translate] All feeds fetched — starting translation")
    (elfeed-translate--on-db-update)))

(defun elfeed-translate--on-db-update ()
  "Translate new entries and update RSS files.
Called by `elfeed-translate--on-all-feeds-updated' after all feeds
have finished updating, or by `elfeed-translate-update' for manual
trigger.  Collects untranslated titles and content independently,
splits each into batches using the appropriate batch size, and
processes them via async API calls — either sequentially or in
parallel depending on `elfeed-translate-parallel'.

Title batches use `elfeed-translate-system-prompt' and
`elfeed-translate-batch-size'.  Content batches use
`elfeed-translate-content-system-prompt' and
`elfeed-translate-content-batch-size'.  Both are merged into a
single queue (title batches first, content batches second) and
processed as one cycle."
  (when (and (not elfeed-translate--busy)
             (elfeed-translate--translatable-feeds))
    (let* ((collected (elfeed-translate--collect-untranslated))
           (title-items (plist-get collected :title-items))
           (content-items (plist-get collected :content-items)))
      (if (and (null title-items) (null content-items))
          (progn
            (message "[elfeed-translate] All content up to date — regenerating RSS files")
            (dolist (feed-url (elfeed-translate--translatable-feeds))
              (elfeed-translate--generate-rss feed-url)))
        (let* (;; Deduplicated titles for title batches
               (titles (delete-dups (mapcar #'cdr title-items)))
               ;; Deduplicated content snippets for content batches
               (contents (delete-dups (mapcar #'cdr content-items)))
               ;; Collect all affected feed URLs
               (affected-feeds
                (delete-dups
                 (append (mapcar #'car title-items)
                         (mapcar #'car content-items)))))
          ;; Build unified queue: plists (:call-fn :texts :prompt :retries)
          (let* ((title-batches
                  (mapcar (lambda (batch)
                            (list :call-fn #'elfeed-translate--call-api
                                  :texts batch
                                  :prompt elfeed-translate-system-prompt
                                  :retries 0))
                          (elfeed-translate--split-into-batches
                           titles elfeed-translate-batch-size)))
                 (content-batches
                  (mapcar (lambda (batch)
                            (list :call-fn #'elfeed-translate--call-api
                                  :texts batch
                                  :prompt elfeed-translate-content-system-prompt
                                  :retries 0))
                          (elfeed-translate--split-into-batches
                           contents elfeed-translate-content-batch-size)))
                 (queue (append title-batches content-batches)))
            (message
             "[elfeed-translate] %d titles (%d batch(es)) + %d content (%d batch(es)) across %d feed(s)"
             (length titles) (length title-batches)
             (length contents) (length content-batches)
             (length affected-feeds))
            (if elfeed-translate-parallel
                (elfeed-translate--process-batches-parallel
                 queue affected-feeds)
              (elfeed-translate--process-batches
               queue affected-feeds))))))))

;; ═══════════════════════════════════════════════════════════════════════
;; Public Commands
;; ═══════════════════════════════════════════════════════════════════════

(defvar elfeed-translate--setup-done nil
  "Non-nil after the one-time portion of `elfeed-translate-setup' has run.")

;;;###autoload
(defun elfeed-translate-setup ()
  "Configure and enable elfeed-translate.
Creates output directory, loads the translation cache, generates
initial RSS files, and installs the feed-update hooks.

This function is idempotent — the heavy one-time work (directory
creation, cache load, RSS generation) only runs on the first call.
Subsequent calls merely ensure the hooks are in place.

Hooks into `elfeed-search-mode-hook' so that opening Elfeed
(\"M-x elfeed\") automatically loads the cache and enables translation.
Translation is triggered after ALL feeds finish updating (via
`elfeed-update-hooks' with a completion counter), not per-feed."
  (interactive)
  (unless elfeed-translate-api-key
    (display-warning
     'elfeed-translate
     "API key is empty.  Set `elfeed-translate-api-key' before updating feeds."
     :warning))
  (unless (elfeed-translate--translatable-feeds)
    (display-warning
     'elfeed-translate
     (format "No feeds tagged with `%s' or `%s'.  Add a tag to feeds in `elfeed-feeds'."
             elfeed-translate-feed-tag
             elfeed-translate-content-tag)
     :warning))
  ;; One-time initialisation
  (unless elfeed-translate--setup-done
    (make-directory elfeed-translate-output-dir t)
    (elfeed-translate--load-cache)
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (elfeed-translate--generate-rss feed-url))
    (setq elfeed-translate--setup-done t)
    (message "[elfeed-translate] Setup — %d feed(s), %d cached translation(s)"
             (length (elfeed-translate--translatable-feeds))
             (elfeed-translate--cache-count))
    (unless (featurep 'elfeed-search)
      (message "[elfeed-translate] Run M-x elfeed-translate-show-feeds to get your translated feed URLs")))
  ;; Always ensure hooks are installed (idempotent)
  (add-hook 'elfeed-update-init-hooks #'elfeed-translate--on-feed-update-init)
  (add-hook 'elfeed-update-hooks #'elfeed-translate--on-feed-updated))

;;;###autoload
(defun elfeed-translate-teardown ()
  "Remove elfeed-translate hooks and close the cache database."
  (interactive)
  (remove-hook 'elfeed-update-init-hooks #'elfeed-translate--on-feed-update-init)
  (remove-hook 'elfeed-update-hooks #'elfeed-translate--on-feed-updated)
  (elfeed-translate--close-cache)
  (message "[elfeed-translate] Teardown complete"))

;;;###autoload
(defun elfeed-translate-update ()
  "Manually translate uncached entries from all tagged feeds.
Cached entries remain unchanged.  Use `elfeed-translate-clear-cache'
first only when an explicit full retranslation is intended."
  (interactive)
  (unless (elfeed-translate--translatable-feeds)
    (user-error "No feeds tagged with `%s' or `%s' in `elfeed-feeds'"
                elfeed-translate-feed-tag
                elfeed-translate-content-tag))
  (message "[elfeed-translate] Starting manual translation...")
  (elfeed-translate--on-db-update))

;;;###autoload
(defun elfeed-translate-clear-cache ()
  "Clear all cached translations and regenerate RSS files.
Use this when you want to force a fresh translation of all content
or deliberately replace the installation's single target language."
  (interactive)
  (when (yes-or-no-p "Clear all cached translations and re-translate everything? ")
    (elfeed-translate--cache-clear)
    ;; Regenerate empty RSS files (will be filled after next update)
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (elfeed-translate--generate-rss feed-url))
    (message "[elfeed-translate] Cache cleared.  Update feeds to re-translate.")))

;;;###autoload
(defun elfeed-translate-test-api ()
  "Test the complete configured title-translation pipeline.
Sends two English titles through the same request builder, transport,
response parser and id-bearing JSON protocol used by normal translation.
Displays a structured, credential-safe report containing request
encoding information, HTTP metadata and translated results."
  (interactive)
  (when elfeed-translate--busy
    (user-error "A translation cycle is already active"))
  (unless (and (stringp elfeed-translate-api-key)
               (not (string-empty-p (string-trim
                                     elfeed-translate-api-key))))
    (user-error "Set `elfeed-translate-api-key' first"))
  (let* ((texts '("OpenAI releases a new model for developers"
                  "How to build a reliable RSS reader"))
         (started-at (float-time))
         (preflight
          (condition-case err
              (elfeed-translate--build-request
               texts elfeed-translate-system-prompt)
            (error
             (user-error "Request preflight failed: %s"
                         (error-message-string err)))))
         (json-data (plist-get preflight :data))
         (headers (plist-get preflight :headers)))
    (message
     "[elfeed-translate] Testing translation via %s (model: %s)..."
     elfeed-translate-api-url elfeed-translate-model)
    (elfeed-translate--call-api
     texts
     (lambda (result)
       (let ((elapsed (- (float-time) started-at))
             (buffer (get-buffer-create "*elfeed-translate-api-test*")))
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert "elfeed-translate API translation test\n")
             (insert "=====================================\n\n")
             (insert (format "Endpoint       : %s\n"
                             elfeed-translate-api-url))
             (insert (format "Model          : %s\n"
                             elfeed-translate-model))
             (insert (format "Target language: %s\n"
                             elfeed-translate-target-lang))
             (insert (format "Elapsed        : %.2fs\n" elapsed))
             (insert (format "JSON bytes     : %d\n"
                             (string-bytes json-data)))
             (insert (format "JSON multibyte : %s\n"
                             (multibyte-string-p json-data)))
             (insert (format "Headers ASCII  : %s\n"
                             (seq-every-p
                              (lambda (header)
                                (and (not (multibyte-string-p (car header)))
                                     (not (multibyte-string-p (cdr header)))))
                              headers)))
             (insert "API key        : <redacted>\n")
             (insert (format "HTTP status    : %s\n"
                             (or (plist-get result :http-status) "N/A")))
             (insert (format "Finish reason  : %s\n"
                             (or (plist-get result :finish-reason) "N/A")))
             (insert (format "Output protocol: %s\n"
                             (or (plist-get result :protocol) "N/A")))
             (insert (format "Result         : %s\n\n"
                             (if (elfeed-translate--result-ok-p result)
                                 "SUCCESS"
                               "FAILED")))
             (if (elfeed-translate--result-ok-p result)
                 (cl-mapc
                  (lambda (source pair)
                    (insert (format "Source      : %s\n" source))
                    (insert (format "Translation : %s\n\n" (cdr pair))))
                  texts (plist-get result :pairs))
               (insert (format "Failure kind   : %s\n"
                               (or (plist-get result :kind) "unknown")))
               (insert (format "Retryable      : %s\n"
                               (plist-get result :retryable)))
               (insert (format "Message        : %s\n"
                               (or (plist-get result :message)
                                   "No diagnostic message"))))
             (goto-char (point-min)))
           (special-mode))
         (pop-to-buffer buffer)
         (message "[elfeed-translate] Translation test %s (%.2fs)"
                  (if (elfeed-translate--result-ok-p result)
                      "succeeded"
                    "failed")
                  elapsed)))
     nil
     elfeed-translate-system-prompt)))

;;;###autoload
(defun elfeed-translate-stats ()
  "Display translation statistics in the message area.
Shows all translatable feeds and their translation status."
  (interactive)
  (let* ((feeds (elfeed-translate--translatable-feeds))
         (lines '())
         (total-cached (elfeed-translate--cache-count))
         (total-entries 0)
         (total-untranslated 0))
    (push (format "elfeed-translate status:
  Title tag      : %s
  Content tag    : %s
  Target language: %s
  API endpoint   : %s
  Model          : %s
  Tagged feeds   : %d
  Cached entries : %d
"
                  elfeed-translate-feed-tag
                  elfeed-translate-content-tag
                  elfeed-translate-target-lang
                  elfeed-translate-api-url
                  elfeed-translate-model
                  (length feeds)
                  total-cached)
          lines)
    (if (not feeds)
        (push (format "  (No feeds tagged with `%s' or `%s' in `elfeed-feeds')\n"
                      elfeed-translate-feed-tag
                      elfeed-translate-content-tag)
              lines)
      (dolist (feed-url feeds)
        (let* ((entries (elfeed-translate--entries-for-feed feed-url))
               (n-all (length entries))
               (has-title (elfeed-translate--feed-has-title-tag-p feed-url))
               (has-content (elfeed-translate--feed-has-content-tag-p feed-url))
               (n-cached
                (seq-count
                 (lambda (e)
                   (or (and has-title
                            (elfeed-entry-title e)
                            (not (string-empty-p (elfeed-entry-title e)))
                            (elfeed-translate--cache-get (elfeed-entry-title e)))
                       (and has-content
                            (elfeed-translate--entry-content e)
                            (elfeed-translate--cache-get
                             (elfeed-translate--entry-content e)))))
                 entries))
               (path (elfeed-translate--local-feed-path feed-url))
               (tags-str (cond
                          ((and has-title has-content) " [title+content]")
                          (has-content " [content]")
                          (t ""))))
          (cl-incf total-entries n-all)
          (cl-incf total-untranslated (- n-all n-cached))
          (push (format "  %s%s
      %d entries (%d translated, %d pending)
      → %s%s
"
                        feed-url tags-str
                        n-all n-cached (- n-all n-cached)
                        path
                        (if (file-exists-p path) "" " [MISSING]"))
                lines))))
    (push (format "
  Total entries   : %d (%d untranslated)\n"
                  total-entries total-untranslated)
          lines)
    (message "%s" (string-join (nreverse lines)))))

;; ═══════════════════════════════════════════════════════════════════════
;; Global Minor Mode
;; ═══════════════════════════════════════════════════════════════════════

;;;###autoload
(define-minor-mode global-elfeed-translate-mode
  "Toggle automatic translation of Elfeed entry titles and content.
When enabled, entries of feeds tagged with `elfeed-translate-feed-tag'
and/or `elfeed-translate-content-tag' are automatically translated
after all feeds finish updating.  If
`elfeed-translate-auto-refresh' is enabled, `elfeed-update' is
re-triggered after translation so translated content appears
automatically."
  :global t
  :lighter " ELTL"
  (if global-elfeed-translate-mode
      (add-hook 'elfeed-search-mode-hook #'elfeed-translate-setup)
    (elfeed-translate-teardown)))

;; ═══════════════════════════════════════════════════════════════════════
;; Auto-start hook: run setup whenever the Elfeed search buffer opens.
;; This mirrors how elfeed-org hooks into elfeed-search-mode-hook to
;; load feeds — here we load the translation cache and enable the
;; feed-update hooks automatically.  The setup function is idempotent so
;; repeated calls are cheap.
;; ═══════════════════════════════════════════════════════════════════════

;;;###autoload


(provide 'elfeed-translate)
;;; elfeed-translate.el ends here
