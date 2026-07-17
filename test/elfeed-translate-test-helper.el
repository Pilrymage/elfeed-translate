;;; elfeed-translate-test-helper.el --- Test support for elfeed-translate -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((test-dir (file-name-directory (or load-file-name buffer-file-name)))
       (root-dir (expand-file-name ".." test-dir))
       (straight-elfeed
        (expand-file-name "straight/build/elfeed" user-emacs-directory)))
  (add-to-list 'load-path root-dir)
  (when (file-directory-p straight-elfeed)
    (add-to-list 'load-path straight-elfeed)))

(defmacro elfeed-translate-test--with-temp-cache (&rest body)
  "Run BODY with an isolated SQLite translation cache."
  (declare (indent 0) (debug t))
  `(let ((test-dir (make-temp-file "elfeed-translate-cache-" t))
         (elfeed-translate--db nil))
     (unwind-protect
         (let ((elfeed-translate-output-dir test-dir))
           (elfeed-translate--load-cache)
           ,@body)
       (elfeed-translate--close-cache)
       (delete-directory test-dir t))))

(provide 'elfeed-translate-test-helper)
;;; elfeed-translate-test-helper.el ends here
