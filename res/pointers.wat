;; Pointer/Array operations demonstration
;; Shows memory read/write operations with array-like access

(module
  ;; Type definitions
  (type $t_i32_to_i32 (func (param i32) (result i32)))
  (type $t_i32_i32_to_void (func (param i32 i32)))
  (type $t_void_to_i32 (func (result i32)))

  ;; Memory and table
  (table (;0;) 4 4 funcref)
  (memory (;0;) 16)
  (global $stack_ptr (mut i32) (i32.const 0))
  (global $element_size i32 (i32.const 4))  ;; Size of u32 in bytes

  ;; Function: Read u32 from array at given index
  ;; param: index (i32) - array index
  ;; returns: u32 value at that index
  (func $read_u32 (type $t_i32_to_i32) (param $index i32) (result i32)
    local.get $index
    global.get $element_size
    i32.mul               ;; Calculate byte offset (index * 4)
    i32.load align=1      ;; Load 32-bit value from memory
  )

  ;; Function: Write u32 to array at given index
  ;; param: index (i32) - array index
  ;; param: value (i32) - value to write
  (func $write_u32 (type $t_i32_i32_to_void) (param $index i32) (param $value i32)
    local.get $index
    global.get $element_size
    i32.mul               ;; Calculate byte offset (index * 4)
    local.get $value
    i32.store             ;; Store 32-bit value to memory
  )

  ;; Main function: Fill array with squares and return element at index 42
  ;; Creates an array where arr[i] = i^2, then returns arr[42]
  (func $main (type $t_void_to_i32) (result i32)
    (local $i i32)
    
    ;; Initialize loop counter
    i32.const 0
    local.set $i
    
    ;; Loop to fill array: for i in 0..100
    block $done
      loop $continue
        ;; Check if i >= 100
        local.get $i
        i32.const 100
        i32.ge_u
        br_if $done
        
        ;; Write arr[i] = square(i)
        local.get $i
        local.get $i
        call $square
        call $write_u32
        
        ;; Increment i
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        
        br $continue
      end
    end
    
    ;; Return arr[42] = 42^2 = 1764
    i32.const 42
    call $read_u32
  )

  ;; Helper function: Square a number
  ;; param: x (i32)
  ;; returns: x * x
  (func $square (type $t_i32_to_i32) (param $x i32) (result i32)
    local.get $x
    local.get $x
    i32.mul
  )

  ;; Exports
  (export "memory" (memory 0))
  (export "read_u32" (func $read_u32))
  (export "write_u32" (func $write_u32))
  (export "main" (func $main))
  (export "$lambda3" (func $square))
  
  ;; Element segment (function table initialization)
  (elem (;0;) (i32.const 0) func $read_u32 $write_u32 $main $square)
)
