;;; elfeed-translate-api-test.el --- API tests -*- lexical-binding: t; -*-

;;; Code:

(require 'elfeed-translate-test-helper)
(require 'elfeed-translate-api)

(ert-deftest elfeed-translate-api-build-request-is-unibyte-json ()
  (let* ((elfeed-translate-api-key
          (decode-coding-string "test-key" 'utf-8))
         (elfeed-translate-model "test-model")
         (request (elfeed-translate--build-request
                   '("English title" "中文标题")
                   elfeed-translate-system-prompt))
         (data (plist-get request :data))
         (headers (plist-get request :headers))
         (parsed (json-parse-string data :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object :json-false)))
    (should-not (multibyte-string-p data))
    (should (= (length data) (string-bytes data)))
    (should (equal (cdr (assoc 'model parsed)) "test-model"))
    (should (seq-every-p
             (lambda (header)
               (and (not (multibyte-string-p (car header)))
                    (not (multibyte-string-p (cdr header)))))
             headers))))

(ert-deftest elfeed-translate-api-id-json-pairs-by-id-not-position ()
  (let* ((sources '("first" "second"))
         (content
          "[{\"id\":\"item-0002\",\"translation\":\"第二\"},{\"id\":\"item-0001\",\"translation\":\"第一\"}]")
         (result (elfeed-translate--parse-id-json-content
                  content sources 200 "stop")))
    (should (elfeed-translate--result-ok-p result))
    (should (equal (plist-get result :pairs)
                   '(("first" . "第一") ("second" . "第二"))))
    (should (eq (plist-get result :protocol) 'id-json))))

(ert-deftest elfeed-translate-api-rejects-duplicate-id ()
  (let ((result
         (elfeed-translate--parse-id-json-content
          "[{\"id\":\"item-0001\",\"translation\":\"一\"},{\"id\":\"item-0001\",\"translation\":\"二\"}]"
          '("first" "second") 200 "stop")))
    (should-not (elfeed-translate--result-ok-p result))
    (should (eq (plist-get result :kind) 'translation-json))
    (should (plist-get result :retryable))))

(ert-deftest elfeed-translate-api-finish-reason-classification ()
  (should-not (elfeed-translate--finish-reason-failure "stop" 200))
  (let ((truncated
         (elfeed-translate--finish-reason-failure "length" 200))
        (filtered
         (elfeed-translate--finish-reason-failure "content_filter" 200)))
    (should (eq (plist-get truncated :kind) 'completion-truncated))
    (should (plist-get truncated :retryable))
    (should (eq (plist-get filtered :kind) 'completion-filtered))
    (should-not (plist-get filtered :retryable))))

(ert-deftest elfeed-translate-api-parses-complete-http-buffer ()
  (let* ((sources '("first" "second"))
         (content
          "[{\"id\":\"item-0001\",\"translation\":\"第一\"},{\"id\":\"item-0002\",\"translation\":\"第二\"}]")
         (body (json-serialize
                `((choices . [((message . ((content . ,content)))
                               (finish_reason . "stop"))])))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (encode-coding-string
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
               'utf-8))
      (insert body)
      (let ((result (elfeed-translate--parse-response sources (current-buffer))))
        (should (elfeed-translate--result-ok-p result))
        (should (equal (plist-get result :pairs)
                       '(("first" . "第一") ("second" . "第二"))))))))

(provide 'elfeed-translate-api-test)
;;; elfeed-translate-api-test.el ends here
