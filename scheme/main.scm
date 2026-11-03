;;; main.scm — the program.
;;;
;;; Load the bounded contexts in dependency order (a define-library registers
;;; when its file is loaded; its body runs when first imported), then the two
;;; edge modules, and hand the whole game to Scheme's own loop. Python is
;;; already waiting underneath: it built this environment, installed the
;;; window's primitives, and will not touch the game again.

(load "core/rop")

(load "domain/geometry")
(load "domain/board")
(load "domain/bag")
(load "domain/modes")
(load "domain/game")
(load "domain/plan")

(load "rules/commands")
(load "rules/kicks")
(load "rules/scoring")
(load "policies/gravity")
(load "rules/pipeline")

(load "content/campaign")
(load "content/locale")

(load "presentation/view")
(load "conductor/arcade")

(arcade-main)

