;;; elfeed-translate-cache-test.el --- Cache tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate-cache)

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

(provide 'elfeed-translate-cache-test)
;;; elfeed-translate-cache-test.el ends here
