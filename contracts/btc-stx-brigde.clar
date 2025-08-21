;; btc-stx-bridge.clar - Simplified BTC <-> STX bridge (educational)
;; -------------------------------------------------------------------
;; WARNING: Cross-chain bridges are extremely security-sensitive.
;; This contract is for demonstration/educational purposes only and
;; omits production features (SPV proofs, slashing, monitoring).
;; -------------------------------------------------------------------

(define-constant contract-owner tx-sender)
(define-constant ROLE_ADMIN u1)
(define-constant ERR_UNAUTHORIZED u100)
(define-constant ERR_ALREADY_PROCESSED u101)
(define-constant ERR_NOT_ENOUGH_SIGS u102)

;; ----------------------------
;; Wrapped BTC token (wBTC)
;; ----------------------------

(define-data-var total-supply uint u0)
(define-map balances { account: principal } { balance: uint })

(define-read-only (balance-of (who principal))
  (default-to u0 (get balance (map-get? balances { account: who }))))

(define-read-only (get-total-supply)
  (var-get total-supply))

(define-private (mint (to principal) (amount uint))
  (let 
    ((current-total (var-get total-supply))
     (current-balance (balance-of to)))
    (map-set balances { account: to } { balance: (+ current-balance amount) })
    (var-set total-supply (+ current-total amount))
    (ok true)))

(define-private (burn (from principal) (amount uint))
  (let 
    ((current-total (var-get total-supply))
     (current-balance (balance-of from)))
    (asserts! (>= current-balance amount) (err u1))
    (map-set balances { account: from } { balance: (- current-balance amount) })
    (var-set total-supply (- current-total amount))
    (ok true)))

(define-public (transfer (to principal) (amount uint))
  (begin
    ;; Validate inputs
    (asserts! (validate-principal to) (err u1))
    (asserts! (> amount u0) (err u1))

    (let 
      ((from tx-sender)
       (from-balance (balance-of from))
       (to-balance (balance-of to)))

      ;; Validate balances
      (asserts! (>= from-balance amount) (err u1))

      ;; Process transfer
      (map-set balances { account: from } { balance: (- from-balance amount) })
      (map-set balances { account: to } { balance: (+ to-balance amount) })
      (ok true))))

;; ----------------------------
;; Bridge state
;; ----------------------------

(define-data-var validator-threshold uint u2)
(define-map validators { account: principal } { active: bool })
(define-map approvals { deposit-hash: (buff 32) } { approvers: (list 20 principal) })
(define-map processed { deposit-hash: (buff 32) } { done: bool })

;; Validation helpers
(define-read-only (validate-principal (who principal))
  (is-some (to-consensus-buff? who)))

(define-read-only (validate-buff32 (b (buff 32)))
  (is-eq (len b) u32))

(define-private (validate-list (lst (list 20 principal)))
  (begin
    (asserts! (<= (len lst) u20) (err u1))
    (ok lst)))

(define-private (append-to-list (item principal) (lst (list 20 principal)))
  (begin
    (asserts! (validate-principal item) (err u1))
    (try! (validate-list lst))
    (ok (unwrap! (as-max-len? (append lst item) u20) (err u1)))))

;; ----------------------------
;; Admin functions
;; ----------------------------

(define-public (add-validator (v principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err ERR_UNAUTHORIZED))
    (asserts! (validate-principal v) (err u1))
    (ok (map-set validators { account: v } { active: true }))))

(define-public (remove-validator (v principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err ERR_UNAUTHORIZED))
    (asserts! (validate-principal v) (err u1))
    (ok (map-delete validators { account: v }))))

(define-public (set-threshold (n uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err ERR_UNAUTHORIZED))
    (asserts! (> n u0) (err u1))
    (ok (var-set validator-threshold n))))

;; ----------------------------
;; Peg-in (BTC -> STX)
;; ----------------------------
;; Off-chain: validators observe a BTC deposit. They agree on a deposit-hash,
;; sign it, and call approve-deposit. Once threshold approvals are reached,
;; wBTC is minted to recipient.

(define-public (approve-deposit (deposit-hash (buff 32)) (recipient principal) (amount uint))
  (begin
    ;; Validate inputs
    (asserts! (validate-buff32 deposit-hash) (err u1))
    (asserts! (validate-principal recipient) (err u1))
    (asserts! (> amount u0) (err u1))

    (let 
      ((validator-status (default-to false (get active (map-get? validators { account: tx-sender }))))
      (is-processed (default-to false (get done (map-get? processed { deposit-hash: deposit-hash }))))
      (current-record (map-get? approvals { deposit-hash: deposit-hash }))
      (current-approvers (default-to (list) (get approvers current-record))))

      ;; Must be validator
      (asserts! validator-status (err ERR_UNAUTHORIZED))

      ;; Prevent reprocessing
      (asserts! (not is-processed) (err ERR_ALREADY_PROCESSED))

      ;; Check if already approved by this validator
      (if (is-some (index-of current-approvers tx-sender))
          (ok false)
          (let ((new-approvers (unwrap! (append-to-list tx-sender current-approvers) (err u1))))
            ;; Validate the new list
            (try! (validate-list new-approvers))
            
            ;; Update approvals
            (map-set approvals { deposit-hash: deposit-hash } { approvers: new-approvers })
            
            ;; Check threshold and process if met
            (if (>= (len new-approvers) (var-get validator-threshold))
                (begin
                  (map-set processed { deposit-hash: deposit-hash } { done: true })
                  (unwrap! (mint recipient amount) (err ERR_UNAUTHORIZED))
                  (ok true))
                (ok false))))))) 

;; ----------------------------
;; Peg-out (STX -> BTC)
;; ----------------------------
;; User burns wBTC on Stacks, provides target BTC address (as buff).
;; Off-chain: validators see burn event, release BTC to address.

(define-public (request-withdrawal (btc-address (buff 42)) (amount uint))
  (begin
    (asserts! (>= (balance-of tx-sender) amount) (err u1))
    (unwrap! (burn tx-sender amount) (err ERR_UNAUTHORIZED))
    (print { event: "withdraw", user: tx-sender, to-btc: btc-address, amount: amount })
    (ok true)))
