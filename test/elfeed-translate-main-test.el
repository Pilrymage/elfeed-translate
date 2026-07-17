;;; elfeed-translate-main-test.el --- Facade and dispatcher tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate)
(require 'loaddefs-gen)

(ert-deftest elfeed-translate-main-loads-all-five-source-features ()
  (dolist (feature '(elfeed-translate-core
                     elfeed-translate-cache
                     elfeed-translate-api
                     elfeed-translate-elfeed
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
              "(provide 'elfeed-translate-elfeed)" autoloads))))
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
           "elfeed-translate.el"
           (symbol-file 'elfeed-translate--process-batches 'defun))))

(ert-deftest elfeed-translate-main-splits-batches-without-loss ()
  (should (equal (elfeed-translate--split-into-batches '(1 2 3 4 5) 2)
                 '((1 2) (3 4) (5)))))

(ert-deftest elfeed-translate-main-collects-through-module-boundaries ()
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

(provide 'elfeed-translate-main-test)
;;; elfeed-translate-main-test.el ends here
