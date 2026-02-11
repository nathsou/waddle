;; Factorial calculator
;; Demonstrates recursive function implementation in WebAssembly

(module
  ;; Type definitions
  (type $t_i32_to_i32 (func (param i32) (result i32)))
  (type $t_void_to_i32 (func (result i32)))
  (type $t_void (func))

  ;; Memory and table
  (table (;0;) 2 2 funcref)
  (memory (;0;) 16)
  (global (;0;) (mut i32) (i32.const 0))

  ;; Function: Calculate factorial recursively
  ;; param: n (i32)
  ;; returns: n! (factorial of n)
  (func $fact (type $t_i32_to_i32) (param $n i32) (result i32)
    local.get $n
    i32.eqz               ;; Check if n == 0
    if (result i32)
      ;; Base case: 0! = 1
      i32.const 1
    else
      ;; Recursive case: n! = n * (n-1)!
      local.get $n
      local.get $n
      i32.const 1
      i32.sub             ;; n - 1
      call $fact          ;; factorial(n - 1)
      i32.mul             ;; n * factorial(n - 1)
    end
  )

  ;; Main function: Calculate 11!
  (func $main (type $t_void_to_i32) (result i32)
    i32.const 11
    call $fact
  )

  ;; Start function: Calculate 10! and discard result
  ;; This runs automatically when the module is instantiated
  (func $start (type $t_void)
    i32.const 10
    call $fact
    drop                  ;; Discard the result
  )

  ;; Exports
  (export "memory" (memory 0))
  (export "fact" (func $fact))
  (export "main" (func $main))
  
  ;; Start section - runs $start automatically on instantiation
  (start $start)
  
  ;; Element segment (function table initialization)
  (elem (;0;) (i32.const 0) func $fact $main)
)
