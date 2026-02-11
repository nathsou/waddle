;; Fibonacci calculator
;; Demonstrates tail-recursive optimization

(module
  ;; Type definitions
  (type $t_i32_to_i32 (func (param i32) (result i32)))
  (type $t_i32_i32_i32_to_i32 (func (param i32 i32 i32) (result i32)))
  (type $t_void_to_i32 (func (result i32)))

  ;; Memory and table
  (table (;0;) 3 3 funcref)
  (memory (;0;) 16)
  (global (;0;) (mut i32) (i32.const 0))

  ;; Function: Calculate Fibonacci number (wrapper)
  ;; param: n (i32) - which Fibonacci number to calculate
  ;; returns: nth Fibonacci number
  (func $fib (type $t_i32_to_i32) (param $n i32) (result i32)
    local.get $n
    i32.const 0           ;; Initial value of fib(0) = 0
    i32.const 1           ;; Initial value of fib(1) = 1
    call $fib_helper
  )

  ;; Helper function: Tail-recursive Fibonacci implementation
  ;; param: counter (i32) - remaining iterations
  ;; param: a (i32) - current Fibonacci number
  ;; param: b (i32) - next Fibonacci number
  ;; returns: nth Fibonacci number
  (func $fib_helper (type $t_i32_i32_i32_to_i32) (param $counter i32) (param $a i32) (param $b i32) (result i32)
    local.get $counter
    i32.eqz               ;; Check if counter == 0
    if (result i32)
      ;; Base case: return a
      local.get $a
    else
      ;; Recursive case: fib(counter-1, b, a+b)
      local.get $counter
      i32.const 1
      i32.sub             ;; counter - 1
      
      local.get $b        ;; new a = old b
      
      local.get $a
      local.get $b
      i32.add             ;; new b = a + b
      
      call $fib_helper
    end
  )

  ;; Main function: Calculate the 83rd Fibonacci number
  (func $main (type $t_void_to_i32) (result i32)
    i32.const 83
    call $fib
  )

  ;; Exports
  (export "memory" (memory 0))
  (export "fib" (func $fib))
  (export "$lambda1" (func $fib_helper))
  (export "main" (func $main))
  
  ;; Element segment (function table initialization)
  (elem (;0;) (i32.const 0) func $fib $fib_helper $main)
)
