;; Switch statement demonstration
;; Shows use of br_table instruction for efficient multi-way branching

(module
  ;; Type definitions
  (type $t_i32_to_i32 (func (param i32) (result i32)))
  (type $t_void_to_i32 (func (result i32)))

  ;; Function: Map input value to power of 10 using switch/br_table
  ;; param: n (i32) - input value (0-3)
  ;; returns: 10^n for n in [0,3], or 1000 for any other value
  (func $switch_demo (type $t_i32_to_i32) (param $n i32) (result i32)
    block $default         ;; Case default (fallthrough)
      block $case_2        ;; Case 2
        block $case_1      ;; Case 1
          block $case_0    ;; Case 0
            ;; Branch table: maps input to case block
            local.get $n
            br_table 
              $case_0      ;; If n == 0, goto case_0
              $case_1      ;; If n == 1, goto case_1
              $case_2      ;; If n == 2, goto case_2
              $default     ;; Otherwise, goto default
          end
          
          ;; Case 0: return 1 (10^0)
          i32.const 1
          return
        end
        
        ;; Case 1: return 10 (10^1)
        i32.const 10
        return
      end
      
      ;; Case 2: return 100 (10^2)
      i32.const 100
      return
    end
    
    ;; Default case: return 1000 (10^3)
    i32.const 1000
    return
  )

  ;; Main function: Test the switch with multiple values
  ;; Computes: switch(0) + switch(1) + switch(2) + switch(99)
  ;;         = 1 + 10 + 100 + 1000 = 1111
  (func $main (type $t_void_to_i32) (result i32)
    ;; Test case 0
    i32.const 0
    call $switch_demo
    
    ;; Test case 1
    i32.const 1
    call $switch_demo
    i32.add
    
    ;; Test case 2
    i32.const 2
    call $switch_demo
    i32.add
    
    ;; Test default case (99 -> default)
    i32.const 99
    call $switch_demo
    i32.add
  )

  ;; Exports
  (export "main" (func $main))
)
