;;; elfeed-translate-core-test.el --- Core tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate-core)

(ert-deftest elfeed-translate-core-success-result-keeps-metadata ()
  (let ((result (elfeed-translate--success-result
                 '(("source" . "译文"))
                 :http-status 200 :finish-reason "stop")))
    (should (elfeed-translate--result-ok-p result))
    (should (equal (plist-get result :pairs) '(("source" . "译文"))))
    (should (= (plist-get result :http-status) 200))
    (should (equal (plist-get result :finish-reason) "stop"))))

(ert-deftest elfeed-translate-core-failure-summary-is-structured ()
  (let ((result (elfeed-translate--failure-result
                 'http "rate limited" nil :http-status 429)))
    (should-not (elfeed-translate--result-ok-p result))
    (should (equal (elfeed-translate--failure-summary result)
                   "http: HTTP 429: rate limited"))))

(provide 'elfeed-translate-core-test)
;;; elfeed-translate-core-test.el ends here
