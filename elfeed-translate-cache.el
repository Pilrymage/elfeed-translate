;;; elfeed-translate-cache.el --- SQLite cache for elfeed-translate -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.6.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, rss, translation

;;; Commentary:

;; SQLite-backed persistence for source-text translations.  This module
;; owns cache-key generation and the database connection.

;;; Code:

(require 'sqlite)
(require 'elfeed-translate-core)

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
PAIRS is a list of (source-text . translation) cons cells.  Cache
keys are derived here so callers do not depend on the persistence
format.  Uses BEGIN/COMMIT for atomicity and efficiency."
  (when (and elfeed-translate--db pairs (sqlite-available-p))
    (sqlite-execute elfeed-translate--db "BEGIN")
    (condition-case err
        (progn
          (dolist (pair pairs)
            (let* ((source (car pair))
                  (key (elfeed-translate--cache-key source))
                  (translation (cdr pair)))
              (unless (equal source translation)
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

(provide 'elfeed-translate-cache)
;;; elfeed-translate-cache.el ends here
