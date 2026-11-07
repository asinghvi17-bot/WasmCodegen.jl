# Build the page: julia +1.13 --project=. page.jl (after build.jl and native.jl), writing
# images.html with the module embedded
using Base64

dir = @__DIR__
bytes = read(joinpath(dir, "images.wasm"))   # optimized by `compile` (wasm-opt -O3)

# native times on 512 × 512 (native.jl prints them): a 7 × 7 Gaussian, a 5 × 5 sharpening
native = [parse(Float64, match(r": ([0-9.]+) ms", l)[1])
          for l in readlines(`$(Base.julia_cmd()) --project=$dir $(joinpath(dir, "native.jl"))`) if startswith(l, "native:")]

stats = Dict(split(l, "=") |> p -> p[1] => p[2] for l in readlines(joinpath(dir, "stats.txt")))
html = read(joinpath(dir, "page.template.html"), String)
html = replace(html, "__WASM_BASE64__" => base64encode(bytes),
               "__SIZE__" => string(round(Int, length(bytes) / 1024)),
               "__FUNCS__" => stats["functions"], "__OBJECTS__" => stats["objects"],
               "__NATIVE__" => join(native, ", "))
write(joinpath(dir, "images.html"), html)
println("images.html: $(length(html)) bytes (module $(length(bytes)) bytes), native ms $(native)")
