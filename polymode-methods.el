
;; (defmethod pm/install-config ((object pm-config))
;;   "Clone OBJECT and bind it to `pm/local-config'.
;; Iterate over submodes slot and move those which return non-nil
;; `pm/applies-p' into active-submodes slot."
;;   (setq pm/local-config (clone object))
;;   (dolist (sm (oref pm/local-config submodes))
;;     (when (pm/applies-p sm)
;;       (object-add-to-list pm/local-config active-submodes sm t))))


;; (defgeneric pm/applies-p (object)
;;   "Check if an OBJECT applies to the current context (buffer and mode).")

;; (defmethod pm/applies-p ((submode pm-inner-submode))
;;   "Check if  SUBMODE appllies to the current buffer.
;; Default method match :extensions slots of SUBMODE with the
;; current file's extension."
;;   (let ((EXT (upcase (file-name-extension (buffer-file-name))))
;;         out) 
;;     ;; todo: should be regexp
;;     (member* EXT (oref submode :extensions)  :test 'equal :key 'upcase)))


;;;; INTERFACE
(defgeneric pm/initialize (config)
  "Initialize current buffer with CONFIG.

First initialize the :base-submode and :inner-submodes slots of
CONFIG object ...

Current buffer is setup as the base buffer.")
;; (defmethod pm/initialize ((config pm-config))
;;   (pm--setup-buffer (current-buffer)))

(defmethod pm/initialize ((config pm-config))
  (eval `(oset config :base-submode
               (clone ,(oref config :base-submode-name))))
  (oset (oref config :base-submode)
        :buffer (current-buffer))
  (let ((base-mode (pm--get-available-mode
                    (oref (oref config :base-submode) :mode))))
    ;; don't reinitialize if already there; can be used in minor modes
    (unless (eq major-mode base-mode)
      (let ((polymode-mode t)) ;;major-modes might check it 
        (funcall base-mode))
      ;; after emacs mode install
      (setq pm/config config)
      (setq pm/submode (oref config :base-submode))
      (oset pm/submode :mode base-mode)))
  (set (make-local-variable 'polymode-mode) t)
  ;; todo: initialize inner-submodes here?
  (pm--setup-buffer (current-buffer)))
  
                          
(defmethod pm/initialize ((config pm-config-one))
  (call-next-method)
  (eval `(oset config :inner-submodes
               (list (clone ,(oref config :inner-submode-name))))))


(defgeneric pm/get-buffer (submode &optional span-type)
  "Get the indirect buffer associated with SUBMODE and
SPAN-TYPE. Should return nil if buffer has not yet been
installed. Also see `pm/get-span'.")

(defmethod pm/get-buffer ((submode pm-submode) &optional type)
  (oref submode :buffer))

(defmethod pm/get-buffer ((submode pm-inner-submode) &optional type)
  (cond ((eq 'body type) (oref submode :buffer))
        ((eq 'head type) (oref submode :head-buffer))
        ((eq 'tail type) (oref submode :tail-buffer))
        (t (error "Don't know how to select buffer of type" type
                  "for submode" (object-name submode)
                  "of class" (class-of submode)))))

(defgeneric pm/select-buffer (submode span)
  "Ask SUBMODE to select (make current) its indirect buffer
corresponding to the type of the SPAN returned by
`pm/get-span'.")

(defmethod pm/select-buffer ((submode pm-submode) span)
  "Select the buffer associated with SUBMODE.
Install a new indirect buffer if it is not already installed.

For this method to work correctly, SUBMODE's class should define
`pm/install-buffer' and `pm/get-buffer' methods."
  (let* ((type (car span))
         (buff (pm/get-buffer submode type)))
    (unless (buffer-live-p buff)
      (pm/install-buffer submode type)
      (setq buff (pm/get-buffer submode type)))
    (pm--select-buffer buff)))

;; (pm--select-buffer (pm/get-buffer submode (car span))))

;; (defmethod pm/select-buffer ((submode pm-inner-submode) span)
;;   "Select the buffer associated with SUBMODE.
;; Install a new indirect buffer if it is not already installed.

;; For this method to work correctly, SUBMODE's class should define
;; `pm/install-buffer' and `pm/get-buffer' methods."
;;   (let* ((type (car span))
;;          (buff (pm/get-buffer submode type)))
;;     (unless (buffer-live-p buff)
;;       (pm/install-buffer submode type)
;;       (setq buff (pm/get-buffer submode type)))
;;     (pm--select-buffer buff)))

(defun pm-get-mode-symbol-from-name (str)
  "Default mode function guesser.
Return major mode function constructed from STR by appending
'-mode' if needed. If the constructed symbol is not a function
return an error."
  (let* ((mname (if (string-match-p "-mode$" str)
                    str
                  (concat str "-mode")))
         (fsymb (intern mname)))
    (if (fboundp fsymb)
        fsymb
      (error "Symbol %s is not a valid function" mname))))
  
(defmethod pm/select-buffer ((config pm-config-multi-auto) &optional span)
  
  (if (null (car span))
      (pm/select-buffer (oref config :base-submode) span)
    (let ((type (car span))
          (proto (symbol-value (oref config :auto-submode-name)))
          submode)
      (save-excursion
        (goto-char (cadr span))
        (unless (eq type 'head)
          (re-search-backward (oref proto :head-reg) nil 'noerr))
        (re-search-forward (oref proto :retriever-regexp))
        (let* ((str (or (match-string-no-properties (oref proto :retriever-num))
                        (error "retriever subexpression didn't match")))
               (name (concat "auto-submode:" str)))
          (setq submode
                (or (loop for obj in (oref config :auto-submodes)
                          when  (equal name (aref obj object-name))
                          return obj)
                    (let ((new-obj (clone proto
                                          name :mode (pm-get-mode-symbol-from-name str))))
                      (object-add-to-list config :auto-submodes new-obj)
                      new-obj)))))
      (pm/select-buffer submode span))))



(defgeneric pm/install-buffer (submode &optional type)
  "Ask SUBMODE to install an indirect buffer corresponding to
span TYPE.")

(defmethod pm/install-buffer ((submode pm-submode) &optional type)
  "Independently on the TYPE call `pm/create-indirect-buffer'
create and install a new buffer in slot :buffer of SUBMODE."
  (let* ((mode (oref submode :mode))
         (buf (or (pm--get-indirect-buffer-of-mode mode)
                  (pm--create-indirect-buffer mode))))
    (with-current-buffer buf
      (setq pm/submode submode)
      (pm--setup-buffer))
    (oset submode :buffer buf)))

(defmethod pm/install-buffer ((submode pm-inner-submode) type)
  "Depending of the TYPE install an indirect buffer into
slot :buffer of SUBMODE. Create this buffer if does not exist."
  (let* ((mode
          (cond ((eq 'body type) (oref submode :mode))
                ((eq 'head type) (oref submode :head-mode))
                ((eq 'tail type) (oref submode :tail-mode))
                (t (error "TYPE argument must be one of body, head, tail. "))))
         (buf (or (pm--get-indirect-buffer-of-mode mode)
                  (pm--create-indirect-buffer mode))))
    (with-current-buffer buf
      (setq pm/submode submode)
      (pm--setup-buffer))
    (pm--set-submode-buffer submode type buf)))


(defgeneric pm/get-span (submode &optional pos)
  "Ask a submode for the span at point.
Return a list of three elements (TYPE BEG END OBJECT) where TYPE
is a symbol representing the type of the span surrounding
POS (head, tail, body, inline etc). BEG and END are the
coordinates of the span. OBJECT is a sutable object which is
'responsable' for this span. That is, OBJECT could be dispached
upon with `pm/select-buffer' or other methods form the interface.

Should return nil if there is no SUBMODE specific span around POS.")

(defmethod pm/get-span (submode &optional pos)
  "Simply return nil. Base mode usually do/can not compute the span"
  nil)

(defmethod pm/get-span ((config pm-config) &optional pos)
    "Apply pm/get-span on every element of submodes slot of config object.
Return a cons (submode . span), for which START is closest to
POS (and before it); i.e. the innermost span.  POS defaults to
point."
    ;; fixme: base should be last, to take advantage of the submodes computation
    (let ((smodes (cons (oref config :base-submode) 
                        (oref config :inner-submodes)))
          (start (point-min))
          (end (point-max))
          (pos (or pos (point)))
          span val)
      (save-restriction
        (widen)
        (dolist (sm smodes)
          (setq val (pm/get-span sm pos))
          (if (and val (>= (nth 1 val) start))
              (setq span val
                    start (nth 1 val)
                    end (nth 2 val)))))
      (unless (and (<= start end) (<= pos end) (>= pos start))
        (error "Bad polymode selection: %s, %s"
               (list start end) pos))
      ;; fixme: why is this here?
      (if (= start end)
          (setq end (1+ end)))
      (when (and span
                 (null (car span))) ; submodes can compute the base span by returning nil
        (setcar (last span) (oref config :base-submode)))
      span))


(defmethod pm/get-span ((config pm-config-multi-auto) &optional pos)
  (let ((span-other (call-next-method)))
    (if (oref config :head-reg)
        (let ((span (pm--span-at-point (oref config :head-reg)
                                       (oref config :tail-reg)
                                       pos)))
          (if (and span-other
                   (> (cadr span-other) (cadr span)))
              span-other
            (append span (list config))))
      span-other)))


(defmethod pm/get-span ((submode pm-inner-submode) &optional pos)
  "Return a list of the form (TYPE POS-START POS-END SELF).
TYPE can be 'body, 'head or 'tail. SELF is just a submode object
in this case."
  (with-slots (head-reg tail-reg head-mode tail-mode) submode
    (let* ((span (pm--span-at-point head-reg tail-reg pos))
           (type (car span)))
      (when (or (and (eq type 'head) (eq head-mode 'base))
                (and (eq type 'tail) (or (eq tail-mode 'base)
                                         (and (null tail-mode)
                                              (eq head-mode 'base)))))
        (setcar span nil))
      (append span (list submode)))))

;;; UTILS
(defun pm--span-at-point (head-reg tail-reg &optional pos)
  "Basic span detector with head/tail.

Return (type span-start span-end) where type is one of the
follwoing symbols:

nil - pos is between (tail-reg or point-min) and (head-reg or point-max)
body - pos is between head-reg and (tail-reg or point-max)
head -  head span
tail -  tail span"
  ;; ! start of the span is part of the span !
  (save-excursion
    (save-restriction
      (widen)
      (setq pos (or pos (point)))
      (goto-char pos)
      (let* ((reg (concat "\\(?1:\\(" tail-reg "\\)\\)\\|\\(?2:\\(" head-reg "\\)\\)"))
             (pos1-end (if (re-search-backward reg nil t)
                           (match-end 0)))
             (pos1-tail? (or (null pos1-end) (match-end 1))) ;; consider point-min as a tail
             (pos1-end (goto-char (or pos1-end  (point-min))))
             (pos2-start (if (re-search-forward reg nil t)
                             (match-beginning 0)))
             (pos2-end (and pos2-start (match-end 0)))
             (pos2-tail? (and pos2-start (match-end 1)))
             (pos2-start (or pos2-start (point-max)))) ;consider pointmax as head
        (if (< pos pos2-start) ; inside doc or chunk body
            (if pos1-tail? 
                (list nil pos1-end pos2-start) ;doc
              (list 'body pos1-end pos2-start)) ; chunk body
          ;; else inside head or tail
          (if (< pos pos2-end) ; <- this one should be always true
              (if pos2-tail?
                  (list 'tail pos2-start pos2-end)
                (list 'head pos2-start pos2-end)))
          )))))

;; (let ((ess-blink-delay 1)
;;       (span (pm/-span-at-point-with-headtail  "^<<\\(.*\\)>>=" "^\\(@ +%def .*\\)$\\|\\(@[ \n]\\)")))
;;   (ess-blink-region (cadr span) (nth 2 span)))

;; (pm/-span-at-point-with-headtail  "^<<\\(.*\\)>>=" "^\\(@ +%def .*\\)$\\|\\(@[ \n]\\)")
;; (pm/-span-at-point "^<<\\(.*\\)>>=" "^\\(@ +%def .*\\)$\\|\\(@[ \n]\\)")

;; (defun pm/-span-at-point (head-reg tail-reg &optional pos)
;;   "Basic span detector.

;; Return (type span-start span-end) where type is one of the

;; nil - pos is between tail-reg-end and (head-reg-start or point-max)
;; t  - pos is between head-reg-start and (tail-reg-end or point-max)
;; "
;;   (save-excursion
;;     (save-restriction
;;       (widen)
;;       (setq pos (or pos (point)))
;;       (goto-char pos)
;;       (let ((reg (concat "\\(?1:\\(" tail-reg "\\)\\)\\|\\(?2:\\(" head-reg "\\)\\)"))
;;             (out '(nil nil nil nil nil))
;;             (mdata (and (re-search-backward reg nil t)
;;                         (match-data t))))
;;         (if (and mdata (nth 4 mdata))
;;             ;; found head
;;             (progn
;;               (setcar (cdr out) (nth 4 mdata)) ;; head start
;;               (setcar (cddr out) (nth 5 mdata)) ;; head end
;;               (goto-char (nth 5 mdata)))
;;           ;; found tail or nothing
;;           (goto-char (or (nth 3 mdata)  ; end of previous tail 
;;                          (point-min)))
;;           (if (and (re-search-forward head-reg) ;; pos might be in the head
;;                    (> pos (match-beginning 0))) 
;;               (progn
;;                 (setcar (cdr out) (match-beginning 0))
;;                 (setcar (cddr out)
;;                         (goto-char (mach-end 0))))
;;             (setq out nil)))
;;         (when out
;;           ;; head coordinates have been recorded and positioned at the head-end
;;           (if (re-search-forward tail-reg)
;;               (if (< pos (match-end 0))
;;                   (progn 
;;                     (setcar (last out 2) (match-beginning 0))
;;                     (setcar (last out) (match-end 0)))
;;                 ;; position of end is before pos. (should not happen if regs are exclusive)
;;                 (setq out nil))
;;             ;; point-max
;;             (setcar (last out 2) (point-max))
;;             (setcar (last out) (point-max))))
;;         out))))





;; ;;         (head-start (match-beginning 2))



;; ;;      ;; this is all match data, simplify?
;; ;;      (pos1-head-start (and pos1-end (match-end 2)))
;; ;;      (pos1-tail-start (and pos1-end (match-end 1)))
;; ;;      (pos1-end (goto-char (or pos1-end (point-min))))
;; ;;      (pos1-start (or pos1-tail-start pos1-head-start))

;; ;;      (pos2-end (if (re-search-forward reg nil t)
;; ;;                    (match-end 0)))
;; ;;      (pos2-head-start (and pos2-end (match-start 2)))
;; ;;      (pos2-tail-start (and pos2-end (match-start 1)))
;; ;;      (pos2-start (or pos2-tail-start pos2-head-start))
;; ;;      (pos2-end (or pos2-end (point-max)))
;; ;;      )
;; ;; (if (< pos pos2-end) ; inside doc or chunk
;; ;;     (cond
;; ;;      (pos2-tail-start
;; ;;       (if pos1-head-start
;; ;;           (list t pos1-head-start pos2-end)
;; ;;         (list t pos1-end pos2-end))) ;; incomplete chunk, take everything from previous pos
;; ;;      (pos2-head-start
;; ;;       (list nil pos1-end pos2-head-start)) ;; doc
;; ;;      (pos1-head-start
;; ;;       (list t pos1-head-start pos2-end)) ;; incomplete chunk, take everything to the end
;; ;;      (pos1-tail-start
;; ;;       (list nil pos1-end))
;; ;;      (pos2-tail-start )
;; ;;           (if pos1-start
;; ;;               (if pos2-tail-start
;; ;;       (list t new-pos (or pos2-start (point-max)))) ; chunk body
;; ;;   (if (< pos pos2-end) ;; just in case
;; ;;       (if pos2-tail?
;; ;;           (list 2 pos2-start pos2-end)
;; ;;         (list 1 pos2-start pos2-end)))
;; ;;   )))))

(provide 'polymode-methods)
