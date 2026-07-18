;;; elfeed-translate-cache-test.el --- Cache tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate-cache)

(defun elfeed-translate-test--create-legacy-sqlite (file pairs)
  "Create legacy SQLite FILE containing raw cache-key/value PAIRS."
  (make-directory (file-name-directory file) t)
  (let ((db (sqlite-open file)))
    (unwind-protect
        (progn
          (sqlite-execute
           db
           "CREATE TABLE translations (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
          (dolist (pair pairs)
            (sqlite-execute
             db "INSERT INTO translations (key, value) VALUES (?, ?)"
             (list (elfeed-translate--cache-key (car pair)) (cdr pair)))))
      (sqlite-close db))))

(ert-deftest elfeed-translate-cache-owns-source-key-generation ()
  (skip-unless (sqlite-available-p))
  (elfeed-translate-test--with-temp-cache
    (elfeed-translate--cache-set-batch
     '(("first source" . "第一条")
       ("second source" . "第二条")
       ("already Chinese" . "already Chinese")))
    (should (equal (elfeed-translate--cache-get "first source") "第一条"))
    (should (equal (elfeed-translate--cache-get "second source") "第二条"))
    (should-not (elfeed-translate--cache-get "already Chinese"))
    (should (= (elfeed-translate--cache-count) 2))
    (should (equal (elfeed-translate--cache-key "first source")
                   (secure-hash 'md5 "first source")))))

(ert-deftest elfeed-translate-cache-clear-removes-all-values ()
  (skip-unless (sqlite-available-p))
  (elfeed-translate-test--with-temp-cache
    (elfeed-translate--cache-set-batch '(("source" . "译文")))
    (elfeed-translate--cache-clear)
    (should (= (elfeed-translate--cache-count) 0))))

(ert-deftest elfeed-translate-cache-survives-output-directory-change ()
  (skip-unless (sqlite-available-p))
  (elfeed-translate-test--with-temp-cache
    (elfeed-translate--cache-set-batch '(("source" . "译文")))
    (let ((first-cache (elfeed-translate--cache-file)))
      (setq elfeed-translate-output-dir
            (expand-file-name "feeds-b" test-dir))
      (elfeed-translate--close-cache)
      (elfeed-translate--load-cache :none)
      (should (equal first-cache (elfeed-translate--cache-file)))
      (should (equal (elfeed-translate--cache-get "source") "译文")))))

(ert-deftest elfeed-translate-cache-merges-diverged-sqlite-databases ()
  (skip-unless (sqlite-available-p))
  (let* ((test-dir (make-temp-file "elfeed-translate-merge-" t))
         (legacy-new (expand-file-name "new/translate-cache.sqlite" test-dir))
         (legacy-old (expand-file-name "old/translate-cache.sqlite" test-dir))
         (elfeed-translate-output-dir (expand-file-name "feeds" test-dir))
         (elfeed-translate-cache-file
          (expand-file-name "fixed/translate-cache.sqlite" test-dir))
         (elfeed-translate--db nil))
    (unwind-protect
        (progn
          (elfeed-translate-test--create-legacy-sqlite
           legacy-new '(("recent-only" . "新译文")
                        ("shared" . "较新译文")))
          (elfeed-translate-test--create-legacy-sqlite
           legacy-old '(("old-only" . "旧库译文")
                        ("shared" . "较旧译文")))
          (elfeed-translate--load-cache (list legacy-new legacy-old))
          (should (= (elfeed-translate--cache-count) 3))
          (should (equal (elfeed-translate--cache-get "recent-only") "新译文"))
          (should (equal (elfeed-translate--cache-get "old-only") "旧库译文"))
          (should (equal (elfeed-translate--cache-get "shared") "较新译文"))
          (should (file-exists-p legacy-new))
          (should (file-exists-p legacy-old))
          (should
           (= (caar
               (sqlite-select
                elfeed-translate--db
                "SELECT COUNT(*) FROM meta WHERE key LIKE 'migrated_sqlite:%'"))
              2))
          ;; Recorded sources must not be imported again on later loads.
          (elfeed-translate--close-cache)
          (elfeed-translate--load-cache (list legacy-new legacy-old))
          (should (= (elfeed-translate--cache-count) 3)))
      (elfeed-translate--close-cache)
      (delete-directory test-dir t))))

(provide 'elfeed-translate-cache-test)
;;; elfeed-translate-cache-test.el ends here
