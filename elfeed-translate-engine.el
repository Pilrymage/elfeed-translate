;;; elfeed-translate-engine.el --- Translation engine for elfeed-translate -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.7.0
;; Package-Requires: ((emacs "29.1") (elfeed "3.0"))
;; Keywords: news, rss, translation

;;; Commentary:

;; Cross-module translation-cycle orchestration: collection, batching,
;; retries, bounded parallel dispatch, Elfeed update hooks and RSS
;; finalization.  The public facade remains `elfeed-translate'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'elfeed)
(require 'elfeed-translate-core)
(require 'elfeed-translate-cache)
(require 'elfeed-translate-api)
(require 'elfeed-translate-elfeed)

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
  (let ((updated 0)
        (failed 0))
    (dolist (feed-url affected-feeds)
      (condition-case err
          (progn
            (elfeed-translate--generate-rss
             feed-url #'elfeed-translate--cache-get)
            (cl-incf updated))
        (error
         (cl-incf failed)
         (message "[elfeed-translate] RSS update FAILED for %s: %s"
                  feed-url (error-message-string err)))))
    (message
     "[elfeed-translate] All batches complete — %d/%d feed(s) updated in %s%s"
     updated (length affected-feeds)
     (abbreviate-file-name elfeed-translate-output-dir)
     (if (> failed 0) (format ", %d failed" failed) "")))
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

(defun elfeed-translate--fatal-cycle-failure-p (result)
  "Return non-nil when RESULT should abort all unsent batches.
Transport, proxy, provider HTTP and request-configuration failures
normally affect the complete cycle rather than one translation item.
Model output failures remain isolated to their batch and may retry."
  (memq (plist-get result :kind)
        '(network timeout send http empty-response configuration
          request-validation api-structure parse busy)))

(defun elfeed-translate--report-cycle-abort (result unsent)
  "Report fatal RESULT and the number of UNSENT batches discarded."
  (message
   (concat "[elfeed-translate] Translation cycle ABORTED; %d batch(es) "
           "will not be sent. Check proxy, DNS, network and provider status: %s")
   unsent (elfeed-translate--failure-summary result)))

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
               (if (elfeed-translate--fatal-cycle-failure-p result)
                   (progn
                     (elfeed-translate--report-cycle-abort
                      result (length remaining))
                     (setq remaining nil))
                 (message
                  "[elfeed-translate] Batch %d/%d: FAILED, not retrying: %s"
                  batch-num total (elfeed-translate--failure-summary result)))
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
:failed, :skipped, :aborted, :dispatching, :retry-timers,
:max-concurrent, :affected-feeds, :consecutive-fatal,
:fatal-limit and :throttle-until.  Queue elements are plists:
(:call-fn :texts :prompt :retries :heal-retries :throttle-retries).
Bound by `elfeed-translate--process-batches-parallel' and read by
`elfeed-translate--parallel-dispatch' and
`elfeed-translate--parallel-callback'.")

(defun elfeed-translate--parallel-cancel-retry-timers (state)
  "Cancel every delayed retry timer recorded in parallel STATE."
  (dolist (timer (plist-get state :retry-timers))
    (when (timerp timer)
      (cancel-timer timer)))
  (plist-put state :retry-timers nil))

(defun elfeed-translate--parallel-abort (state result)
  "Abort unsent work in parallel STATE because of fatal RESULT."
  (unless (plist-get state :aborted)
    (let* ((queued (length (plist-get state :queue)))
           (waiting (plist-get state :retry-waiting))
           (unsent (+ queued waiting)))
      (plist-put state :aborted t)
      (plist-put state :abort-result result)
      (plist-put state :skipped (+ (plist-get state :skipped) unsent))
      (plist-put state :queue nil)
      (plist-put state :retry-waiting 0)
      (plist-put state :throttle-until nil)
      (elfeed-translate--parallel-cancel-retry-timers state)
      (elfeed-translate--report-cycle-abort result unsent))))

(defun elfeed-translate--parallel-finalize (state)
  "Finalize parallel STATE exactly once and release cycle state."
  (when (eq state elfeed-translate--parallel-state)
    (let ((affected-feeds (plist-get state :affected-feeds))
          (completed (plist-get state :completed))
          (failed (plist-get state :failed))
          (skipped (plist-get state :skipped))
          (aborted (plist-get state :aborted)))
      (elfeed-translate--parallel-cancel-retry-timers state)
      ;; Release state before RSS generation or auto-refresh.  An error while
      ;; writing one file must never leave the translation engine permanently
      ;; busy or let a late callback corrupt a later cycle.
      (setq elfeed-translate--parallel-state nil)
      (setq elfeed-translate--busy nil)
      (condition-case err
          (elfeed-translate--finalize affected-feeds)
        (error
         (message "[elfeed-translate] RSS finalization FAILED: %s"
                  (error-message-string err))))
      (message
       "[elfeed-translate] Cycle finished%s: %d completed, %d failed, %d skipped"
       (if aborted " after abort" "") completed failed skipped))))

(defun elfeed-translate--parallel-maybe-finalize (state)
  "Finalize parallel STATE when no queued, active or delayed work remains."
  (when (and (eq state elfeed-translate--parallel-state)
             (not (plist-get state :dispatching))
             (null (plist-get state :queue))
             (= (plist-get state :in-flight) 0)
             (= (plist-get state :retry-waiting) 0))
    (elfeed-translate--parallel-finalize state)))

(defun elfeed-translate--self-heal-failure-p (result)
  "Return non-nil when RESULT is a transport failure eligible for self-healing.
These failures (`network', `timeout', `send') increment the
consecutive-fatal counter and may be re-queued once before the batch
is abandoned.  Serial mode does not use this predicate."
  (memq (plist-get result :kind) '(network timeout send)))

(defun elfeed-translate--throttle-failure-p (result)
  "Return non-nil when RESULT is an HTTP 429 that should throttle dispatch.
Unlike other HTTP errors, 429 signals rate limiting rather than a
permanent fault: the cycle pauses, then resumes from the queue."
  (and (eq (plist-get result :kind) 'http)
       (eql (plist-get result :http-status) 429)))

(defun elfeed-translate--throttle-wait (result)
  "Return seconds to pause dispatch after a 429 RESULT.
The provider's `Retry-After' value is used as a hint and clamped to
`elfeed-translate-max-throttle-wait'.  When missing, a fallback of
twice `elfeed-translate-retry-base-delay' (at least 2 seconds) is used."
  (let* ((hint (plist-get result :retry-after))
         (max-wait (max 0.0 (float elfeed-translate-max-throttle-wait)))
         (fallback (max 2.0 (* 2.0 (float elfeed-translate-retry-base-delay)))))
    (cond
     ((and (numberp hint) (>= hint 0))
      (if (> hint max-wait)
          (progn
            (message "[elfeed-translate] Throttle wait clamped: provider=%ds, max=%ds"
                     (round hint) (round max-wait))
            max-wait)
        hint))
     (t fallback))))

(defun elfeed-translate--parallel-record-fatal (state result)
  "Record a consecutive fatal failure in STATE and trip the circuit if needed.
Increments `:consecutive-fatal' and, when it reaches `:fatal-limit',
aborts the cycle with RESULT.  Returns t when the circuit tripped."
  (let* ((count (1+ (or (plist-get state :consecutive-fatal) 0)))
         (limit (plist-get state :fatal-limit)))
    (plist-put state :consecutive-fatal count)
    (when elfeed-translate-debug
      (message "[elfeed-translate] Consecutive fatal: %d/%d" count limit))
    (if (>= count limit)
        (progn
          (message
           "[elfeed-translate] Circuit tripped: %d consecutive fatal, aborting"
           count)
          (elfeed-translate--parallel-abort state result)
          t)
      nil)))

(defun elfeed-translate--parallel-resume-throttle (state)
  "Resume dispatch after a 429 throttle pause expires for STATE.
Clears `:throttle-until' and pumps the queue.  Stale calls from an
older cycle are ignored."
  (when (eq state elfeed-translate--parallel-state)
    (plist-put state :throttle-until nil)
    (elfeed-translate--parallel-dispatch)
    (elfeed-translate--parallel-maybe-finalize state)))

(defun elfeed-translate--parallel-requeue-retry (state element)
  "Put delayed retry ELEMENT back into parallel STATE's queue."
  (when (eq state elfeed-translate--parallel-state)
    (plist-put state :retry-waiting
               (max 0 (1- (plist-get state :retry-waiting))))
    (unless (plist-get state :aborted)
      (plist-put state :queue
                 (append (plist-get state :queue) (list element))))
    (elfeed-translate--parallel-dispatch)
    (elfeed-translate--parallel-maybe-finalize state)))

(defun elfeed-translate--parallel-callback (state element result)
  "Completion callback for one parallel API batch.
STATE identifies the cycle that dispatched ELEMENT.  RESULT is a
structured API result.  Stale callbacks from an older cycle are
ignored.

Failure handling:
  - HTTP 429 throttles dispatch: the batch is re-queued and a
    `:throttle-until' deadline pauses new dispatch until it expires.
    After two throttled retries the batch escalates to a fatal
    failure counted by the consecutive-fatal circuit.
  - Transport failures (`network', `timeout', `send') self-heal
    once: the batch is re-queued after a short backoff.  Every such
    failure (including the self-heal retry) increments the
    consecutive-fatal circuit, which aborts the cycle once
    `:fatal-limit' is reached.
  - Other fatal-cycle failures (configuration, parse, non-429 HTTP,
    ...) abort the cycle immediately.
  - Retryable model-output failures use exponential backoff up to
    `elfeed-translate-max-retries'."
  (when (eq state elfeed-translate--parallel-state)
    (let* ((completed (plist-get state :completed))
           (total (plist-get state :total))
           (retries (plist-get element :retries))
           (heal-retries (or (plist-get element :heal-retries) 0))
           (throttle-retries (or (plist-get element :throttle-retries) 0))
           (aborted (plist-get state :aborted)))
      (unwind-protect
          (progn
            (plist-put state :in-flight
                       (max 0 (1- (plist-get state :in-flight))))
            (cond
             ((elfeed-translate--result-ok-p result)
              (let ((pairs (plist-get result :pairs)))
                (elfeed-translate--cache-set-batch pairs)
                (plist-put state :completed (1+ completed))
                (message
                 "[elfeed-translate] Batch completed: %d ok (%d/%d)"
                 (length pairs) (1+ completed) total)))
             ;; 429 throttling: pause dispatch and re-queue the batch.
             ((and (not aborted)
                   (elfeed-translate--throttle-failure-p result)
                   (< throttle-retries 2))
              (let* ((new-throttle (1+ throttle-retries))
                     (wait (elfeed-translate--throttle-wait result))
                     (throttle-until
                      (time-add (current-time) (seconds-to-time wait)))
                     (prior-until (plist-get state :throttle-until))
                     (retry-element
                      (plist-put (copy-sequence element)
                                 :throttle-retries new-throttle))
                     (timer
                      (run-at-time
                       wait nil #'elfeed-translate--parallel-resume-throttle
                       state)))
                (plist-put state :throttle-until
                           (if (and prior-until
                                    (time-less-p throttle-until prior-until))
                               prior-until
                             throttle-until))
                (plist-put state :queue
                           (append (plist-get state :queue)
                                   (list retry-element)))
                (plist-put state :retry-timers
                           (cons timer (plist-get state :retry-timers)))
                (when elfeed-translate-debug
                  (message
                   (concat "[elfeed-translate] Throttling for %.1fs "
                           "(Retry-After=%s); batch requeued (throttle %d/2)")
                   wait (or (plist-get result :retry-after) "none")
                   new-throttle))))
             ;; 429 exhausted: escalate to a consecutive fatal failure.
             ((elfeed-translate--throttle-failure-p result)
              (message
               "[elfeed-translate] 429 batch escalated to fatal (throttle-retries=%d)"
               throttle-retries)
              (let ((tripped
                     (elfeed-translate--parallel-record-fatal state result)))
                (unless tripped
                  (plist-put state :completed (1+ completed))
                  (plist-put state :failed
                             (1+ (plist-get state :failed)))
                  (message
                   "[elfeed-translate] Batch FAILED (%d/%d), not retrying: %s"
                   (1+ completed) total
                   (elfeed-translate--failure-summary result)))))
             ;; Transport self-heal: re-queue once, circuit permitting.
             ((and (not aborted)
                   (elfeed-translate--self-heal-failure-p result)
                   (< heal-retries 1))
              (let ((tripped
                     (elfeed-translate--parallel-record-fatal state result)))
                (if tripped
                    nil
                  (let* ((delay (elfeed-translate--retry-delay result 0))
                         (retry-element
                          (plist-put (copy-sequence element)
                                     :heal-retries (1+ heal-retries)))
                         (timer
                          (run-at-time
                           delay nil #'elfeed-translate--parallel-requeue-retry
                           state retry-element)))
                    (plist-put state :retry-waiting
                               (1+ (plist-get state :retry-waiting)))
                    (plist-put state :retry-timers
                               (cons timer (plist-get state :retry-timers)))
                    (message
                     (concat "[elfeed-translate] Batch transport failure: %s; "
                             "self-heal retry in %.1fs (consecutive-fatal incremented)")
                     (elfeed-translate--failure-summary result) delay)))))
             ;; Transport exhausted (self-heal used up) or circuit tripped.
             ((elfeed-translate--self-heal-failure-p result)
              (let ((tripped
                     (elfeed-translate--parallel-record-fatal state result)))
                (unless tripped
                  (plist-put state :completed (1+ completed))
                  (plist-put state :failed
                             (1+ (plist-get state :failed)))
                  (message
                   "[elfeed-translate] Batch FAILED (%d/%d), self-heal exhausted: %s"
                   (1+ completed) total
                   (elfeed-translate--failure-summary result)))))
             ;; Other fatal-cycle failures abort immediately.
             ((elfeed-translate--fatal-cycle-failure-p result)
              (plist-put state :completed (1+ completed))
              (plist-put state :failed (1+ (plist-get state :failed)))
              (elfeed-translate--parallel-abort state result))
             ;; Retryable model-output failures with exponential backoff.
             ((and (not aborted)
                   (plist-get result :retryable)
                   (< retries elfeed-translate-max-retries))
              (let* ((delay (elfeed-translate--retry-delay result retries))
                     (retry-element
                      (plist-put (copy-sequence element)
                                 :retries (1+ retries)))
                     (timer
                      (run-at-time
                       delay nil #'elfeed-translate--parallel-requeue-retry
                       state retry-element)))
                (plist-put state :retry-waiting
                           (1+ (plist-get state :retry-waiting)))
                (plist-put state :retry-timers
                           (cons timer (plist-get state :retry-timers)))
                (message
                 (concat "[elfeed-translate] Batch failed: %s; "
                         "retry %d/%d in %.1fs")
                 (elfeed-translate--failure-summary result)
                 (1+ retries) elfeed-translate-max-retries delay)))
             (t
              (plist-put state :completed (1+ completed))
              (plist-put state :failed (1+ (plist-get state :failed)))
              (message
               "[elfeed-translate] Batch FAILED (%d/%d), not retrying: %s"
               (1+ completed) total
               (elfeed-translate--failure-summary result)))))
        (elfeed-translate--parallel-dispatch)
        (elfeed-translate--parallel-maybe-finalize state)))))

(defun elfeed-translate--parallel-dispatch ()
  "Dispatch pending batches up to the concurrency limit.
Reads `elfeed-translate--parallel-state'.  Queue elements are
plists (:call-fn :texts :prompt :retries :heal-retries
:throttle-retries).  Passes the element to
`elfeed-translate--parallel-callback' via a closure.  When
`:throttle-until' is in the future, dispatch pauses until the
throttle timer resumes it."
  (let ((state elfeed-translate--parallel-state))
    ;; A request function can invoke its callback synchronously when request
    ;; validation or DNS/proxy setup fails.  Prevent that callback from
    ;; recursively dispatching against stale local queue counters.
    (when (and state
               (not (plist-get state :dispatching)))
      (plist-put state :dispatching t)
      (unwind-protect
          (while (and (eq state elfeed-translate--parallel-state)
                      (not (plist-get state :aborted))
                      (plist-get state :queue)
                      (let ((tu (plist-get state :throttle-until)))
                        (not (and tu
                                  (time-less-p (current-time) tu))))
                      (< (plist-get state :in-flight)
                         (plist-get state :max-concurrent)))
            (let* ((element (car (plist-get state :queue)))
                   (call-fn (plist-get element :call-fn))
                   (texts (plist-get element :texts))
                   (prompt (plist-get element :prompt))
                   (retries (plist-get element :retries)))
              (plist-put state :queue (cdr (plist-get state :queue)))
              (plist-put state :in-flight
                         (1+ (plist-get state :in-flight)))
              (message
               "[elfeed-translate] Dispatching batch (%d items, retries=%d)... (%d pending)"
               (length texts) retries (length (plist-get state :queue)))
              (condition-case err
                  (funcall call-fn
                           texts
                           (lambda (result)
                             (elfeed-translate--parallel-callback
                              state element result))
                           prompt)
                (error
                 (elfeed-translate--parallel-callback
                  state element
                  (elfeed-translate--failure-result
                   'send (error-message-string err) nil))))))
        (plist-put state :dispatching nil))
      (elfeed-translate--parallel-maybe-finalize state))))

(defun elfeed-translate--process-batches-parallel (queue affected-feeds)
  "Process a QUEUE of batches concurrently with a self-managed limiter.
QUEUE is a list of plists (:call-fn :texts :prompt :retries).
At most `elfeed-translate-max-concurrent' API requests are in flight
at once.  Failed batches are re-enqueued with incremented :retries,
up to `elfeed-translate-max-retries'.  Translations are written to
the SQLite cache in per-batch transactions, and affected RSS files
are regenerated once every batch has completed.

AFFECTED-FEEDS is a list of feed URLs to regenerate on completion.

STATE is kept in `elfeed-translate--parallel-state'.  Each callback
also receives the exact state object that dispatched it, preventing a
late response from corrupting a newer cycle."
  (if (null queue)
      (message "[elfeed-translate] No batches to process")
    (setq elfeed-translate--parallel-state
          (list :queue (copy-sequence queue)
                :in-flight 0
                :retry-waiting 0
                :retry-timers nil
                :completed 0
                :failed 0
                :skipped 0
                :aborted nil
                :abort-result nil
                :dispatching nil
                :total (length queue)
                :max-concurrent (max 1 elfeed-translate-max-concurrent)
                :affected-feeds affected-feeds
                :consecutive-fatal 0
                :fatal-limit (max 1 elfeed-translate-max-consecutive-fatal)
                :throttle-until nil))
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


(provide 'elfeed-translate-engine)
;;; elfeed-translate-engine.el ends here
