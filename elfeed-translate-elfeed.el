;;; elfeed-translate-elfeed.el --- Elfeed adapter for elfeed-translate -*- lexical-binding: t; -*-

;; Author: pilrymage
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1") (elfeed "3.0"))
;; Keywords: news, rss, translation

;;; Commentary:

;; Elfeed database queries, feed/tag inspection, local feed paths and RSS
;; rendering for elfeed-translate.  Cache access is supplied by callers.

;;; Code:

(require 'elfeed)
(require 'elfeed-db)
(require 'xml)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'elfeed-translate-core)

;; Utility Functions
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--feed-hash (feed-url)
  "Return a short hex hash of FEED-URL.
Used for naming local RSS files and generating unique entry GUIDs."
  (secure-hash 'md5 feed-url))

(defun elfeed-translate--local-feed-url (feed-url)
  "Return the file:// URL for the translated RSS file of FEED-URL."
  (concat "file:///"
          (elfeed-translate--local-feed-path feed-url)))

(defun elfeed-translate--local-feed-path (feed-url)
  "Return the absolute file path for the translated RSS file of FEED-URL."
  (let ((hash (elfeed-translate--feed-hash feed-url))
        (dir  (expand-file-name elfeed-translate-output-dir)))
    (expand-file-name (concat hash ".xml") dir)))

(defun elfeed-translate--rfc2822-date (timestamp)
  "Convert TIMESTAMP (float seconds since epoch) to RFC 2822 format.
Always produces English weekday/month abbreviations regardless of the
system locale or `system-time-locale', because some locales (e.g.
Chinese) cause `format-time-string' to emit non-standard names like
\"周二\" / \"6月\" that Elfeed cannot parse."
  (let ((system-time-locale "C"))
    (if (and timestamp (> timestamp 0))
        (format-time-string "%a, %d %b %Y %H:%M:%S %z"
                            (seconds-to-time timestamp))
      (format-time-string "%a, %d %b %Y %H:%M:%S %z"))))

(defun elfeed-translate--entry-guid (feed-url entry)
  "Build a unique GUID for ENTRY in the translated RSS file of FEED-URL.
Prefixes with the feed hash to avoid ID collisions between different
translated feeds when originals happen to share guids."
  (let ((hash (elfeed-translate--feed-hash feed-url))
        (eid  (elfeed-entry-id entry)))
    (concat hash ":" (cdr eid))))

(defun elfeed-translate--feed-autotags (feed-url)
  "Return the autotag symbols for FEED-URL from `elfeed-feeds'.
Returns nil for feeds without autotags.  Works with both plain
URL entries and (URL . TAGS) cons entries."
  (elfeed-feed-autotags feed-url))

(defun elfeed-translate--feed-has-title-tag-p (feed-url)
  "Return non-nil if FEED-URL has `elfeed-translate-feed-tag' in its autotags."
  (memq elfeed-translate-feed-tag
        (elfeed-translate--feed-autotags feed-url)))

(defun elfeed-translate--feed-has-content-tag-p (feed-url)
  "Return non-nil if FEED-URL has `elfeed-translate-content-tag' in its autotags."
  (memq elfeed-translate-content-tag
        (elfeed-translate--feed-autotags feed-url)))

(defun elfeed-translate--entry-content (entry)
  "Return the content string of ENTRY, or nil if it has no content.
Handles both string content and `elfeed-ref' objects (the latter
are dereferenced via `elfeed-deref').  The content is truncated to
`elfeed-translate-content-max-chars' characters."
  (let ((content (elfeed-entry-content entry)))
    (when content
      (let ((text
             (cond
              ((stringp content) content)
              ((elfeed-ref-p content) (elfeed-deref content))
              (t nil))))
        (when (and text (not (string-empty-p text)))
          (if (> (length text) elfeed-translate-content-max-chars)
              (substring text 0 elfeed-translate-content-max-chars)
            text))))))

(defun elfeed-translate--translatable-feeds ()
  "Return a list of all feed URLs that should be translated.
A feed is translatable if it has `elfeed-translate-feed-tag'
or `elfeed-translate-content-tag' as an autotag in `elfeed-feeds'."
  (let ((feeds '()))
    (dolist (f elfeed-feeds)
      (let ((url (if (consp f) (car f) f)))
        (when (or (elfeed-translate--feed-has-title-tag-p url)
                  (elfeed-translate--feed-has-content-tag-p url))
          (push url feeds))))
    (nreverse feeds)))

(defun elfeed-translate--entries-for-feed (feed-url)
  "Return all Elfeed entries belonging to FEED-URL, newest first."
  (let ((entries '()))
    (maphash
     (lambda (_id entry)
       (when (equal (elfeed-entry-feed-id entry) feed-url)
         (push entry entries)))
     elfeed-db-entries)
    (sort entries
          (lambda (a b)
            (> (elfeed-entry-date a) (elfeed-entry-date b))))))

;; ═══════════════════════════════════════════════════════════════════════
;; RSS XML Generation
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--format-title (original translated)
  "Format a translated title according to `elfeed-translate-title-style'.
ORIGINAL is the original-language title, TRANSLATED is the
translated title.  The separator is taken from
`elfeed-translate-title-separator'."
  (cl-case elfeed-translate-title-style
    (replace translated)
    (target-first (concat translated elfeed-translate-title-separator original))
    (original-first (concat original elfeed-translate-title-separator translated))
    (otherwise translated)))

(defun elfeed-translate--generate-rss (feed-url translation-lookup)
  "Generate a local RSS 2.0 XML file for FEED-URL.
TRANSLATION-LOOKUP is called with source text and returns its cached
translation, or nil.
Includes entries that have at least one cached translation (title
or content), OR any entry from the feed if the feed has a
translate tag — original content is always included in
<description>, translated only when `translate_content' is tagged
and the translation is cached.  Returns the path to the generated file."
  (let* ((feed (elfeed-db-get-feed feed-url))
         (feed-title (if feed
                         (or (elfeed-feed-title feed) feed-url)
                       feed-url))
         (translated-feed-title (concat elfeed-translate-feed-title-prefix
                                        feed-title))
         (has-title-tag (elfeed-translate--feed-has-title-tag-p feed-url))
         (has-content-tag (elfeed-translate--feed-has-content-tag-p feed-url))
         (entries (elfeed-translate--entries-for-feed feed-url))
         ;; Include an entry if it has any translation cached, OR if the
         ;; feed has any translate tag (so original content is carried over
         ;; even for entries whose translation hasn't completed yet).
         (translated-entries
          (seq-filter
           (lambda (e)
             (let ((title (elfeed-entry-title e))
                   (content (elfeed-translate--entry-content e)))
               (or (and has-title-tag
                        title
                        (not (string-empty-p title))
                        (funcall translation-lookup title))
                   (and has-content-tag
                        content
                        (funcall translation-lookup content))
                   has-title-tag
                   has-content-tag)))
           entries))
         (file (elfeed-translate--local-feed-path feed-url)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
      (insert "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">\n")
      (insert "  <channel>\n")
      ;; Channel metadata
      (insert (format "    <title>%s</title>\n"
                      (xml-escape-string translated-feed-title)))
      (insert (format "    <link>%s</link>\n"
                      (xml-escape-string feed-url)))
      (insert (format "    <description>Auto-translated RSS feed for %s</description>\n"
                      (xml-escape-string feed-url)))
      (insert (format "    <atom:link href=\"%s\" rel=\"self\" type=\"application/rss+xml\"/>\n"
                      (xml-escape-string (elfeed-translate--local-feed-url feed-url))))
      ;; Entries
      (dolist (entry translated-entries)
        (let* ((original-title (elfeed-entry-title entry))
               (raw-content (elfeed-translate--entry-content entry))
               (translated-title
                (when (and has-title-tag original-title
                           (not (string-empty-p original-title)))
                  (funcall translation-lookup original-title)))
               (translated-content
                (when (and has-content-tag raw-content)
                  (funcall translation-lookup raw-content)))
               ;; Decide display title
               (display-title
                (cond
                 ((and translated-title original-title)
                  (elfeed-translate--format-title original-title translated-title))
                 (translated-title translated-title)
                 (original-title original-title)
                 (t "")))
               ;; Description: use translated if available, else original
               (description
                (cond
                 (translated-content translated-content)
                 (raw-content raw-content)
                 (t nil)))
               (link (elfeed-entry-link entry))
               (guid (elfeed-translate--entry-guid feed-url entry))
               (date (elfeed-entry-date entry)))
          (insert "    <item>\n")
          (insert (format "      <title>%s</title>\n"
                          (xml-escape-string display-title)))
          (insert (format "      <link>%s</link>\n"
                          (xml-escape-string (or link ""))))
          (insert (format "      <guid isPermaLink=\"false\">%s</guid>\n"
                          (xml-escape-string guid)))
          (insert (format "      <pubDate>%s</pubDate>\n"
                          (elfeed-translate--rfc2822-date date)))
          (when description
            (insert (format "      <description>%s</description>\n"
                            (xml-escape-string description))))
          (insert "    </item>\n")))
      (insert "  </channel>\n")
      (insert "</rss>\n")
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) file nil 'silent)))
    file))

;; ═══════════════════════════════════════════════════════════════════════

;; ═══════════════════════════════════════════════════════════════════════
;; Feed List Display
;; ═══════════════════════════════════════════════════════════════════════

(defun elfeed-translate--insert-org-format (feeds)
  "Insert translated feed URLs in elfeed-org compatible format.
FEEDS is a list of source feed URL strings.

Level-2 heading (\\*\\*) for the \"Translated feeds\" group so it can
sit under a user's existing level-1 feed group.  Each feed is a
level-3 heading (\\*\\*\\*) using an org link with the translated
feed title as the description."
  (insert "# Copy the headlines above into your elfeed-org file,\n")
  (insert "# then run M-x elfeed-org-reload (or restart Emacs).\n")
  (insert "** Translated feeds")
  (when elfeed-translate-tag
    (insert (format " :%s:" elfeed-translate-tag)))
  (insert "\n")
  (dolist (feed-url feeds)
    (let* ((local-url (elfeed-translate--local-feed-url feed-url))
           (feed (elfeed-db-get-feed feed-url))
           (display-title (concat elfeed-translate-feed-title-prefix
                                  (if feed
                                      (or (elfeed-feed-title feed) feed-url)
                                    feed-url))))
      (insert (format "*** [[%s][%s]]\n" local-url display-title))
      (insert (format "    :PROPERTIES:\n"))
      (insert (format "    :ORIGINAL-FEED: %s\n" feed-url))
      (insert (format "    :END:\n")))))

(defun elfeed-translate--insert-plain-format (feeds)
  "Insert translated feed URLs in `elfeed-feeds' compatible format.
FEEDS is a list of source feed URL strings."
  (insert ";; Translated feed URLs for `elfeed-feeds'.\n")
  (insert ";; Copy the lines below into your Elfeed configuration,\n")
  (insert ";; then run M-x elfeed-update.\n\n")
  (dolist (feed-url feeds)
    (let* ((local-url (elfeed-translate--local-feed-url feed-url))
           (feed (elfeed-db-get-feed feed-url))
           (title (if feed
                      (or (elfeed-feed-title feed) feed-url)
                    feed-url)))
      (insert (format ";; Original: %s\n" title))
      (insert (format "(\"%s\" %s)\n\n" local-url elfeed-translate-tag)))))

;;;###autoload

(provide 'elfeed-translate-elfeed)
;;; elfeed-translate-elfeed.el ends here
