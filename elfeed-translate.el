;;; elfeed-translate.el --- Translate Elfeed entry titles and content via LLM API -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.5.0
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

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'elfeed-translate-core)
(require 'elfeed-translate-cache)
(require 'elfeed-translate-api)
(require 'elfeed-translate-elfeed)

(declare-function org-fold-hide-drawers-all "org-fold")
(declare-function org-cycle-hide-drawers "org-cycle")

;; ═══════════════════════════════════════════════════════════════════════
;; Translation Cycle State
;; ═══════════════════════════════════════════════════════════════════════

(defvar elfeed-translate--busy nil
  "Non-nil while a translation cycle is active.
Both serial and parallel dispatch hold this for the complete cycle,
including delayed retries, and clear it after finalization.
`elfeed-translate--on-db-update' checks it to avoid starting
overlapping cycles.  The API transport does not access this state.")

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
      (elfeed-translate--generate-rss
       feed-url #'elfeed-translate--cache-get))
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
    (elfeed-translate--generate-rss
     feed-url #'elfeed-translate--cache-get))
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
plists (:call-fn :texts :prompt :retries).  Passes the element to
`elfeed-translate--parallel-callback' via a closure."
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
              (elfeed-translate--generate-rss
               feed-url #'elfeed-translate--cache-get)))
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
      (elfeed-translate--generate-rss
       feed-url #'elfeed-translate--cache-get))
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
      (elfeed-translate--generate-rss
       feed-url #'elfeed-translate--cache-get))
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
  :group 'elfeed-translate
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
