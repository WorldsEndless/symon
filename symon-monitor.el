(require 'symon-sparkline)

 ;; I/O helpers

(defun symon-monitor--make-history-ring (size)
  "like `(make-ring size)' but filled with `nil'."
  (cons 0 (cons size (make-vector size nil))))

(defun symon-monitor--linux-read-lines (file reader indices)
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char 1)
    (mapcar (lambda (index)
              (save-excursion
                (when (search-forward-regexp (concat "^" index "\\(.*\\)$") nil t)
                  (if reader
                      (funcall reader (match-string 1))
                    (match-string 1)))))
            indices)))

(defun symon-monitor--slurp (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-substring (point-min) (line-end-position))))

 ;; Process management

(defvar symon--process-buffer-name " *symon-process*")
(defvar symon--process-reference-count 0)

(defun symon--read-value-from-process-buffer (index)
  "Read a value from a specific buffer"
  (when (get-buffer symon--process-buffer-name)
    (with-current-buffer symon--process-buffer-name
      (when (save-excursion
              (search-backward-regexp (concat index ":\\([0-9]+\\)\\>") nil t))
        (read (match-string 1))))))

(defun symon--maybe-start-process (cmd)
  (setq symon--process-reference-count
        (1+ symon--process-reference-count))
  (unless (get-buffer symon--process-buffer-name)
    (let ((proc (start-process-shell-command
                 "symon-process" symon--process-buffer-name cmd))
          (filter (lambda (proc str)
                    (when (get-buffer symon--process-buffer-name)
                      (with-current-buffer symon--process-buffer-name
                        (when (and (string-match "-" str) (search-backward "----" nil t))
                          (delete-region 1 (point)))
                        (goto-char (1+ (buffer-size)))
                        (insert str))))))
      (set-process-query-on-exit-flag proc nil)
      (set-process-filter proc filter))))

(defun symon--maybe-kill-process ()
  (setq symon--process-reference-count
        (1- symon--process-reference-count))
  (when (and (zerop symon--process-reference-count)
             (get-buffer symon--process-buffer-name))
    (kill-buffer symon--process-buffer-name)))

 ;; Class definitions

(defclass symon-monitor ()
  ((interval :type integer
             :initform 4
             :initarg :interval
             :documentation "Fetch interval in seconds.")
   (display-opts :type list
                 :initform nil
                 :initarg :display-opts
                 :documentation "User-specified display options for this monitor.")
   (default-display-opts :type list
     :initform nil
     :type list
     :documentation "Default display options for this monitor.")

   ;; Internal slots

   (timer
    :documentation "Fires `symon-monitor-fetch' for this monitor.")
   (value
    :accessor symon-monitor-value
    :documentation "Most recent value"))

  :abstract t
  :documentation "Base (default) Symon monitor class.")

(cl-defmethod symon-monitor-update ((this symon-monitor))
  "Update THIS, storing the latest value."
  (oset this value (symon-monitor-fetch this)))

(defun symon-monitor--plist-merge (defaults user)
  (let ((opts (copy-list defaults))
        (user (copy-list user)))
    (while user
      (setq opts (plist-put opts (pop user) (pop user))))
    opts))

(cl-defmethod symon-monitor-setup ((this symon-monitor))
  "Setup this monitor.

This method is called when activating `symon-mode'."

  ;; Merge display opts
  (with-slots (display-opts default-display-opts) this
    (setq display-opts (symon-monitor--plist-merge
                        default-display-opts
                        display-opts)))

  (oset this timer
        (run-with-timer 0 (oref this interval)
                        (apply-partially #'symon-monitor-update this))))

(cl-defmethod symon-monitor-cleanup ((this symon-monitor))
  "Cleanup the monitor.

   This method is called when deactivating `symon-mode'."
  (when (slot-boundp this 'timer)
    (cancel-timer (oref this timer))
    (oset this timer nil)))

(cl-defmethod symon-monitor-fetch ((this symon-monitor))
  "Fetch the current monitor value.")

(cl-defmethod symon-monitor-display ((this symon-monitor))
  "Default display method for Symon monitors."
  (let* ((val (car (ring-elements (oref this history))))
         (plist (oref this display-opts))
         (index (plist-get plist :index))
         (unit (plist-get plist :unit)))
    (concat index
            (if (not (numberp val)) "N/A"
              (format "%d%s" val unit)))))

(defclass symon-monitor-history (symon-monitor)
  ((history-size :type integer :custom integer
                 :initform 50
                 :initarg :history-size)
   (history
    :accessor symon-monitor-history
    :documentation "Ring of historical monitor values"))

  :abstract t
  :documentation "Monitor class which stores a history of values.")

(cl-defmethod symon-monitor-setup ((this symon-monitor-history))
  (oset this history (symon-monitor--make-history-ring
                      (oref this history-size)))
  (cl-call-next-method))

(cl-defmethod symon-monitor-history ((this symon-monitor-history))
  (oref this history))

(cl-defmethod symon-monitor-value ((this symon-monitor-history))
  (oref this value))

(cl-defmethod symon-monitor-update :before ((this symon-monitor-history))
  (ring-insert (oref this history) (symon-monitor-fetch this)))

(cl-defmethod symon-monitor-display ((this symon-monitor-history))
  "Default display method for Symon monitors."
  (let* ((lst (ring-elements (oref this history)))
         (plist (oref this display-opts))
         (sparkline (plist-get plist :sparkline))
         (upper-bound (plist-get plist :upper-bound))
         (lower-bound (plist-get plist :lower-bound)))

    (concat (cl-call-next-method)
            (when (and sparkline (window-system))
              (let ((sparkline (symon--make-sparkline
                                lst lower-bound upper-bound)))
                (when symon-sparkline-use-xpm
                  (setq sparkline
                        (symon--convert-sparkline-to-xpm sparkline)))
                (propertize " " 'display sparkline))))))

(provide 'symon-monitor)
