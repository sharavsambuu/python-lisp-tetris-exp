;;; content/locale.scm — (tetris locale)
;;;
;;; Every string a player can read, as data. Content, not code: a *locale*
;;; is a column in the map below, and a translation is an edit to a string,
;;; never to a screen. The closed set of locales lives in `locale-specs`;
;;; the first entry is the default (English), and every row of `*strings*`
;;; carries one string per locale in that same order.
;;;
;;; How to translate or fix a string: find its row, edit the text. A `#f`
;;; in a locale's slot means "not translated yet" — the player sees the
;;; English string until you fill it in, so partial translations ship.
;;; How to add a locale: append `(code "Native name")` to `locale-specs`
;;; and a new column to every row of `*strings*`.
;;;
;;; The read path is built for the frame budget (ch. 13): switching a
;;; locale rebuilds ONE alist (key -> string) for the chosen column, so a
;;; repaint's `tr` is a single `assq` — paid per locale switch, never per
;;; string per frame.
;;;
;;; The domain never imports this: `(tetris modes)`'s labels and the
;;; bests table keep their canonical English spellings as *keys*; the
;;; edge modules translate at the moment of display.

(define-library (tetris locale)
  (import (scheme base)
          (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)))
  (export tr
          tr-fmt
          tr-or
          set-locale!
          cycle-locale!
          current-locale
          locale-names
          locale-label)

  (begin
    ;; The closed locale set, in column order. The first is the default.
    (define locale-specs
      '((en "English")
        (mn "Монгол")))

    ;; Which column is live, and the flat alist `tr` actually reads —
    ;; rebuilt only when the locale changes.
    (define *locale-index* 0)
    (define *lookup* '())

    ;; ---------------------------------------------------------------- ;;
    ;;  The string map — one row per string                              ;;
    ;; ---------------------------------------------------------------- ;;
    ;;
    ;;   (key english mongolian)
    ;;
    ;; Keys are stable symbols: code reads `(tr 'menu-quit)`, the map owns
    ;; every spelling. Edit freely; nothing else in the program changes.
    (define *strings*
      '(
        ;; -- the title menu -------------------------------------------
        (menu-free-play        "Free play"                       "Чөлөөт тоглоом")
        (menu-quit             "Quit"                            "Гарах")
        (menu-language         "Language"                        "Хэл")
        (menu-levels-word      "levels"                          "түвшин")
        (menu-best             "best"                            "дээд")
        (menu-level-n          "Level ~a"                        "Түвшин ~a")
        (menu-done-mark        " [x]"                            " [x]")

        ;; -- the ways to play (display names; keys stay English) ------
        (mode-marathon         "marathon"                        "марафон")
        (mode-sprint           "sprint"                          "спринт")
        (mode-ultra            "ultra"                           "ультра")
        (mode-cheese           "cheese"                          "чийз")

        ;; -- campaigns, challenges, goals (keys = the content ids) ----
        (campaign-ascent       "The Ascent"                      "Өргөлт")
        (challenge-first-lines "First Lines"                     "Эхний мөрүүд")
        (challenge-ten-lines   "Ten Lines"                       "Арав мөр")
        (challenge-twenty      "Twenty"                          "Хорь")
        (challenge-sprint-40   "Sprint 40"                       "Спринт 40")
        (challenge-one-minute  "One Minute"                      "Нэг минут")
        (challenge-thirty-sec  "Thirty Seconds"                  "Хагас минут")
        (challenge-cheese-five "Dig In"                          "Ухаж эхлэх")
        (challenge-cheese-ten  "Deep Dig"                        "Гүн ухалт")
        (challenge-cheese-twenty "Full Board"                    "Бүтэн самбар")
        (goal-first-lines      "Clear 5 lines"                   "5 мөр арилга")
        (goal-ten-lines        "Clear 10 lines"                  "10 мөр арилга")
        (goal-twenty           "Clear 20 lines"                  "20 мөр арилга")
        (goal-sprint-40        "The classic 40-line race"        "Сонгодог 40 мөрийн уралдаан")
        (goal-one-minute       "Most score in 60 seconds"        "60 секундын дотор их оноо")
        (goal-thirty-sec       "Most score in 30 seconds"        "30 секундын дотор их оноо")
        (goal-cheese-five      "Dig through 5 garbage rows"      "5 хог мөрийг ух")
        (goal-cheese-ten       "Dig through 10 garbage rows"     "10 хог мөрийг ух")
        (goal-cheese-twenty    "Dig through 20 garbage rows"     "20 хог мөрийг ух")

        ;; -- screen titles and hints ----------------------------------
        (title-free-play       "FREE PLAY — SELECT MODE"         "ЧӨЛӨӨТ ТОГЛООМ — ГОРМЫГ СОНГОХ")
        (title-starting-level  "STARTING LEVEL"                  "ЭХНИЙ ТҮВШИН")
        (hint-title            "UP/DOWN MOVE   RETURN PICK   Q QUIT"
                               "ДЭЭШ/ДОШ: ХӨДӨЛГӨӨН   RETURN: СОНГОХ   Q: ГАРАХ")
        (hint-esc-back         "ESC: BACK"                       "ESC: БУЦАХ")
        (hint-mode             "RETURN: CHOOSE   ESC: BACK"      "RETURN: СОНГОХ   ESC: БУЦАХ")
        (hint-level            "LEFT/RIGHT: STEP   UP/DOWN: SKIP 5   RETURN: PLAY"
                               "ЗҮҮН/БАРУУН: НЭГЖ   ДЭЭШ/ДОШ: 5-ээр   RETURN: ТОГЛОХ")

        ;; -- the overlays (title, pause, win, lose) -------------------
        (overlay-return-start  "RETURN to start"                 "RETURN — эхлэх")
        (overlay-paused        "PAUSED"                          "ТҮР ЗОГСООСОН")
        (overlay-p-resume      "P to resume"                     "P — үргэлжлүүлэх")
        (overlay-r-restart     "R to restart"                    "R — дахин эхлэх")
        (overlay-esc-menu      "ESC to menu"                     "ESC — цэс рүү")
        (overlay-level-clear   "LEVEL CLEAR!"                    "ТҮВШИН ТӨГСЛӨӨ!")
        (overlay-score         "score ~a"                        "оноо ~a")
        (overlay-return-onward "RETURN onward"                   "RETURN — үргэлжлүүлэх")
        (overlay-r-replay      "R to replay"                     "R — дахин тоглох")
        (overlay-game-over     "GAME OVER"                       "ТОГЛООМ ДУУСЛАА")
        (overlay-lines         "lines ~a"                        "мөр ~a")
        (overlay-r-again       "R to play again"                 "R — дахин тоглох")

        ;; -- the HUD ---------------------------------------------------
        (hud-score             "SCORE"                           "ОНОО")
        (hud-lines             "LINES"                           "МӨР")
        (hud-level             "LEVEL"                           "ТҮВШИН")
        (hud-time              "TIME ~a"                         "ХУГАЦАА ~a")
        (hud-target            "TARGET ~a/~a"                    "ЗОРИЛТ ~a/~a")
        (hud-garbage           "GARBAGE ~a"                      "ХОГ ~a")
        (hud-combo             "COMBO x~a"                       "КОМБО x~a")
        (hud-b2b               "BACK-TO-BACK"                    "ТАСРАЛТГҮЙ")
        (hud-keys              "KEYS"                            "ТОВЧУУД")

        ;; -- the keys panel (keys by the English label, slugified) ----
        (key-move              "move"                            "хөдөлгөх")
        (key-soft-drop         "soft drop"                       "зөөлөн буулгах")
        (key-rotate-cw         "rotate cw"                       "баруун эрг.")
        (key-rotate-ccw        "rotate ccw"                      "зүүн эрг.")
        (key-hard-drop         "hard drop"                       "хатуу унагах")
        (key-hold              "hold"                            "барих")
        (key-pause             "pause"                           "зогсоох")
        (key-ai-on-off         "AI on/off"                       "AI асаах/унтраах")
        (key-ghost-on-off      "ghost on/off"                    "сүүдэр үзүүлэх")
        (key-restart           "restart"                         "дахин эхлэх")
        (key-select            "select"                          "сонгох")
        (key-back-menu         "back / menu"                     "буцах / цэс")
        ))

    ;; ---------------------------------------------------------------- ;;
    ;;  The read path                                                     ;;
    ;; ---------------------------------------------------------------- ;;

    (define (locale-count) (length locale-specs))

    (define (locale-names) (map car locale-specs))

    (define (locale-label code)
      (let ((entry (assq code locale-specs)))
        (if entry (cadr entry) (symbol->string code))))

    (define (current-locale)
      (car (list-ref locale-specs *locale-index*)))

    ;; The whole locale switches here, in one fold: each row's chosen
    ;; column becomes the flat alist a repaint reads. A missing column or
    ;; a `#f` slot answers the English string — partial translations ship.
    (define (rebuild-cache!)
      (set! *lookup*
            (map (lambda (row)
                   (cons (car row)
                         (if (< (+ *locale-index* 1) (length row))
                             (or (list-ref row (+ *locale-index* 1))
                                 (cadr row))
                             (cadr row))))
                 *strings*)))

    (define (set-locale! code)
      (let loop ((specs locale-specs) (i 0))
        (cond ((null? specs) #f)
              ((eq? (car (car specs)) code)
               (set! *locale-index* i)
               (rebuild-cache!)
               #t)
              (else (loop (cdr specs) (+ i 1))))))

    (define (cycle-locale!)
      (set-locale! (car (list-ref locale-specs
                                  (modulo (+ *locale-index* 1)
                                          (locale-count))))))

    ;; `key` with a fallback for rows the map does not know — content ids
    ;; ride this: the campaign's own title answers until you translate it.
    (define (tr-or key default)
      (let ((entry (assq key *lookup*)))
        (if entry (cdr entry) default)))

    (define (tr key)
      (tr-or key (symbol->string key)))

    ;; A value's text, for the ~a slots.
    (define (->text v)
      (cond ((string? v) v)
            ((number? v) (number->string v))
            ((symbol? v) (symbol->string v))
            (else "")))

    ;; Replace the first `~a` in s with val's text.
    (define (splice s val)
      (let ((n (string-length s)))
        (let loop ((i 0) (acc ""))
          (cond ((>= i n) acc)
                ((and (char=? (string-ref s i) #\~)
                      (< (+ i 1) n)
                      (char=? (string-ref s (+ i 1)) #\a))
                 (string-append acc (->text val)
                                (substring s (+ i 2) n)))
                (else (loop (+ i 1)
                            (string-append acc
                                           (string (string-ref s i)))))))))

    ;; (tr-fmt 'key v1 v2 …) fills each `~a` slot in order.
    (define (tr-fmt key . vals)
      (let loop ((s (tr key)) (rest vals))
        (if (null? rest)
            s
            (loop (splice s (car rest)) (cdr rest)))))

    ;; The default cache: English, ready before any screen paints.
    (rebuild-cache!)
    )
)
