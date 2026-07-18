;;; run-tests.el --- Batch test runner for elfeed-translate -*- lexical-binding: t; -*-

;;; Code:

(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path test-dir))

(require 'elfeed-translate-core-test)
(require 'elfeed-translate-cache-test)
(require 'elfeed-translate-api-test)
(require 'elfeed-translate-elfeed-test)
(require 'elfeed-translate-engine-test)
(require 'elfeed-translate-main-test)

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
