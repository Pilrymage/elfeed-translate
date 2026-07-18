;;; elfeed-translate-api.el --- OpenAI-compatible client for elfeed-translate -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.7.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, rss, translation

;;; Commentary:

;; Request validation, asynchronous HTTP transport and response parsing
;; for elfeed-translate.  This module performs one request at a time and
;; does not own translation-cycle scheduling or cache persistence.

;;; Code:

(require 'url)
(require 'json)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'elfeed-translate-core)

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
Returns a plist containing :data and :headers.  The JSON body
is verified to be valid UTF-8 JSON in a unibyte string, and every
HTTP header is normalised to ASCII unibyte form before Emacs' URL
library concatenates it with the body."
  (let* ((prompt-template (or system-prompt
                              elfeed-translate-system-prompt))
         (system-prompt-str (format prompt-template
                                    elfeed-translate-target-lang))
         (user-content (elfeed-translate--batch-user-content texts))
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

(defun elfeed-translate--call-api (texts callback &optional system-prompt)
  "Translate TEXTS (list of strings) via the configured LLM API.
CALLBACK receives one structured result plist.  On success it has
:ok t and :pairs containing (source-text . translated) pairs.  On
failure it has :ok nil plus :kind, :message and :retryable metadata.

The texts are sent as an id-bearing JSON array.  The API response is
expected to return each id exactly once with its translation; legacy
separator output remains a compatibility fallback.

SYSTEM-PROMPT is the prompt template (with %s for target language).
Defaults to `elfeed-translate-system-prompt'.

Always uses `url-retrieve' directly — never `url-queue-retrieve',
which defers the actual request to an idle timer and loses the
dynamic `url-request-method' / `url-request-extra-headers' /
`url-request-data' bindings."
  (cond
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
    (condition-case request-err
        (let* ((request (elfeed-translate--build-request texts system-prompt))
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
                                        texts (current-buffer))
                                     (error
                                      (elfeed-translate--dump-failed-response
                                       (current-buffer) texts
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
                        )))
                  nil 'silent))))
            (error
             (let ((result
                    (elfeed-translate--failure-result
                     'send (error-message-string send-err) nil)))
               (message "[elfeed-translate] Failed to send API request: %s"
                        (plist-get result :message))
               (when callback (funcall callback result))))))
      (error
       (let ((result
              (elfeed-translate--failure-result
               'request-validation
               (error-message-string request-err)
               nil)))
         (message "[elfeed-translate] Request validation failed: %s"
                  (plist-get result :message))
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

(defun elfeed-translate--dump-failed-response (buffer sources reason)
  "Write the full raw content of BUFFER to a debug buffer for inspection.
SOURCES is the list of source texts sent in the failed request.  REASON is a
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
        (insert (format "Items     : %d\n" (length sources)))
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
    (content sources http-status finish-reason)
  "Parse id-bearing translation JSON CONTENT and pair it with SOURCES.
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
                (elfeed-translate--batch-item-ids (length sources)))
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
                      sources expected-ids)
           :http-status http-status
           :finish-reason finish-reason
           :protocol 'id-json))))))

(defun elfeed-translate--parse-legacy-content
    (content sources http-status finish-reason)
  "Parse legacy separator CONTENT as a compatibility fallback."
  (let ((translated (split-string content "---" t "[ \t\n\r]+")))
    (cond
     ((= (length translated) (length sources))
      (elfeed-translate--success-result
       (cl-mapcar #'cons sources translated)
       :http-status http-status :finish-reason finish-reason
       :protocol 'legacy-separator))
     (t
      (let ((lines (split-string content "\n" t "\\s-*")))
        (if (= (length lines) (length sources))
            (elfeed-translate--success-result
             (cl-mapcar #'cons sources lines)
             :http-status http-status :finish-reason finish-reason
             :protocol 'legacy-lines)
          (elfeed-translate--failure-result
           'output-mismatch
           (format "Expected %d translations, received %d"
                   (length sources) (length lines))
           t :http-status http-status :finish-reason finish-reason)))))))

(defun elfeed-translate--parse-response (sources buffer)
  "Parse the API response in BUFFER and pair with SOURCES.
SOURCES is the list of source texts sent.  Returns a structured
success or failure result.  Uses
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
           buffer sources (format "HTTP %d" http-status))
          (throw
           'parse-error
           (elfeed-translate--failure-result
            'http message-text nil
            :http-status http-status
            :retry-after (elfeed-translate--retry-after-seconds buffer)))))
      (unless response-text
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response
         buffer sources "empty body")
        (throw
         'parse-error
         (elfeed-translate--failure-result
          'empty-response "Response body is missing" nil
          :http-status http-status)))
      (when (string-empty-p response-text)
        (message "[elfeed-translate] Empty response body")
        (elfeed-translate--dump-failed-response buffer sources "empty body string")
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
                  buffer sources (format "JSON parse: %s"
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
             buffer sources "unexpected API structure")
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
              content sources http-status finish-reason)
              (elfeed-translate--parse-legacy-content
               content sources http-status finish-reason)))))))


(provide 'elfeed-translate-api)
;;; elfeed-translate-api.el ends here
