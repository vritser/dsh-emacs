;;; dsh-test-rpc.el --- Rpc tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)
(require 'url-auth)
(require 'url-http)

(ert-deftest dsh-emacs-test-rpc-stop-invalidates-inflight-results ()
  :tags '(dsh-unit)
  (dolist (kind '(sync async upload))
    (dolist (status '(200 401))
      (with-temp-buffer
        (let* ((origin (current-buffer))
               (dsh-emacs-base-url "http://old.example")
               (dsh-emacs--server-generation 0)
               (dsh-emacs--server-process nil)
               (dsh-emacs--server-alive-check nil)
               (dsh-emacs--server-auth-cookie "same-cookie")
               (dsh-emacs--command-fetch-inflight nil)
               (dsh-emacs--command-fetch-stamps nil)
               (dsh-emacs--skill-fetch-inflight nil)
               (dsh-emacs--skill-fetch-stamps nil)
               (response (generate-new-buffer " *dsh-stopped-response*"))
               (calls 0) (sent 0) received result)
          (unwind-protect
              (cl-letf (((symbol-function 'dsh-emacs--server-auth-header)
                         (lambda (&rest _) '(("Cookie" . "same-cookie"))))
                        ((symbol-function 'url-retrieve-synchronously)
                         (lambda (&rest _)
                           (cl-incf sent)
                           (dsh-emacs-server-stop)
                           response))
                        ((symbol-function 'url-retrieve)
                         (lambda (_url callback &rest _)
                           (cl-incf sent)
                           (setq received callback)
                           response)))
                (with-current-buffer response
                  (setq-local url-http-response-status status)
                  (insert "HTTP/1.1 200 OK\n\n{\"result\":{\"ok\":true,\"value\":17}}"))
                (if (eq kind 'sync)
                    (should-not (car (dsh-emacs--rpc-request "session/list" nil)))
                  (cl-labels ((done (value)
                                (should (eq (current-buffer) origin))
                                (cl-incf calls)
                                (setq result value)
                                ;; Failure settlement cannot start work on a
                                ;; new server attempt, even in batch mode.
                                (should-error (dsh-emacs-server-ensure)
                                              :type 'user-error)
                                (should-error
                                 (dsh-emacs--rpc-request "session/list" nil)
                                 :type 'user-error)
                                (should-error
                                 (dsh-emacs-command-catalog-fetch "old-session")
                                 :type 'user-error)
                                (should-error
                                 (dsh-emacs-skill-catalog-fetch "old-session")
                                 :type 'user-error)
                                (should-not dsh-emacs--command-fetch-inflight)
                                (should-not dsh-emacs--skill-fetch-inflight)))
                    (if (eq kind 'upload)
                        (dsh-emacs--http-post
                         "http://old.example/upload" "application/octet-stream"
                         "file" #'done)
                      (dsh-emacs--rpc-async "session/list" nil
                                            (lambda (ok _value) (done ok))))
                    (dsh-emacs-server-stop)
                    (with-current-buffer response
                      (funcall received
                               (and (= status 401) '(:error (error http 401)))))
                    (should (= calls 1))
                    (should-not result)))
                (should (= sent 1))
                (should (equal dsh-emacs--server-auth-cookie "same-cookie"))
                (should-not (buffer-live-p response)))
            (when (buffer-live-p response) (kill-buffer response))))))))

(ert-deftest dsh-emacs-test-rpc-rechecks-owner-after-authentication ()
  :tags '(dsh-unit)
  (dolist (kind '(sync async))
    (let ((dsh-emacs--server-generation 0)
          (dsh-emacs--server-process nil)
          (dsh-emacs--server-alive-check nil)
          (sent 0))
      (cl-letf (((symbol-function 'dsh-emacs--server-auth-header)
                 (lambda (&rest _) (dsh-emacs-server-stop) nil))
                ((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _) (cl-incf sent) nil))
                ((symbol-function 'url-retrieve)
                 (lambda (&rest _) (cl-incf sent) nil)))
        (should-error
         (if (eq kind 'sync)
             (dsh-emacs--rpc-request "session/list" nil)
           (dsh-emacs--rpc-async "session/list" nil #'ignore))
         :type 'user-error)
        (should (= sent 0))))))

(ert-deftest dsh-emacs-test-rpc-owner-expires-during-response-cleanup ()
  :tags '(dsh-unit)
  (dolist (kind '(sync async))
    (dolist (stage '(decode cleanup))
      (let ((dsh-emacs--server-generation 0)
            (dsh-emacs--server-process nil)
            (dsh-emacs--server-alive-check nil)
            (response (generate-new-buffer " *dsh-response-reentry*"))
            (result :not-called))
        (unwind-protect
            (cl-letf (((symbol-function 'dsh-emacs--server-auth-header) #'ignore)
                      ((symbol-function 'dsh-emacs--decode-response-body)
                       (lambda ()
                         (when (eq stage 'decode) (dsh-emacs-server-stop))
                         '((result . ((ok . t) (value . 19))))))
                      ((symbol-function 'url-retrieve-synchronously)
                       (lambda (&rest _) response))
                      ((symbol-function 'url-retrieve)
                       (lambda (_url callback &rest _)
                         (with-current-buffer response (funcall callback nil)))))
              (with-current-buffer response
                (insert "HTTP/1.1 200 OK\n\n{}")
                (when (eq stage 'cleanup)
                  (add-hook 'kill-buffer-hook #'dsh-emacs-server-stop nil t)))
              (if (eq kind 'sync)
                  (setq result (car (dsh-emacs--rpc-request "session/list" nil)))
                (dsh-emacs--rpc-async "session/list" nil
                                      (lambda (ok _value) (setq result ok))))
              (should-not result)
              (should-not (buffer-live-p response)))
          (when (buffer-live-p response) (kill-buffer response)))))))

(ert-deftest dsh-emacs-test-rpc-outbound-json-ignores-user-settings ()
  :tags '(dsh-unit)
  (let ((json-null :user-null)
        (json-false :user-false)
        (json-encoding-pretty-print t)
        (json-encoding-separator ";")
        (json-encoding-object-sort-predicate #'string>))
    (dolist (encode
             (list (lambda (args)
                     (dsh-protocol-rpc-request-json "test/write" "rpc-1" args))
                   (lambda (args)
                     (dsh-protocol-mux-open-json
                      "stream-1" "test/follow" args))))
      (should (string-match-p "\"payload\":{\"args\":{}}"
                              (funcall encode nil)))
      (should (string-match-p "\"args\":{\"_request\":{}}"
                              (funcall encode
                                       (dsh-protocol-session-list-request))))
      (let* ((args '((request . ((enabled . t) (disabled . :json-false)
                                (missing . nil) (empty . [])
                                (labels . ("first" "second"))))))
             (json (funcall encode args))
             (wire (dsh-protocol-read-json json)))
        (should-not (string-match-p "\n" json))
        (should (equal (cdr (assq 'args (cdr (assq 'payload wire))))
                       '((request . ((enabled . t) (disabled . :json-false)
                                     (missing . nil) (empty . [])
                                     (labels . ["first" "second"])))))))
      (let* ((answers '(((id . "q1") (selected . ("A" "B")))
                        ((id . "q2") (selected . []) (custom . "Other"))))
             (wire (dsh-protocol-read-json
                    (funcall encode `((answer . ((answers . ,answers))))))))
        (should (equal (cdr (assq 'args (cdr (assq 'payload wire))))
                       '((answer . ((answers . [((id . "q1")
                                                 (selected . ["A" "B"]))
                                                ((id . "q2") (selected . [])
                                                 (custom . "Other"))]))))))))
    (should (equal (dsh-protocol-mux-cancel-json "stream-1")
                   "{\"type\":\"cancel\",\"streamId\":\"stream-1\"}"))))

(ert-deftest dsh-emacs-test-rpc-transports-send-fixed-json-as-utf8 ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://rpc.example")
        (json-null :user-null)
        (json-false :user-false)
        (json-encoding-pretty-print t)
        (json-encoding-separator ";")
        (args '((text . "中文 😊") (missing) (flag . :json-false) (items . [])))
        (calls 0))
    (cl-labels
        ((response (url)
           (should (equal url "http://rpc.example/api/test/write"))
           (should-not (multibyte-string-p url-request-data))
           (let ((json (decode-coding-string url-request-data 'utf-8)))
             (should-not (string-match-p "\n" json))
             (should (equal (dsh-protocol-read-json json)
                            `((type . "client-request") (rpcId . "rpc-1")
                              (method . "test/write")
                              (payload . ((args . ,args)))))))
           (setq calls (1+ calls))
           (let ((buffer (generate-new-buffer " *dsh-outbound-test*")))
             (with-current-buffer buffer
               (insert "HTTP/1.1 200 OK\n\n{\"result\":{\"ok\":true,\"value\":17}}"))
             buffer)))
      (cl-letf (((symbol-function 'dsh-emacs--server-auth-header) #'ignore)
                ((symbol-function 'dsh-emacs--rpc-id) (lambda () "rpc-1"))
                ((symbol-function 'url-retrieve-synchronously)
                 (lambda (url &rest _) (response url)))
                ((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _)
                   (with-current-buffer (response url) (funcall callback nil)))))
        (should (equal (dsh-emacs--rpc-request "test/write" args) '(t . 17)))
        (let (result)
          (dsh-emacs--rpc-async "test/write" args
                                (lambda (ok value) (setq result (cons ok value))))
          (should (equal result '(t . 17))))
        (should (= calls 2))))))

;; --- Test 14: RPC JSON booleans and empty payload ---
(ert-deftest dsh-emacs-test-rpc-rpc-empty-payload-is-object ()
  :tags '(dsh-unit)
  (let ((request (dsh-protocol-rpc-request-json "session/list" "rpc-1" nil)))
    (ert-info ((format "%s" "rpc-empty-payload-is-object"))
      (should (string-match-p "\"payload\":{\"args\":{}}" request)))))

;; --- Test 14b: session/list carries the _request argument (real 0.1.2
;; descriptor) ---
;; In 0.1.2-rc.1 the sole argument of `session/list' is named `_request' (an empty
;; list request object), not `request' as in the other session methods. Sending
;; `{}' is rejected by the server (`missing "_request"'); args must carry the
;; `_request' key with value `{}'.
(ert-deftest dsh-emacs-test-rpc-session-list-args-carries-request ()
  :tags '(dsh-unit)
  (let* ((args (dsh-protocol-session-list-request))
         (wrap (dsh-protocol-rpc-request-json "session/list" "rpc-1" args)))
    (ert-info ((format "%s" "session-list-args-carries-_request"))
      (should (and (= 1 (length args))
                   (eq '_request (car (car args))))))
    (ert-info ((format "%s" "session-list-wrap-encodes-_request-object"))
      (should (string-match-p "\"args\":{\"_request\":{}}" wrap)))))

(ert-deftest dsh-emacs-test-rpc-rpc-false-result-is-error ()
  :tags '(dsh-unit)
  (let* ((response (json-read-from-string
                    "{\"result\":{\"ok\":false,\"error\":{\"code\":\"bad-request\"}}}"))
         (unwrapped (dsh-protocol-rpc-result--from-alist response)))
    (ert-info ((format "%s" "rpc-false-result-is-error"))
      (should (and (not (car unwrapped))
                   (equal (cdr (assq 'code (cdr unwrapped))) "bad-request"))))))

;; Native and Lisp wire readers must preserve the same protocol shapes,
;; independently of a user's json.el customization.
(ert-deftest dsh-emacs-test-rpc-wire-json-string-shapes-native-case ()
  :tags '(dsh-unit)
  (dolist (native (if (and (fboundp 'json-available-p) (json-available-p))
                      '(t nil) '(nil)))
    (let ((json-object-type 'hash-table)
          (json-array-type 'list)
          (json-key-type 'string)
          (json-null :custom-null)
          (json-false :custom-false)
          (json (concat "{\"items\":[{\"sessionId\":\"s\",\"title\":\"中文 😊\","
                        "\"blank\":false,\"running\":true,\"value\":null,"
                        "\"array\":[],\"object\":{},\"count\":42,\"ratio\":1.25}]}"))
          (expected '((items . [((sessionId . "s") (title . "中文 😊")
                                 (blank . :json-false) (running . t) (value)
                                 (array . []) (object) (count . 42)
                                 (ratio . 1.25))]))))
      (cl-letf (((symbol-function 'json-available-p) (lambda () native)))
        (ert-info ((format "%s" (format "wire-json-string-shapes-native-%s" native)))
          (should (equal expected (dsh-protocol-read-json json))))
        (with-temp-buffer
          (insert "prefix " json)
          (goto-char 8)
          (ert-info ((format "%s" (format "wire-json-buffer-shapes-native-%s" native)))
            (should (equal expected (dsh-protocol-read-json)))
            (should (eobp))))
        (dolist (bad '("{\"items\":[" "{\"ok\":tru}" "\"unterminated"))
          (ert-info ((format "%s" (format "wire-json-rejects-malformed-native-%s" native)))
            (should (condition-case nil (progn (dsh-protocol-read-json bad) nil)
                      (error t)))
            (should (with-temp-buffer
                      (insert bad)
                      (goto-char (point-min))
                      (condition-case nil (progn (dsh-protocol-read-json) nil)
                        (error t))))))))))

;; --- Test 15: JSON arrays and working directory ---
(ert-deftest dsh-emacs-test-rpc-json-array-and-symbol-keys-supported ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "json-array-and-symbol-keys-supported"))
    (should (and (equal '(a b) (dsh-protocol--list [a b]))
                 (equal "assistant/message"
                        (dsh-protocol--field "type"
                                                '((type . "assistant/message"))))))))

(ert-deftest dsh-emacs-test-rpc-client-time-zone-is-iana ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "client-time-zone-is-iana"))
    (should (and (stringp (dsh-emacs--client-time-zone))
                 (not (string-empty-p (dsh-emacs--client-time-zone)))
                 (dsh-emacs--valid-iana-time-zone-p
                  (dsh-emacs--client-time-zone))))))

(ert-deftest dsh-emacs-test-rpc-ambiguous-time-zone-is-replaced ()
  :tags '(dsh-unit)
  (let ((process-environment (cons "TZ=CST" process-environment)))
    (ert-info ((format "%s" "ambiguous-time-zone-is-replaced"))
      (should (dsh-emacs--valid-iana-time-zone-p
               (dsh-emacs--client-time-zone))))))

;; --- Test 18: UTF-8 response decoding ---
(ert-deftest dsh-emacs-test-rpc-rpc-response-decodes-utf8 ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (encode-coding-string "\"你好 😊\"" 'utf-8))
    (goto-char (point-min))
    (should (equal (dsh-emacs--decode-response-body) "你好 😊"))
    (should enable-multibyte-characters)))

;; --- Test 93f: http-error-hint gives auth guidance for 401 ---
(ert-deftest dsh-emacs-test-rpc-http-error-hint-401-mentions-auth ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "http-error-hint-401-mentions-auth"))
    (should (string-match-p "401"
                            (dsh-emacs--http-error-hint '(error http 401))))))

;; RPC auth failure does not enter Basic interaction; the sync path must read the
;; HTTP status rather than parse the error page. Async responses are dispatched
;; after the request's dynamic bindings have exited, mimicking url's buffer-local
;; configuration.
(ert-deftest dsh-emacs-test-rpc-rpc-case-http-case-auth-result ()
  :tags '(dsh-unit)
  (dolist (mode '(sync async))
    (dolist (status '(200 401 403))
      (let ((dsh-emacs-base-url "http://rpc.example:3080")
            (dsh-emacs--server-auth-cookie "dsh-auth-RPC=cached")
            (url-request-noninteractive nil)
            (url-registered-auth-schemes nil)
            (response nil)
            (pending nil)
            (request-headers nil)
            (inhibited-cookies nil)
            (challenges nil)
            (result 'not-called))
        (url-register-auth-scheme "basic" nil 4)
        (cl-labels
            ((make-response (url)
               (setq request-headers url-request-extra-headers
                     response (generate-new-buffer " *dsh-rpc-auth-test*"))
               (with-current-buffer response
                 (setq-local url-http-response-status status)
                 (setq-local url-current-object (url-generic-parse-url url))
                 (setq-local url-http-extra-headers request-headers)
                 (setq-local url-http-noninteractive url-request-noninteractive)
                 (insert (format "HTTP/1.1 %d Test\n\n" status)
                         (if (= status 200)
                             "{\"result\":{\"ok\":true,\"value\":\"accepted\"}}"
                           "Authentication failed")))
               response)
             (authenticate ()
               (when (= status 401)
                 (with-current-buffer response
                   (url-http-handle-authentication nil)))))
          (cl-letf (((symbol-function 'url-get-authentication)
                     (lambda (_url _realm type prompt &rest _)
                       (push (list type prompt
                                   (not (or url-request-noninteractive
                                            url-http-noninteractive)))
                             challenges)
                       nil))
                    ((symbol-function 'url-retrieve-synchronously)
                     (lambda (url &optional _silent inhibit-cookies &rest _)
                       (setq inhibited-cookies inhibit-cookies)
                       (make-response url)
                       (authenticate)
                       response))
                    ((symbol-function 'url-retrieve)
                     (lambda (url callback &optional _args _silent inhibit-cookies)
                       (setq pending callback
                             inhibited-cookies inhibit-cookies)
                       (make-response url))))
            (unwind-protect
                (progn
                  (if (eq mode 'sync)
                      (setq result (dsh-emacs--rpc-request "session/list" nil))
                    (dsh-emacs--rpc-async
                     "session/list" nil
                     (lambda (ok value) (setq result (cons ok value))))
                    (authenticate)
                    (with-current-buffer response
                      (funcall pending (when (>= status 400)
                                         (list :error (list 'error 'http status))))))
                  (ert-info ((format "%s" (format "rpc-%s-http-%s-auth-result" mode status)))
                    (should (equal result (if (= status 200) '(t . "accepted") '(nil))))
                    (should (equal (cdr (assoc "Cookie" request-headers))
                                   "dsh-auth-RPC=cached"))
                    (should (eq inhibited-cookies t))
                    (should (equal challenges (and (= status 401) '(("basic" t nil)))))
                    (should (equal dsh-emacs--server-auth-cookie
                                   (unless (= status 401) "dsh-auth-RPC=cached")))
                    (should (not (buffer-live-p response)))))
              (when (buffer-live-p response) (kill-buffer response)))))))))

(ert-deftest dsh-emacs-test-rpc-late-401-preserves-replacement-auth ()
  :tags '(dsh-unit)
  (dolist (mode '(sync async closed-origin))
    (dolist (scenario '(replaced unauthenticated other-server current))
      (ert-info ((format "%s / %s" mode scenario))
        (let* ((dsh-emacs-base-url "http://old.example:3080")
               (sent (unless (eq scenario 'unauthenticated)
                       "dsh-auth-test=old"))
               (replacement (if (memq scenario '(other-server current))
                                sent
                              "dsh-auth-test=new"))
               (dsh-emacs--server-auth-cookie sent)
               (origin (generate-new-buffer " *dsh-late-401-origin*"))
               (response (generate-new-buffer " *dsh-late-401-response*"))
               (pending nil)
               (calls 0)
               (result 'not-called))
          (cl-labels
              ((replace-auth ()
                 (setq dsh-emacs--server-auth-cookie replacement)
                 (when (eq scenario 'other-server)
                   (setq dsh-emacs-base-url "http://new.example:3080")))
               (capture-request (url)
                 (should (equal url "http://old.example:3080/api/session/list"))
                 (should (equal (cdr (assoc "Cookie" url-request-extra-headers))
                                sent))))
            (unwind-protect
                (cl-letf (((symbol-function 'dsh-emacs--server-auth-header)
                           (lambda () (when sent (list (cons "Cookie" sent)))))
                          ((symbol-function 'url-retrieve-synchronously)
                           (lambda (url &rest _)
                             (capture-request url)
                             ;; Synchronous HTTP also yields to other work.
                             (replace-auth)
                             response))
                          ((symbol-function 'url-retrieve)
                           (lambda (url callback &rest _)
                             (capture-request url)
                             (setq pending callback)
                             response)))
                  (with-current-buffer response
                    (setq-local url-http-response-status 401)
                    (insert "HTTP/1.1 401 Unauthorized\n\n"))
                  (with-current-buffer origin
                    (if (eq mode 'sync)
                        (setq result (dsh-emacs--rpc-request "session/list" nil))
                      (dsh-emacs--rpc-async
                       "session/list" nil
                       (lambda (ok value)
                         (should (eq (current-buffer) origin))
                         (cl-incf calls)
                         (setq result (cons ok value))))))
                  (unless (eq mode 'sync)
                    (replace-auth)
                    (when (eq mode 'closed-origin) (kill-buffer origin))
                    (with-current-buffer response
                      (funcall pending '(:error (error http 401)))))
                  (should (equal dsh-emacs--server-auth-cookie
                                 (unless (eq scenario 'current) replacement)))
                  (should (equal result (if (eq mode 'closed-origin)
                                            'not-called
                                          '(nil))))
                  (should (= calls (if (eq mode 'async) 1 0)))
                  (should-not (buffer-live-p response)))
              (when (buffer-live-p origin) (kill-buffer origin))
              (when (buffer-live-p response) (kill-buffer response)))))))))

(ert-deftest dsh-emacs-test-rpc-response-and-callback-contracts ()
  :tags '(dsh-unit)
  (dolist (mode '(sync async))
    (dolist (body '("{\"result\":{\"ok\":true,\"value\":\"中文 😊\"}}"
                    "{\"result\":{\"ok\":false,\"error\":\"denied\"}}"
                    "{broken" "" "truncated-headers"))
      (let ((dsh-emacs-base-url "http://rpc.example:3080")
            (response nil)
            (pending nil)
            (origin (current-buffer))
            (seen-buffer nil)
            (calls 0)
            (result 'not-called))
        (cl-labels
            ((make-response ()
               (setq response (generate-new-buffer " *dsh-rpc-response-test*"))
               (with-current-buffer response
                 (set-buffer-multibyte nil)
                 (insert (encode-coding-string
                          (if (equal body "truncated-headers")
                              "HTTP/1.1 200 OK\r\nContent-Type: application/json"
                            (concat "HTTP/1.1 200 OK\n\n" body))
                          'utf-8)))
               response))
          (cl-letf (((symbol-function 'dsh-emacs--server-auth-header) #'ignore)
                    ((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _) (make-response)))
                    ((symbol-function 'url-retrieve)
                     (lambda (_url callback &rest _)
                       (setq pending callback)
                       (make-response))))
            (unwind-protect
                (progn
                  (if (eq mode 'sync)
                      (setq result (dsh-emacs--rpc-request "test/read" nil))
                    (dsh-emacs--rpc-async
                     "test/read" nil
                     (lambda (ok value)
                       (setq seen-buffer (current-buffer)
                             calls (1+ calls)
                             result (cons ok value))))
                    (with-current-buffer response (funcall pending nil)))
                  (should (equal result
                                 (cond ((string-match-p "true" body)
                                        '(t . "中文 😊"))
                                       ((string-match-p "false" body)
                                        '(nil . "denied"))
                                       (t '(nil)))))
                  (should-not (buffer-live-p response))
                  (when (eq mode 'async)
                    (should (= calls 1))
                    (should (eq seen-buffer origin))))
              (when (buffer-live-p response) (kill-buffer response)))))))))

(ert-deftest dsh-emacs-test-rpc-post-callback-lifetime-and-binary-body ()
  :tags '(dsh-unit)
  (dolist (outcome '(success dead error quit))
    (let ((origin (generate-new-buffer " *dsh-post-origin*"))
          (response (generate-new-buffer " *dsh-post-response*"))
          (body (unibyte-string 0 128 255))
          (pending nil)
          (calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs--server-auth-header) #'ignore)
                    ((symbol-function 'url-retrieve)
                     (lambda (url callback _args silent inhibit-cookies)
                       (should (equal url "http://rpc.example/api/upload"))
                       (should (eq url-request-data body))
                       (should (equal url-request-method "POST"))
                       (should (equal url-request-extra-headers
                                      '(("Content-Type" . "application/octet-stream"))))
                       (should url-request-noninteractive)
                       (should silent)
                       (should inhibit-cookies)
                       (setq pending callback))))
            (with-current-buffer response
              (insert "HTTP/1.1 200 OK\n\n{\"receipt\":\"file-1\"}"))
            (with-current-buffer origin
              (dsh-emacs--http-post
               "http://rpc.example/api/upload" "application/octet-stream" body
               (lambda (value)
                 (should (eq (current-buffer) origin))
                 (should-not (buffer-live-p response))
                 (should (equal value '((receipt . "file-1"))))
                 (setq calls (1+ calls))
                 (pcase outcome
                   ('error (error "callback failure"))
                   ('quit (signal 'quit nil))))))
            (when (eq outcome 'dead) (kill-buffer origin))
            (if (eq outcome 'error)
                (should-error (with-current-buffer response (funcall pending nil))
                              :type 'error)
              (with-current-buffer response (funcall pending nil)))
            (should (= calls (if (eq outcome 'dead) 0 1)))
            (should-not (buffer-live-p response)))
        (when (buffer-live-p response) (kill-buffer response))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest dsh-emacs-test-rpc-server-loads-without-entry-point ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (should
     (zerop
      (call-process
       (expand-file-name invocation-name invocation-directory)
       nil t nil "-Q" "--batch" "-L" dsh-emacs-test-root
       "--eval"
       (prin1-to-string
        '(progn
           (require 'dsh-emacs-server)
           (unless (and (fboundp 'dsh-emacs--rpc-request)
                        (fboundp 'dsh-emacs--rpc-async)
                        (fboundp 'dsh-emacs--http-post)
                        (not (featurep 'dsh-emacs))
                        (not (featurep 'dsh-emacs-render)))
             (error "HTTP transport depends on the entry point")))))))
    (should (equal (buffer-string) ""))))

(ert-deftest dsh-emacs-test-rpc-transport-authentication-headers ()
  :tags '(dsh-unit)
  (dolist (scheme '("http" "https"))
    (dolist (cookie '(nil "dsh-auth-test=cached"))
      (let* ((dsh-emacs-base-url
              (format "%s://alice:secret@rpc.example:3080" scheme))
             (expected (append '(("Content-Type" . "application/json"))
                               (and cookie (list (cons "Cookie" cookie)))))
             (calls 0)
             (sent nil))
        (cl-labels
            ((response (url)
               (should (equal url (concat dsh-emacs-base-url "/api/test/read")))
               (should (equal url-request-extra-headers expected))
               (should url-request-noninteractive)
               (setq calls (1+ calls))
               (let ((buffer (generate-new-buffer " *dsh-auth-headers*")))
                 (with-current-buffer buffer
                   (insert "HTTP/1.1 200 OK\n\n{\"result\":{\"ok\":true,\"value\":17}}"))
                 buffer)))
          (cl-letf (((symbol-function 'dsh-emacs--server-auth-cookie-header)
                     (lambda () cookie))
                    ((symbol-function 'url-retrieve-synchronously)
                     (lambda (url _silent inhibit-cookies &rest _)
                       (should inhibit-cookies)
                       (response url)))
                    ((symbol-function 'url-retrieve)
                     (lambda (url callback _args _silent inhibit-cookies)
                       (should inhibit-cookies)
                       (with-current-buffer (response url)
                         (funcall callback nil))))
                    ((symbol-function 'process-send-string)
                     (lambda (_process text) (setq sent text))))
            (should (equal (dsh-emacs--rpc-request "test/read" nil) '(t . 17)))
            (let (result)
              (dsh-emacs--rpc-async "test/read" nil
                                    (lambda (ok value) (setq result (cons ok value))))
              (should (equal result '(t . 17))))
            (should (= calls 2))
            (let ((process (dsh-test--event-process :name "handshake-test" :noquery t)))
              (unwind-protect (dsh-emacs-events--send-handshake process)
                (delete-process process)))
            (should (string-match-p
                     (regexp-quote "Authorization: Basic YWxpY2U6c2VjcmV0\r\n")
                     sent))
            (should (equal (and (string-match "Cookie: \\([^\r\n]+\\)\r\n" sent)
                                (match-string 1 sent))
                           cookie))))))))

(provide 'dsh-test-rpc)
;;; dsh-test-rpc.el ends here
