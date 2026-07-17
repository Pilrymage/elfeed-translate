;;; elfeed-translate-core.el --- Shared configuration for elfeed-translate -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1") (elfeed "3.0"))
;; Keywords: news, rss, translation

;;; Commentary:

;; Shared customization and result values used by the internal
;; elfeed-translate modules.  Users should continue to load
;; `elfeed-translate', which is the package facade.

;;; Code:

(require 'elfeed-db)
(require 'subr-x)

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

;; ═══════════════════════════════════════════════════════════════════════
;; Structured Results
;; ═══════════════════════════════════════════════════════════════════════

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


(provide 'elfeed-translate-core)
;;; elfeed-translate-core.el ends here
