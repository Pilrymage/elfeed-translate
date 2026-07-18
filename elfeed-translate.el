;;; elfeed-translate.el --- Translate Elfeed entry titles and content via LLM API -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.7.0
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
(require 'elfeed-translate-engine)

(declare-function org-fold-hide-drawers-all "org-fold")
(declare-function org-cycle-hide-drawers "org-cycle")


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
      (message
       "[elfeed-translate] %d feed URL(s) regenerated in %s — copy these URLs into your feed configuration"
       (length feeds) (abbreviate-file-name elfeed-translate-output-dir)))))



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
  (when-let ((stale (elfeed-translate--stale-local-feed-mappings)))
    (display-warning
     'elfeed-translate
     (format
      (concat "%d translated file subscription(s) point to an old output "
              "directory. Active output: %s. Run M-x "
              "elfeed-translate-show-feeds and replace the stale file URLs "
              "(for example %s).")
      (length stale)
      (abbreviate-file-name elfeed-translate-output-dir)
      (caar stale))
     :warning))
  ;; One-time initialisation
  (unless elfeed-translate--setup-done
    (make-directory elfeed-translate-output-dir t)
    (elfeed-translate--load-cache)
    (dolist (feed-url (elfeed-translate--translatable-feeds))
      (elfeed-translate--generate-rss
       feed-url #'elfeed-translate--cache-get))
    (setq elfeed-translate--setup-done t)
    (message "[elfeed-translate] Setup — %d feed(s), %d cached translation(s), output: %s"
             (length (elfeed-translate--translatable-feeds))
             (elfeed-translate--cache-count)
             (abbreviate-file-name elfeed-translate-output-dir))
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
  Cache file     : %s
  Feed output    : %s
  Tagged feeds   : %d
  Cached entries : %d
"
                  elfeed-translate-feed-tag
                  elfeed-translate-content-tag
                  elfeed-translate-target-lang
                  elfeed-translate-api-url
                  elfeed-translate-model
                  (abbreviate-file-name (elfeed-translate--cache-file))
                  (abbreviate-file-name elfeed-translate-output-dir)
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

(provide 'elfeed-translate)
;;; elfeed-translate.el ends here
