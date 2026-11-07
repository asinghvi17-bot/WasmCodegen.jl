# Image filtering in WebAssembly

JuliaImages' filtering, compiled to WebAssembly GC: ImageFiltering's `imfilter` on
ImageCore's `RGB{N0f8}` and `Gray` pixels, from the packages of the General registry,
unchanged, and a page to try it, with a kernel whose weights you choose.

```
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. build.jl        # images.wasm (entry points in model.jl)
julia +1.13 --project=. native.jl       # the cases of cases.jl, natively: reference.bin
node --experimental-wasm-exnref check.mjs   # the module's pixels must match
julia +1.13 --project=. page.jl         # images.html
```

The page writes an image's pixels into the module (an `Int32` each, its red, green and blue
bytes), sets the kernel's weights, filters, and reads the filtered pixels back. The filter is
`imfilter(img, centered(K), border, Algorithm.FIR())`, a correlation, with one of
ImageFiltering's borders (`"replicate"`, `"reflect"`, `"circular"`, `Fill(0)`), in color or
on `Gray.(img)`. The presets are ImageFiltering's kernels (`Kernel.gaussian`, `Kernel.DoG`,
`Kernel.sobel`, `Kernel.prewitt`, `Kernel.scharr`, `Kernel.laplacian2d`) and a few classic
3 × 3 ones. As natively, `imfilter` factors the kernel by its SVD and filters a kernel of
rank one with two 1-D passes; the SVD is LAPACK's `gesdd` from WasmCodegen's runtime.

On the 29 cases of `cases.jl` (every preset, each border, color and gray), the module's
pixels equal native Julia's, or differ by one level in a channel (about 4% of them, mostly
for the separable edge kernels): where a value lands on a rounding boundary of `N0f8`, the
last bits of the SVD's factors, which differ from OpenBLAS's, decide it. The module is about
240 KB; a 7 × 7 Gaussian on 512 × 512 pixels takes about 28 ms in Node.js, 6 ms natively.
