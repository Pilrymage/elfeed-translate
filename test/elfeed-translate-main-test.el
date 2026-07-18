;;; elfeed-translate-main-test.el --- Public facade tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate)
(require 'loaddefs-gen)

(ert-deftest elfeed-translate-main-loads-all-six-source-features ()
  (dolist (feature '(elfeed-translate-core
                     elfeed-translate-cache
                     elfeed-translate-api
                     elfeed-translate-elfeed
                     elfeed-translate-engine
                     elfeed-translate))
    (should (featurep feature))))

(ert-deftest elfeed-translate-main-autoloads-do-not-provide-package-features ()
  "Autoload generation must not make internal `require' calls no-ops."
  (let* ((root-dir
          (file-name-directory
           (symbol-file 'elfeed-translate--process-batches 'defun)))
         (temp-dir (make-temp-file "elfeed-translate-autoloads-" t))
         (output (expand-file-name "generated-autoloads.el" temp-dir)))
    (unwind-protect
        (progn
          (loaddefs-generate root-dir output nil nil nil t)
          (let ((autoloads
                 (with-temp-buffer
                   (insert-file-contents output)
                   (buffer-string))))
            (should-not
             (string-match-p "(provide 'elfeed-translate)" autoloads))
            (should-not
             (string-match-p
              "(provide 'elfeed-translate-elfeed)" autoloads))
            (should-not
             (string-match-p
              "(provide 'elfeed-translate-engine)" autoloads))))
      (delete-directory temp-dir t))))

(ert-deftest elfeed-translate-main-functions-live-in-expected-modules ()
  (should (string-suffix-p
           "elfeed-translate-api.el"
           (symbol-file 'elfeed-translate--call-api 'defun)))
  (should (string-suffix-p
           "elfeed-translate-cache.el"
           (symbol-file 'elfeed-translate--cache-get 'defun)))
  (should (string-suffix-p
           "elfeed-translate-elfeed.el"
           (symbol-file 'elfeed-translate--generate-rss 'defun)))
  (should (string-suffix-p
           "elfeed-translate-engine.el"
           (symbol-file 'elfeed-translate--process-batches 'defun))))

(provide 'elfeed-translate-main-test)
;;; elfeed-translate-main-test.el ends here
