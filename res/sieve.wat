;; ==============================================================================
;; Sieve of Eratosthenes implementation
;; ==============================================================================
;; Efficient algorithm for finding prime numbers up to a given limit.
;; This demonstrates object-oriented style programming with structs in WebAssembly.
;; Counts primes up to 100,000.
;; ==============================================================================

(module
  (type (;0;) (func (param i32 i32) (result i32)))
  (type (;1;) (func (param i32 i32 i32)))
  (type (;2;) (func (param i32 i32)))
  (type (;3;) (func (param i32)))
  (type (;4;) (func (result i32)))
  (type (;5;) (func (param i32) (result i32)))
  (type (;6;) (func (param i32 i32) (result i32)))
  (type (;7;) (func (param i32 i32 i32)))
  
  ;; --------------------------------------------------------------------------
  ;; Function 0: Array_read
  ;; Read value from array at given index
  ;; param 0: arr_ptr - pointer to array struct
  ;; param 1: index - array index  
  ;; returns: value at index
  ;; --------------------------------------------------------------------------
  (func (;0;) (type 6) (param i32 i32) (result i32)
    local.get 0
    i32.load align=1
    local.get 1
    global.get 1          ;; element_size = 4
    i32.mul
    i32.add
    i32.load align=1)
  
  ;; --------------------------------------------------------------------------
  ;; Function 1: Array_write
  ;; Write value to array at given index
  ;; param 0: arr_ptr - pointer to array struct
  ;; param 1: index - array index
  ;; param 2: value - value to write
  ;; --------------------------------------------------------------------------
  (func (;1;) (type 7) (param i32 i32 i32)
    local.get 0
    i32.load align=1
    local.get 1
    global.get 1          ;; element_size = 4
    i32.mul
    i32.add
    local.get 2
    i32.store)
  
  ;; --------------------------------------------------------------------------
  ;; Function 2: Array_push
  ;; Push value to end of array
  ;; param 0: arr_ptr - pointer to array struct
  ;; param 1: value - value to push
  ;; --------------------------------------------------------------------------
  (func (;2;) (type 2) (param i32 i32)
    local.get 0
    local.get 0
    i32.load offset=4 align=1  ;; Get length
    local.get 1
    call 1                     ;; Array_write
    local.get 0
    local.get 0
    i32.load offset=4 align=1
    i32.const 1
    i32.add
    i32.store offset=4 align=1)  ;; Increment length
  
  ;; --------------------------------------------------------------------------
  ;; Function 3: Sieve_clear
  ;; Initialize sieve with starting value 2
  ;; param 0: sieve_ptr - pointer to sieve struct
  ;; --------------------------------------------------------------------------
  (func (;3;) (type 3) (param i32)
    local.get 0
    i32.load align=1
    i32.const 0
    i32.store offset=4 align=1  ;; Reset primes array length to 0
    local.get 0
    i32.load align=1
    i32.const 2
    call 2                      ;; Push 2 (first prime)
    local.get 0
    i32.const 1
    i32.store offset=4 align=1)  ;; Set current candidate to 1
  
  ;; --------------------------------------------------------------------------
  ;; Function 4: Sieve_isPrime
  ;; Check if candidate is prime using known primes
  ;; param 0: sieve_ptr - pointer to sieve struct
  ;; param 1: candidate - number to check
  ;; returns: 1 if prime, 0 if composite
  ;; --------------------------------------------------------------------------
  (func (;4;) (type 6) (param i32 i32) (result i32)
    (local i32 i32)        ;; local 2: prime_index, local 3: prime
    i32.const 0
    local.set 2
    local.get 0
    i32.load align=1
    local.get 2
    call 0                 ;; Read first prime
    local.set 3
    block  ;; label = @1
      loop  ;; label = @2
        local.get 3
        local.get 3
        i32.mul            ;; prime^2
        local.get 1
        i32.gt_u           ;; prime^2 > candidate?
        br_if 1 (;@1;)
        local.get 1
        local.get 3
        i32.rem_u          ;; candidate % prime
        i32.eqz
        if  ;; label = @3
          i32.const 0      ;; Not prime
          return
        end
        local.get 2
        i32.const 1
        i32.add
        local.set 2        ;; Next prime index
        local.get 0
        i32.load align=1
        local.get 2
        call 0             ;; Read next prime
        local.set 3
        br 0 (;@2;)
      end
    end
    local.get 0
    i32.load align=1
    local.get 1
    call 2                 ;; Add to primes array
    i32.const 1)           ;; Return true
  
  ;; --------------------------------------------------------------------------
  ;; Function 5: Sieve_nextPrime
  ;; Find next prime number
  ;; param 0: sieve_ptr - pointer to sieve struct
  ;; returns: next prime number
  ;; --------------------------------------------------------------------------
  (func (;5;) (type 5) (param i32) (result i32)
    local.get 0
    local.get 0
    i32.load offset=4 align=1
    i32.const 2
    i32.add
    i32.store offset=4 align=1  ;; Increment candidate by 2 (skip even)
    block  ;; label = @1
      loop  ;; label = @2
        local.get 0
        local.get 0
        i32.load offset=4 align=1
        call 4               ;; Check if prime
        br_if 1 (;@1;)
        local.get 0
        local.get 0
        i32.load offset=4 align=1
        i32.const 2
        i32.add
        i32.store offset=4 align=1  ;; Try next odd number
        br 0 (;@2;)
      end
    end
    local.get 0
    i32.load offset=4 align=1)  ;; Return current candidate
  
  ;; --------------------------------------------------------------------------
  ;; Function 6: Sieve_countUpTo
  ;; Count primes up to limit
  ;; param 0: sieve_ptr - pointer to sieve struct
  ;; param 1: limit - upper limit for primes
  ;; returns: count of primes <= limit
  ;; --------------------------------------------------------------------------
  (func (;6;) (type 6) (param i32 i32) (result i32)
    local.get 0
    call 3                   ;; Initialize sieve
    block  ;; label = @1
      loop  ;; label = @2
        local.get 0
        i32.load offset=4 align=1
        local.get 1
        i32.gt_u             ;; current > limit?
        br_if 1 (;@1;)
        local.get 0
        call 5               ;; Find next prime
        drop
        br 0 (;@2;)
      end
    end
    local.get 0
    i32.load align=1
    i32.load offset=4 align=1
    i32.const 1
    i32.sub)                 ;; Return count (length - 1)
  
  ;; --------------------------------------------------------------------------
  ;; Function 7: main
  ;; Count primes up to 100,000
  ;; --------------------------------------------------------------------------
  (func (;7;) (type 4) (result i32)
    (local i32 i32 i32)
    global.get 0
    i32.const 8
    i32.sub
    global.set 0
    global.get 0
    global.get 0
    global.get 0
    global.get 0
    i32.const 8
    i32.sub
    global.set 0
    global.get 0
    global.get 0
    global.get 0
    global.get 0
    i32.const 40000
    i32.sub
    global.set 0
    global.get 0
    local.set 0              ;; local 0: array_data_ptr
    i32.const 0
    local.set 1              ;; local 1: loop counter i
    block  ;; label = @1
      loop  ;; label = @2
        local.get 1
        i32.const 40000
        i32.eq
        br_if 1 (;@1;)
        local.get 0
        local.get 1
        i32.add
        i32.const 0
        i32.store align=1    ;; Zero out array
        local.get 1
        i32.const 4
        i32.add
        local.set 1
        br 0 (;@2;)
      end
    end
    local.get 0
    i32.store align=1
    i32.const 0
    i32.store offset=4 align=1
    i32.store align=1
    i32.const 0
    i32.store offset=4 align=1
    local.tee 2              ;; local 2: sieve_ptr
    i32.const 100000
    call 6                   ;; Count primes up to 100,000
    global.get 0
    i32.const 40016
    i32.add
    global.set 0)            ;; Clean up stack
  
  (table (;0;) 8 8 funcref)
  (memory (;0;) 17)
  (global (;0;) (mut i32) (i32.const 40016))
  (global (;1;) i32 (i32.const 4))
  (export "memory" (memory 0))
  (export "Array_read" (func 0))
  (export "Array_write" (func 1))
  (export "Array_push" (func 2))
  (export "Sieve_clear" (func 3))
  (export "Sieve_isPrime" (func 4))
  (export "Sieve_nextPrime" (func 5))
  (export "Sieve_countUpTo" (func 6))
  (export "main" (func 7))
  (elem (;0;) (i32.const 0) func 0 1 2 3 4 5 6 7))
