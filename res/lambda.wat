;; ==============================================================================
;; Lambda/Higher-order function demonstration
;; ==============================================================================
;; Shows indirect function calls through function table.
;; Demonstrates applying a function twice: square(square(7)) = 7^4 = 2401
;; ==============================================================================

(module
  ;; Type 0: (i32) -> i32 - Function that takes i32 and returns i32
  (type (;0;) (func (param i32) (result i32)))
  
  ;; Type 1: () -> i32 - Function that returns i32
  (type (;1;) (func (result i32)))
  
  ;; Type 2: (i32, i32) -> i32 - Function that takes two i32 and returns i32
  (type (;2;) (func (param i32 i32) (result i32)))
  
  ;; --------------------------------------------------------------------------
  ;; Function 0: main
  ;; Entry point - demonstrates higher-order function usage
  ;; returns: result of square(square(7)) = 2401
  ;; --------------------------------------------------------------------------
  (func (;0;) (type 1) (result i32)
    i32.const 2           ;; Push function table index 2 (square function)
    i32.const 7           ;; Push input value 7
    call 1)               ;; Call apply_twice(2, 7)
  
  ;; --------------------------------------------------------------------------
  ;; Function 1: apply_twice
  ;; Higher-order function: Apply a function twice
  ;; param 0: func_idx - index of function in function table
  ;; param 1: x - input value
  ;; returns: result of f(f(x))
  ;; --------------------------------------------------------------------------
  (func (;1;) (type 2) (param i32 i32) (result i32)
    local.get 1           ;; Get x
    local.get 0           ;; Get func_idx
    call_indirect (type 0)  ;; Call f(x) - first application
    local.get 0           ;; Get func_idx again
    call_indirect (type 0))  ;; Call f(result) - second application
  
  ;; --------------------------------------------------------------------------
  ;; Function 2: square
  ;; Lambda function: Square a number
  ;; param 0: x
  ;; returns: x * x
  ;; --------------------------------------------------------------------------
  (func (;2;) (type 0) (param i32) (result i32)
    local.get 0           ;; Get x
    local.get 0           ;; Get x again
    i32.mul)              ;; Multiply: x * x
  
  ;; Function table with 3 slots
  (table (;0;) 3 3 funcref)
  
  ;; Linear memory: 16 pages
  (memory (;0;) 16)
  
  ;; Global variable (mutable)
  (global (;0;) (mut i32) (i32.const 0))
  
  ;; Exports
  (export "memory" (memory 0))
  (export "main" (func 0))
  (export "$lambda1" (func 1))
  (export "$lambda2" (func 2))
  
  ;; Initialize function table at offset 0 with all functions
  ;; Table layout: [0] = main, [1] = apply_twice, [2] = square
  (elem (;0;) (i32.const 0) func 0 1 2))
