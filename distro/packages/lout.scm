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

(define-module (distro packages lout)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix utils)
  #:use-module (guix build-system gnu))

(define-public lout
  ;; This one is a bit tricky, because it doesn't follow the GNU Build System
  ;; rules.  Instead, it has a makefile that has to be patched to set the
  ;; prefix, etc., and it has no makefile rules to build its doc.
  (let ((configure-phase
         '(lambda* (#:key outputs #:allow-other-keys)
            (let ((out (assoc-ref outputs "out"))
                  (doc (assoc-ref outputs "doc")))
              (substitute* "makefile"
                (("^PREFIX[[:blank:]]*=.*$")
                 (string-append "PREFIX = " out "\n"))
                (("^LOUTLIBDIR[[:blank:]]*=.*$")
                 (string-append "LOUTLIBDIR = " out "/lib/lout\n"))
                (("^LOUTDOCDIR[[:blank:]]*=.*$")
                 (string-append "LOUTDOCDIR = " doc "/doc/lout\n"))
                (("^MANDIR[[:blank:]]*=.*$")
                 (string-append "MANDIR = " out "/man\n")))
              (mkdir out)
              (mkdir (string-append out "/bin"))
              (mkdir (string-append out "/lib"))
              (mkdir (string-append out "/man"))
              (mkdir-p (string-append doc "/doc/lout")))))
        (install-man-phase
         '(lambda* (#:key outputs #:allow-other-keys)
            (zero? (system* "make" "installman"))))
        (doc-phase
         '(lambda* (#:key outputs #:allow-other-keys)
            (define out
              (assoc-ref outputs "doc"))

            (setenv "PATH"
                    (string-append (assoc-ref outputs "out")
                                   "/bin:" (getenv "PATH")))
            (chdir "doc")
            (every (lambda (doc)
                     (format #t "doc: building `~a'...~%" doc)
                     (with-directory-excursion doc
                       (let ((file (string-append out "/doc/lout/"
                                                  doc ".ps")))
                         (and (or (file-exists? "outfile.ps")
                                  (zero? (system* "lout" "-r4" "-o"
                                                  "outfile.ps" "all")))
                              (begin
                                (copy-file "outfile.ps" file)
                                #t)
                              (zero? (system* "ps2pdf"
                                              "-dPDFSETTINGS=/prepress"
                                              "-sPAPERSIZE=a4"
                                              file
                                              (string-append out "/doc/lout/"
                                                             doc ".pdf")))))))
                   '("design" "expert" "slides" "user")))))
   (package
    (name "lout")
    (version "3.39")
    (source (origin
             (method url-fetch)
             ;; FIXME: `http-get' doesn't follow redirects, hence the URL.
             (uri (string-append
                   "http://download-mirror.savannah.gnu.org/releases/lout/lout-"
                   version ".tar.gz"))
             (sha256
              (base32
               "12gkyqrn0kaa8xq7sc7v3wm407pz2fxg9ngc75aybhi5z825b9vq"))))
    (build-system gnu-build-system)               ; actually, just a makefile
    (outputs '("out" "doc"))
    (inputs `(("ghostscript" ,(nixpkgs-derivation "ghostscript"))))
    (arguments `(#:modules ((guix build utils)
                            (guix build gnu-build-system)
                            (srfi srfi-1))        ; we need SRFI-1
                 #:tests? #f                      ; no "check" target

                 ;; Customize the build phases.
                 #:phases (alist-replace
                           'configure ,configure-phase

                           (alist-cons-after
                            'install 'install-man-pages
                            ,install-man-phase

                            (alist-cons-after
                             'install 'install-doc
                             ,doc-phase
                             %standard-phases)))))
    (synopsis "Lout, a document layout system similar in style to LaTeX")
    (description
"The Lout document formatting system is now reads a high-level description of
a document similar in style to LaTeX and produces a PostScript or plain text
output file.

Lout offers an unprecedented range of advanced features, including optimal
paragraph and page breaking, automatic hyphenation, PostScript EPS file
inclusion and generation, equation formatting, tables, diagrams, rotation and
scaling, sorted indexes, bibliographic databases, running headers and
odd-even pages, automatic cross referencing, multilingual documents including
hyphenation (most European languages are supported), formatting of computer
programs, and much more, all ready to use.  Furthermore, Lout is easily
extended with definitions which are very much easier to write than troff of
TeX macros because Lout is a high-level, purely functional language, the
outcome of an eight-year research project that went back to the
beginning.")
    (license "GPLv3+")
    (home-page "http://savannah.nongnu.org/projects/lout/"))))
