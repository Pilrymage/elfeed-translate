;;; elfeed-translate-engine-test.el --- Engine tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate-engine)

(ert-deftest elfeed-translate-engine-splits-batches-without-loss ()
  (should (equal (elfeed-translate--split-into-batches '(1 2 3 4 5) 2)
                 '((1 2) (3 4) (5)))))

(ert-deftest elfeed-translate-engine-finalize-continues-after-rss-error ()
  (let ((elfeed-translate-auto-refresh nil)
        (written nil))
    (cl-letf (((symbol-function 'elfeed-translate--generate-rss)
               (lambda (feed _lookup)
                 (if (equal feed "bad")
                     (error "disk error")
                   (push feed written)))))
      (elfeed-translate--finalize '("bad" "good")))
    (should (equal written '("good")))))

(ert-deftest elfeed-translate-engine-collects-through-module-boundaries ()
  (let ((entry (elfeed-entry--create
                :id "entry"
                :title "new title"
                :content "cached body"
                :content-type 'html
                :feed-id "feed")))
    (cl-letf (((symbol-function 'elfeed-translate--translatable-feeds)
               (lambda () '("feed")))
              ((symbol-function 'elfeed-translate--feed-has-title-tag-p)
               (lambda (_url) t))
              ((symbol-function 'elfeed-translate--feed-has-content-tag-p)
               (lambda (_url) t))
              ((symbol-function 'elfeed-translate--entries-for-feed)
               (lambda (_url) (list entry)))
              ((symbol-function 'elfeed-translate--cache-get)
               (lambda (source)
                 (and (equal source "cached body") "正文"))))
      (should (equal (elfeed-translate--collect-untranslated)
                     '(:title-items (("feed" . "new title"))
                       :content-items nil))))))

(ert-deftest elfeed-translate-engine-sync-network-failure-aborts-pending ()
  "A synchronous proxy/DNS failure must not dispatch later batches."
  (let ((elfeed-translate--parallel-state nil)
        (elfeed-translate--busy nil)
        (elfeed-translate-max-concurrent 4)
        (elfeed-translate-max-consecutive-fatal 1)
        (calls 0)
        (finalized nil))
    (cl-letf (((symbol-function 'elfeed-translate--finalize)
               (lambda (feeds) (setq finalized feeds))))
      (let* ((call-fn
              (lambda (_texts callback _prompt)
                (cl-incf calls)
                (funcall callback
                         (elfeed-translate--failure-result
                          'send "proxy getaddrinfo failed" nil))))
             (queue
              (mapcar
               (lambda (text)
                 (list :call-fn call-fn :texts (list text)
                       :prompt "prompt %s" :retries 0))
               '("one" "two" "three"))))
        (elfeed-translate--process-batches-parallel queue '("feed"))))
    (should (= calls 1))
    (should (equal finalized '("feed")))
    (should-not elfeed-translate--busy)
    (should-not elfeed-translate--parallel-state)))

(ert-deftest elfeed-translate-engine-async-network-failure-drains-in-flight ()
  "Fatal failure drops pending work but preserves completed in-flight work."
  (let ((elfeed-translate--parallel-state nil)
        (elfeed-translate--busy nil)
        (elfeed-translate-max-concurrent 2)
        (elfeed-translate-max-consecutive-fatal 1)
        (callbacks nil)
        (calls 0)
        (cached nil)
        (finalized nil))
    (cl-letf (((symbol-function 'elfeed-translate--cache-set-batch)
               (lambda (pairs) (setq cached (append cached pairs))))
              ((symbol-function 'elfeed-translate--finalize)
               (lambda (feeds) (setq finalized feeds))))
      (let* ((call-fn
              (lambda (_texts callback _prompt)
                (cl-incf calls)
                (setq callbacks (append callbacks (list callback)))))
             (queue
              (mapcar
               (lambda (text)
                 (list :call-fn call-fn :texts (list text)
                       :prompt "prompt %s" :retries 0))
               '("one" "two" "three"))))
        (elfeed-translate--process-batches-parallel queue '("feed"))
        (should (= calls 2))
        (funcall (nth 0 callbacks)
                 (elfeed-translate--failure-result
                  'network "proxy disconnected" nil))
        (should-not finalized)
        (funcall (nth 1 callbacks)
                 (elfeed-translate--success-result
                  '(("two" . "二")) :http-status 200))))
    (should (= calls 2))
    (should (equal cached '(("two" . "二"))))
    (should (equal finalized '("feed")))
    (should-not elfeed-translate--busy)
    (should-not elfeed-translate--parallel-state)))

(ert-deftest elfeed-translate-engine-sync-success-finalizes-once ()
  (let ((elfeed-translate--parallel-state nil)
        (elfeed-translate--busy nil)
        (elfeed-translate-max-concurrent 2)
        (calls 0)
        (writes 0)
        (finalizes 0))
    (cl-letf (((symbol-function 'elfeed-translate--cache-set-batch)
               (lambda (_pairs) (cl-incf writes)))
              ((symbol-function 'elfeed-translate--finalize)
               (lambda (_feeds) (cl-incf finalizes))))
      (let* ((call-fn
              (lambda (texts callback _prompt)
                (cl-incf calls)
                (funcall callback
                         (elfeed-translate--success-result
                          (list (cons (car texts) "译文"))))))
             (queue
              (mapcar
               (lambda (text)
                 (list :call-fn call-fn :texts (list text)
                       :prompt "prompt %s" :retries 0))
               '("one" "two" "three"))))
        (elfeed-translate--process-batches-parallel queue '("feed"))))
    (should (= calls 3))
    (should (= writes 3))
    (should (= finalizes 1))
    (should-not elfeed-translate--parallel-state)))

(ert-deftest elfeed-translate-engine-serial-network-failure-stops-queue ()
  (let ((elfeed-translate--serial-completed nil)
        (elfeed-translate--serial-total nil)
        (elfeed-translate--busy nil)
        (calls 0)
        (finalizes 0))
    (cl-letf (((symbol-function 'elfeed-translate--finalize)
               (lambda (_feeds) (cl-incf finalizes))))
      (let* ((call-fn
              (lambda (_texts callback _prompt)
                (cl-incf calls)
                (funcall callback
                         (elfeed-translate--failure-result
                          'send "proxy failed" nil))))
             (element
              (list :call-fn call-fn :texts '("one")
                    :prompt "prompt %s" :retries 0)))
        (elfeed-translate--process-batches
         (list element (copy-sequence element)) '("feed"))))
    (should (= calls 1))
    (should (= finalizes 1))
    (should-not elfeed-translate--busy)))

(ert-deftest elfeed-translate-engine-circuit-trips-after-K-failures ()
  "K consecutive transport failures trip the circuit and skip remaining batches."
  (let ((elfeed-translate--parallel-state nil)
        (elfeed-translate--busy nil)
        (elfeed-translate-max-concurrent 4)
        (elfeed-translate-max-consecutive-fatal 3)
        (calls 0)
        (finalized nil))
    (cl-letf (((symbol-function 'elfeed-translate--finalize)
               (lambda (feeds) (setq finalized feeds)))
              ((symbol-function 'run-at-time)
               (lambda (&rest _args) 'fake-timer))
              ((symbol-function 'cancel-timer) (lambda (_t) nil))
              ((symbol-function 'timerp) (lambda (_t) t)))
      (let* ((call-fn
              (lambda (_texts callback _prompt)
                (cl-incf calls)
                (funcall callback
                         (elfeed-translate--failure-result
                          'send "proxy failed" nil))))
             (queue
              (mapcar (lambda (text)
                        (list :call-fn call-fn :texts (list text)
                              :prompt "prompt %s" :retries 0))
                      '("a" "b" "c" "d"))))
        (elfeed-translate--process-batches-parallel queue '("feed"))))
    (should (= calls 3))
    (should (equal finalized '("feed")))
    (should-not elfeed-translate--busy)
    (should-not elfeed-translate--parallel-state)))

(ert-deftest elfeed-translate-engine-429-throttle-pauses-then-resumes ()
  "A 429 pauses dispatch; after the throttle timer fires, the batch re-sends."
  (let ((elfeed-translate--parallel-state nil)
        (elfeed-translate--busy nil)
        (elfeed-translate-max-concurrent 1)
        (elfeed-translate-max-throttle-wait 30)
        (elfeed-translate-max-consecutive-fatal 3)
        (calls 0)
        (cached nil)
        (finalized nil)
        (captured-timers nil))
    (cl-letf (((symbol-function 'elfeed-translate--cache-set-batch)
               (lambda (pairs) (setq cached (append cached pairs))))
              ((symbol-function 'elfeed-translate--finalize)
               (lambda (feeds) (setq finalized feeds)))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args)
                 (push (cons fn args) captured-timers)
                 'fake-timer))
              ((symbol-function 'cancel-timer) (lambda (_t) nil))
              ((symbol-function 'timerp) (lambda (_t) t)))
      (let* ((call-fn
              (lambda (_texts callback _prompt)
                (cl-incf calls)
                (if (= calls 1)
                    (funcall callback
                             (elfeed-translate--failure-result
                              'http "rate limited" nil
                              :http-status 429 :retry-after 10))
                  (funcall callback
                           (elfeed-translate--success-result
                            '(("one" . "一")) :http-status 200)))))
             (queue
              (list (list :call-fn call-fn :texts '("one")
                          :prompt "prompt %s" :retries 0))))
        (elfeed-translate--process-batches-parallel queue '("feed"))
        (should (= calls 1))
        (should-not finalized)
        (should (plist-get elfeed-translate--parallel-state :throttle-until))
        (dolist (ct captured-timers)
          (when (eq (car ct) #'elfeed-translate--parallel-resume-throttle)
            (apply (car ct) (cdr ct))))))
    (should (= calls 2))
    (should (equal cached '(("one" . "一"))))
    (should (equal finalized '("feed")))
    (should-not elfeed-translate--busy)
    (should-not elfeed-translate--parallel-state)))

(ert-deftest elfeed-translate-engine-throttle-wait-clamps-large-retry-after ()
  "A provider Retry-After above the configured maximum is clamped."
  (let ((elfeed-translate-max-throttle-wait 30)
        (elfeed-translate-retry-base-delay 1.0))
    (let ((result (elfeed-translate--failure-result
                   'http "rate limited" nil
                   :http-status 429 :retry-after 120)))
      (should (<= (elfeed-translate--throttle-wait result) 30.0)))
    (let ((result (elfeed-translate--failure-result
                   'http "rate limited" nil :http-status 429)))
      (should (>= (elfeed-translate--throttle-wait result) 2.0)))))

(provide 'elfeed-translate-engine-test)
;;; elfeed-translate-engine-test.el ends here
