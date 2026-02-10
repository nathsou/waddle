(module
  ;; Internal helper function: Maps an index to a score.
  ;; 0 -> 1
  ;; 1 -> 10
  ;; 2 -> 100
  ;; Default -> 1000
  (func $get_score (param $index i32) (result i32)
    
    ;; Nesting blocks to create jump targets
    (block $block_default
      (block $block_case_2
        (block $block_case_1
          (block $block_case_0
            
            local.get $index
            
            ;; br_table:
            ;; 0 -> break to $block_case_0
            ;; 1 -> break to $block_case_1
            ;; 2 -> break to $block_case_2
            ;; anything else -> break to $block_default
            br_table $block_case_0 $block_case_1 $block_case_2 $block_default
          )
          
          ;; -- Case 0 Logic --
          i32.const 1
          return
        )

        ;; -- Case 1 Logic --
        i32.const 10
        return
      )

      ;; -- Case 2 Logic --
      i32.const 100
      return
    )

    ;; -- Default Logic --
    i32.const 1000
    return
  )

  ;; Main Export: Returns the sum of different cases
  (func (export "main") (result i32)
    ;; We will sum: case(0) + case(1) + case(2) + case(99)
    ;; Expected:    1       + 10      + 100     + 1000      = 1111
    
    i32.const 0
    call $get_score  ;; stack: 1

    i32.const 1
    call $get_score  ;; stack: 1, 10
    i32.add          ;; stack: 11

    i32.const 2
    call $get_score  ;; stack: 11, 100
    i32.add          ;; stack: 111

    i32.const 99     ;; (Out of bounds/Default)
    call $get_score  ;; stack: 111, 1000
    i32.add          ;; stack: 1111
  )
)