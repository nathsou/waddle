;; ==============================================================================
;; Project Euler Problem 14: Longest Collatz sequence
;; ==============================================================================
;; Find the starting number under 1,000,000 that produces the longest Collatz 
;; chain. The Collatz sequence is defined as:
;;   - If n is even: n / 2
;;   - If n is odd: 3n + 1
;; Continue until reaching 1.
;; ==============================================================================

(module
  ;; Type 0: (i32) -> i32 - Used for isEven, nextCollatz, collatzLen
  (type (;0;) (func (param i32) (result i32)))
  
  ;; Type 1: () -> (i32, i32) - Used for pb14 and main, returns two values
  (type (;1;) (func (result i32 i32)))
  
  ;; --------------------------------------------------------------------------
  ;; Function 0: isEven
  ;; Check if a number is even
  ;; param 0: n (i32) - number to check
  ;; returns: 1 if even, 0 if odd
  ;; --------------------------------------------------------------------------
  (func (;0;) (type 0) (param i32) (result i32)
    local.get 0
    i32.const 1
    i32.and
    i32.eqz)
  
  ;; --------------------------------------------------------------------------
  ;; Function 1: nextCollatz
  ;; Calculate the next number in the Collatz sequence
  ;; param 0: n (i32) - current number
  ;; returns: next number in sequence
  ;; --------------------------------------------------------------------------
  (func (;1;) (type 0) (param i32) (result i32)
    local.get 0
    call 0
    if (result i32)  ;; label = @1
      local.get 0
      i32.const 1
      i32.shr_u
    else
      i32.const 3
      local.get 0
      i32.mul
      i32.const 1
      i32.add
    end)
  
  ;; --------------------------------------------------------------------------
  ;; Function 2: collatzLen
  ;; Calculate the length of the Collatz sequence starting from n
  ;; param 0: n (i32) - starting number
  ;; returns: length of sequence until reaching 1
  ;; --------------------------------------------------------------------------
  (func (;2;) (type 0) (param i32) (result i32)
    (local i32)
    i32.const 1
    local.set 1
    block  ;; label = @1
      loop  ;; label = @2
        local.get 0
        i32.const 1
        i32.eq
        br_if 1 (;@1;)
        local.get 0
        call 1
        local.set 0
        local.get 1
        i32.const 1
        i32.add
        local.set 1
        br 0 (;@2;)
      end
    end
    local.get 1)
  
  ;; --------------------------------------------------------------------------
  ;; Function 3: pb14
  ;; Solve Project Euler Problem 14
  ;; Finds the starting number under 1,000,000 with the longest Collatz chain
  ;; returns: (max_length, number_with_max_length)
  ;; --------------------------------------------------------------------------
  (func (;3;) (type 1) (result i32 i32)
    (local i32 i32 i32 i32)
    i32.const 0
    local.set 0
    i32.const 0
    local.set 1
    i32.const 1
    local.set 2
    block  ;; label = @1
      loop  ;; label = @2
        local.get 2
        i32.const 1000000
        i32.gt_u
        br_if 1 (;@1;)
        local.get 2
        call 2
        local.tee 3
        local.get 0
        i32.gt_u
        if  ;; label = @3
          local.get 3
          local.set 0
          local.get 2
          local.set 1
        end
        local.get 2
        i32.const 1
        i32.add
        local.set 2
        br 0 (;@2;)
      end
    end
    local.get 0
    local.get 1)
  
  ;; --------------------------------------------------------------------------
  ;; Function 4: main
  ;; Entry point - simply calls pb14
  ;; --------------------------------------------------------------------------
  (func (;4;) (type 1) (result i32 i32)
    call 3)
  
  (table (;0;) 5 5 funcref)
  (memory (;0;) 16)
  (global (;0;) (mut i32) (i32.const 0))
  (export "memory" (memory 0))
  (export "isEven" (func 0))
  (export "nextCollatz" (func 1))
  (export "collatzLen" (func 2))
  (export "pb14" (func 3))
  (export "main" (func 4))
  (elem (;0;) (i32.const 0) func 0 1 2 3 4))
