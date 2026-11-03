;;; conductor/profile.scm — the memory: progress that survives restarts.
;;;
;;; The seam grew two primitives for this file: `(read-profile)` and
;;; `(write-profile! doc)`. Python owns the file — JSON at the platform
;;; config dir, written atomically — and this module owns the meaning:
;;; what the document holds, when it is written, and what a bad one
;;; costs (a fresh start, never a crash). Like the view and the other
;;; conductor files, this is edge code: it speaks to the host, so it
;;; lives at top level, outside the library fence. The pure contexts
;;; stay pure — nothing under domain/ or content/ may call either
;;; primitive, and the fence test greps for the names.
;;;
;;; The document crosses as an alist with string keys — the same move
;;; as `boot-config`, but the keys are STRINGS, not symbols: a
;;; profile's keys are data (persona ids, level keys, mode labels),
;;; not a fixed CLI vocabulary, and JSON objects are string-keyed by
;;; nature. The conductor's own shapes convert at this boundary:
;;; `*bests*` and `*done*` hold proper two-element lists (the campaign
;;; library's `assoc` contract), the document holds key-first entries.
;;; One representation note: the interpreter folds `(key . alist)`
;;; into the proper list `(key <alist…>)`, so a scalar entry is a true
;;; dotted pair and a list-valued entry reads key-first — and
;;; `(cdr entry)` is the value under both readings, which is all
;;; `profile-ref` ever asks.
;;;
;;; Document v1:
;;;
;;;   (("version" . 1)
;;;    ("locale"  . "en")                     ; the session's language
;;;    ("name"    . "Player")                 ; the player's name (stage 5)
;;;    ("done"    . (("ascent:1" . #t) ...))  ; campaign rungs won
;;;    ("bests"   . (("sprint" . 123) ...))   ; free play's scoreboard
;;;    ("ladder"  . 0)                        ; next persona to face (stage 5)
;;;    ("records" . (("wall" . (("wins" . 1) ("losses" . 0)
;;;                             ("margin" . 42))) ...))
;;;    ("leashes" . (("wall" . (("pace" . 1.2) ...)) ...)))
;;;
;;; The ladder, the records and the leashes are schema now — the versus
;;; screens and the tuned leashes populate them at stages 5 and 6. The
;;; document is versioned from day one, so the guard below has a hook
;;; the day the format moves.
;;;
;;; Save points: a settled match, a locale change, quitting. Never per
;;; frame — the disk is the one actuator this file owns, and it is
;;; bounded the way every actuator is: by call sites, not by discipline.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)
                (filter srfi-1:filter))
        (tetris locale))

;; The document, or #f before the first load. Every save refuses while
;; it is #f, so a broken boot cannot write a blank over a good file.
(define *profile* #f)

;; A document from a NEWER build is booted around, never overwritten:
;; this flag keeps every save a refusal until the build that owns the
;; format arrives. Losing a session's progress is honest; silently
;; clobbering a file this build cannot read is not.
(define *profile-readonly* #f)

(define (fresh-profile)
  ;; First boot: v1, everything empty. The empty structures exist so a
  ;; reader never has to default twice.
  (list (cons "version" 1)
        (cons "done" '())
        (cons "bests" '())
        (cons "ladder" 0)
        (cons "records" '())
        (cons "leashes" '())))

;; --------------------------------------------------------------------- ;;
;;  The document, as values                                               ;;
;; --------------------------------------------------------------------- ;;

(define (profile-ref doc key . default)
  (let ((entry (assoc key doc)))
    (cond (entry (cdr entry))
          ((null? default) #f)
          (else (car default)))))

(define (profile-set doc key value)
  ;; Pure: a new document with the key's value replaced — the same move
  ;; as `record-best`. The edge threads values; nothing mutates in place.
  (cons (cons key value)
        (srfi-1:filter (lambda (e) (not (equal? (car e) key))) doc)))

(define (profile-valid? doc)
  ;; The v1 contract: an alist whose version is exactly the number 1.
  (and (list? doc)
       (let ((entry (assoc "version" doc)))
         (and entry (exact? (cdr entry)) (= (cdr entry) 1)))))

(define (profile-note . parts)
  (display "profile: ")
  (let loop ((parts parts))
    (if (null? parts)
        (newline)
        (begin (display (car parts)) (loop (cdr parts))))))

;; The campaign library's shapes are proper two-element lists
;; (`("sprint" 123)`); the document's are dotted pairs
;; (`("sprint" . 123)`). The conversion lives here, at the boundary —
;; neither side should know the other's shape.
(define (pairs->dotted pairs)
  (map (lambda (e) (cons (car e) (cadr e))) pairs))

(define (dotted->pairs alist)
  (map (lambda (e) (list (car e) (cdr e))) alist))

;; --------------------------------------------------------------------- ;;
;;  Load, sync, save                                                      ;;
;; --------------------------------------------------------------------- ;;

(define (profile-load!)
  ;; Boot: read, validate, restore. A missing file is a first boot
  ;; (quiet — nobody's first launch is an error); a corrupt or foreign
  ;; document is a fresh start with a note. The conditions-chapter
  ;; pattern applied to the disk: the failure is a value the session
  ;; runs on, not a crash.
  (set! *profile-readonly* #f)
  (let ((doc (guard (e (#t
                         (profile-note "unreadable; starting fresh")
                         'corrupt))
                (read-profile))))
    (cond ((eq? doc 'corrupt)
           (set! *profile* (fresh-profile)))
          ((null? doc)
           (set! *profile* (fresh-profile)))
          ((not (profile-valid? doc))
           (let ((version (guard (e (#t #f))
                            (cdr (assoc "version" doc)))))
             (if (and version (exact? version) (> version 1))
                 (begin
                   (profile-note "document from a newer build; "
                                 "playing without saving")
                   (set! *profile* (fresh-profile))
                   (set! *profile-readonly* #t))
                 (begin
                   (profile-note "unrecognized document; starting fresh")
                   (set! *profile* (fresh-profile))))))
          (else
           (set! *profile* doc))))
  ;; The session state the document owns, restored into the conductor's
  ;; shapes. A locale on the command line still wins: boot! re-runs its
  ;; own `set-locale!` after this when the flag was carried.
  (set! *bests* (dotted->pairs (profile-ref *profile* "bests" '())))
  (set! *done*  (dotted->pairs (profile-ref *profile* "done" '())))
  (let ((loc (profile-ref *profile* "locale" #f)))
    (if loc (set-locale! (string->symbol loc)) #f)))

(define (profile-sync-progress!)
  ;; The session's progress, folded into the document. Called at the
  ;; settle — the one moment a match's outcome is final.
  (set! *profile*
        (profile-set (profile-set *profile*
                                  "bests" (pairs->dotted *bests*))
                     "done" (pairs->dotted *done*))))

(define (profile-record-locale!)
  ;; The language row cycled: the choice is rare and deliberate, so it
  ;; is worth a write at once instead of waiting for a settle.
  (if (and *profile* (not *profile-readonly*))
      (begin
        (set! *profile*
              (profile-set *profile* "locale"
                           (symbol->string (current-locale))))
        (profile-save!))
      #f))

(define (profile-save!)
  ;; The one write. Guarded: a full disk or a grumpy filesystem is a
  ;; console note, never a dead frame — the game outranks its memory.
  (cond ((not *profile*) #f)
        (*profile-readonly* #f)
        (else
         (guard (e (#t (profile-note "not saved") #f))
           (write-profile! *profile*)))))
