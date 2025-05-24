;; Cash Flow Analysis Contract
;; Evaluates working capital needs and analyzes cash flow patterns

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-invalid-input (err u202))
(define-constant err-unauthorized (err u203))
(define-constant err-insufficient-data (err u204))

;; Data Variables
(define-data-var next-analysis-id uint u1)

;; Data Maps
(define-map cash-flow-data
  { entity: principal, period: uint }
  {
    revenue: uint,
    expenses: uint,
    receivables: uint,
    payables: uint,
    inventory: uint,
    payment-cycle-days: uint,
    submission-date: uint
  }
)

(define-map working-capital-analysis
  { analysis-id: uint }
  {
    entity: principal,
    current-ratio: uint,
    working-capital-need: uint,
    cash-conversion-cycle: uint,
    risk-score: uint,
    recommendations: (string-ascii 200),
    analysis-date: uint,
    validity-period: uint
  }
)

(define-map payment-history
  { entity: principal, counter: uint }
  {
    payment-date: uint,
    amount: uint,
    days-delayed: uint,
    payment-type: (string-ascii 20)
  }
)

(define-map entity-payment-counter
  { entity: principal }
  { counter: uint }
)

;; Public Functions

;; Submit cash flow data
(define-public (submit-cash-flow-data (revenue uint) (expenses uint) (receivables uint) (payables uint) (inventory uint) (payment-cycle-days uint))
  (let
    (
      (current-period (/ block-height u144)) ;; Approximate daily periods
    )
    (asserts! (> revenue u0) err-invalid-input)
    (asserts! (> payment-cycle-days u0) err-invalid-input)
    (asserts! (<= payment-cycle-days u365) err-invalid-input) ;; Max 1 year cycle

    (map-set cash-flow-data
      { entity: tx-sender, period: current-period }
      {
        revenue: revenue,
        expenses: expenses,
        receivables: receivables,
        payables: payables,
        inventory: inventory,
        payment-cycle-days: payment-cycle-days,
        submission-date: block-height
      }
    )
    (ok true)
  )
)

;; Calculate working capital need
(define-public (calculate-working-capital-need)
  (let
    (
      (current-period (/ block-height u144))
      (cash-flow (unwrap! (map-get? cash-flow-data { entity: tx-sender, period: current-period }) err-insufficient-data))
      (analysis-id (var-get next-analysis-id))
      (current-ratio (calculate-current-ratio cash-flow))
      (cash-cycle (calculate-cash-conversion-cycle cash-flow))
      (working-capital (calculate-working-capital cash-flow))
      (risk-score (calculate-risk-score cash-flow current-ratio))
    )

    (map-set working-capital-analysis
      { analysis-id: analysis-id }
      {
        entity: tx-sender,
        current-ratio: current-ratio,
        working-capital-need: working-capital,
        cash-conversion-cycle: cash-cycle,
        risk-score: risk-score,
        recommendations: (generate-recommendations risk-score current-ratio),
        analysis-date: block-height,
        validity-period: u30 ;; Valid for 30 blocks
      }
    )

    (var-set next-analysis-id (+ analysis-id u1))
    (ok analysis-id)
  )
)

;; Update payment history
(define-public (update-payment-history (amount uint) (days-delayed uint) (payment-type (string-ascii 20)))
  (let
    (
      (current-counter (default-to u0 (get counter (map-get? entity-payment-counter { entity: tx-sender }))))
      (new-counter (+ current-counter u1))
    )
    (asserts! (> amount u0) err-invalid-input)

    (map-set payment-history
      { entity: tx-sender, counter: new-counter }
      {
        payment-date: block-height,
        amount: amount,
        days-delayed: days-delayed,
        payment-type: payment-type
      }
    )

    (map-set entity-payment-counter
      { entity: tx-sender }
      { counter: new-counter }
    )
    (ok new-counter)
  )
)

;; Private Functions

;; Calculate current ratio
(define-private (calculate-current-ratio (cash-flow { revenue: uint, expenses: uint, receivables: uint, payables: uint, inventory: uint, payment-cycle-days: uint, submission-date: uint }))
  (let
    (
      (current-assets (+ (get receivables cash-flow) (get inventory cash-flow)))
      (current-liabilities (get payables cash-flow))
    )
    (if (is-eq current-liabilities u0)
      u10000 ;; Very high ratio if no liabilities
      (/ (* current-assets u1000) current-liabilities) ;; Ratio * 1000 for precision
    )
  )
)

;; Calculate cash conversion cycle
(define-private (calculate-cash-conversion-cycle (cash-flow { revenue: uint, expenses: uint, receivables: uint, payables: uint, inventory: uint, payment-cycle-days: uint, submission-date: uint }))
  (let
    (
      (dso (get payment-cycle-days cash-flow)) ;; Days Sales Outstanding
      (dio (if (> (get expenses cash-flow) u0) (/ (* (get inventory cash-flow) u365) (get expenses cash-flow)) u0)) ;; Days Inventory Outstanding
      (dpo (if (> (get expenses cash-flow) u0) (/ (* (get payables cash-flow) u365) (get expenses cash-flow)) u0)) ;; Days Payable Outstanding
    )
    (if (> (+ dso dio) dpo)
      (- (+ dso dio) dpo)
      u0
    )
  )
)

;; Calculate working capital need
(define-private (calculate-working-capital (cash-flow { revenue: uint, expenses: uint, receivables: uint, payables: uint, inventory: uint, payment-cycle-days: uint, submission-date: uint }))
  (let
    (
      (daily-revenue (if (> (get payment-cycle-days cash-flow) u0) (/ (get revenue cash-flow) (get payment-cycle-days cash-flow)) u0))
      (cash-cycle (calculate-cash-conversion-cycle cash-flow))
    )
    (* daily-revenue cash-cycle)
  )
)

;; Calculate risk score
(define-private (calculate-risk-score (cash-flow { revenue: uint, expenses: uint, receivables: uint, payables: uint, inventory: uint, payment-cycle-days: uint, submission-date: uint }) (current-ratio uint))
  (let
    (
      (revenue-volatility (if (> (get revenue cash-flow) (get expenses cash-flow)) u200 u800)) ;; Lower score for profitable entities
      (liquidity-score (if (> current-ratio u1200) u200 u600)) ;; Lower score for good liquidity
      (cycle-score (if (> (get payment-cycle-days cash-flow) u60) u600 u300)) ;; Higher score for long cycles
    )
    (/ (+ revenue-volatility liquidity-score cycle-score) u3)
  )
)

;; Generate recommendations
(define-private (generate-recommendations (risk-score uint) (current-ratio uint))
  (if (> risk-score u600)
    "High risk: Improve cash flow management and reduce payment cycles"
    (if (< current-ratio u1000)
      "Moderate risk: Increase working capital reserves"
      "Low risk: Maintain current financial practices"
    )
  )
)

;; Read-only Functions

;; Get cash flow data
(define-read-only (get-cash-flow-data (entity principal) (period uint))
  (map-get? cash-flow-data { entity: entity, period: period })
)

;; Get latest cash flow data
(define-read-only (get-latest-cash-flow-data (entity principal))
  (let
    (
      (current-period (/ block-height u144))
    )
    (map-get? cash-flow-data { entity: entity, period: current-period })
  )
)

;; Get working capital analysis
(define-read-only (get-working-capital-analysis (analysis-id uint))
  (map-get? working-capital-analysis { analysis-id: analysis-id })
)

;; Get risk assessment
(define-read-only (get-risk-assessment (entity principal))
  (let
    (
      (current-period (/ block-height u144))
      (cash-flow (map-get? cash-flow-data { entity: entity, period: current-period }))
    )
    (match cash-flow
      data (let
        (
          (current-ratio (calculate-current-ratio data))
          (risk-score (calculate-risk-score data current-ratio))
        )
        (some { risk-score: risk-score, current-ratio: current-ratio })
      )
      none
    )
  )
)

;; Get payment history
(define-read-only (get-payment-history (entity principal) (counter uint))
  (map-get? payment-history { entity: entity, counter: counter })
)

;; Get payment counter
(define-read-only (get-payment-counter (entity principal))
  (default-to u0 (get counter (map-get? entity-payment-counter { entity: entity })))
)

;; Get next analysis ID
(define-read-only (get-next-analysis-id)
  (var-get next-analysis-id)
)
