# Image filtering with JuliaImages, compiled to WebAssembly: ImageFiltering's `imfilter` on
# ImageCore's colors, with a kernel the page edits.
#
# The page writes an image's pixels into the module and the weights of the kernel, filters,
# and reads the filtered pixels back. Only numbers cross the boundary: a pixel is an Int32 of
# its red, green and blue bytes (r | g << 8 | b << 16).

using ImageFiltering, ImageCore, OffsetArrays

const IMG = Ref(Matrix{RGB{N0f8}}(undef, 0, 0))
const OUT = Ref(Matrix{RGB{N0f8}}(undef, 0, 0))
const KERN = Ref(zeros(3, 3))

"Make room for an image of `h` rows and `w` columns."
img_resize(h::Int32, w::Int32)::Int32 = (IMG[] = Matrix{RGB{N0f8}}(undef, h, w); Int32(length(IMG[])))

rgb(p::Int32) = RGB{N0f8}(reinterpret(N0f8, p % UInt8), reinterpret(N0f8, (p >> 8) % UInt8),
                          reinterpret(N0f8, (p >> 16) % UInt8))
packed(c::RGB{N0f8}) = Int32(reinterpret(red(c))) | Int32(reinterpret(green(c))) << 8 |
                       Int32(reinterpret(blue(c))) << 16

"Set the pixel `i` (1-based, in row-major order, as a canvas has them)."
function img_set(i::Int32, p::Int32)::Int32
    img = IMG[]
    y, x = divrem(i - 1, size(img, 2))
    img[y+1, x+1] = rgb(p)
    return Int32(0)
end

"The filtered pixel `i` (1-based, row-major)."
function out_get(i::Int32)::Int32
    out = OUT[]
    y, x = divrem(i - 1, size(out, 2))
    return packed(out[y+1, x+1])
end

## the kernel

"Make the kernel `n` × `n` (`n` odd), of zeros."
kernel_resize(n::Int32)::Int32 = (KERN[] = zeros(n, n); n)
kernel_size()::Int32 = Int32(size(KERN[], 1))
kernel_set(i::Int32, j::Int32, v::Float64)::Int32 = (KERN[][i, j] = v; Int32(0))
kernel_get(i::Int32, j::Int32)::Float64 = KERN[][i, j]

# `k` (of odd sizes, centered: its center at index 0) at the center of the kernel `K`, cropped
function put_centered!(K::Matrix{Float64}, k::AbstractMatrix)
    c = (size(K, 1) + 1) ÷ 2
    for I in CartesianIndices(k)
        i, j = c + I[1], c + I[2]
        (1 <= i <= size(K, 1) && 1 <= j <= size(K, 2)) && (K[i, j] = k[I])
    end
    return K
end
put_centered!(K::Matrix{Float64}, k::Matrix{Float64}) = put_centered!(K, centered(k))

const PRESETS = ["identity", "box blur", "Gaussian blur", "sharpen", "Laplacian",
                 "difference of Gaussians", "Sobel x", "Sobel y", "Prewitt x", "Scharr x",
                 "emboss", "outline", "motion blur"]

"""
Set the kernel to the preset `p` (of `PRESETS`), `n` × `n`, of width `σ` (the Gaussians'):
ImageFiltering's kernels (`Kernel.gaussian`, `Kernel.DoG`, `Kernel.sobel`, ...) where it has
them. Returns `n`.
"""
function kernel_preset(p::Int32, n::Int32, σ::Float64)::Int32
    K = zeros(n, n)
    c = (n + 1) ÷ 2
    if p == 1
        K[c, c] = 1
    elseif p == 2
        fill!(K, 1 / n^2)
    elseif p == 3
        put_centered!(K, Kernel.gaussian((σ, σ), (n, n)))
    elseif p == 4
        # unsharp masking: the image plus its difference from its blur
        put_centered!(K, Kernel.gaussian((σ, σ), (n, n)))
        K .*= -1
        K[c, c] += 2
    elseif p == 5
        put_centered!(K, Kernel.laplacian2d(0))
    elseif p == 6
        put_centered!(K, Kernel.DoG((σ, σ), (1.6σ, 1.6σ), (n, n)))
    elseif p == 7
        put_centered!(K, Kernel.sobel()[2])
    elseif p == 8
        put_centered!(K, Kernel.sobel()[1])
    elseif p == 9
        put_centered!(K, Kernel.prewitt()[2])
    elseif p == 10
        put_centered!(K, Kernel.scharr()[2])
    elseif p == 11
        put_centered!(K, [-2.0 -1.0 0.0; -1.0 1.0 1.0; 0.0 1.0 2.0])
    elseif p == 12
        put_centered!(K, [-1.0 -1.0 -1.0; -1.0 8.0 -1.0; -1.0 -1.0 -1.0])
    else
        for i in 1:n
            K[i, i] = 1 / n
        end
    end
    KERN[] = K
    return n
end

"Whether `imfilter` finds the kernel separable (of rank 1, by its SVD): two 1-D passes."
kernel_separable()::Int32 = Int32(ImageFiltering.isseparable(ImageFiltering.factorkernel(centered(KERN[]))))

## filtering

function filtered(img, k, b::Int32)
    alg = ImageFiltering.Algorithm.FIR()
    return b == 1 ? imfilter(img, k, "replicate", alg) : b == 2 ? imfilter(img, k, "reflect", alg) :
           b == 3 ? imfilter(img, k, "circular", alg) : imfilter(img, k, Fill(zero(eltype(img))), alg)
end

# a filtered value as a pixel: times `gain`, then 1: clamped to [0, 1], 2: its absolute value,
# 3: plus ½ (signed responses, as edges, around mid-gray)
function finish(c::Colorant, post::Int32, gain::Float64)
    v = gain * RGB{Float64}(c)
    v = post == 2 ? mapc(abs, v) : post == 3 ? v + RGB(0.5, 0.5, 0.5) : v
    return RGB{N0f8}(clamp01nan(v))
end

"""
Filter the image with the kernel (`imfilter`: a correlation, the kernel centered), its border
`b` 1: replicate, 2: reflect, 3: circular, 4: zero, in color or (`gray` 1) as `Gray`; each
filtered value as `finish` makes it a pixel. Returns the number of pixels.
"""
function filter_image(b::Int32, gray::Int32, post::Int32, gain::Float64)::Int32
    img, k = IMG[], centered(KERN[])
    size(OUT[]) == size(img) || (OUT[] = similar(img))
    out = OUT[]
    if gray == 1
        out .= finish.(filtered(Gray.(img), k, b), post, gain)
    else
        out .= finish.(filtered(img, k, b), post, gain)
    end
    return Int32(length(out))
end

const ENTRIES = [(img_resize, (Int32, Int32)), (img_set, (Int32, Int32)), (out_get, (Int32,)),
                 (kernel_resize, (Int32,)), (kernel_size, ()), (kernel_set, (Int32, Int32, Float64)),
                 (kernel_get, (Int32, Int32)), (kernel_preset, (Int32, Int32, Float64)),
                 (kernel_separable, ()), (filter_image, (Int32, Int32, Int32, Float64))]
