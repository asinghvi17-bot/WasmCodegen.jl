# Bytes for JavaScript

A program giving bytes to JavaScript: a message built in Julia (as a dashboard's update, a
few hundred bytes of MsgPack, would be) given to a function of the page's own in one call.
`Config(import_libraries = ["page"])` makes `ccall((:message, "page"), Cvoid, (Vector{UInt8},),
msg)` a call of the import `page.message(offset, length)`, the message's bytes in the module's
memory, which `host.bytes(offset, length)` of `js/julia.mjs` gives as a `Uint8Array`
(`model.jl`, `run.mjs`). A `String` is passed the same way (`host.string` decodes it).

```
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. build.jl    # jsbytes.wasm
node run.mjs                        # the message both ways, and their times
```

`run.mjs` also reads the message as a module without the import must, 4 bytes per call of
an export (`message_word`), checks that both give the same bytes, and times each for a
message of 1 KiB. In Node 26, giving it takes about 1.3 µs, reading it by 256 calls about
5.7 µs.
