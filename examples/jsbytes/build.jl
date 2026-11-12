# Build jsbytes.wasm from model.jl: julia +1.13 --project=. build.jl
using WasmCodegen
include("model.jl")

c = WasmCodegen.compile([WasmCodegen.Entry(f, at) for (f, at) in ENTRIES];
                        config = WasmCodegen.Config(import_libraries = ["page"]))
write(joinpath(@__DIR__, "jsbytes.wasm"), c.bytes)
println("jsbytes.wasm: $(length(c.bytes)) bytes, $(length(c.cgm.funcs)) functions")
