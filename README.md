# Waddle

WASM core 1.0 Virtual Machine in Zig

## Features

- [x] Binary format (.wasm) parser
- [x] Text format (.wat) parser
- [x] Bytecode interpreter

## Extensions

- [x] [Multi-value](https://github.com/WebAssembly/spec/blob/main/proposals/multi-value/Overview.md)
- [ ] [Bulk Memory Operations](https://github.com/WebAssembly/spec/blob/main/proposals/bulk-memory-operations/Overview.md)

## TODO
- [ ] Module validation
- [ ] Pass all official tests
- [ ] WASI preview 1 support
- [ ] Move to a register VM with SSA passes
- [ ] AOT compiler
