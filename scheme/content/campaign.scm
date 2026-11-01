;;; content/campaign.scm — (tetris campaign)
;;;
;;; Campaigns, levels and mode presets, as data. Content, not code: a
;;; *challenge* is a named match recipe — a mode, the options a menu hands
;;; straight to `new-game`, and a one-line goal. A *campaign* is an ordered
;;; ladder over those recipes. The shell (the conductor) walks them; nothing
;;; here knows a key, a screen, or the pipeline — so a new campaign, or a new
;;; "mode" (a challenge preset), is a diff to a list below and nothing else.
;;;
;;; Progress is a hash table, not an alist: the done-set is asked once a
;;; frame by the campaign screen (a checkmark per level), and a hash answer
;;; is one step where an alist walk is a length. The session's best scores
;;; live in one too. Both are *values* the conductor threads — `mark-done!`
;;; mutates the table it is given, which is fine: progress is edge state,
;;; not match state, and never enters the game record.

(define-library (tetris campaign)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each))
          (tetris modes))
  (export challenge
          challenge-id
          challenge-title
          challenge-mode
          challenge-options
          challenge-goal
          challenge-ids
          challenge-by-id
          campaign
          campaign-id
          campaign-title
          campaign-description
          campaign-levels
          campaign-by-id
          campaigns
          level-key
          level-done?
          mark-done
          best-for
          record-best)

  (begin
    ;; The join SRFI 13 would own: this library's scope is closed, and the
    ;; prelude's string-join does not reach in here.
    (define (join-with sep xs)
      (let loop ((xs xs) (acc ""))
        (cond ((null? xs) acc)
              ((null? (cdr xs)) (string-append acc (car xs)))
              (else (loop (cdr xs) (string-append acc (car xs) sep))))))

    ;; A challenge is `(("id" …) ("title" …) ("mode" …) ("options" …) ("goal" …))`.
    ;; The fields are read by accessors, so a challenge reads as the record
    ;; it is.
    (define (challenge id title mode options goal)
      (list (list "id" id)
            (list "title" title)
            (list "mode" mode)
            (list "options" options)
            (list "goal" goal)))

    (define (field c k) (cadr (assq k c)))

    (define (challenge-id c) (field c "id"))
    (define (challenge-title c) (field c "title"))
    (define (challenge-mode c) (field c "mode"))
    (define (challenge-options c) (field c "options"))
    (define (challenge-goal c) (field c "goal"))


    ;; One `(key value)` pair of the options alist `new-game` takes.
    (define (mode-opt key value) (list key value))

    ;; The challenges — the presets a campaign (or free play) can hand out.
    (define *challenges*
      (list
       (challenge "first-lines"   "First Lines"    'sprint
                  (list (mode-opt 'target-lines 5))  "Clear 5 lines")
       (challenge "ten-lines"     "Ten Lines"      'sprint
                  (list (mode-opt 'target-lines 10)) "Clear 10 lines")
       (challenge "twenty"        "Twenty"         'sprint
                  (list (mode-opt 'target-lines 20)) "Clear 20 lines")
       (challenge "sprint-40"     "Sprint 40"      'sprint
                  (list (mode-opt 'target-lines 40)) "The classic 40-line race")
       (challenge "one-minute"    "One Minute"     'ultra
                  (list (mode-opt 'time-limit 60))   "Most score in 60 seconds")
       (challenge "thirty-sec"    "Thirty Seconds" 'ultra
                  (list (mode-opt 'time-limit 30))   "Most score in 30 seconds")
       (challenge "cheese-five"   "Dig In"         'cheese
                  (list (mode-opt 'cheese-rows 5))   "Dig through 5 garbage rows")
       (challenge "cheese-ten"    "Deep Dig"       'cheese
                  (list (mode-opt 'cheese-rows 10))  "Dig through 10 garbage rows")
       (challenge "cheese-twenty" "Full Board"     'cheese
                  (list (mode-opt 'cheese-rows 20))  "Dig through 20 garbage rows")))

    (define (challenge-ids) (map challenge-id *challenges*))

    (define (challenge-by-id id)
      ;; The challenge named `id`, or a raised condition naming the set —
      ;; never a silent miss. The conductor's guard turns one into a message.
      (let loop ((cs *challenges*))
        (cond ((null? cs)
               (raise (list "no challenge" id
                            (string-append "try one of: "
                                           (join-with ", " (challenge-ids))))))
              ((string=? (challenge-id (car cs)) id) (car cs))
              (else (loop (cdr cs))))))

    ;; A campaign is `(("id" …) ("title" …) ("description" …) ("levels" …))`,
    ;; where `levels` is a list of challenges (not ids: the ladder is
    ;; already resolved).
    (define (campaign id title description levels)
      (list (list "id" id)
            (list "title" title)
            (list "description" description)
            (list "levels" levels)))

    (define (campaign-id c) (field c "id"))
    (define (campaign-title c) (field c "title"))
    (define (campaign-description c) (field c "description"))
    (define (campaign-levels c) (field c "levels"))

    (define *campaigns*
      (list
       (campaign "ascent" "The Ascent"
                 "From your first line to a full cheese board."
                 (list (challenge-by-id "first-lines")
                       (challenge-by-id "ten-lines")
                       (challenge-by-id "twenty")
                       (challenge-by-id "one-minute")
                       (challenge-by-id "cheese-five")
                       (challenge-by-id "thirty-sec")
                       (challenge-by-id "cheese-ten")
                       (challenge-by-id "sprint-40")))))

    (define (campaigns) *campaigns*)

    (define (campaign-by-id id)
      ;; The campaign named `id`, or #f — the title menu only offers real ones.
      (let loop ((cs *campaigns*))
        (cond ((null? cs) #f)
              ((string=? (campaign-id (car cs)) id) (car cs))
              (else (loop (cdr cs))))))

    ;; ---------------------------------------------------------------- ;;
    ;;  Progress — a level key, and the won set                            ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;; The done-set and the bests are *alists*, and their updates are pure:
    ;; `mark-done` answers a new set the way `board-place` answers a new
    ;; board. (The hash tables live one layer up, in the conductor's edge
    ;; scope — a library scope is closed, and the hash primitives are edge
    ;; vocabulary.) Progress is edge state, not match state, and never
    ;; enters the game record.

    ;; A level key: campaign id + 1-based position. Stable across edits to
    ;; the ladder's titles and goals.
    (define (level-key campaign-id index)
      (string-append campaign-id ":" (number->string index)))

    (define (level-done? done key)
      (if (assoc key done) #t #f))

    (define (mark-done done key)
      ;; Pure and idempotent: raising a stored pass is a no-op, so a frame
      ;; may call it freely.
      (if (level-done? done key)
          done
          (cons (list key #t) done)))

    ;; The session's best score per mode label — free play's scoreboard.
    (define (best-for bests mode-label)
      (let ((entry (assoc mode-label bests)))
        (if entry (cadr entry) 0)))

    (define (record-best bests mode-label score)
      (if (> score (best-for bests mode-label))
          (cons (list mode-label score)
                (filter (lambda (e) (not (string=? (car e) mode-label)))
                        bests))
          bests)))
)


