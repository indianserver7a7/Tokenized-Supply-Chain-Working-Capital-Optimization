;; Financing Optimization Contract
;; Matches capital providers with requirements and optimizes financing terms

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u300))
(define-constant err-not-found (err u301))
(define-constant err-invalid-input (err u302))
(define-constant err-unauthorized (err u303))
(define-constant err-insufficient-funds (err u304))
(define-constant err-already-exists (err u305))
(define-constant err-expired (err u306))

;; Data Variables
(define-data-var next-request-id uint u1)
(define-data-var next-offer-id uint u1)
(define-data-var platform-fee-rate uint u100) ;; 1% in basis points

;; Data Maps
(define-map financing-requests
  { request-id: uint }
  {
    borrower: principal,
    amount-needed: uint,
    term-days: uint,
    max-interest-rate: uint, ;; In basis points (100 = 1%)
    purpose: (string-ascii 100),
    collateral-offered: uint,
    request-date: uint,
    expiry-date: uint,
    status: (string-ascii 20), ;; pending, matched, funded, cancelled
    risk-assessment: uint
  }
)

(define-map financing-offers
  { offer-id: uint }
  {
    lender: principal,
    amount-available: uint,
    min-term-days: uint,
    max-term-days: uint,
    interest-rate: uint, ;; In basis points
    min-credit-score: uint,
    offer-date: uint,
    expiry-date: uint,
    status: (string-ascii 20) ;; active, matched, withdrawn
  }
)

(define-map financing-matches
  { request-id: uint, offer-id: uint }
  {
    matched-amount: uint,
    final-interest-rate: uint,
    term-days: uint,
    match-date: uint,
    status: (string-ascii 20), ;; matched, accepted, funded, completed
    repayment-due-date: uint
  }
)

(define-map active-loans
  { loan-id: uint }
  {
    borrower: principal,
    lender: principal,
    principal-amount: uint,
    interest-rate: uint,
    term-days: uint,
    start-date: uint,
    due-date: uint,
    amount-repaid: uint,
    status: (string-ascii 20) ;; active, defaulted, completed
  }
)

(define-data-var next-loan-id uint u1)

;; Public Functions

;; Create financing request
(define-public (create-financing-request (amount-needed uint) (term-days uint) (max-interest-rate uint) (purpose (string-ascii 100)) (collateral-offered uint))
  (let
    (
      (request-id (var-get next-request-id))
      (expiry-date (+ block-height u1440)) ;; Expires in ~10 days
    )
    (asserts! (> amount-needed u0) err-invalid-input)
    (asserts! (and (>= term-days u7) (<= term-days u365)) err-invalid-input) ;; 7 days to 1 year
    (asserts! (<= max-interest-rate u5000) err-invalid-input) ;; Max 50% interest rate

    (map-set financing-requests
      { request-id: request-id }
      {
        borrower: tx-sender,
        amount-needed: amount-needed,
        term-days: term-days,
        max-interest-rate: max-interest-rate,
        purpose: purpose,
        collateral-offered: collateral-offered,
        request-date: block-height,
        expiry-date: expiry-date,
        status: "pending",
        risk-assessment: u500 ;; Default risk score
      }
    )

    (var-set next-request-id (+ request-id u1))
    (ok request-id)
  )
)

;; Provide financing offer
(define-public (provide-financing (amount-available uint) (min-term-days uint) (max-term-days uint) (interest-rate uint) (min-credit-score uint))
  (let
    (
      (offer-id (var-get next-offer-id))
      (expiry-date (+ block-height u2880)) ;; Expires in ~20 days
    )
    (asserts! (> amount-available u0) err-invalid-input)
    (asserts! (<= min-term-days max-term-days) err-invalid-input)
    (asserts! (<= interest-rate u5000) err-invalid-input) ;; Max 50% interest rate
    (asserts! (<= min-credit-score u1000) err-invalid-input)

    (map-set financing-offers
      { offer-id: offer-id }
      {
        lender: tx-sender,
        amount-available: amount-available,
        min-term-days: min-term-days,
        max-term-days: max-term-days,
        interest-rate: interest-rate,
        min-credit-score: min-credit-score,
        offer-date: block-height,
        expiry-date: expiry-date,
        status: "active"
      }
    )

    (var-set next-offer-id (+ offer-id u1))
    (ok offer-id)
  )
)

;; Optimize and match financing terms
(define-public (optimize-terms (request-id uint) (offer-id uint))
  (let
    (
      (request (unwrap! (map-get? financing-requests { request-id: request-id }) err-not-found))
      (offer (unwrap! (map-get? financing-offers { offer-id: offer-id }) err-not-found))
      (optimized-rate (calculate-optimized-rate request offer))
      (matched-amount (min (get amount-needed request) (get amount-available offer)))
    )
    ;; Check if request and offer are compatible
    (asserts! (is-eq (get status request) "pending") err-invalid-input)
    (asserts! (is-eq (get status offer) "active") err-invalid-input)
    (asserts! (<= (get expiry-date request) block-height) err-expired)
    (asserts! (<= (get expiry-date offer) block-height) err-expired)
    (asserts! (and (>= (get term-days request) (get min-term-days offer))
                   (<= (get term-days request) (get max-term-days offer))) err-invalid-input)
    (asserts! (<= optimized-rate (get max-interest-rate request)) err-invalid-input)

    (map-set financing-matches
      { request-id: request-id, offer-id: offer-id }
      {
        matched-amount: matched-amount,
        final-interest-rate: optimized-rate,
        term-days: (get term-days request),
        match-date: block-height,
        status: "matched",
        repayment-due-date: (+ block-height (* (get term-days request) u144))
      }
    )

    ;; Update request and offer status
    (map-set financing-requests
      { request-id: request-id }
      (merge request { status: "matched" })
    )

    (map-set financing-offers
      { offer-id: offer-id }
      (merge offer { status: "matched" })
    )

    (ok { request-id: request-id, offer-id: offer-id, rate: optimized-rate, amount: matched-amount })
  )
)

;; Execute financing agreement
(define-public (execute-financing (request-id uint) (offer-id uint))
  (let
    (
      (match-info (unwrap! (map-get? financing-matches { request-id: request-id, offer-id: offer-id }) err-not-found))
      (request (unwrap! (map-get? financing-requests { request-id: request-id }) err-not-found))
      (offer (unwrap! (map-get? financing-offers { offer-id: offer-id }) err-not-found))
      (loan-id (var-get next-loan-id))
    )
    (asserts! (is-eq (get status match-info) "matched") err-invalid-input)
    (asserts! (or (is-eq tx-sender (get borrower request)) (is-eq tx-sender (get lender offer))) err-unauthorized)

    ;; Create active loan record
    (map-set active-loans
      { loan-id: loan-id }
      {
        borrower: (get borrower request),
        lender: (get lender offer),
        principal-amount: (get matched-amount match-info),
        interest-rate: (get final-interest-rate match-info),
        term-days: (get term-days match-info),
        start-date: block-height,
        due-date: (get repayment-due-date match-info),
        amount-repaid: u0,
        status: "active"
      }
    )

    ;; Update match status
    (map-set financing-matches
      { request-id: request-id, offer-id: offer-id }
      (merge match-info { status: "funded" })
    )

    ;; Update request status
    (map-set financing-requests
      { request-id: request-id }
      (merge request { status: "funded" })
    )

    (var-set next-loan-id (+ loan-id u1))
    (ok loan-id)
  )
)

;; Process loan repayment
(define-public (repay-loan (loan-id uint) (amount uint))
  (let
    (
      (loan (unwrap! (map-get? active-loans { loan-id: loan-id }) err-not-found))
      (total-due (calculate-total-due loan))
      (current-repaid (get amount-repaid loan))
      (new-repaid (+ current-repaid amount))
    )
    (asserts! (is-eq tx-sender (get borrower loan)) err-unauthorized)
    (asserts! (is-eq (get status loan) "active") err-invalid-input)
    (asserts! (> amount u0) err-invalid-input)

    (map-set active-loans
      { loan-id: loan-id }
      (merge loan {
        amount-repaid: new-repaid,
        status: (if (>= new-repaid total-due) "completed" "active")
      })
    )

    (ok new-repaid)
  )
)

;; Private Functions

;; Calculate optimized interest rate
(define-private (calculate-optimized-rate (request { borrower: principal, amount-needed: uint, term-days: uint, max-interest-rate: uint, purpose: (string-ascii 100), collateral-offered: uint, request-date: uint, expiry-date: uint, status: (string-ascii 20), risk-assessment: uint })
                                         (offer { lender: principal, amount-available: uint, min-term-days: uint, max-term-days: uint, interest-rate: uint, min-credit-score: uint, offer-date: uint, expiry-date: uint, status: (string-ascii 20) }))
  (let
    (
      (base-rate (get interest-rate offer))
      (risk-adjustment (/ (get risk-assessment request) u20)) ;; Risk adjustment factor
      (collateral-discount (if (> (get collateral-offered request) u0) u50 u0)) ;; 0.5% discount for collateral
      (optimized-rate (- (+ base-rate risk-adjustment) collateral-discount))
    )
    (min optimized-rate (get max-interest-rate request))
  )
)

;; Calculate total amount due including interest
(define-private (calculate-total-due (loan { borrower: principal, lender: principal, principal-amount: uint, interest-rate: uint, term-days: uint, start-date: uint, due-date: uint, amount-repaid: uint, status: (string-ascii 20) }))
  (let
    (
      (principal (get principal-amount loan))
      (rate (get interest-rate loan))
      (days (get term-days loan))
      (interest (/ (* (* principal rate) days) (* u10000 u365))) ;; Simple interest calculation
    )
    (+ principal interest)
  )
)

;; Read-only Functions

;; Get financing request
(define-read-only (get-financing-request (request-id uint))
  (map-get? financing-requests { request-id: request-id })
)

;; Get financing offer
(define-read-only (get-financing-offer (offer-id uint))
  (map-get? financing-offers { offer-id: offer-id })
)

;; Get financing match
(define-read-only (get-financing-match (request-id uint) (offer-id uint))
  (map-get? financing-matches { request-id: request-id, offer-id: offer-id })
)

;; Get active loan
(define-read-only (get-active-loan (loan-id uint))
  (map-get? active-loans { loan-id: loan-id })
)

;; Calculate loan payment due
(define-read-only (get-loan-payment-due (loan-id uint))
  (match (map-get? active-loans { loan-id: loan-id })
    loan (some (- (calculate-total-due loan) (get amount-repaid loan)))
    none
  )
)

;; Get next request ID
(define-read-only (get-next-request-id)
  (var-get next-request-id)
)

;; Get next offer ID
(define-read-only (get-next-offer-id)
  (var-get next-offer-id)
)

;; Get next loan ID
(define-read-only (get-next-loan-id)
  (var-get next-loan-id)
)

;; Min function helper
(define-private (min (a uint) (b uint))
  (if (<= a b) a b)
)
