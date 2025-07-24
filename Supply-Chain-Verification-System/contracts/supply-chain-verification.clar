;; Supply Chain Verification System
;; A comprehensive platform for tracking product journeys with incentives and penalties

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-stage (err u104))
(define-constant err-insufficient-stake (err u105))
(define-constant err-verification-failed (err u106))

;; Data Variables
(define-data-var next-product-id uint u1)
(define-data-var min-stake-amount uint u1000000) ;; 1 STX in microSTX
(define-data-var verification-reward uint u100000) ;; 0.1 STX reward
(define-data-var false-report-penalty uint u500000) ;; 0.5 STX penalty

;; Data Maps
(define-map products
    { product-id: uint }
    {
        name: (string-ascii 64),
        origin: (string-ascii 128),
        current-stage: (string-ascii 32),
        owner: principal,
        created-at: uint,
        is-verified: bool,
        total-verifications: uint
    }
)

(define-map product-stages
    { product-id: uint, stage-number: uint }
    {
        stage-name: (string-ascii 32),
        location: (string-ascii 128),
        timestamp: uint,
        handler: principal,
        verified: bool,
        verifier: (optional principal),
        verification-count: uint
    }
)

(define-map verifier-stakes
    { verifier: principal, product-id: uint }
    {
        amount: uint,
        timestamp: uint,
        is-active: bool
    }
)

(define-map verifier-reputation
    { verifier: principal }
    {
        successful-verifications: uint,
        false-reports: uint,
        total-stake: uint,
        reputation-score: uint
    }
)

(define-map product-handlers
    { product-id: uint, handler: principal }
    {
        stages-handled: uint,
        last-update: uint,
        is-authorized: bool
    }
)

;; Read-only functions
(define-read-only (get-product (product-id uint))
    (map-get? products { product-id: product-id })
)

(define-read-only (get-product-stage (product-id uint) (stage-number uint))
    (map-get? product-stages { product-id: product-id, stage-number: stage-number })
)

(define-read-only (get-verifier-reputation (verifier principal))
    (map-get? verifier-reputation { verifier: verifier })
)

(define-read-only (get-verifier-stake (verifier principal) (product-id uint))
    (map-get? verifier-stakes { verifier: verifier, product-id: product-id })
)

(define-read-only (get-next-product-id)
    (var-get next-product-id)
)

(define-read-only (calculate-reputation-score (successful uint) (false-reports uint))
    (if (> false-reports u0)
        (/ (* successful u100) (+ successful false-reports))
        u100
    )
)

;; Public functions

;; Create a new product
(define-public (create-product (name (string-ascii 64)) (origin (string-ascii 128)))
    (let ((product-id (var-get next-product-id)))
        (begin
            (map-set products
                { product-id: product-id }
                {
                    name: name,
                    origin: origin,
                    current-stage: "created",
                    owner: tx-sender,
                    created-at: block-height,
                    is-verified: false,
                    total-verifications: u0
                }
            )
            (map-set product-handlers
                { product-id: product-id, handler: tx-sender }
                {
                    stages-handled: u1,
                    last-update: block-height,
                    is-authorized: true
                }
            )
            (var-set next-product-id (+ product-id u1))
            (ok product-id)
        )
    )
)

;; Add a new stage to product journey
(define-public (add-product-stage 
    (product-id uint) 
    (stage-number uint) 
    (stage-name (string-ascii 32)) 
    (location (string-ascii 128)))
    (let ((product (unwrap! (get-product product-id) err-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get owner product)) err-unauthorized)
            (map-set product-stages
                { product-id: product-id, stage-number: stage-number }
                {
                    stage-name: stage-name,
                    location: location,
                    timestamp: block-height,
                    handler: tx-sender,
                    verified: false,
                    verifier: none,
                    verification-count: u0
                }
            )
            (map-set products
                { product-id: product-id }
                (merge product { current-stage: stage-name })
            )
            (ok true)
        )
    )
)

;; Stake tokens for verification rights
(define-public (stake-for-verification (product-id uint) (amount uint))
    (begin
        (asserts! (>= amount (var-get min-stake-amount)) err-insufficient-stake)
        (asserts! (is-some (get-product product-id)) err-not-found)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (map-set verifier-stakes
            { verifier: tx-sender, product-id: product-id }
            {
                amount: amount,
                timestamp: block-height,
                is-active: true
            }
        )
        (match (get-verifier-reputation tx-sender)
            existing-rep (map-set verifier-reputation
                { verifier: tx-sender }
                (merge existing-rep { total-stake: (+ (get total-stake existing-rep) amount) })
            )
            (map-set verifier-reputation
                { verifier: tx-sender }
                {
                    successful-verifications: u0,
                    false-reports: u0,
                    total-stake: amount,
                    reputation-score: u100
                }
            )
        )
        (ok true)
    )
)

;; Verify a product stage
(define-public (verify-stage (product-id uint) (stage-number uint) (is-valid bool))
    (let (
        (stage (unwrap! (get-product-stage product-id stage-number) err-not-found))
        (stake (unwrap! (get-verifier-stake tx-sender product-id) err-unauthorized))
    )
        (begin
            (asserts! (get is-active stake) err-unauthorized)
            (asserts! (not (get verified stage)) err-already-exists)
            
            ;; Update stage verification
            (map-set product-stages
                { product-id: product-id, stage-number: stage-number }
                (merge stage {
                    verified: is-valid,
                    verifier: (some tx-sender),
                    verification-count: (+ (get verification-count stage) u1)
                })
            )
            
            ;; Update verifier reputation
            (match (get-verifier-reputation tx-sender)
                existing-rep 
                (if is-valid
                    (let ((new-successful (+ (get successful-verifications existing-rep) u1)))
                        (map-set verifier-reputation
                            { verifier: tx-sender }
                            (merge existing-rep {
                                successful-verifications: new-successful,
                                reputation-score: (calculate-reputation-score 
                                    new-successful 
                                    (get false-reports existing-rep))
                            })
                        )
                    )
                    (let ((new-false (+ (get false-reports existing-rep) u1)))
                        (map-set verifier-reputation
                            { verifier: tx-sender }
                            (merge existing-rep {
                                false-reports: new-false,
                                reputation-score: (calculate-reputation-score 
                                    (get successful-verifications existing-rep) 
                                    new-false)
                            })
                        )
                    )
                )
                err-not-found
            )
            
            ;; Reward or penalize verifier
            (if is-valid
                (try! (as-contract (stx-transfer? (var-get verification-reward) tx-sender tx-sender)))
                (try! (stx-transfer? (var-get false-report-penalty) tx-sender (as-contract tx-sender)))
            )
            
            (ok is-valid)
        )
    )
)

;; Complete product verification
(define-public (complete-product-verification (product-id uint))
    (let ((product (unwrap! (get-product product-id) err-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get owner product)) err-unauthorized)
            (map-set products
                { product-id: product-id }
                (merge product {
                    is-verified: true,
                    total-verifications: (+ (get total-verifications product) u1)
                })
            )
            (ok true)
        )
    )
)

;; Transfer product ownership
(define-public (transfer-product (product-id uint) (new-owner principal))
    (let ((product (unwrap! (get-product product-id) err-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get owner product)) err-unauthorized)
            (map-set products
                { product-id: product-id }
                (merge product { owner: new-owner })
            )
            (ok true)
        )
    )
)

;; Withdraw stake (only if no active verifications)
(define-public (withdraw-stake (product-id uint))
    (let ((stake (unwrap! (get-verifier-stake tx-sender product-id) err-not-found)))
        (begin
            (asserts! (get is-active stake) err-unauthorized)
            (map-set verifier-stakes
                { verifier: tx-sender, product-id: product-id }
                (merge stake { is-active: false })
            )
            (try! (as-contract (stx-transfer? (get amount stake) tx-sender tx-sender)))
            (ok (get amount stake))
        )
    )
)

;; Admin functions (contract owner only)
(define-public (set-min-stake (new-amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set min-stake-amount new-amount)
        (ok true)
    )
)

(define-public (set-verification-reward (new-reward uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set verification-reward new-reward)
        (ok true)
    )
)

(define-public (set-false-report-penalty (new-penalty uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set false-report-penalty new-penalty)
        (ok true)
    )
)

;; Emergency functions
(define-public (pause-product (product-id uint))
    (let ((product (unwrap! (get-product product-id) err-not-found)))
        (begin
            (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (get owner product))) err-unauthorized)
            (map-set products
                { product-id: product-id }
                (merge product { current-stage: "paused" })
            )
            (ok true)
        )
    )
)