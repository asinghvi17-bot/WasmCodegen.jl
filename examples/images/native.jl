# Filter natively the cases of cases.jl: julia +1.13 --project=. native.jl, which writes
# reference.bin (each case's pixels, Int32) and cases.json for check.mjs, and prints the time
include("model.jl")
include("cases.jl")

img_resize(Int32(H), Int32(W))
for y in 1:H, x in 1:W
    img_set(Int32((y - 1) * W + x), test_pixel(y, x))
end
ref = Int32[]
seps = Int[]
for (p, n, σ, b, g, post, gain) in CASES
    kernel_preset(Int32(p), Int32(n), σ)
    push!(seps, kernel_separable())
    filter_image(Int32(b), Int32(g), Int32(post), gain)
    append!(ref, [out_get(Int32(i)) for i in 1:H*W])
end
write(joinpath(@__DIR__, "reference.bin"), ref)
open(joinpath(@__DIR__, "cases.json"), "w") do io
    print(io, "{\"H\": $H, \"W\": $W, \"cases\": [", join(("[" * join(c, ", ") * "]" for c in CASES), ", "),
          "], \"separable\": [", join(seps, ", "), "]}")
end
# the time of a 512 × 512 Gaussian blur (7 × 7, separable) and a 5 × 5 sharpening (not)
img_resize(Int32(512), Int32(512))
for y in 1:512, x in 1:512
    img_set(Int32((y - 1) * 512 + x), test_pixel(y, x))
end
for (p, n) in ((3, 7), (4, 5))
    kernel_preset(Int32(p), Int32(n), 1.5)
    filter_image(Int32(1), Int32(0), Int32(1), 1.0)
    t = minimum(@elapsed(filter_image(Int32(1), Int32(0), Int32(1), 1.0)) for _ in 1:20)
    println("native: $(PRESETS[p]) $n × $n on 512 × 512: $(round(t * 1000, digits=1)) ms")
end
println("$(length(CASES)) cases, separable: $seps")
