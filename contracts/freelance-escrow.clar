;; Freelance Payment Protection - Escrow Service Contract
;; Secure milestone-based payments and automated dispute resolution for freelancers and clients

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROJECT-NOT-FOUND (err u101))
(define-constant ERR-INVALID-MILESTONE (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-PROJECT-COMPLETED (err u104))
(define-constant ERR-MILESTONE-ALREADY-PAID (err u105))
(define-constant ERR-INVALID-DISPUTE (err u106))
(define-constant ERR-DEADLINE-PASSED (err u107))
(define-constant ERR-INVALID-PARAMETERS (err u108))

;; Platform fee percentage (2%)
(define-constant PLATFORM-FEE-PERCENTAGE u2)

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var next-project-id uint u1)
(define-data-var next-milestone-id uint u1)
(define-data-var next-dispute-id uint u1)
(define-data-var platform-fee-collected uint u0)
(define-data-var total-projects-created uint u0)
(define-data-var total-milestones-completed uint u0)

;; Data Maps
(define-map projects
    { project-id: uint }
    {
        client: principal,
        freelancer: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        total-amount: uint,
        deadline: uint,
        status: (string-ascii 20),
        created-at: uint,
        completed-at: (optional uint)
    }
)

(define-map milestones
    { milestone-id: uint }
    {
        project-id: uint,
        description: (string-ascii 200),
        amount: uint,
        deadline: uint,
        status: (string-ascii 15),
        submitted-at: (optional uint),
        approved-at: (optional uint),
        paid-at: (optional uint)
    }
)

(define-map project-funds
    { project-id: uint }
    {
        deposited: uint,
        paid-out: uint,
        available: uint
    }
)

(define-map disputes
    { dispute-id: uint }
    {
        project-id: uint,
        milestone-id: (optional uint),
        raised-by: principal,
        reason: (string-ascii 300),
        status: (string-ascii 15),
        created-at: uint,
        resolved-at: (optional uint),
        resolution: (optional (string-ascii 200))
    }
)

(define-map project-milestones
    { project-id: uint }
    { milestone-ids: (list 20 uint) }
)

(define-map user-reputation
    { user: principal }
    {
        projects-completed: uint,
        total-earned: uint,
        average-rating: uint,
        disputes-raised: uint,
        disputes-won: uint
    }
)

(define-map authorized-arbitrators
    { arbitrator: principal }
    { authorized: bool }
)

;; Public Functions

;; Create a new freelance project
(define-public (create-project
    (freelancer principal)
    (title (string-ascii 100))
    (description (string-ascii 500))
    (total-amount uint)
    (deadline uint))
    (let (
        (project-id (var-get next-project-id))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (> total-amount u0) ERR-INVALID-PARAMETERS)
        (asserts! (> deadline block-height) ERR-INVALID-PARAMETERS)
        (asserts! (not (is-eq tx-sender freelancer)) ERR-INVALID-PARAMETERS)
        
        (map-set projects
            { project-id: project-id }
            {
                client: tx-sender,
                freelancer: freelancer,
                title: title,
                description: description,
                total-amount: total-amount,
                deadline: deadline,
                status: "created",
                created-at: block-height,
                completed-at: none
            }
        )
        
        (map-set project-funds
            { project-id: project-id }
            {
                deposited: u0,
                paid-out: u0,
                available: u0
            }
        )
        
        (map-set project-milestones
            { project-id: project-id }
            { milestone-ids: (list) }
        )
        
        (var-set next-project-id (+ project-id u1))
        (var-set total-projects-created (+ (var-get total-projects-created) u1))
        
        (ok project-id)
    )
)

;; Deposit funds for a project
(define-public (deposit-project-funds (project-id uint) (amount uint))
    (let (
        (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (current-funds (default-to { deposited: u0, paid-out: u0, available: u0 }
                                  (map-get? project-funds { project-id: project-id })))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-PARAMETERS)
        (asserts! (is-eq (get status project) "created") ERR-PROJECT-COMPLETED)
        
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        (map-set project-funds
            { project-id: project-id }
            {
                deposited: (+ (get deposited current-funds) amount),
                paid-out: (get paid-out current-funds),
                available: (+ (get available current-funds) amount)
            }
        )
        
        (ok true)
    )
)

;; Create a milestone for a project
(define-public (create-milestone
    (project-id uint)
    (description (string-ascii 200))
    (amount uint)
    (deadline uint))
    (let (
        (milestone-id (var-get next-milestone-id))
        (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (current-milestones (get milestone-ids 
                           (default-to { milestone-ids: (list) }
                                     (map-get? project-milestones { project-id: project-id }))))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq tx-sender (get client project)) 
                     (is-eq tx-sender (get freelancer project))) ERR-NOT-AUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-PARAMETERS)
        (asserts! (> deadline block-height) ERR-INVALID-PARAMETERS)
        (asserts! (< (len current-milestones) u20) ERR-INVALID-PARAMETERS)
        
        (map-set milestones
            { milestone-id: milestone-id }
            {
                project-id: project-id,
                description: description,
                amount: amount,
                deadline: deadline,
                status: "pending",
                submitted-at: none,
                approved-at: none,
                paid-at: none
            }
        )
        
        (map-set project-milestones
            { project-id: project-id }
            { milestone-ids: (unwrap! (as-max-len? 
                                     (append current-milestones milestone-id) u20) 
                                   ERR-INVALID-PARAMETERS) }
        )
        
        (var-set next-milestone-id (+ milestone-id u1))
        
        (ok milestone-id)
    )
)

;; Submit milestone for review
(define-public (submit-milestone (milestone-id uint))
    (let (
        (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-INVALID-MILESTONE))
        (project (unwrap! (map-get? projects { project-id: (get project-id milestone) }) ERR-PROJECT-NOT-FOUND))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq tx-sender (get freelancer project)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone) "pending") ERR-INVALID-MILESTONE)
        (asserts! (<= block-height (get deadline milestone)) ERR-DEADLINE-PASSED)
        
        (map-set milestones
            { milestone-id: milestone-id }
            (merge milestone {
                status: "submitted",
                submitted-at: (some block-height)
            })
        )
        
        (ok true)
    )
)

;; Approve milestone and release payment
(define-public (approve-milestone (milestone-id uint))
    (let (
        (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-INVALID-MILESTONE))
        (project (unwrap! (map-get? projects { project-id: (get project-id milestone) }) ERR-PROJECT-NOT-FOUND))
        (project-funds-data (unwrap! (map-get? project-funds { project-id: (get project-id milestone) }) ERR-INSUFFICIENT-FUNDS))
        (milestone-amount (get amount milestone))
        (platform-fee (/ (* milestone-amount PLATFORM-FEE-PERCENTAGE) u100))
        (freelancer-payment (- milestone-amount platform-fee))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone) "submitted") ERR-INVALID-MILESTONE)
        (asserts! (>= (get available project-funds-data) milestone-amount) ERR-INSUFFICIENT-FUNDS)
        
        ;; Transfer payment to freelancer
        (try! (as-contract (stx-transfer? freelancer-payment tx-sender (get freelancer project))))
        
        ;; Update milestone status
        (map-set milestones
            { milestone-id: milestone-id }
            (merge milestone {
                status: "approved",
                approved-at: (some block-height),
                paid-at: (some block-height)
            })
        )
        
        ;; Update project funds
        (map-set project-funds
            { project-id: (get project-id milestone) }
            {
                deposited: (get deposited project-funds-data),
                paid-out: (+ (get paid-out project-funds-data) milestone-amount),
                available: (- (get available project-funds-data) milestone-amount)
            }
        )
        
        ;; Update platform fee collection and statistics
        (var-set platform-fee-collected (+ (var-get platform-fee-collected) platform-fee))
        (var-set total-milestones-completed (+ (var-get total-milestones-completed) u1))
        
        ;; Update user reputation
        (unwrap! (update-user-reputation (get freelancer project) milestone-amount) ERR-INVALID-PARAMETERS)
        
        (ok true)
    )
)

;; Raise a dispute
(define-public (raise-dispute
    (project-id uint)
    (milestone-id (optional uint))
    (reason (string-ascii 300)))
    (let (
        (dispute-id (var-get next-dispute-id))
        (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq tx-sender (get client project))
                     (is-eq tx-sender (get freelancer project))) ERR-NOT-AUTHORIZED)
        
        (map-set disputes
            { dispute-id: dispute-id }
            {
                project-id: project-id,
                milestone-id: milestone-id,
                raised-by: tx-sender,
                reason: reason,
                status: "open",
                created-at: block-height,
                resolved-at: none,
                resolution: none
            }
        )
        
        (var-set next-dispute-id (+ dispute-id u1))
        
        (ok dispute-id)
    )
)

;; Resolve dispute (arbitrators only)
(define-public (resolve-dispute
    (dispute-id uint)
    (resolution (string-ascii 200))
    (award-to principal))
    (let (
        (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-INVALID-DISPUTE))
        (project (unwrap! (map-get? projects { project-id: (get project-id dispute) }) ERR-PROJECT-NOT-FOUND))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (default-to false (get authorized (map-get? authorized-arbitrators { arbitrator: tx-sender }))) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status dispute) "open") ERR-INVALID-DISPUTE)
        
        (map-set disputes
            { dispute-id: dispute-id }
            (merge dispute {
                status: "resolved",
                resolved-at: (some block-height),
                resolution: (some resolution)
            })
        )
        
        (ok true)
    )
)

;; Complete project
(define-public (complete-project (project-id uint))
    (let (
        (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
        (asserts! (not (is-eq (get status project) "completed")) ERR-PROJECT-COMPLETED)
        
        (map-set projects
            { project-id: project-id }
            (merge project {
                status: "completed",
                completed-at: (some block-height)
            })
        )
        
        (ok true)
    )
)

;; Authorize arbitrator (contract owner only)
(define-public (authorize-arbitrator (arbitrator principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        (map-set authorized-arbitrators
            { arbitrator: arbitrator }
            { authorized: true }
        )
        
        (ok true)
    )
)

;; Emergency pause contract
(define-public (pause-contract)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (var-set contract-paused true)
        (ok true)
    )
)

;; Resume contract
(define-public (resume-contract)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (var-set contract-paused false)
        (ok true)
    )
)

;; Private Functions

;; Update user reputation
(define-private (update-user-reputation (user principal) (amount uint))
    (let (
        (current-rep (default-to {
            projects-completed: u0,
            total-earned: u0,
            average-rating: u0,
            disputes-raised: u0,
            disputes-won: u0
        } (map-get? user-reputation { user: user })))
    )
        (map-set user-reputation
            { user: user }
            {
                projects-completed: (+ (get projects-completed current-rep) u1),
                total-earned: (+ (get total-earned current-rep) amount),
                average-rating: (get average-rating current-rep),
                disputes-raised: (get disputes-raised current-rep),
                disputes-won: (get disputes-won current-rep)
            }
        )
        
        (ok true)
    )
)

;; Read-only Functions

;; Get project details
(define-read-only (get-project (project-id uint))
    (map-get? projects { project-id: project-id })
)

;; Get milestone details
(define-read-only (get-milestone (milestone-id uint))
    (map-get? milestones { milestone-id: milestone-id })
)

;; Get project funds
(define-read-only (get-project-funds (project-id uint))
    (map-get? project-funds { project-id: project-id })
)

;; Get dispute details
(define-read-only (get-dispute (dispute-id uint))
    (map-get? disputes { dispute-id: dispute-id })
)

;; Get project milestones
(define-read-only (get-project-milestones (project-id uint))
    (map-get? project-milestones { project-id: project-id })
)

;; Get user reputation
(define-read-only (get-user-reputation (user principal))
    (map-get? user-reputation { user: user })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
    {
        total-projects: (- (var-get next-project-id) u1),
        total-milestones: (- (var-get next-milestone-id) u1),
        total-disputes: (- (var-get next-dispute-id) u1),
        total-projects-created: (var-get total-projects-created),
        total-milestones-completed: (var-get total-milestones-completed),
        platform-fee-collected: (var-get platform-fee-collected),
        contract-paused: (var-get contract-paused)
    }
)

;; Check if arbitrator is authorized
(define-read-only (is-arbitrator-authorized (arbitrator principal))
    (default-to false (get authorized (map-get? authorized-arbitrators { arbitrator: arbitrator })))
)


;; title: freelance-escrow
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

