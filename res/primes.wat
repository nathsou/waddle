;; Prime number calculator
;; Counts prime numbers less than 1,000,000

(module
  ;; Type definitions
  (type $t_i32_to_i32 (func (param i32) (result i32)))
  (type $t_void_to_i32 (func (result i32)))

  ;; Memory and table
  (table (;0;) 4 4 funcref)
  (memory (;0;) 16)
  (global (;0;) (mut i32) (i32.const 0))

  ;; Function: Check if a number is even
  ;; param: n (i32)
  ;; returns: 1 if even, 0 if odd
  (func $isEven (type $t_i32_to_i32) (param $n i32) (result i32)
    local.get $n
    i32.const 1
    i32.and           ;; n & 1
    i32.eqz           ;; result == 0 (i.e., even)
  )

  ;; Function: Check if a number is prime
  ;; param: n (i32)
  ;; returns: 1 if prime, 0 if composite
  (func $isPrime (type $t_i32_to_i32) (param $n i32) (result i32)
    (local $divisor i32)
    
    ;; Handle n < 2
    local.get $n
    i32.const 2
    i32.lt_u
    if
      i32.const 0
      return
    end
    
    ;; Handle n == 2 (the only even prime)
    local.get $n
    i32.const 2
    i32.eq
    if
      i32.const 1
      return
    end
    
    ;; Check if n is even (and not 2)
    local.get $n
    call $isEven
    if
      i32.const 0
      return
    end
    
    ;; Check odd divisors from 3 up to sqrt(n)
    i32.const 3
    local.set $divisor
    
    block $done
      loop $continue
        ;; Check if divisor^2 > n (i.e., divisor > sqrt(n))
        local.get $divisor
        local.get $divisor
        i32.mul
        local.get $n
        i32.gt_u
        br_if $done
        
        ;; Check if n is divisible by divisor
        local.get $n
        local.get $divisor
        i32.rem_u
        i32.eqz
        if
          ;; Found a divisor, so not prime
          i32.const 0
          return
        end
        
        ;; Try next odd number
        local.get $divisor
        i32.const 2
        i32.add
        local.set $divisor
        
        br $continue
      end
    end
    
    ;; No divisors found, so n is prime
    i32.const 1
  )

  ;; Function: Count prime numbers less than n
  ;; param: limit (i32)
  ;; returns: count of primes < limit
  (func $countPrimesLessThan (type $t_i32_to_i32) (param $limit i32) (result i32)
    (local $current i32)
    (local $count i32)
    
    ;; Initialize: start from limit and count down
    local.get $limit
    local.set $current
    
    i32.const 0
    local.set $count
    
    block $done
      loop $continue
        ;; Check if current <= 1
        local.get $current
        i32.const 1
        i32.le_u
        br_if $done
        
        ;; Check if current is prime
        local.get $current
        call $isPrime
        if
          ;; Increment count
          local.get $count
          i32.const 1
          i32.add
          local.set $count
        end
        
        ;; Decrement current
        local.get $current
        i32.const 1
        i32.sub
        local.set $current
        
        br $continue
      end
    end
    
    local.get $count
  )

  ;; Main function: Count primes less than 1,000,000
  (func $main (type $t_void_to_i32) (result i32)
    i32.const 1000000
    call $countPrimesLessThan
  )

  ;; Exports
  (export "memory" (memory 0))
  (export "isEven" (func $isEven))
  (export "isPrime" (func $isPrime))
  (export "countPrimesLessThan" (func $countPrimesLessThan))
  (export "main" (func $main))
  
  ;; Element segment (function table initialization)
  (elem (;0;) (i32.const 0) func $isEven $isPrime $countPrimesLessThan $main)
)
