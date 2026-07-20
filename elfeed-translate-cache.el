;;; elfeed-translate-cache.el --- SQLite cache for elfeed-translate -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.8.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, rss, translation

;;; Commentary:

;; SQLite-backed persistence for source-text translations.  This module
;; owns cache-key generation and the database connection.

;;; Code:

(require 'sqlite)
(require 'cl-lib)
(require 'elfeed-translate-core)

;; Translation Cache (SQLite-backed)
;; ═══════════════════════════════════════════════════════════════════════

(defvar elfeed-translate--db nil
  "SQLite database connection for the translation cache.
Opened by `elfeed-translate--load-cache' and closed by
`elfeed-translate--close-cache'.  nil when not yet opened.")

(defun elfeed-translate--cache-file ()
  "Return the path to the SQLite cache database file."
  (expand-file-name elfeed-translate-cache-file))

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

(defun elfeed-translate--legacy-sqlite-cache-files ()
  "Return likely pre-0.7 SQLite cache paths in priority order.
The active output directory is preferred, followed by the Elfeed DB
output directory and the historical ~/.elfeed location."
  (delete-dups
   (mapcar
    #'expand-file-name
    (list
     (expand-file-name "translate-cache.sqlite"
                       elfeed-translate-output-dir)
     (expand-file-name "translated/translate-cache.sqlite"
                       elfeed-db-directory)
     (expand-file-name "~/.elfeed/translated/translate-cache.sqlite")))))

(defun elfeed-translate--sqlite-migration-key (source-file)
  "Return the metadata key recording migration of SOURCE-FILE."
  (concat "migrated_sqlite:"
          (secure-hash 'sha256 (expand-file-name source-file))))

(defun elfeed-translate--sqlite-cache-migrated-p (source-file)
  "Return non-nil when SOURCE-FILE was already merged into the open cache."
  (and
   (sqlite-select
    elfeed-translate--db
    "SELECT 1 FROM meta WHERE key = ? LIMIT 1"
    (list (elfeed-translate--sqlite-migration-key source-file)))
   t))

(defun elfeed-translate--migrate-sqlite-cache (source-file)
  "Merge translations from legacy SQLite SOURCE-FILE into the open cache.
Existing values in the target win, allowing callers to order source
files from most to least preferred.  The source database is retained
as a recovery copy.  Return the number of inserted rows."
  (let* ((source (expand-file-name source-file))
         (target (elfeed-translate--cache-file))
         (attached nil)
         (inserted 0))
    (when (and (file-regular-p source)
               (not (file-equal-p source target))
               (not (elfeed-translate--sqlite-cache-migrated-p source)))
      (condition-case err
          (unwind-protect
              (progn
                (sqlite-execute
                 elfeed-translate--db
                 "ATTACH DATABASE ? AS legacy_cache"
                 (list source))
                (setq attached t)
                (if (null
                     (sqlite-select
                      elfeed-translate--db
                      (concat
                       "SELECT 1 FROM legacy_cache.sqlite_master "
                       "WHERE type = 'table' AND name = 'translations'")))
                    (message
                     "[elfeed-translate] Legacy SQLite has no translations table: %s"
                     source)
                  (sqlite-execute
                   elfeed-translate--db
                   (concat
                    "INSERT OR IGNORE INTO main.translations (key, value) "
                    "SELECT key, value FROM legacy_cache.translations"))
                  (setq inserted
                        (or (caar
                             (sqlite-select elfeed-translate--db
                                            "SELECT changes()"))
                            0))
                  (sqlite-execute
                   elfeed-translate--db
                   "INSERT OR REPLACE INTO main.meta (key, value) VALUES (?, ?)"
                   (list (elfeed-translate--sqlite-migration-key source)
                         source))
                  (message
                   "[elfeed-translate] Merged %d translation(s) from %s"
                   inserted source)))
            (when attached
              (sqlite-execute elfeed-translate--db
                              "DETACH DATABASE legacy_cache")))
        (error
         (message "[elfeed-translate] SQLite cache merge failed for %s: %s"
                  source (error-message-string err)))))
    inserted))

(defun elfeed-translate--migrate-sqlite-caches (source-files)
  "Merge each legacy cache in SOURCE-FILES into the open fixed cache."
  (let ((total 0))
    (dolist (source source-files)
      (cl-incf total (elfeed-translate--migrate-sqlite-cache source)))
    total))

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
                         (unless (equal original translation)
                           (sqlite-execute
                            elfeed-translate--db
                            "INSERT OR IGNORE INTO translations (key, value) VALUES (?, ?)"
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

(defun elfeed-translate--load-cache (&optional legacy-files)
  "Open the SQLite cache database and initialise tables.
LEGACY-FILES can supply an ordered list of old SQLite databases for
tests or explicit migration.  nil discovers historical output paths;
the sentinel :none disables SQLite migration.  A legacy
`translate-cache.el' hash table is migrated separately."
  (when elfeed-translate--db
    (elfeed-translate--close-cache))
  (let ((db-file (elfeed-translate--cache-file)))
    (make-directory (file-name-directory db-file) t)
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
    ;; Merge SQLite databases from older output-dir-coupled versions.  The
    ;; first source wins on duplicate keys; all source files are retained.
    (elfeed-translate--migrate-sqlite-caches
     (cond
      ((eq legacy-files :none) nil)
      ((listp legacy-files)
       (if legacy-files
           legacy-files
         (elfeed-translate--legacy-sqlite-cache-files)))
      (t (elfeed-translate--legacy-sqlite-cache-files))))
    ;; Migrate legacy cache if present
    (elfeed-translate--migrate-old-cache)
    (message "[elfeed-translate] Cache opened — %d translation(s) in %s"
             (elfeed-translate--cache-count)
             (abbreviate-file-name db-file))))

(defun elfeed-translate--close-cache ()
  "Close the SQLite cache database connection."
  (when (and elfeed-translate--db (sqlite-available-p))
    (sqlite-close elfeed-translate--db)
    (setq elfeed-translate--db nil)))

;; ═══════════════════════════════════════════════════════════════════════

(provide 'elfeed-translate-cache)
;;; elfeed-translate-cache.el ends here
