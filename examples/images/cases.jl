# The cases native.jl and check.mjs filter, on the same synthetic image (`test_pixel`), as
# (preset, size, σ, border, gray, post, gain); cases.json has them for check.mjs.
const H, W = 96, 128
test_pixel(y, x) = Int32((x * 7 + y * 3) % 256) | Int32((x * y) % 256) << 8 | Int32(((x ⊻ y) * 5) % 256) << 16
const CASES = [(p, n, σ, b, g, post, gain)
               for (p, n, σ) in ((1, 3, 1.0), (2, 5, 1.0), (3, 7, 1.5), (4, 5, 1.0), (5, 3, 1.0), (6, 9, 1.0),
                                 (7, 3, 1.0), (8, 3, 1.0), (9, 3, 1.0), (10, 3, 1.0), (11, 3, 1.0),
                                 (12, 3, 1.0), (13, 7, 1.0))
               for (b, g, post, gain) in ((1, 0, 1, 1.0), (4, 1, 3, 4.0))]
append!(CASES, [(3, 5, 1.0, b, 0, 1, 1.0) for b in 2:3])
append!(CASES, [(7, 3, 1.0, 1, 0, 2, 4.0)])
