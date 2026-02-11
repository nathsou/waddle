;; Project Euler Problem 92: Square digit chains
;; Count how many starting numbers below 10,000,000 reach 89

(module
  ;; Type definitions
  (type $t_i32_to_i32 (func (param i32) (result i32)))
  (type $t_void_to_i32 (func (result i32)))

  ;; Memory and table
  (table (;0;) 4 4 funcref)
  (memory (;0;) 16)
  (global (;0;) (mut i32) (i32.const 0))

  ;; Function: Calculate sum of squares of digits
  ;; param: n (i32)
  ;; returns: sum of squared digits
  (func $digitsSquareSum (type $t_i32_to_i32) (param $n i32) (result i32)
    (local $sum i32)
    
    ;; Initialize sum to 0
    i32.const 0
    local.set $sum
    
    block $done
      loop $continue
        ;; Check if n <= 0
        local.get $n
        i32.const 0
        i32.le_u
        br_if $done
        
        ;; Add square of last digit to sum
        local.get $sum
        local.get $n
        i32.const 10
        i32.rem_u         ;; Get last digit (n % 10)
        call $square      ;; Square it
        i32.add
        local.set $sum
        
        ;; Remove last digit from n
        local.get $n
        i32.const 10
        i32.div_u         ;; n / 10
        local.set $n
        
        br $continue
      end
    end
    
    local.get $sum
  )

  ;; Helper function: Square a number
  ;; param: x (i32)
  ;; returns: x * x
  (func $square (type $t_i32_to_i32) (param $x i32) (result i32)
    local.get $x
    local.get $x
    i32.mul
  )

  ;; Function: Check if a number reaches 89
  ;; param: n (i32)
  ;; returns: 1 if reaches 89, 0 if reaches 1
  (func $reaches89 (type $t_i32_to_i32) (param $n i32) (result i32)
    block $done
      loop $continue
        ;; Check if we've reached 1
        local.get $n
        i32.const 1
        i32.eq
        br_if $done
        
        ;; Check if we've reached 89
        local.get $n
        i32.const 89
        i32.eq
        if
          i32.const 1
          return
        end
        
        ;; Calculate next value in chain
        local.get $n
        call $digitsSquareSum
        local.set $n
        
        br $continue
      end
    end
    
    ;; Reached 1, so return 0
    i32.const 0
  )

  ;; Main function: Count numbers below 10,000,000 that reach 89
  (func $main (type $t_void_to_i32) (result i32)
    (local $current i32)
    (local $count i32)
    
    ;; Initialize current to 1
    i32.const 1
    local.set $current
    
    ;; Initialize count to 0
    i32.const 0
    local.set $count
    
    block $done
      loop $continue
        ;; Check if current >= 10,000,000
        local.get $current
        i32.const 10000000
        i32.ge_u
        br_if $done
        
        ;; Check if current reaches 89
        local.get $current
        call $reaches89
        if
          ;; Increment count
          local.get $count
          i32.const 1
          i32.add
          local.set $count
        end
        
        ;; Increment current
        local.get $current
        i32.const 1
        i32.add
        local.set $current
        
        br $continue
      end
    end
    
    local.get $count
  )

  ;; Exports
  (export "memory" (memory 0))
  (export "digitsSquareSum" (func $digitsSquareSum))
  (export "$lambda1" (func $square))
  (export "reaches89" (func $reaches89))
  (export "main" (func $main))
  
  ;; Element segment (function table initialization)
  (elem (;0;) (i32.const 0) func $digitsSquareSum $square $reaches89 $main)
)
