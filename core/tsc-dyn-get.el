;;; tsc-dyn-get.el --- Utilities to obtain tsc-dyn -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 2020  Tuấn-Anh Nguyễn
;;
;; Author: Tuấn-Anh Nguyễn <ubolonton@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; This file contains the utilities to obtain the dynamic module `tsc-dyn', by
;; either downloading pre-built binaries or building from source.

;;; Code:

(require 'seq)
(require 'dired-aux)
(require 'compile)

(eval-when-compile
  (require 'subr-x))

(eval-when-compile
  ;; Version string set by `tsc-dyn' when it's loaded.
  (defvar tsc-dyn--version))

(defconst tsc-dyn-get--version-file "DYN-VERSION")

(defconst tsc--dir (file-name-directory (or (locate-library "tsc.el") ""))
  "The directory where the library `tsc' is located.")

(defgroup tsc nil
  "Core tree-sitter APIs."
  :group 'languages)

(defcustom tsc-dyn-dir tsc--dir
  "The directory that `tsc-dyn' module is resided.
This should be set before `tsc' is loaded.

In Windows you may want to set this to prevent package upgrade failure by loaded
module deletion. See ubolonton/emacs-tree-sitter#122 for more detail.

Example setting:
\(setq tsc-dyn-dir (expand-file-name \"tree-sitter/\" user-emacs-directory))"
  :group 'tsc
  :type 'directory)

(defcustom tsc-dyn-get-from '(:github :compilation)
  "Where the dynamic module binary should come from, in order of priority."
  :group 'tsc
  :type '(set (const :tag "Binary from GitHub" :github)
              (const :tag "Local Compilation" :compilation)))

;; TODO: Handle systems with no pre-built binaries better.
(defun tsc-dyn-get--dir ()
  "Return the directory to put `tsc-dyn' module in."
  (or tsc-dyn-dir
      (error "Could not locate the directory for `tsc-dyn'")))

(defun tsc-dyn-get--ext ()
  "Return the dynamic module extension, which is system-dependent."
  (pcase system-type
    ('windows-nt "dll")
    ('darwin "dylib")
    ((or 'gnu 'gnu/linux 'gnu/kfreebsd) "so")
    ((or 'ms-dos 'cygwin) (error "Unsupported system-type %s" system-type))
    (_ "so")))

(defun tsc-dyn-get--file ()
  "Return the dynamic module filename, which is system-dependent."
  (format "tsc-dyn.%s" (tsc-dyn-get--ext)))

;; TODO: Remove this when cargo allows specifying output file name.
(defun tsc-dyn-get--out-file ()
  "Return cargo's output filename, which is system-dependent."
  (let ((base (pcase system-type
                ('windows-nt "tsc_dyn")
                (_ "libtsc_dyn"))))
    (format "%s.%s" base (tsc-dyn-get--ext))))

(defun tsc-dyn-get--download (version)
  "Download the pre-compiled VERSION of `tsc-dyn' module."
  (let* ((bin-dir (tsc-dyn-get--dir))
         (default-directory bin-dir)
         (_ (unless (file-directory-p bin-dir) (make-directory bin-dir)))
         (dyn-file (tsc-dyn-get--file))
         (gz-file (format "%s.gz" dyn-file))
         (uncompressed? (version< "0.7.0" version))
         (url (format "https://github.com/emacs-tree-sitter/elisp-tree-sitter/releases/download/%s/%s"
                      version (if uncompressed? dyn-file gz-file))))
    (message "Downloading %s" url)
    (if uncompressed?
        (url-copy-file url dyn-file :ok-if-already-exists)
      (url-copy-file url gz-file)
      (when (file-exists-p dyn-file)
        (delete-file dyn-file))
      ;; XXX: Uncompressing with `dired-compress-file' doesn't work on Windows.
      (dired-compress-file gz-file))
    (with-temp-file tsc-dyn-get--version-file
      (let ((coding-system-for-write 'utf-8))
        (insert version)))))

(defmacro tsc-dyn-get--compilation-to-stdout (condition &rest body)
  "Eval BODY forms with compilation output conditionally redirected to `princ'."
  (declare (indent 1))
  (if condition
      (let ((print-stdout (make-symbol "print-stdout")))
        `(let ((,print-stdout (lambda (_proc string) (princ string))))
           (advice-add 'compilation-filter :override ,print-stdout)
           (unwind-protect
               (progn ,@body)
             (advice-remove 'compilation-filter ,print-stdout))))
    `(progn ,@body)))

(defun tsc-dyn-get--build (&optional dir)
  "Build the dynamic module `tsc-dyn' from source."
  (unless dir (setq dir tsc-dyn-dir))
  (tsc-dyn-get--compilation-to-stdout noninteractive
    (let* ((default-directory dir)
           proc
           (compilation-start-hook (lambda (p) (setq proc p)))
           (compilation-auto-jump-to-first-error nil)
           (compilation-scroll-output t)
           (comp-buffer (compilation-start
                         "cargo build --release"
                         nil (lambda (_) "*tsc-dyn compilation*"))))
      (if-let ((window (get-buffer-window comp-buffer)))
          (select-window window)
        (pop-to-buffer comp-buffer))
      (with-current-buffer comp-buffer
        (setq-local compilation-error-regexp-alist nil)
        (add-hook 'compilation-finish-functions
          (lambda (_buffer status)
            (unless (string= status "finished\n")
              (error "Compiling tsc-dyn failed with status: %s" status))
            (message "Cleaning up")
            ;; TODO: Ask if the file exists.
            (let ((file (tsc-dyn-get--file)))
              (when (file-exists-p file)
                (delete-file file))
              (rename-file (format "target/release/%s" (tsc-dyn-get--out-file))
                           file))
            (delete-directory "target" :recursive))
          nil :local)
        (unless noninteractive
          (when (functionp 'ansi-color-apply-on-region)
            (add-hook 'compilation-filter-hook
              (lambda () (ansi-color-apply-on-region ;; compilation-filter-start
                     (point-min)
                     (point-max)))))))
      (when noninteractive
        (while (not (memq (process-status proc) '(exit failed signal)))
          (sleep-for 0.1))))))

(defun tsc--try-load-dyn (file)
  "Try loading `tsc-dyn' from FILE. Return nil if the file does not exist."
  (or (featurep 'tsc-dyn)
      (condition-case _
          (module-load file)
        (module-open-failed nil))))

;; XXX: Using `require' after setting`module-file-suffix' to `.dylib' results in
;; "Cannot open load file: No such file or directory, tsc-dyn".
;;
;; XXX: Using `load' results in an error message with garbled text: "Symbol’s
;; value as variable is void: Ïúíþ".
;;
;; Therefore, we need to search for the file and use `module-load' directly.
(defun tsc--mac-load-dyn ()
  "Search and load the dynamic module on macOS."
  (let ((file "tsc-dyn.dylib"))
    ;; Try directory containing `load-file-name'. Typical case.
    (when load-file-name
      (tsc--try-load-dyn (concat (file-name-directory load-file-name)
                                 file)))
    ;; Try working directory (e.g. when invoked by `cask').
    (tsc--try-load-dyn file)
    ;; Fall back to `load-path'.
    (seq-find (lambda (dir)
                (let ((full-name (concat (file-name-as-directory
                                          (expand-file-name dir))
                                         file)))
                  (tsc--try-load-dyn full-name)))
              load-path)))

(defun tsc-dyn-get-ensure (version)
  "Try to load a specific VERSION of  `tsc-dyn'.
If it's not found, try to download it."
  ;; On Windows, we cannot overwrite the old dll file while it's opened
  ;; (loaded), so we'll have to do the version check before loading the module,
  ;; through a version file.
  (let* ((default-directory (tsc-dyn-get--dir))
         (current-version (when (file-exists-p
                                 tsc-dyn-get--version-file)
                            (with-temp-buffer
                              (let ((coding-system-for-read 'utf-8))
                                (insert-file-contents
                                 tsc-dyn-get--version-file)
                                (buffer-string))))))
    ;; This is also run on CI, after we've built the binaries, but before
    ;; publishing them. Downloading at that time doesn't make sense, so we
    ;; disable it with a special version string.
    (unless (string= current-version "LOCAL")
      (when (or (not current-version)
                (version< current-version version))
        (tsc-dyn-get--download version))))
  (let ((load-path (nconc `(,tsc-dyn-dir) load-path)))
    ;; XXX: We wanted a universal package containing binaries for all platforms,
    ;; so we used a unique extension for each. On macOS, we use`.dylib', which
    ;; is more sensible than `.so' anyway.
    (unless (featurep 'tsc-dyn)
      (when (eq system-type 'darwin)
        (tsc--mac-load-dyn)))
    ;; If we could not load it (e.g. when the dynamic module was deleted, but the
    ;; version file was not), try downloading again.
    (unless (require 'tsc-dyn nil :noerror)
      (tsc-dyn-get--download version))
    ;; We should have the binary by now. Try to load for real.
    (unless (featurep 'tsc-dyn)
      (when (eq system-type 'darwin)
        (tsc--mac-load-dyn))
      (require 'tsc-dyn)))
  ;; Check if and older version was already loaded.
  (unless (string= version tsc-dyn--version)
    (display-warning 'tree-sitter
                     (format "Version %s of tsc-dyn was already loaded. Please restart Emacs to load the requested version %s"
                             tsc-dyn--version version)
                     :emergency)))

(provide 'tsc-dyn-get)
;;; tsc-dyn-get.el ends here
