;;; elfeed-translate-main-test.el --- Facade and dispatcher tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate)

(ert-deftest elfeed-translate-main-loads-all-five-source-features ()
  (dolist (feature '(elfeed-translate-core
                     elfeed-translate-cache
                     elfeed-translate-api
                     elfeed-translate-elfeed
                     elfeed-translate))
    (should (featurep feature))))

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
