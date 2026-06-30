;;; elfeed-translate.el --- Translate Elfeed entry titles via LLM API -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (elfeed "3.0"))
;; Keywords: news, rss, translation
;; URL: https://github.com/pilrymage/elfeed-translate

;;; Commentary:

;; This package translates Elfeed RSS entry titles using an LLM API
;; (OpenAI-compatible).  It generates local RSS XML files containing
;; translated titles, creating separate subscription sources to avoid
;; duplicate entry issues in Elfeed's database.
;;
;; Usage:
;;   1. Tag the feeds you want translated in `elfeed-feeds':
;;        (setq elfeed-feeds
;;              \\='((\"https://example.com/en/rss\" translate-title)))
;;      Or in elfeed-org format:
;;        * English Blogs :translate_title:
;;        ** https://example.com/en/rss
;;   2. Configure `elfeed-translate-api-key'
;;   3. M-x elfeed-translate-setup  (or enable `global-elfeed-translate-mode')
;;   4. M-x elfeed-translate-show-feeds    copy the file:// URLs into your
;;      feed configuration (elfeed-org file or `elfeed-feeds')
;;   5. M-x elfeed-update    titles get translated, RSS files regenerated
;;   6. Another M-x elfeed-update    translated titles appear

;;; Code:

(require 'elfeed)
(require 'elfeed-db)
(require 'url)
(require 'json)
(require 'xml)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)

;;                                                                        
;; Customization
;;                                                                        

(defgroup elfeed-translate nil
  "Translate Elfeed entry titles using LLM APIs.
Generates local RSS files with translated titles as separate
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
  "Target language for title translation."
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
   "    \n\n"
   "EXAMPLE OUTPUT:\n"
   "     OpenAI    GPT-5   \n"
   "---\n"
   "     Flask    REST API\n"
   "---\n"
   "    ")
  "System prompt template for the translation API.
%s is replaced with `elfeed-translate-target-lang'."
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
Used only in parallel mode.  Each batch is still capped at
`elfeed-translate-batch-size' titles.  Has no effect when
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

;;                                                                        
;; Translation Cache
;;                                                                        

(defvar elfeed-translate--cache (make-hash-table :test 'equal)
  "Hash table mapping original title   translated title.")

(defvar elfeed-translate--cache-dirty nil
  "Non-nil when the cache has unsaved modifications.")

(defun elfeed-translate--cache-file ()
  "Return the path to the persisted cache file."
  (expand-file-name "translate-cache.el" elfeed-translate-output-dir))

(defun elfeed-translate--load-cache ()
  "Load translation cache from disk into memory."
  (let ((file (elfeed-translate--cache-file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case err
            (let ((data (read (current-buffer))))
              (if (hash-table-p data)
                  (progn
                    (setq elfeed-translate--cache data)
                    (setq elfeed-translate--cache-dirty nil)
                    (message "[elfeed-translate] Loaded %d cached translations"
                             (hash-table-count data)))
                (message "[elfeed-translate] Invalid cache format, ignoring")))
          (error
           (message "[elfeed-translate] Error reading cache file: %s"
                    (error-message-string err))))))))

(defun elfeed-translate--save-cache ()
  "Persist the translation cache to disk."
  (when elfeed-translate--cache-dirty
    (let ((file (elfeed-translate--cache-file)))
      (make-directory (file-name-directory file) t)
      (with-temp-buffer
        (let (print-level print-length)
          (print elfeed-translate--cache (current-buffer)))
        (write-region (point-min) (point-max) file nil 'silent))
      (setq elfeed-translate--cache-dirty nil))))

(defun elfeed-translate--cache-get (title)
  "Return the cached translation for TITLE, or nil."
  (gethash title elfeed-translate--cache))

(defun elfeed-translate--cache-set (title translation)
  "Store TRANSLATION as the cached version of TITLE."
  (unless (equal title translation)
    (puthash title translation elfeed-translate--cache)
    (setq elfeed-translate--cache-dirty t)))

;;                                                                        
;; Utility Functions
;;                                                                        

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
\"  \" / \"6 \" that Elfeed cannot parse."
  (if (and timestamp (> timestamp 0))
      (format-time-string "%a, %d %b %Y %H:%M:%S %z"
                          (seconds-to-time timestamp))
    (format-time-string "%a, %d %b %Y %H:%M:%S %z")))

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

(defun elfeed-translate--feed-has-tag-p (feed-url)
  "Return non-nil if FEED-URL has `elfeed-translate-feed-tag' in its autotags."
  (memq elfeed-translate-feed-tag
        (elfeed-translate--feed-autotags feed-url)))

(defun elfeed-translate--translatable-feeds ()
  "Return a list of all feed URLs that should be translated.
A feed is translatable if it has `elfeed-translate-feed-tag' as
an autotag in `elfeed-feeds'."
  (let ((feeds '()))
    (dolist (f elfeed-feeds)
      (let ((url (if (consp f) (car f) f)))
        (when (elfeed-translate--feed-has-tag-p url)
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

;;                                                                        
;; RSS XML Generation
;;                                                                        

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
Includes only entries that have a cached translation.  Returns the
path to the generated file."
  (let* ((feed (elfeed-db-get-feed feed-url))
         (feed-title (if feed
                         (or (elfeed-feed-title feed) feed-url)
                       feed-url))
         (translated-title (concat elfeed-translate-feed-title-prefix
                                   feed-title))
         (entries (elfeed-translate--entries-for-feed feed-url))
         (translated-entries
          (seq-filter
           (lambda (e)
             (and (elfeed-entry-title e)
                  (not (string-empty-p (elfeed-entry-title e)))
                  (elfeed-translate--cache-get (elfeed-entry-title e))))
           entries))
         (file (elfeed-translate--local-feed-path feed-url)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
      (insert "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">\n")
      (insert "  <channel>\n")
      ;; Channel metadata
      (insert (format "    <title>%s</title>\n"
                      (xml-escape-string translated-title)))
      (insert (format "    <link>%s</link>\n"
                      (xml-escape-string feed-url)))
      (insert (format "    <description>Auto-translated RSS feed for %s</description>\n"
                      (xml-escape-string feed-url)))
      (insert (format "    <atom:link href=\"%s\" rel=\"self\" type=\"application/rss+xml\"/>\n"
                      (xml-escape-string (elfeed-translate--local-feed-url feed-url))))
      ;; Entries
      (dolist (entry translated-entries)
        (let* ((original-title (elfeed-entry-title entry))
               (translated-title (elfeed-translate--cache-get original-title))
               (display-title (elfeed-translate--format-title
                               original-title translated-title))
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
          (insert "    </item>\n")))
      (insert "  </channel>\n")
      (insert "</rss>\n")
      (write-region (point-min) (point-max) file nil 'silent))
    file))

;;                                                                        
;; API Client
;;                                                                        

(defvar elfeed-translate--busy nil
  "Non-nil while a translation cycle is active.
In serial mode this is set per API request and cleared on completion.
In parallel mode it is held for the whole dispatch cycle and cleared
once every batch has completed.  `elfeed-translate--on-db-update'
checks this to avoid starting overlapping cycles.")

(defun elfeed-translate--call-api (titles callback &optional no-busy-guard)
  "Translate TITLES (list of strings) via the configured LLM API.
CALLBACK receives one argument: an alist of (original . translated)
pairs on success, or nil on failure.

The titles are sent as a single batch, separated by '---' markers.
The API response is expected to contain translated titles separated
by the same marker.

When NO-BUSY-GUARD is non-nil, neither check nor touch
`elfeed-translate--busy'.  Used by parallel dispatch
\(`elfeed-translate--process-batches-parallel') which manages the lock
at the cycle level and allows several requests in flight at once.

Always uses `url-retrieve' directly   never `url-queue-retrieve',
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
   ((null titles)
    (when callback (funcall callback nil)))
   (t
    (unless no-busy-guard (setq elfeed-translate--busy t))
    (let* ((system-prompt (format elfeed-translate-system-prompt
                                  elfeed-translate-target-lang))
           (user-content (string-join titles "\n---\n"))
           (request-body
            `((model . ,elfeed-translate-model)
              (messages . [((role . "system")
                            (content . ,system-prompt))
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
  Titles: %d
  First : %s"
                 elfeed-translate-api-url
                 elfeed-translate-model
                 (length titles)
                 (if titles
                     (substring (car titles) 0 (min 80 (length (car titles))))
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
                   ;; Watchdog already fired   discard this late response.
                   (progn
                     (when timeout-timer
                       (cancel-timer timeout-timer)
                       (setq timeout-timer nil)))
                 (unwind-protect
                     (let ((result
                            (condition-case parse-err
                                (elfeed-translate--parse-response
                                 titles (current-buffer))
                              (error
                               (message
                                "[elfeed-translate] Parse error: %s"
                                (error-message-string parse-err))
                               (elfeed-translate--dump-failed-response
                                (current-buffer) titles
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
      ;; No header/body separator found   return everything
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

(defun elfeed-translate--parse-response (titles buffer)
  "Parse the API response in BUFFER and pair with TITLES.
Returns an alist of (original . translated) or nil on failure.
Uses catch/throw for early exit instead of cl-return-from to avoid
issues with condition-case unwinding."
  (catch 'parse-error
    ;; Early exit on HTTP errors   the body is likely an HTML error
    ;; page, not JSON, so skip json-parse-string to avoid confusing
    ;; parse-error messages.
    (let ((http-status (elfeed-translate--http-status buffer)))
      (when (and http-status (>= http-status 400))
        (message "[elfeed-translate] HTTP %d   skipping JSON parse" http-status)
        (elfeed-translate--dump-failed-response
         buffer titles (format "HTTP %d" http-status))
        (throw 'parse-error nil)))
    (let ((response-text (elfeed-translate--extract-body buffer)))
      (unless response-text
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response buffer titles "empty body")
        (throw 'parse-error nil))
      (when (string-empty-p response-text)
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response buffer titles "empty body string")
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
                     buffer titles (format "JSON parse: %s"
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
             buffer titles "unexpected API structure")
            (throw 'parse-error nil))

          ;; Split the translated content by the batch separator
          (let ((translated (split-string content "---" t "[ \t\n\r]+")))
            (if (= (length translated) (length titles))
                (cl-mapcar #'cons titles translated)
              (message
               (concat "[elfeed-translate] Title count mismatch: "
                       "expected %d, got %d (%s). "
                       "Falling back to line-by-line parsing.")
               (length titles) (length translated)
               (mapconcat #'identity translated " | "))
              ;; Fallback: split by newlines
              (let ((lines (split-string content "\n" t "\\s-*")))
                (if (= (length lines) (length titles))
                    (cl-mapcar #'cons titles lines)
                  (message "[elfeed-translate] Line count still mismatched: %d vs %d"
                           (length titles) (length lines))
                  nil)))))))))

;;                                                                        
;; Core Translation Logic
;;                                                                        

(defun elfeed-translate--collect-untranslated ()
  "Scan all feeds marked with `elfeed-translate-feed-tag' for untranslated titles.
Returns an alist of (feed-url . title) for titles needing translation."
  (let ((items '()))
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (dolist (entry (elfeed-translate--entries-for-feed feed-url))
        (let ((title (elfeed-entry-title entry)))
          (when (and title
                     (not (string-empty-p title))
                     (not (elfeed-translate--cache-get title)))
            (push (cons feed-url title) items)))))
    (nreverse items)))

;;                                                                        
;; Feed List Display
;;                                                                        

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
      (user-error "No feeds tagged with `%s' in `elfeed-feeds'"
                  elfeed-translate-feed-tag))
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
                     (org-cycle-hide-drawers 'all) ; org 9.0 9.5
                   (error nil)))))
          (emacs-lisp-mode))
        (read-only-mode 1))
      (pop-to-buffer buf)
      (message "[elfeed-translate] %d feed URL(s) shown   copy into your feed configuration"
               (length feeds)))))

;;                                                                        
;; DB Update Handler
;;                                                                        

(defun elfeed-translate--split-into-batches (list batch-size)
  "Split LIST into sublists of at most BATCH-SIZE elements."
  (let ((batches '())
        (remaining list))
    (while remaining
      (let ((chunk (seq-take remaining batch-size)))
        (push chunk batches)
        (setq remaining (nthcdr batch-size remaining))))
    (nreverse batches)))

(defun elfeed-translate--finalize (title->feeds)
  "After all batches complete: regenerate RSS files.
TITLE->FEEDS maps original titles to their source feed-urls.

Only regenerates the local XML files   it does NOT call
`elfeed-update-feed'.  The user's next `elfeed-update' (or
scheduled update) will pick up the new content naturally."
  (let ((affected-feeds '()))
    (maphash (lambda (_title feeds)
               (dolist (f feeds)
                 (cl-pushnew f affected-feeds :test #'equal)))
             title->feeds)
    (dolist (feed-url affected-feeds)
      (elfeed-translate--generate-rss feed-url))
    (message "[elfeed-translate] All batches complete   %d feed(s) updated"
             (length affected-feeds))))

(defun elfeed-translate--process-batches (batches title->feeds total-batches)
  "Process BATCHES sequentially, one API call per batch.
TITLE->FEEDS maps titles   feed-urls.  TOTAL-BATCHES is the initial
number of batches (for progress reporting)."
  (when batches
    (let ((batch (car batches))
          (remaining (cdr batches))
          (batch-num (1+ (- total-batches (length batches)))))
      (message "[elfeed-translate] Batch %d/%d: translating %d titles..."
               batch-num total-batches (length batch))
      (elfeed-translate--call-api
       batch
       (lambda (pairs)
         (if pairs
             (progn
               (dolist (pair pairs)
                 (elfeed-translate--cache-set (car pair) (cdr pair)))
               (message "[elfeed-translate] Batch %d/%d: %d ok"
                        batch-num total-batches (length pairs)))
           (message "[elfeed-translate] Batch %d/%d: FAILED"
                    batch-num total-batches))
         (if remaining
             (elfeed-translate--process-batches
              remaining title->feeds total-batches)
           ;; All batches done   persist and refresh
           (elfeed-translate--save-cache)
           (elfeed-translate--finalize title->feeds)))))))

(defvar elfeed-translate--parallel-state nil
  "Plist holding parallel-dispatch state between async callbacks.
Keys: :queue, :in-flight, :completed, :total, :max-concurrent,
:finalize-fn, :title->feeds.  Bound by
`elfeed-translate--process-batches-parallel' and read by
`elfeed-translate--parallel-dispatch' and
`elfeed-translate--parallel-callback'.")

(defun elfeed-translate--parallel-callback (pairs)
  "Completion callback for one parallel API batch.
Reads and mutates `elfeed-translate--parallel-state'.  Decrements
the in-flight counter, caches results if PAIRS is non-nil, then
dispatches the next pending batch(es) and finalises when done."
  (let* ((state elfeed-translate--parallel-state)
         (completed (plist-get state :completed))
         (total (plist-get state :total))
         (finalize-fn (plist-get state :finalize-fn)))
    (unwind-protect
        (progn
          (plist-put state :in-flight (1- (plist-get state :in-flight)))
          (plist-put state :completed (1+ completed))
          (if pairs
              (progn
                (dolist (pair pairs)
                  (elfeed-translate--cache-set (car pair) (cdr pair)))
                (message
                 "[elfeed-translate] Batch completed: %d ok (%d/%d)"
                 (length pairs) (1+ completed) total))
            (message "[elfeed-translate] Batch FAILED (%d/%d)"
                     (1+ completed) total)))
      (elfeed-translate--parallel-dispatch)
      (when (and (null (plist-get state :queue))
                 (= (plist-get state :in-flight) 0))
        (funcall finalize-fn)))))

(defun elfeed-translate--parallel-dispatch ()
  "Dispatch pending batches up to the concurrency limit.
Reads `elfeed-translate--parallel-state' and sends batches via
`elfeed-translate--call-api' with `elfeed-translate--parallel-callback'
as the completion callback."
  (let* ((state elfeed-translate--parallel-state)
         (queue (plist-get state :queue))
         (in-flight (plist-get state :in-flight))
         (max-concurrent (plist-get state :max-concurrent)))
    (while (and queue (< in-flight max-concurrent))
      (let ((batch (pop queue)))
        (plist-put state :queue queue)
        (plist-put state :in-flight (1+ in-flight))
        (setq in-flight (1+ in-flight))
        (message
         "[elfeed-translate] Dispatching batch (%d titles)... (%d pending)"
         (length batch) (length queue))
        (elfeed-translate--call-api
         batch #'elfeed-translate--parallel-callback t)))))

(defun elfeed-translate--process-batches-parallel (batches title->feeds total-batches)
  "Process BATCHES concurrently with a self-managed concurrency limiter.
At most `elfeed-translate-max-concurrent' API requests are in flight
at once.  Each batch is still capped at `elfeed-translate-batch-size'
titles.  The cache is saved and affected RSS files regenerated once
every batch has completed.

TITLE->FEEDS maps titles   feed-urls (used by `elfeed-translate--finalize').
TOTAL-BATCHES is the total number of batches (for progress reporting).

Unlike `elfeed-translate--process-batches', this function does not
wait for a batch's response before sending the next; `--busy' is held
for the whole cycle and cleared on completion.

State is kept in `elfeed-translate--parallel-state' (a plist) rather
than in `let*' closures, because the Emacs Lisp interpreter does not
reliably capture `let*'-bound variables inside lambdas that are
invoked from process filters (async callbacks)."
  (if (null batches)
      (message "[elfeed-translate] No batches to process")
    (setq elfeed-translate--parallel-state
          (list :queue (copy-sequence batches)
                :in-flight 0
                :completed 0
                :total total-batches
                :max-concurrent (max 1 elfeed-translate-max-concurrent)
                :title->feeds title->feeds
                :finalize-fn
                (lambda ()
                  (elfeed-translate--save-cache)
                  (elfeed-translate--finalize title->feeds)
                  (setq elfeed-translate--busy nil)
                  (setq elfeed-translate--parallel-state nil))))
    (setq elfeed-translate--busy t)
    (elfeed-translate--parallel-dispatch)))

(defun elfeed-translate--on-db-update ()
  "Handle `elfeed-db-update-hook': translate new titles, update RSS files.
Splits large title sets into batches (see `elfeed-translate-batch-size')
and processes them via async API calls, either sequentially or in
parallel depending on `elfeed-translate-parallel'."
  (when (and (not elfeed-translate--busy)
             (elfeed-translate--translatable-feeds))
    (let ((items (elfeed-translate--collect-untranslated)))
      (if (not items)
          (progn
            (message "[elfeed-translate] All titles up to date   regenerating RSS files")
            (dolist (feed-url (elfeed-translate--translatable-feeds))
              (elfeed-translate--generate-rss feed-url)))
        (let* ((titles (delete-dups (mapcar #'cdr items)))
               ;; Build reverse index: title   list of feed-urls
               (title->feeds (make-hash-table :test 'equal))
               (batches (elfeed-translate--split-into-batches
                         titles elfeed-translate-batch-size)))
          (dolist (item items)
            (let ((feed-url (car item))
                  (title (cdr item)))
              (cl-pushnew feed-url (gethash title title->feeds)
                          :test #'equal)))
          (message "[elfeed-translate] %d titles in %d batch(es) across %d feed(s)"
                   (length titles)
                   (length batches)
                   (length (delete-dups (mapcar #'car items))))
          (if elfeed-translate-parallel
              (elfeed-translate--process-batches-parallel
               batches title->feeds (length batches))
            (elfeed-translate--process-batches
             batches title->feeds (length batches))))))))

;;                                                                        
;; Public Commands
;;                                                                        

(defvar elfeed-translate--setup-done nil
  "Non-nil after the one-time portion of `elfeed-translate-setup' has run.")

;;;###autoload
(defun elfeed-translate-setup ()
  "Configure and enable elfeed-translate.
Creates output directory, loads the translation cache, generates
initial RSS files, and installs the update hook.

This function is idempotent   the heavy one-time work (directory
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
     (format "No feeds tagged with `%s'.  Add the tag to feeds in `elfeed-feeds'."
             elfeed-translate-feed-tag)
     :warning))
  ;; One-time initialisation
  (unless elfeed-translate--setup-done
    (make-directory elfeed-translate-output-dir t)
    (elfeed-translate--load-cache)
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (elfeed-translate--generate-rss feed-url))
    (setq elfeed-translate--setup-done t)
    (message "[elfeed-translate] Setup   %d feed(s), %d cached translation(s)"
             (length (elfeed-translate--translatable-feeds))
             (hash-table-count elfeed-translate--cache))
    (unless (featurep 'elfeed-search)
      (message "[elfeed-translate] Run M-x elfeed-translate-show-feeds to get your translated feed URLs")))
  ;; Always ensure the DB-update hook is installed (idempotent)
  (add-hook 'elfeed-db-update-hook #'elfeed-translate--on-db-update))

;;;###autoload
(defun elfeed-translate-teardown ()
  "Remove elfeed-translate hooks and persist the cache."
  (interactive)
  (remove-hook 'elfeed-db-update-hook #'elfeed-translate--on-db-update)
  (elfeed-translate--save-cache)
  (message "[elfeed-translate] Teardown complete"))

;;;###autoload
(defun elfeed-translate-update ()
  "Manually trigger translation of all tagged feed titles.
Useful for re-translating after changing the target language or
system prompt."
  (interactive)
  (unless (elfeed-translate--translatable-feeds)
    (user-error "No feeds tagged with `%s' in `elfeed-feeds'"
                elfeed-translate-feed-tag))
  (message "[elfeed-translate] Starting manual translation...")
  (elfeed-translate--on-db-update))

;;;###autoload
(defun elfeed-translate-clear-cache ()
  "Clear all cached translations and regenerate RSS files.
Use this when you want to force a fresh translation of all titles
(with a new target language, for example)."
  (interactive)
  (when (yes-or-no-p "Clear all cached translations and re-translate everything? ")
    (setq elfeed-translate--cache (make-hash-table :test 'equal))
    (setq elfeed-translate--cache-dirty t)
    (elfeed-translate--save-cache)
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
Shows all feeds tagged with `elfeed-translate-feed-tag' and
their translation status."
  (interactive)
  (let* ((feeds (elfeed-translate--translatable-feeds))
         (lines '())
         (total-cached (hash-table-count elfeed-translate--cache))
         (total-entries 0)
         (total-untranslated 0))
    (push (format "elfeed-translate status:
  Feed tag       : %s
  Target language: %s
  API endpoint   : %s
  Model          : %s
  Tagged feeds   : %d
  Cached entries : %d
"
                  elfeed-translate-feed-tag
                  elfeed-translate-target-lang
                  elfeed-translate-api-url
                  elfeed-translate-model
                  (length feeds)
                  total-cached)
          lines)
    (if (not feeds)
        (push (format "  (No feeds tagged with `%s' in `elfeed-feeds')\n"
                      elfeed-translate-feed-tag)
              lines)
      (dolist (feed-url feeds)
        (let* ((entries (elfeed-translate--entries-for-feed feed-url))
               (n-all (length entries))
               (n-cached
                (seq-count
                 (lambda (e)
                   (and (elfeed-entry-title e)
                        (elfeed-translate--cache-get (elfeed-entry-title e))))
                 entries))
               (path (elfeed-translate--local-feed-path feed-url)))
          (cl-incf total-entries n-all)
          (cl-incf total-untranslated (- n-all n-cached))
          (push (format "  %s
      %d entries (%d translated, %d pending)
        %s%s
"
                        feed-url n-all n-cached (- n-all n-cached)
                        path
                        (if (file-exists-p path) "" " [MISSING]"))
                lines))))
    (push (format "
  Total entries   : %d (%d untranslated)\n"
                  total-entries total-untranslated)
          lines)
    (message "%s" (string-join (nreverse lines)))))

;;                                                                        
;; Global Minor Mode
;;                                                                        

;;;###autoload
(define-minor-mode global-elfeed-translate-mode
  "Toggle automatic translation of Elfeed entry titles.
When enabled, titles of feeds tagged with `elfeed-translate-feed-tag'
are automatically translated after each feed update via the
configured LLM API."
  :global t
  :lighter " ELTL"
  (if global-elfeed-translate-mode
      (elfeed-translate-setup)
    (elfeed-translate-teardown)))

;;                                                                        
;; Auto-start hook: run setup whenever the Elfeed search buffer opens.
;; This mirrors how elfeed-org hooks into elfeed-search-mode-hook to
;; load feeds   here we load the translation cache and enable the
;; db-update-hook automatically.  The setup function is idempotent so
;; repeated calls are cheap.
;;                                                                        

;;;###autoload
(add-hook 'elfeed-search-mode-hook #'elfeed-translate-setup)

(provide 'elfeed-translate)
;;; elfeed-translate.el ends here
