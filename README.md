# Waddle

WASM core 1.0 Virtual Machine in Zig

## Features

- [x] Binary format (.wasm) parser
- [x] WAT file support (using bundled `wat2wasm` tool) 
- [x] Bytecode interpreter

## Extensions

- [x] [Multi-value](https://github.com/WebAssembly/spec/blob/main/proposals/multi-value/Overview.md)
- [x] [Non-trapping Float-to-int Conversions](https://github.com/WebAssembly/spec/blob/main/proposals/nontrapping-float-to-int-conversion/Overview.md)
- [ ] [Bulk Memory Operations](https://github.com/WebAssembly/spec/blob/main/proposals/bulk-memory-operations/Overview.md)
- [x] [Reference Types](https://github.com/WebAssembly/spec/blob/main/proposals/reference-types/Overview.md)

## TODO
- [ ] Module validation
- [ ] Pass all official tests
- [ ] WASI preview 1 support
- [ ] Move to a register VM with SSA passes
