;;; Guix --- Nix package management from Guile.         -*- coding: utf-8 -*-
;;; Copyright (C) 2012 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of Guix.
;;;
;;; Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix build utils)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:export (directory-exists?
            with-directory-excursion
            mkdir-p
            copy-recursively
            find-files

            set-path-environment-variable
            search-path-as-string->list
            list->search-path-as-string
            alist-cons-before
            alist-cons-after
            alist-replace
            with-atomic-file-replacement
            substitute
            substitute*
            dump-port
            patch-shebang
            fold-port-matches
            remove-store-references))


;;;
;;; Directories.
;;;

(define (directory-exists? dir)
  "Return #t if DIR exists and is a directory."
  (let ((s (stat dir #f)))
    (and s
         (eq? 'directory (stat:type s)))))

(define-syntax-rule (with-directory-excursion dir body ...)
  "Run BODY with DIR as the process's current directory."
  (let ((init (getcwd)))
   (dynamic-wind
     (lambda ()
       (chdir dir))
     (lambda ()
       body ...)
     (lambda ()
       (chdir init)))))

(define (mkdir-p dir)
  "Create directory DIR and all its ancestors."
  (define absolute?
    (string-prefix? "/" dir))

  (define not-slash
    (char-set-complement (char-set #\/)))

  (let loop ((components (string-tokenize dir not-slash))
             (root       (if absolute?
                             ""
                             ".")))
    (match components
      ((head tail ...)
       (let ((path (string-append root "/" head)))
         (catch 'system-error
           (lambda ()
             (mkdir path)
             (loop tail path))
           (lambda args
             (if (= EEXIST (system-error-errno args))
                 (loop tail path)
                 (apply throw args))))))
      (() #t))))

(define* (copy-recursively source destination
                           #:optional (log (current-output-port)))
  "Copy SOURCE directory to DESTINATION."
  (define strip-source
    (let ((len (string-length source)))
      (lambda (file)
        (substring file len))))

  (file-system-fold (const #t)                    ; enter?
                    (lambda (file stat result)    ; leaf
                      (let ((dest (string-append destination
                                                 (strip-source file))))
                        (format log "`~a' -> `~a'~%" file dest)
                        (copy-file file dest)))
                    (lambda (dir stat result)     ; down
                      (mkdir-p (string-append destination
                                              (strip-source dir))))
                    (lambda (dir stat result)     ; up
                      result)
                    (const #t)                    ; skip
                    (lambda (file stat errno result)
                      (format (current-error-port) "i/o error: ~a: ~a~%"
                              file (strerror errno))
                      #f)
                    #t
                    source))

(define (find-files dir regexp)
  "Return the list of files under DIR whose basename matches REGEXP."
  (define file-rx
    (if (regexp? regexp)
        regexp
        (make-regexp regexp)))

  (file-system-fold (const #t)
                    (lambda (file stat result)    ; leaf
                      (if (regexp-exec file-rx (basename file))
                          (cons file result)
                          result))
                    (lambda (dir stat result)     ; down
                      result)
                    (lambda (dir stat result)     ; up
                      result)
                    (lambda (file stat result)    ; skip
                      result)
                    (lambda (file stat errno result)
                      (format (current-error-port) "find-files: ~a: ~a~%"
                              file (strerror errno))
                      #f)
                    '()
                    dir))


;;;
;;; Search paths.
;;;

(define (search-path-as-list sub-directories input-dirs)
  "Return the list of directories among SUB-DIRECTORIES that exist in
INPUT-DIRS.  Example:

  (search-path-as-list '(\"share/emacs/site-lisp\" \"share/emacs/24.1\")
                       (list \"/package1\" \"/package2\" \"/package3\"))
  => (\"/package1/share/emacs/site-lisp\"
      \"/package3/share/emacs/site-lisp\")

"
  (append-map (lambda (input)
                (filter-map (lambda (dir)
                              (let ((dir (string-append input "/"
                                                        dir)))
                                (and (directory-exists? dir)
                                     dir)))
                            sub-directories))
              input-dirs))

(define (list->search-path-as-string lst separator)
  (string-join lst separator))

(define* (search-path-as-string->list path #:optional (separator #\:))
  (string-tokenize path (char-set-complement (char-set separator))))

(define* (set-path-environment-variable env-var sub-directories input-dirs
                                        #:key (separator ":"))
  "Look for each of SUB-DIRECTORIES in INPUT-DIRS.  Set ENV-VAR to a
SEPARATOR-separated path accordingly.  Example:

  (set-path-environment-variable \"PKG_CONFIG\"
                                 '(\"lib/pkgconfig\")
                                 (list package1 package2))
"
  (let* ((path  (search-path-as-list sub-directories input-dirs))
         (value (list->search-path-as-string path separator)))
   (setenv env-var value)
   (format #t "environment variable `~a' set to `~a'~%"
           env-var value)))


;;;
;;; Phases.
;;;
;;; In (guix build gnu-build-system), there are separate phases (configure,
;;; build, test, install).  They are represented as a list of name/procedure
;;; pairs.  The following procedures make it easy to change the list of
;;; phases.
;;;

(define* (alist-cons-before reference key value alist
                            #:optional (key=? equal?))
  "Insert the KEY/VALUE pair before the first occurrence of a pair whose key
is REFERENCE in ALIST.  Use KEY=? to compare keys."
  (let-values (((before after)
                (break (match-lambda
                        ((k . _)
                         (key=? k reference)))
                       alist)))
    (append before (alist-cons key value after))))

(define* (alist-cons-after reference key value alist
                           #:optional (key=? equal?))
  "Insert the KEY/VALUE pair after the first occurrence of a pair whose key
is REFERENCE in ALIST.  Use KEY=? to compare keys."
  (let-values (((before after)
                (break (match-lambda
                        ((k . _)
                         (key=? k reference)))
                       alist)))
    (match after
      ((reference after ...)
       (append before (cons* reference `(,key . ,value) after)))
      (()
       (append before `((,key . ,value)))))))

(define* (alist-replace key value alist #:optional (key=? equal?))
  "Replace the first pair in ALIST whose car is KEY with the KEY/VALUE pair.
An error is raised when no such pair exists."
  (let-values (((before after)
                (break (match-lambda
                        ((k . _)
                         (key=? k key)))
                       alist)))
    (match after
      ((_ after ...)
       (append before (alist-cons key value after))))))


;;;
;;; Text substitution (aka. sed).
;;;

(define (with-atomic-file-replacement file proc)
  "Call PROC with two arguments: an input port for FILE, and an output
port for the file that is going to replace FILE.  Upon success, FILE is
atomically replaced by what has been written to the output port, and
PROC's result is returned."
  (let* ((template (string-append file ".XXXXXX"))
         (out      (mkstemp! template))
         (mode     (stat:mode (stat file))))
    (with-throw-handler #t
      (lambda ()
        (call-with-input-file file
          (lambda (in)
            (let ((result (proc in out)))
              (close out)
              (chmod template mode)
              (rename-file template file)
              result))))
      (lambda (key . args)
        (false-if-exception (delete-file template))))))

(define (substitute file pattern+procs)
  "PATTERN+PROCS is a list of regexp/two-argument procedure.  For each line
of FILE, and for each PATTERN that it matches, call the corresponding PROC
as (PROC LINE MATCHES); PROC must return the line that will be written as a
substitution of the original line."
  (let ((rx+proc  (map (match-lambda
                        (((? regexp? pattern) . proc)
                         (cons pattern proc))
                        ((pattern . proc)
                         (cons (make-regexp pattern regexp/extended)
                               proc)))
                       pattern+procs)))
    (with-atomic-file-replacement file
      (lambda (in out)
        (let loop ((line (read-line in 'concat)))
          (if (eof-object? line)
              #t
              (let ((line (fold (lambda (r+p line)
                                  (match r+p
                                    ((regexp . proc)
                                     (match (list-matches regexp line)
                                       ((and m+ (_ _ ...))
                                        (proc line m+))
                                       (_ line)))))
                                line
                                rx+proc)))
                (display line out)
                (loop (read-line in 'concat)))))))))


(define-syntax let-matches
  ;; Helper macro for `substitute*'.
  (syntax-rules (_)
    ((let-matches index match (_ vars ...) body ...)
     (let-matches (+ 1 index) match (vars ...)
                  body ...))
    ((let-matches index match (var vars ...) body ...)
     (let ((var (match:substring match index)))
       (let-matches (+ 1 index) match (vars ...)
                    body ...)))
    ((let-matches index match () body ...)
     (begin body ...))))

(define-syntax substitute*
  (syntax-rules ()
    "Substitute REGEXP in FILE by the string returned by BODY.  BODY is
evaluated with each MATCH-VAR bound to the corresponding positional regexp
sub-expression.  For example:

  (substitute* file
     ((\"hello\")
      \"good morning\\n\")
     ((\"foo([a-z]+)bar(.*)$\" all letters end)
      (string-append \"baz\" letter end)))

Here, anytime a line of FILE contains \"hello\", it is replaced by \"good
morning\".  Anytime a line of FILE matches the second regexp, ALL is bound to
the complete match, LETTERS is bound to the first sub-expression, and END is
bound to the last one.

When one of the MATCH-VAR is `_', no variable is bound to the corresponding
match substring.

Alternatively, FILE may be a list of file names, in which case they are
all subject to the substitutions."
    ((substitute* file ((regexp match-var ...) body ...) ...)
     (let ()
       (define (substitute-one-file file-name)
         (substitute
          file-name
          (list (cons regexp
                      (lambda (l m+)
                        ;; Iterate over matches M+ and return the
                        ;; modified line based on L.
                        (let loop ((m* m+)  ; matches
                                   (o  0)   ; offset in L
                                   (r  '())) ; result
                          (match m*
                            (()
                             (let ((r (cons (substring l o) r)))
                               (string-concatenate-reverse r)))
                            ((m . rest)
                             (let-matches 0 m (match-var ...)
                               (loop rest
                                     (match:end m)
                                     (cons*
                                      (begin body ...)
                                      (substring l o (match:start m))
                                      r))))))))
                ...)))

       (match file
         ((files (... ...))
          (for-each substitute-one-file files))
         ((? string? f)
          (substitute-one-file f)))))))


;;;
;;; Patching shebangs---e.g., /bin/sh -> /nix/store/xyz...-bash/bin/sh.
;;;

(define (dump-port in out)
  "Read as much data as possible from IN and write it to OUT."
  (define buffer-size 4096)
  (define buffer
    (make-bytevector buffer-size))

  (let loop ((bytes (get-bytevector-n! in buffer 0 buffer-size)))
    (or (eof-object? bytes)
        (begin
          (put-bytevector out buffer 0 bytes)
          (loop (get-bytevector-n! in buffer 0 buffer-size))))))

(define patch-shebang
  (let ((shebang-rx (make-regexp "^[[:blank:]]*([[:graph:]]+)(.*)$")))
    (lambda* (file
              #:optional (path (search-path-as-string->list (getenv "PATH"))))
      "Replace the #! interpreter file name in FILE by a valid one found in
PATH, when FILE actually starts with a shebang.  Return #t when FILE was
patched, #f otherwise."
      (define (patch p interpreter rest-of-line)
        (let* ((template (string-append file ".XXXXXX"))
               (out      (mkstemp! template))
               (mode     (stat:mode (stat file))))
          (with-throw-handler #t
            (lambda ()
              (format out "#!~a~a~%"
                      interpreter rest-of-line)
              (dump-port p out)
              (close out)
              (chmod template mode)
              (rename-file template file)
              #t)
            (lambda (key . args)
              (format (current-error-port)
                      "patch-shebang: ~a: error: ~a ~s~%"
                      file key args)
              (false-if-exception (delete-file template))
              #f))))

      (with-fluids ((%default-port-encoding #f))  ; ASCII
        (call-with-input-file file
          (lambda (p)
            (and (eq? #\# (read-char p))
                 (eq? #\! (read-char p))
                 (let ((line (false-if-exception (read-line p))))
                   (and=> (and line (regexp-exec shebang-rx line))
                          (lambda (m)
                            (let* ((cmd (match:substring m 1))
                                   (bin (search-path path
                                                     (basename cmd))))
                              (if bin
                                  (if (string=? bin cmd)
                                      #f          ; nothing to do
                                      (begin
                                        (format (current-error-port)
                                                "patch-shebang: ~a: changing `~a' to `~a'~%"
                                                file cmd bin)
                                        (patch p bin (match:substring m 2))))
                                  (begin
                                    (format (current-error-port)
                                            "patch-shebang: ~a: warning: no binary for interpreter `~a' found in $PATH~%"
                                            file (basename cmd))
                                    #f)))))))))))))

(define* (fold-port-matches proc init pattern port
                            #:optional (unmatched (lambda (_ r) r)))
  "Read from PORT character-by-character; for each match against
PATTERN, call (PROC MATCH RESULT), where RESULT is seeded with INIT.
PATTERN is a list of SRFI-14 char-sets.  Call (UNMATCHED CHAR RESULT)
for each unmatched character."
  (define initial-pattern
    ;; The poor developer's regexp.
    (if (string? pattern)
        (map char-set (string->list pattern))
        pattern))

  ;; Note: we're not really striving for performance here...
  (let loop ((chars   '())
             (pattern initial-pattern)
             (matched '())
             (result  init))
    (cond ((null? chars)
           (loop (list (get-char port))
                 pattern
                 matched
                 result))
          ((null? pattern)
           (loop chars
                 initial-pattern
                 '()
                 (proc (list->string (reverse matched)) result)))
          ((eof-object? (car chars))
           (fold-right unmatched result matched))
          ((char-set-contains? (car pattern) (car chars))
           (loop (cdr chars)
                 (cdr pattern)
                 (cons (car chars) matched)
                 result))
          ((null? matched)                        ; common case
           (loop (cdr chars)
                 pattern
                 matched
                 (unmatched (car chars) result)))
          (else
           (let ((matched (reverse matched)))
             (loop (append (cdr matched) chars)
                   initial-pattern
                   '()
                   (unmatched (car matched) result)))))))

(define* (remove-store-references file
                                  #:optional (store (or (getenv "NIX_STORE")
                                                        "/nix/store")))
  "Remove from FILE occurrences of file names in STORE; return #t when
store paths were encountered in FILE, #f otherwise.  This procedure is
known as `nuke-refs' in Nixpkgs."
  (define pattern
    (let ((nix-base32-chars
           '(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9
             #\a #\b #\c #\d #\f #\g #\h #\i #\j #\k #\l #\m #\n
             #\p #\q #\r #\s #\v #\w #\x #\y #\z)))
      `(,@(map char-set (string->list store))
        ,(char-set #\/)
        ,@(make-list 32 (list->char-set nix-base32-chars))
        ,(char-set #\-))))

  (with-fluids ((%default-port-encoding #f))
    (with-atomic-file-replacement file
      (lambda (in out)
        ;; We cannot use `regexp-exec' here because it cannot deal with
        ;; strings containing NUL characters.
        (format #t "removing store references from `~a'...~%" file)
        (setvbuf in _IOFBF 65536)
        (setvbuf out _IOFBF 65536)
        (fold-port-matches (lambda (match result)
                             (put-string out store)
                             (put-char out #\/)
                             (put-string out
                              "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-")
                             #t)
                           #f
                           pattern
                           in
                           (lambda (char result)
                             (put-char out char)
                             result))))))

;;; Local Variables:
;;; eval: (put 'call-with-output-file/atomic 'scheme-indent-function 1)
;;; eval: (put 'with-throw-handler 'scheme-indent-function 1)
;;; eval: (put 'let-matches 'scheme-indent-function 3)
;;; eval: (put 'with-atomic-file-replacement 'scheme-indent-function 1)
;;; End:
