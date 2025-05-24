;; Payment Terms Contract
;; Manages extended payment arrangements and terms

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u400))
(define-constant err-not-found (err u401))
(define-constant err-invalid-input (err u402))
(define-constant err-unauthorized (err u403))
(define-constant err-payment-overdue (err u404))
(define-constant err-already-paid (err u405))
(define-constant err-dispute-exists (err u406))

;; Data Variables
(define-data-var next-terms-id uint u1)
(define-data-var next-dispute-id uint u1)

;; Data Maps
(define-map payment-terms
  { terms-id: uint }
  {
    payer: principal,
    payee: principal,
    total-amount: uint,
    payment-schedule: (string-ascii 20), ;; immediate, milestone, installment
    milestone-count: uint,
    installment-count: uint,
    interest-rate: uint, ;; For late payments
    grace-period-days: uint,
    creation-date: uint,
    final-due-date: uint,
    status: (string-ascii 20), ;; active, completed, defaulted, disputed
    collateral-required: uint,
    early-payment-discount: uint
  }
)

(define-map payment-milestones
  { terms-id: uint, milestone-id: uint }
  {
    description: (string-ascii 100),
    amount: uint,
    due-date: uint,
    completion-criteria: (string-ascii 200),
    status: (string-ascii 20), ;; pending, completed, overdue
    payment-date: (optional uint),
    amount-paid: uint
  }
)

(define-map payment-installments
  { terms-id: uint, installment-id: uint }
  {
    amount: uint,
    due-date: uint,
    status: (string-ascii 20), ;; pending, paid, overdue
    payment-date: (optional uint),
    amount-paid: uint,
    late-fee: uint
  }
)

(define-map payment-disputes
  { dispute-id: uint }
  {
    terms-id: uint,
    disputing-party: principal,
    dispute-reason: (string-ascii 200),
    disputed-amount: uint,
    creation-date: uint,
    status: (string-ascii 20), ;; open, resolved, escalated
    resolution: (optional (string-ascii 200)),
    resolver: (optional principal)
  }
)

(define-map authorized-arbitrators
  { arbitrator: principal }
  { authorized: bool, added-at: uint }
)

;; Public Functions

;; Create payment terms
(define-public (create-payment-terms (payee principal) (total-amount uint) (payment-schedule (string-ascii 20))
                                   (milestone-count uint) (installment-count uint) (interest-rate uint)
                                   (grace-period-days uint) (final-due-date uint) (collateral-required uint)
                                   (early-payment-discount uint))
  (let
    (
      (terms-id (var-get next-terms-id))
    )
    (asserts! (> total-amount u0) err-invalid-input)
    (asserts! (> final-due-date block-height) err-invalid-input)
    (asserts! (<= interest-rate u2000) err-invalid-input) ;; Max 20% interest
    (asserts! (<= grace-period-days u90) err-invalid-input) ;; Max 90 days grace
    (asserts! (<= early-payment-discount u1000) err-invalid-input) ;; Max 10% discount

    (map-set payment-terms
      { terms-id: terms-id }
      {
        payer: tx-sender,
        payee: payee,
        total-amount: total-amount,
        payment-schedule: payment-schedule,
        milestone-count: milestone-count,
        installment-count: installment-count,
        interest-rate: interest-rate,
        grace-period-days: grace-period-days,
        creation-date: block-height,
        final-due-date: final-due-date,
        status: "active",
        collateral-required: collateral-required,
        early-payment-discount: early-payment-discount
      }
    )

    (var-set next-terms-id (+ terms-id u1))
    (ok terms-id)
  )
)

;; Add payment milestone
(define-public (add-payment-milestone (terms-id uint) (milestone-id uint) (description (string-ascii 100))
                                    (amount uint) (due-date uint) (completion-criteria (string-ascii 200)))
  (let
    (
      (terms (unwrap! (map-get? payment-terms { terms-id: terms-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get payer terms)) (is-eq tx-sender (get payee terms))) err-unauthorized)
    (asserts! (is-eq (get status terms) "active") err-invalid-input)
    (asserts! (> amount u0) err-invalid-input)
    (asserts! (> due-date block-height) err-invalid-input)

    (map-set payment-milestones
      { terms-id: terms-id, milestone-id: milestone-id }
      {
        description: description,
        amount: amount,
        due-date: due-date,
        completion-criteria: completion-criteria,
        status: "pending",
        payment-date: none,
        amount-paid: u0
      }
    )
    (ok true)
  )
)

;; Add payment installment
(define-public (add-payment-installment (terms-id uint) (installment-id uint) (amount uint) (due-date uint))
  (let
    (
      (terms (unwrap! (map-get? payment-terms { terms-id: terms-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get payer terms)) (is-eq tx-sender (get payee terms))) err-unauthorized)
    (asserts! (is-eq (get status terms) "active") err-invalid-input)
    (asserts! (> amount u0) err-invalid-input)
    (asserts! (> due-date block-height) err-invalid-input)

    (map-set payment-installments
      { terms-id: terms-id, installment-id: installment-id }
      {
        amount: amount,
        due-date: due-date,
        status: "pending",
        payment-date: none,
        amount-paid: u0,
        late-fee: u0
      }
    )
    (ok true)
  )
)

;; Process milestone payment
(define-public (process-milestone-payment (terms-id uint) (milestone-id uint) (amount uint))
  (let
    (
      (terms (unwrap! (map-get? payment-terms { terms-id: terms-id }) err-not-found))
      (milestone (unwrap! (map-get? payment-milestones { terms-id: terms-id, milestone-id: milestone-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender (get payer terms)) err-unauthorized)
    (asserts! (is-eq (get status milestone) "pending") err-already-paid)
    (asserts! (>= amount (get amount milestone)) err-invalid-input)

    (map-set payment-milestones
      { terms-id: terms-id, milestone-id: milestone-id }
      (merge milestone {
        status: "completed",
        payment-date: (some block-height),
        amount-paid: amount
      })
    )

    ;; Check if all milestones are completed
    (update-terms-status-if-complete terms-id)
    (ok true)
  )
)

;; Process installment payment
(define-public (process-installment-payment (terms-id uint) (installment-id uint) (amount uint))
  (let
    (
      (terms (unwrap! (map-get? payment-terms { terms-id: terms-id }) err-not-found))
      (installment (unwrap! (map-get? payment-installments { terms-id: terms-id, installment-id: installment-id }) err-not-found))
      (late-fee (calculate-late-fee installment terms))
      (total-due (+ (get amount installment) late-fee))
    )
    (asserts! (is-eq tx-sender (get payer terms)) err-unauthorized)
    (asserts! (is-eq (get status installment) "pending") err-already-paid)
    (asserts! (>= amount total-due) err-invalid-input)

    (map-set payment-installments
      { terms-id: terms-id, installment-id: installment-id }
      (merge installment {
        status: "paid",
        payment-date: (some block-height),
        amount-paid: amount,
        late-fee: late-fee
      })
    )

    ;; Check if all installments are paid
    (update-terms-status-if-complete terms-id)
    (ok true)
  )
)

;; Create payment dispute
(define-public (create-payment-dispute (terms-id uint) (dispute-reason (string-ascii 200)) (disputed-amount uint))
  (let
    (
      (terms (unwrap! (map-get? payment-terms { terms-id: terms-id }) err-not-found))
      (dispute-id (var-get next-dispute-id))
    )
    (asserts! (or (is-eq tx-sender (get payer terms)) (is-eq tx-sender (get payee terms))) err-unauthorized)
    (asserts! (> disputed-amount u0) err-invalid-input)
    (asserts! (<= disputed-amount (get total-amount terms)) err-invalid-input)

    (map-set payment-disputes
      { dispute-id: dispute-id }
      {
        terms-id: terms-id,
        disputing-party: tx-sender,
        dispute-reason: dispute-reason,
        disputed-amount: disputed-amount,
        creation-date: block-height,
        status: "open",
        resolution: none,
        resolver: none
      }
    )

    ;; Update terms status to disputed
    (map-set payment-terms
      { terms-id: terms-id }
      (merge terms { status: "disputed" })
    )

    (var-set next-dispute-id (+ dispute-id u1))
    (ok dispute-id)
  )
)

;; Resolve dispute (arbitrators only)
(define-public (resolve-dispute (dispute-id uint) (resolution (string-ascii 200)))
  (let
    (
      (dispute (unwrap! (map-get? payment-disputes { dispute-id: dispute-id }) err-not-found))
      (arbitrator-info (map-get? authorized-arbitrators { arbitrator: tx-sender }))
      (terms (unwrap! (map-get? payment-terms { terms-id: (get terms-id dispute) }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender contract-owner)
                  (and (is-some arbitrator-info)
                       (get authorized (unwrap! arbitrator-info err-unauthorized)))) err-unauthorized)
    (asserts! (is-eq (get status dispute) "open") err-invalid-input)

    (map-set payment-disputes
      { dispute-id: dispute-id }
      (merge dispute {
        status: "resolved",
        resolution: (some resolution),
        resolver: (some tx-sender)
      })
    )

    ;; Update terms status back to active
    (map-set payment-terms
      { terms-id: (get terms-id dispute) }
      (merge terms { status: "active" })
    )

    (ok true)
  )
)

;; Add authorized arbitrator
(define-public (add-arbitrator (arbitrator principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-arbitrators
      { arbitrator: arbitrator }
      { authorized: true, added-at: block-height }
    )
    (ok true)
  )
)

;; Private Functions

;; Calculate late fee for installment
(define-private (calculate-late-fee (installment { amount: uint, due-date: uint, status: (string-ascii 20), payment-date: (optional uint), amount-paid: uint, late-fee: uint })
                                   (terms { payer: principal, payee: principal, total-amount: uint, payment-schedule: (string-ascii 20), milestone-count: uint, installment-count: uint, interest-rate: uint, grace-period-days: uint, creation-date: uint, final-due-date: uint, status: (string-ascii 20), collateral-required: uint, early-payment-discount: uint }))
  (let
    (
      (due-date (get due-date installment))
      (grace-period (get grace-period-days terms))
      (grace-end (+ due-date (* grace-period u144))) ;; Convert days to blocks
      (days-late (if (> block-height grace-end) (/ (- block-height grace-end) u144) u0))
      (interest-rate (get interest-rate terms))
      (amount (get amount installment))
    )
    (if (> days-late u0)
      (/ (* (* amount interest-rate) days-late) (* u10000 u365)) ;; Simple interest calculation
      u0
    )
  )
)

;; Update terms status if all payments complete
(define-private (update-terms-status-if-complete (terms-id uint))
  (let
    (
      (terms (unwrap! (map-get? payment-terms { terms-id: terms-id }) err-not-found))
    )
    ;; This is a simplified check - in practice, you'd verify all milestones/installments
    (if (is-eq (get payment-schedule terms) "immediate")
      (map-set payment-terms
        { terms-id: terms-id }
        (merge terms { status: "completed" })
      )
      terms
    )
  )
)

;; Read-only Functions

;; Get payment terms
(define-read-only (get-payment-terms (terms-id uint))
  (map-get? payment-terms { terms-id: terms-id })
)

;; Get payment milestone
(define-read-only (get-payment-milestone (terms-id uint) (milestone-id uint))
  (map-get? payment-milestones { terms-id: terms-id, milestone-id: milestone-id })
)

;; Get payment installment
(define-read-only (get-payment-installment (terms-id uint) (installment-id uint))
  (map-get? payment-installments { terms-id: terms-id, installment-id: installment-id })
)

;; Get payment dispute
(define-read-only (get-payment-dispute (dispute-id uint))
  (map-get? payment-disputes { dispute-id: dispute-id })
)

;; Check if arbitrator is authorized
(define-read-only (is-authorized-arbitrator (arbitrator principal))
  (match (map-get? authorized-arbitrators { arbitrator: arbitrator })
    arbitrator-info (get authorized arbitrator-info)
    false
  )
)

;; Get next terms ID
(define-read-only (get-next-terms-id)
  (var-get next-terms-id)
)

;; Get next dispute ID
(define-read-only (get-next-dispute-id)
  (var-get next-dispute-id)
)
