;;; elfeed-translate.el --- Translate Elfeed entry titles and content via LLM API -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.3.0
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
   "- The input titles are separated by a line containing exactly \"---\"\n"
   "- You must output exactly the same number of lines, "
   "separated by lines containing exactly \"---\"\n"
   "- Do NOT add numbers, bullets, quotes, or any introductory/concluding text\n"
   "- Each output line must be ONLY the translated title\n\n"
   "TRANSLATION RULES:\n"
   "- Preserve: technical terms, proper nouns, brand names, URLs, emoji\n"
   "- If a title is already in the target language, output it unchanged\n"
   "- Translate the MEANING, not word-for-word; make it sound natural\n\n"
   "EXAMPLE INPUT:\n"
   "Breaking News: OpenAI Announces GPT-5 Model\n"
   "---\n"
   "How to build a REST API with Flask\n"
   "---\n"
   "今日天气\n\n"
   "EXAMPLE OUTPUT:\n"
   "突发新闻：OpenAI 发布 GPT-5 模型\n"
   "---\n"
   "如何使用 Flask 构建 REST API\n"
   "---\n"
   "今日天气")
  "System prompt template for title translation.
%s is replaced with `elfeed-translate-target-lang'."
  :type 'string
  :group 'elfeed-translate)

(defcustom elfeed-translate-content-system-prompt
  (concat
   "You are a translator. Translate each RSS feed content snippet below into %s.\n\n"
   "CRITICAL OUTPUT FORMAT:\n"
   "- The input snippets are separated by a line containing exactly \"---\"\n"
   "- You must output exactly the same number of snippets, "
   "separated by lines containing exactly \"---\"\n"
   "- Do NOT add numbers, bullets, quotes, or any introductory/concluding text\n"
   "- Each output snippet must be ONLY the translated content\n\n"
   "TRANSLATION RULES:\n"
   "- Preserve all HTML tags as-is; only translate the text between tags\n"
   "- Preserve: technical terms, proper nouns, brand names, URLs, emoji, code blocks\n"
   "- If text is already in the target language, output it unchanged\n"
   "- Translate the MEANING, not word-for-word; make it sound natural\n\n"
   "EXAMPLE INPUT:\n"
   "<p>OpenAI has announced the release of GPT-5.</p>\n"
   "---\n"
   "<p>This tutorial covers building REST APIs with Flask.</p>\n\n"
   "EXAMPLE OUTPUT:\n"
   "<p>OpenAI 已发布 GPT-5 模型。</p>\n"
   "---\n"
   "<p>本教程介绍如何使用 Flask 构建 REST API。</p>")
  "System prompt template for content translation.
Used when feeds are tagged with `elfeed-translate-content-tag'.
Each content snippet is treated as an independent translation unit,
separated by \"---\".  %s is replaced with
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
  "Maximum number of retry attempts for a failed API batch.
When a batch fails (timeout, HTTP error, parse error), it is
retried up to this many times before giving up.  Set to 0 to
disable retries."
  :type 'integer
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
            nil))
        (error
         (message "[elfeed-translate] Migration failed: %s"
                  (error-message-string err))))))

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

(defun elfeed-translate--call-api (texts callback &optional no-busy-guard system-prompt)
  "Translate TEXTS (list of strings) via the configured LLM API.
CALLBACK receives one argument: an alist of (cache-key . translated)
pairs on success, or nil on failure.  cache-key is the MD5 of each
input string.

The texts are sent as a single batch, separated by '---' markers.
The API response is expected to contain translated texts separated
by the same marker.

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
    (when callback (funcall callback nil)))
   ((null elfeed-translate-api-key)
    (message "[elfeed-translate] API key is not configured")
    (when callback (funcall callback nil)))
   ((null texts)
    (when callback (funcall callback nil)))
   (t
    (unless no-busy-guard (setq elfeed-translate--busy t))
    (let* ((prompt-template (or system-prompt
                                elfeed-translate-system-prompt))
           (system-prompt-str (format prompt-template
                                      elfeed-translate-target-lang))
           (user-content (string-join texts "\n---\n"))
           ;; Pre-compute cache keys (MD5 of each input text)
           (keys (mapcar #'elfeed-translate--cache-key texts))
           (request-body
            `((model . ,elfeed-translate-model)
              (messages . [((role . "system")
                            (content . ,system-prompt-str))
                           ((role . "user")
                            (content . ,user-content))])
              (temperature . ,elfeed-translate-temperature)))
           (url-request-method "POST")
           (url-request-extra-headers
            `(("Content-Type" . "application/json")
              ("Authorization" . ,(concat "Bearer " elfeed-translate-api-key))))
           (url-request-data (json-serialize request-body)))
      (when elfeed-translate-debug
        (message "[elfeed-translate] Sending API request:
  URL   : %s
  Model : %s
  Items : %d
  First : %s"
                 elfeed-translate-api-url
                 elfeed-translate-model
                 (length texts)
                 (if texts
                     (substring (car texts) 0 (min 80 (length (car texts))))
                   "N/A")))
      (condition-case err
          (let ((done nil)
                (timeout-timer nil)
                (response-buffer nil))
            ;; Watchdog: if the response does not arrive within
            ;; `elfeed-translate-request-timeout' seconds, mark the
            ;; request done and invoke the callback with nil, preventing
            ;; a stalled connection from leaving `--busy' set forever.
            ;; The orphaned process (if any) is killed when its buffer
            ;; is eventually garbage-collected; the response callback
            ;; checks `done' and skips if the watchdog already fired.
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
                         (when callback (funcall callback nil)))))))
            (funcall
             #'url-retrieve
             elfeed-translate-api-url
             (lambda (_status)
               ;; Record the response buffer so the watchdog can kill
               ;; its process if it fires before we finish.
               (setq response-buffer (current-buffer))
               (if done
                   ;; Watchdog already fired — discard this late response.
                   (progn
                     (when timeout-timer
                       (cancel-timer timeout-timer)
                       (setq timeout-timer nil)))
                 (unwind-protect
                     (let ((result
                            (condition-case parse-err
                                (elfeed-translate--parse-response
                                 keys (current-buffer))
                              (error
                               (message
                                "[elfeed-translate] Parse error: %s"
                                (error-message-string parse-err))
                               (elfeed-translate--dump-failed-response
                                (current-buffer) keys
                                (format "parse error: %s"
                                        (error-message-string parse-err)))
                               nil))))
                       (setq done t)
                       (when timeout-timer
                         (cancel-timer timeout-timer)
                         (setq timeout-timer nil))
                       (unless no-busy-guard
                         (setq elfeed-translate--busy nil))
                       (when elfeed-translate-debug
                         (message "[elfeed-translate] API response parsed: %s"
                                  (if result
                                      (format "%d pairs" (length result))
                                    "FAILED")))
                       (funcall callback result))
                   ;; Safety net: if the callback throws, ensure busy is
                   ;; still cleared so future updates are not permanently
                   ;; blocked (serial mode).
                   (unless done
                     (when timeout-timer
                       (cancel-timer timeout-timer)
                       (setq timeout-timer nil)))
                   (unless no-busy-guard
                     (setq elfeed-translate--busy nil)))))
             nil 'silent))
        (error
         (message "[elfeed-translate] Failed to send API request: %s"
                  (error-message-string err))
         (unless no-busy-guard (setq elfeed-translate--busy nil))
         (funcall callback nil)))))))

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

(defun elfeed-translate--parse-response (keys buffer)
  "Parse the API response in BUFFER and pair with KEYS.
KEYS is a list of MD5 cache-key strings in the same order as the
texts sent.  Returns an alist of (key . translated) or nil on
failure.  Uses catch/throw for early exit instead of cl-return-from
to avoid issues with condition-case unwinding."
  (catch 'parse-error
    ;; Early exit on HTTP errors — the body is likely an HTML error
    ;; page, not JSON, so skip json-parse-string to avoid confusing
    ;; parse-error messages.
    (let ((http-status (elfeed-translate--http-status buffer)))
      (when (and http-status (>= http-status 400))
        (message "[elfeed-translate] HTTP %d — skipping JSON parse" http-status)
        (elfeed-translate--dump-failed-response
         buffer keys (format "HTTP %d" http-status))
        (throw 'parse-error nil)))
    (let ((response-text (elfeed-translate--extract-body buffer)))
      (unless response-text
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response buffer keys "empty body")
        (throw 'parse-error nil))
      (when (string-empty-p response-text)
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response buffer keys "empty body string")
        (throw 'parse-error nil))

      ;; Parse JSON.  We pass :object-type / :array-type as keyword
      ;; arguments rather than relying on dynamic variable bindings,
      ;; because passing ANY keyword argument (e.g. :null-object) causes
      ;; json-parse-string to ignore the dynamic vars and use its
      ;; built-in defaults (hash-table / vector).
      (let* ((data
              (condition-case _
                  (json-parse-string response-text
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object :json-false)
                (error
                 ;; Retry with trailing content allowed
                 (condition-case json-err
                     (json-parse-string response-text
                                        :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object :json-false
                                        :allow-trailing-content t)
                   (error
                    (message "[elfeed-translate] JSON parse error: %s"
                             (error-message-string json-err))
                    (elfeed-translate--dump-failed-response
                     buffer keys (format "JSON parse: %s"
                                         (error-message-string json-err)))
                    (throw 'parse-error nil)))))))
        (when elfeed-translate-debug
          (message "[elfeed-translate] Parsed JSON keys: %s"
                   (mapcar #'car data)))

        ;; Navigate: choices[0].message.content
        (let* ((choices (cdr (assoc 'choices data)))
               (first-choice (car choices))
               (message-obj (cdr (assoc 'message first-choice)))
               (content (cdr (assoc 'content message-obj))))
          (unless content
            ;; Log the full response structure for debugging
            (message
             (concat "[elfeed-translate] Unexpected API response structure. "
                     "choices=%s, msg-keys=%s")
             (if choices "present" "missing")
             (if message-obj (mapcar #'car message-obj) "missing"))
            (elfeed-translate--dump-failed-response
             buffer keys "unexpected API structure")
            (throw 'parse-error nil))

          ;; Split the translated content by the batch separator
          (let ((translated (split-string content "---" t "[ \t\n\r]+")))
            (if (= (length translated) (length keys))
                (cl-mapcar #'cons keys translated)
              (message
               (concat "[elfeed-translate] Count mismatch: "
                       "expected %d, got %d (%s). "
                       "Falling back to line-by-line parsing.")
               (length keys) (length translated)
               (mapconcat #'identity translated " | "))
              ;; Fallback: split by newlines
              (let ((lines (split-string content "\n" t "\\s-*")))
                (if (= (length lines) (length keys))
                    (cl-mapcar #'cons keys lines)
                  (message "[elfeed-translate] Line count still mismatched: %d vs %d"
                           (length keys) (length lines))
                  nil)))))))))

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
Only regenerates the local XML files — it does NOT call
`elfeed-update-feed'.  The user's next `elfeed-update' (or
scheduled update) will pick up the new content naturally."
  (dolist (feed-url affected-feeds)
    (elfeed-translate--generate-rss feed-url))
  (message "[elfeed-translate] All batches complete — %d feed(s) updated"
           (length affected-feeds)))

(defvar elfeed-translate--serial-completed nil
  "Counter for serial mode progress reporting.
Tracks how many batches have completed (including retries exhausted)
so that batch numbers stay consistent across retries.  Reset to nil
when the cycle finishes.")

(defun elfeed-translate--process-batches (queue affected-feeds)
  "Process QUEUE sequentially, one API call per batch.
QUEUE is a list of plists: (:call-fn :texts :prompt :retries).
AFFECTED-FEEDS is a list of feed URLs to regenerate on completion.
Failed batches are re-enqueued with an incremented :retries counter,
up to `elfeed-translate-max-retries' attempts."
  (when queue
    (let* ((element (car queue))
           (remaining (cdr queue))
           (call-fn (plist-get element :call-fn))
           (texts (plist-get element :texts))
           (prompt (plist-get element :prompt))
           (retries (plist-get element :retries))
           (done (or elfeed-translate--serial-completed 0))
           (total (+ (length queue) done))
           (batch-num (1+ done)))
      (message "[elfeed-translate] Batch %d/%d: translating %d items..."
               batch-num total (length texts))
      (funcall
       call-fn
       texts
       (lambda (pairs)
         (if pairs
             (progn
               (elfeed-translate--cache-set-batch pairs)
               (message "[elfeed-translate] Batch %d/%d: %d ok"
                        batch-num total (length pairs))
               (setq elfeed-translate--serial-completed
                     (1+ (or elfeed-translate--serial-completed 0))))
           ;; Failed — retry or give up
           (if (< retries elfeed-translate-max-retries)
               (progn
                 (message
                  "[elfeed-translate] Batch %d/%d: FAILED, will retry (%d/%d)..."
                  batch-num total (1+ retries) elfeed-translate-max-retries)
                 (setq remaining
                       (append remaining
                               (list (plist-put
                                      (copy-sequence element)
                                      :retries (1+ retries))))))
             (message "[elfeed-translate] Batch %d/%d: FAILED (retries exhausted)"
                      batch-num total)
             (setq elfeed-translate--serial-completed
                   (1+ (or elfeed-translate--serial-completed 0)))))
         (if remaining
             (elfeed-translate--process-batches remaining affected-feeds)
           (setq elfeed-translate--serial-completed nil)
           (elfeed-translate--finalize affected-feeds)))
       nil  ; no-busy-guard
       prompt))))

(defvar elfeed-translate--parallel-state nil
  "Plist holding parallel-dispatch state between async callbacks.
Keys: :queue, :in-flight, :completed, :total, :max-concurrent,
:finalize-fn.  Queue elements are plists:
(:call-fn :texts :prompt :retries).  Bound by
`elfeed-translate--process-batches-parallel' and read by
`elfeed-translate--parallel-dispatch' and
`elfeed-translate--parallel-callback'.")

(defun elfeed-translate--parallel-callback (element pairs)
  "Completion callback for one parallel API batch.
ELEMENT is the queue plist that was dispatched.  PAIRS is non-nil
on success, nil on failure.  On success, caches results.  On
failure with retries remaining, re-enqueues ELEMENT with
incremented :retries.  Then dispatches next batches and finalises
when the queue is drained and nothing is in flight."
  (let* ((state elfeed-translate--parallel-state)
         (completed (plist-get state :completed))
         (total (plist-get state :total))
         (finalize-fn (plist-get state :finalize-fn))
         (retries (plist-get element :retries)))
    (unwind-protect
        (progn
          (plist-put state :in-flight (1- (plist-get state :in-flight)))
          (if pairs
              (progn
                (elfeed-translate--cache-set-batch pairs)
                (plist-put state :completed (1+ completed))
                (message
                 "[elfeed-translate] Batch completed: %d ok (%d/%d)"
                 (length pairs) (1+ completed) total))
            ;; Failed — retry or give up
            (if (< retries elfeed-translate-max-retries)
                (progn
                  (plist-put state :queue
                             (append (plist-get state :queue)
                                     (list (plist-put
                                            (copy-sequence element)
                                            :retries (1+ retries)))))
                  (message
                   "[elfeed-translate] Batch FAILED, will retry (%d/%d) (%d pending)"
                   (1+ retries) elfeed-translate-max-retries
                   (length (plist-get state :queue))))
              (plist-put state :completed (1+ completed))
              (message "[elfeed-translate] Batch FAILED (%d/%d)"
                       (1+ completed) total))))
      (elfeed-translate--parallel-dispatch)
      (when (and (null (plist-get state :queue))
                 (= (plist-get state :in-flight) 0))
        (funcall finalize-fn)))))

(defun elfeed-translate--parallel-dispatch ()
  "Dispatch pending batches up to the concurrency limit.
Reads `elfeed-translate--parallel-state'.  Queue elements are
plists (:call-fn :texts :prompt :retries).  Calls
`elfeed-translate--call-api' with `no-busy-guard' t and passes the
element to `elfeed-translate--parallel-callback' via a closure."
  (let* ((state elfeed-translate--parallel-state)
         (queue (plist-get state :queue))
         (in-flight (plist-get state :in-flight))
         (max-concurrent (plist-get state :max-concurrent))
         (total (plist-get state :total)))
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
                   (lambda (pairs)
                     (elfeed-translate--parallel-callback element pairs))
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

(defun elfeed-translate--on-db-update ()
  "Handle `elfeed-db-update-hook': translate new entries, update RSS files.
Collects untranslated titles and content independently, splits each
into batches using the appropriate batch size, and processes them
via async API calls — either sequentially or in parallel depending
on `elfeed-translate-parallel'.

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
initial RSS files, and installs the update hook.

This function is idempotent — the heavy one-time work (directory
creation, cache load, RSS generation) only runs on the first call.
Subsequent calls merely ensure `elfeed-db-update-hook' is in place.

Hooked into `elfeed-search-mode-hook' so that opening Elfeed
(\"M-x elfeed\") automatically loads the cache and enables translation."
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
  ;; Always ensure the DB-update hook is installed (idempotent)
  (add-hook 'elfeed-db-update-hook #'elfeed-translate--on-db-update))

;;;###autoload
(defun elfeed-translate-teardown ()
  "Remove elfeed-translate hooks and close the cache database."
  (interactive)
  (remove-hook 'elfeed-db-update-hook #'elfeed-translate--on-db-update)
  (elfeed-translate--close-cache)
  (message "[elfeed-translate] Teardown complete"))

;;;###autoload
(defun elfeed-translate-update ()
  "Manually trigger translation of all tagged feed entries.
Useful for re-translating after changing the target language or
system prompt."
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
(with a new target language, for example)."
  (interactive)
  (when (yes-or-no-p "Clear all cached translations and re-translate everything? ")
    (elfeed-translate--cache-clear)
    ;; Regenerate empty RSS files (will be filled after next update)
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (elfeed-translate--generate-rss feed-url))
    (message "[elfeed-translate] Cache cleared.  Update feeds to re-translate.")))

;;;###autoload
(defun elfeed-translate-test-api ()
  "Send a minimal test request to the configured API and show the response.
Sends a single \"Hello\" prompt to `elfeed-translate-api-url' using
`elfeed-translate-model' and displays the full HTTP response (headers
+ body) in a pop-up buffer.  Use this to verify that the API key,
endpoint, and model name are correct before running a full translation.

The request uses the same `url-retrieve' path as real translation
calls, so it exercises the actual request construction code."
  (interactive)
  (unless elfeed-translate-api-key
    (user-error "Set `elfeed-translate-api-key' first"))
  (let* ((system-prompt (format elfeed-translate-system-prompt
                                elfeed-translate-target-lang))
         (request-body
          `((model . ,elfeed-translate-model)
            (messages . [((role . "system")
                          (content . ,system-prompt))
                         ((role . "user")
                          (content . "Hello"))])
            (temperature . ,elfeed-translate-temperature)))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("Authorization" . ,(concat "Bearer " elfeed-translate-api-key))))
         (url-request-data (json-serialize request-body)))
    (message "[elfeed-translate] Sending test request to %s (model: %s)..."
             elfeed-translate-api-url elfeed-translate-model)
    (condition-case err
        (url-retrieve
         elfeed-translate-api-url
         (lambda (_status)
           (let ((raw (buffer-substring (point-min) (point-max))))
             (with-current-buffer
                 (get-buffer-create "*elfeed-translate-api-test*")
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert raw)
                 (goto-char (point-min)))
               (read-only-mode 1)
               (pop-to-buffer (current-buffer)))
             (message "[elfeed-translate] Test response received (%d bytes)"
                      (length raw))))
         nil 'silent)
      (error
       (message "[elfeed-translate] Test request failed: %s"
                (error-message-string err))))))

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
after each feed update via the configured LLM API."
  :global t
  :lighter " ELTL"
  (if global-elfeed-translate-mode
      (elfeed-translate-setup)
    (elfeed-translate-teardown)))

;; ═══════════════════════════════════════════════════════════════════════
;; Auto-start hook: run setup whenever the Elfeed search buffer opens.
;; This mirrors how elfeed-org hooks into elfeed-search-mode-hook to
;; load feeds — here we load the translation cache and enable the
;; db-update-hook automatically.  The setup function is idempotent so
;; repeated calls are cheap.
;; ═══════════════════════════════════════════════════════════════════════

;;;###autoload
(add-hook 'elfeed-search-mode-hook #'elfeed-translate-setup)

(provide 'elfeed-translate)
;;; elfeed-translate.el ends here
