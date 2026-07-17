;;; elfeed-translate-elfeed-test.el --- Elfeed adapter tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate-elfeed)

(ert-deftest elfeed-translate-elfeed-title-formatting ()
  (let ((elfeed-translate-title-separator " :: "))
    (let ((elfeed-translate-title-style 'replace))
      (should (equal (elfeed-translate--format-title "Original" "译文") "译文")))
    (let ((elfeed-translate-title-style 'target-first))
      (should (equal (elfeed-translate--format-title "Original" "译文")
                     "译文 :: Original")))
    (let ((elfeed-translate-title-style 'original-first))
      (should (equal (elfeed-translate--format-title "Original" "译文")
                     "Original :: 译文")))))

(ert-deftest elfeed-translate-elfeed-rss-uses-injected-cache-lookup ()
  (let* ((test-dir (make-temp-file "elfeed-translate-rss-" t))
         (elfeed-translate-output-dir test-dir)
         (feed (elfeed-feed--create
                :id "feed"
                :url "https://example.test/feed"
                :title "Example Feed"))
         (entry (elfeed-entry--create
                 :id '("feed" . "entry-1")
                 :title "Original title"
                 :link "https://example.test/item"
                 :date 0
                 :content "Original body"
                 :content-type 'html
                 :feed-id "feed"))
         (translations '(("Original title" . "翻译标题")
                         ("Original body" . "翻译正文"))))
    (unwind-protect
        (cl-letf (((symbol-function 'elfeed-db-get-feed)
                   (lambda (_url) feed))
                  ((symbol-function 'elfeed-translate--feed-has-title-tag-p)
                   (lambda (_url) t))
                  ((symbol-function 'elfeed-translate--feed-has-content-tag-p)
                   (lambda (_url) t))
                  ((symbol-function 'elfeed-translate--entries-for-feed)
                   (lambda (_url) (list entry))))
          (let* ((path
                  (elfeed-translate--generate-rss
                   "https://example.test/feed"
                   (lambda (source) (cdr (assoc source translations)))))
                 (xml (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string))))
            (should (string-match-p "翻译标题" xml))
            (should (string-match-p "翻译正文" xml))
            (should (string-match-p "entry-1" xml))))
      (delete-directory test-dir t))))

(provide 'elfeed-translate-elfeed-test)
;;; elfeed-translate-elfeed-test.el ends here
