;; datanest-storage
;; 
;; This contract manages data storage references, permissions, and access control
;; for the DataNest platform. It allows businesses to track ownership of data 
;; stored in decentralized storage systems, manage access permissions, and maintain
;; data integrity through content addressing. The contract handles the complete lifecycle 
;; of business data storage while keeping actual data off-chain for scalability.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-CONTENT-HASH-USED (err u1001))
(define-constant ERR-DATA-NOT-FOUND (err u1002))
(define-constant ERR-INVALID-STORAGE-SIZE (err u1003))
(define-constant ERR-STORAGE-QUOTA-EXCEEDED (err u1004))
(define-constant ERR-NOT-DATA-OWNER (err u1005))
(define-constant ERR-PERMISSION-ALREADY-GRANTED (err u1006))
(define-constant ERR-PERMISSION-NOT-FOUND (err u1007))
(define-constant ERR-INVALID-PAYMENT (err u1008))
(define-constant ERR-TRANSFER-FAILED (err u1009))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant BYTES-PER-STX u10000) ;; Storage pricing: 10000 bytes per STX

;; Data structures
(define-map data-registry
  { content-hash: (buff 32) } ;; SHA-256 hash of the content
  {
    owner: principal,
    creation-height: uint,
    size-bytes: uint,
    name: (string-ascii 100),
    description: (string-ascii 250),
    data-type: (string-ascii 50),
    is-active: bool
  }
)

(define-map access-permissions
  { content-hash: (buff 32), accessor: principal }
  {
    granted-by: principal,
    granted-at-height: uint,
    access-level: (string-ascii 20) ;; "read", "write", "admin"
  }
)

(define-map user-storage-quotas
  { user: principal }
  {
    total-bytes-allocated: uint,
    total-bytes-used: uint,
    last-payment-height: uint
  }
)

;; Track total platform metrics
(define-data-var total-files-stored uint u0)
(define-data-var total-bytes-stored uint u0)
(define-data-var platform-fee-percentage uint u5) ;; 5% platform fee

;; Private functions

;; Check if caller has permission to access a content hash
(define-private (has-permission (content-hash (buff 32)) (accessor principal) (required-level (string-ascii 20)))
  (let
    (
      (data-info (unwrap! (map-get? data-registry { content-hash: content-hash }) false))
      (permission (map-get? access-permissions { content-hash: content-hash, accessor: accessor }))
    )
    (or
      ;; Owner always has access
      (is-eq (get owner data-info) accessor)
      ;; User has explicit permission
      (and
        (is-some permission)
        (let
          ((permission-data (unwrap! permission false)))
          (or
            ;; Admin can do anything
            (is-eq (get access-level permission-data) "admin")
            ;; Write permission covers read
            (and (is-eq required-level "read") (is-eq (get access-level permission-data) "write"))
            ;; Exact permission match
            (is-eq (get access-level permission-data) required-level)
          )
        )
      )
    )
  )
)

;; Update user storage usage when adding new content
(define-private (update-storage-usage (user principal) (size-bytes uint))
  (let
    (
      (current-quota (default-to 
        { total-bytes-allocated: u0, total-bytes-used: u0, last-payment-height: u0 }
        (map-get? user-storage-quotas { user: user })))
      (new-bytes-used (+ (get total-bytes-used current-quota) size-bytes))
    )
    ;; Verify quota isn't exceeded
    (if (> new-bytes-used (get total-bytes-allocated current-quota))
      false
      (begin
        (map-set user-storage-quotas 
          { user: user }
          (merge current-quota { total-bytes-used: new-bytes-used })
        )
        true
      )
    )
  )
)

;; Public functions

;; Register new data in the platform
(define-public (store-data 
  (content-hash (buff 32)) 
  (size-bytes uint) 
  (name (string-ascii 100)) 
  (description (string-ascii 250))
  (data-type (string-ascii 50)))
  (let
    (
      (caller tx-sender)
      (current-height block-height)
    )
    ;; Check if data already exists
    (asserts! (is-none (map-get? data-registry { content-hash: content-hash })) ERR-CONTENT-HASH-USED)
    
    ;; Check if size is valid
    (asserts! (> size-bytes u0) ERR-INVALID-STORAGE-SIZE)
    
    ;; Check if user has sufficient quota
    (asserts! (update-storage-usage caller size-bytes) ERR-STORAGE-QUOTA-EXCEEDED)
    
    ;; Store data reference
    (map-set data-registry
      { content-hash: content-hash }
      {
        owner: caller,
        creation-height: current-height,
        size-bytes: size-bytes,
        name: name,
        description: description,
        data-type: data-type,
        is-active: true
      }
    )
    
    ;; Update platform metrics
    (var-set total-files-stored (+ (var-get total-files-stored) u1))
    (var-set total-bytes-stored (+ (var-get total-bytes-stored) size-bytes))
    
    (ok content-hash)
  )
)

;; Get data information
(define-read-only (get-data-info (content-hash (buff 32)))
  (match (map-get? data-registry { content-hash: content-hash })
    data-info (ok data-info)
    ERR-DATA-NOT-FOUND
  )
)

;; Check if user has access to data
(define-read-only (check-access (content-hash (buff 32)) (accessor principal) (access-level (string-ascii 20)))
  (ok (has-permission content-hash accessor access-level))
)

;; Grant permission to another user
(define-public (grant-access 
  (content-hash (buff 32)) 
  (accessor principal) 
  (access-level (string-ascii 20)))
  (let
    (
      (caller tx-sender)
      (current-height block-height)
      (data-info (unwrap! (map-get? data-registry { content-hash: content-hash }) ERR-DATA-NOT-FOUND))
    )
    ;; Verify caller is the data owner
    (asserts! (is-eq (get owner data-info) caller) ERR-NOT-DATA-OWNER)
    
    ;; Verify access level is valid
    (asserts! (or (is-eq access-level "read") (is-eq access-level "write") (is-eq access-level "admin")) ERR-NOT-AUTHORIZED)
    
    ;; Check if permission already exists
    (asserts! (is-none (map-get? access-permissions { content-hash: content-hash, accessor: accessor })) ERR-PERMISSION-ALREADY-GRANTED)
    
    ;; Grant permission
    (map-set access-permissions
      { content-hash: content-hash, accessor: accessor }
      {
        granted-by: caller,
        granted-at-height: current-height,
        access-level: access-level
      }
    )
    
    (ok true)
  )
)

;; Revoke access permission
(define-public (revoke-access (content-hash (buff 32)) (accessor principal))
  (let
    (
      (caller tx-sender)
      (data-info (unwrap! (map-get? data-registry { content-hash: content-hash }) ERR-DATA-NOT-FOUND))
      (permission (unwrap! (map-get? access-permissions { content-hash: content-hash, accessor: accessor }) ERR-PERMISSION-NOT-FOUND))
    )
    ;; Verify caller is either the data owner or the one who granted permission
    (asserts! (or 
      (is-eq (get owner data-info) caller)
      (is-eq (get granted-by permission) caller)) 
      ERR-NOT-AUTHORIZED)
    
    ;; Delete permission
    (map-delete access-permissions { content-hash: content-hash, accessor: accessor })
    
    (ok true)
  )
)

;; Remove data from platform
(define-public (delete-data (content-hash (buff 32)))
  (let
    (
      (caller tx-sender)
      (data-info (unwrap! (map-get? data-registry { content-hash: content-hash }) ERR-DATA-NOT-FOUND))
    )
    ;; Verify caller is the data owner
    (asserts! (is-eq (get owner data-info) caller) ERR-NOT-DATA-OWNER)
    
    ;; Update user storage quota
    (let
      (
        (user-quota (unwrap! (map-get? user-storage-quotas { user: caller }) ERR-NOT-AUTHORIZED))
        (new-bytes-used (- (get total-bytes-used user-quota) (get size-bytes data-info)))
      )
      (map-set user-storage-quotas
        { user: caller }
        (merge user-quota { total-bytes-used: new-bytes-used })
      )
    )
    
    ;; Mark data as inactive instead of deleting
    (map-set data-registry
      { content-hash: content-hash }
      (merge data-info { is-active: false })
    )
    
    ;; Update platform metrics
    (var-set total-bytes-stored (- (var-get total-bytes-stored) (get size-bytes data-info)))
    
    (ok true)
  )
)

;; Purchase additional storage quota
(define-public (purchase-storage-quota (stx-amount uint))
  (let
    (
      (caller tx-sender)
      (bytes-to-add (* stx-amount BYTES-PER-STX))
      (platform-fee (* stx-amount (/ (var-get platform-fee-percentage) u100)))
      (current-quota (default-to 
        { total-bytes-allocated: u0, total-bytes-used: u0, last-payment-height: u0 }
        (map-get? user-storage-quotas { user: caller })))
    )
    ;; Verify payment is sufficient
    (asserts! (> stx-amount u0) ERR-INVALID-PAYMENT)
    
    ;; Process payment
    (unwrap! (stx-transfer? stx-amount caller CONTRACT-OWNER) ERR-TRANSFER-FAILED)
    
    ;; Update user quota
    (map-set user-storage-quotas
      { user: caller }
      {
        total-bytes-allocated: (+ (get total-bytes-allocated current-quota) bytes-to-add),
        total-bytes-used: (get total-bytes-used current-quota),
        last-payment-height: block-height
      }
    )
    
    (ok bytes-to-add)
  )
)

;; Get user's storage quota and usage
(define-read-only (get-storage-quota (user principal))
  (default-to
    { 
      total-bytes-allocated: u0, 
      total-bytes-used: u0, 
      last-payment-height: u0 
    }
    (map-get? user-storage-quotas { user: user })
  )
)

;; List all data owned by a user
(define-read-only (list-user-data (owner principal))
  (ok true) ;; This would require an off-chain indexer to implement efficiently
)

;; Update metadata for existing data
(define-public (update-data-metadata 
  (content-hash (buff 32)) 
  (name (string-ascii 100)) 
  (description (string-ascii 250))
  (data-type (string-ascii 50)))
  (let
    (
      (caller tx-sender)
      (data-info (unwrap! (map-get? data-registry { content-hash: content-hash }) ERR-DATA-NOT-FOUND))
    )
    ;; Verify caller is the data owner
    (asserts! (is-eq (get owner data-info) caller) ERR-NOT-DATA-OWNER)
    
    ;; Update metadata
    (map-set data-registry
      { content-hash: content-hash }
      (merge data-info { 
        name: name, 
        description: description,
        data-type: data-type
      })
    )
    
    (ok true)
  )
)

;; Contract owner can update platform fee percentage
(define-public (update-platform-fee (new-percentage uint))
  (begin
    ;; Only contract owner can update fee
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    ;; Reasonable maximum fee of 20%
    (asserts! (<= new-percentage u20) ERR-INVALID-PAYMENT)
    
    (var-set platform-fee-percentage new-percentage)
    (ok new-percentage)
  )
)