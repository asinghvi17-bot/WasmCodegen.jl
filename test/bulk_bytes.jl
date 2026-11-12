# Bulk copies of bytes: `memmove` between pointers whose arrays are known only at run time
# (`Runtime.ptr_memmove`: `write`/`unsafe_write` to an IOBuffer, `read!` from one, copies
# through pointers that crossed a call). Between a memory of bytes and a memory of wider
# elements, a loop over the elements; before, by 8-byte words through the pointers' owners
# (or byte by byte, misaligned): a `write` of 256 KiB of Float32 to an IOBuffer took ~2.4x as
# long in Node, a `read!` of them ~5x.
# Copies between arrays and dense arrays reinterpreted (`collect(reinterpret(UInt8, img))`):
# one `memmove` of their bytes; before, Base copied each element through `Ref`s and pointers.

struct BBRGBA; r::UInt8; g::UInt8; b::UInt8; a::UInt8; end   # as RGBA{N0f8}
struct BBN8; i::UInt8; end                                    # as N0f8
struct BBRGB; r::BBN8; g::BBN8; b::BBN8; end                  # as RGB{N0f8}

# a checksum of bytes, and their count
function bb_sum(v::AbstractArray{UInt8})
    h = 0xcbf29ce484222325
    for x in v
        h = (h ⊻ x) * 0x100000001b3
    end
    return (length(v), h)
end
bb_bytes(n) = UInt8[UInt8((i * 31 + (i >> 8)) % 256) for i in 1:n]
bb_img(n) = [BBRGBA(UInt8(i % 256), UInt8(j % 256), UInt8((i * j) % 256), UInt8((i + 3j) % 256)) for i in 1:n, j in 1:3]

# bytes, wider elements and a string written to an IOBuffer (`unsafe_write` of a pointer
# without origin), as MsgPack and Bonito write them
function bb_write(n::Int)
    io = IOBuffer()
    write(io, 0xc7)                       # one byte first: what follows is misaligned
    write(io, bb_bytes(n))
    write(io, Float32[i * 0.5f0 for i in 1:n])
    write(io, Int16[i - 7 for i in 1:n])
    write(io, Float64[i / 3 for i in 1:n])
    write(io, UInt64[i * 0x0101010101010101 for i in 1:n])
    write(io, "héllo"^n)
    return bb_sum(take!(io))
end

# misaligned ranges of wider elements (by bytes through their owners), written and read
@noinline bb_unsafe_write(io, p::Ptr{UInt8}, n::Int) = unsafe_write(io, p, UInt(n))
function bb_misaligned(n::Int)
    io = IOBuffer()
    a = Float32[i * 1.25f0 for i in 1:n]
    b = UInt64[i * 0x0102030405060708 for i in 1:n]
    GC.@preserve a b begin
        bb_unsafe_write(io, Ptr{UInt8}(pointer(a)) + 1, 4n - 2)
        bb_unsafe_write(io, Ptr{UInt8}(pointer(b)) + 3, 8n - 5)
    end
    return bb_sum(take!(io))
end

# bytes read into wider elements (`read!`: element by element), aligned or not
function bb_read(n::Int)
    io = IOBuffer(bb_bytes(4n + 8n + 1))
    a = Vector{Float32}(undef, n)
    read!(io, a)
    skip(io, 1)
    b = Vector{UInt64}(undef, n)
    read!(io, b)
    s = UInt64(0)
    for x in a; s = s * 31 + reinterpret(UInt32, x); end
    for x in b; s = s * 31 + x; end
    return s
end

# copies through pointers between arrays of other element types and within one array,
# overlapping forwards and backwards
@noinline bb_copy!(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::Int) = (unsafe_copyto!(dst, src, n); nothing)
function bb_copies(n::Int)
    f = Float32[i * 0.75f0 for i in 1:n]
    u = zeros(UInt64, n)
    h = zeros(Int16, 2n)
    GC.@preserve f u h begin
        bb_copy!(Ptr{UInt8}(pointer(u)), Ptr{UInt8}(pointer(f)), 4n)          # Float32 -> UInt64
        bb_copy!(Ptr{UInt8}(pointer(h)) + 1, Ptr{UInt8}(pointer(f)), 4n - 1)  # misaligned
        bb_copy!(Ptr{UInt8}(pointer(f)) + 2, Ptr{UInt8}(pointer(f)), 4n - 2)  # overlapping
        bb_copy!(Ptr{UInt8}(pointer(u)), Ptr{UInt8}(pointer(u)) + 4, 8n - 4)
    end
    s = UInt64(0)
    for x in f; s = s * 31 + reinterpret(UInt32, x); end
    for x in u; s = s * 31 + x; end
    for x in h; s = s * 31 + reinterpret(UInt16, x); end
    return s
end

# copies within one array through pointers to its bytes and to its elements (one owner),
# overlapping, the destination after the source and before it, aligned to the elements or
# not (by 8-byte words or by bytes, backwards when the destination is after)
@noinline bb_copy_elems!(dst::Ptr{T}, src::Ptr{T}, n::Int) where {T} = (unsafe_copyto!(dst, src, n); nothing)
function bb_overlap(n::Int)
    f = Float32[i * 0.75f0 for i in 1:4n]
    u = UInt64[i * 0x0102030405060708 for i in 1:2n]
    v = bb_bytes(8n)
    GC.@preserve f u v begin
        pf, pu, pv = pointer(f), pointer(u), pointer(v)
        bf, bu = Ptr{UInt8}(pf), Ptr{UInt8}(pu)
        bb_copy!(bf + 4, bf, 8n)                                  # Float32s as bytes
        bb_copy!(bf, bf + 8, 8n)
        bb_copy!(bf + 3, bf, 8n + 1)
        bb_copy!(bf + 1, bf + 6, 8n)
        bb_copy_elems!(pf + 4, pf, 2n)                            # as Float32s
        bb_copy_elems!(pf, pf + 8, 2n)
        bb_copy!(bu + 8, bu, 8n)                                  # UInt64s as bytes
        bb_copy!(bu, bu + 16, 8n)
        bb_copy!(bu + 5, bu, 8n - 3)
        bb_copy!(bu + 2, bu + 7, 8n - 7)
        bb_copy_elems!(pu + 8, pu, n)                             # as UInt64s
        bb_copy_elems!(pu, pu + 8, n)
        bb_copy_elems!(Ptr{Float32}(pu) + 4, Ptr{Float32}(pu), 2n) # as Float32s
        bb_copy_elems!(Ptr{Float32}(pu), Ptr{Float32}(pu) + 12, 2n)
        bb_copy!(pv + 1, pv, 4n)                                  # bytes
        bb_copy!(pv, pv + 3, 4n)
        bb_copy_elems!(Ptr{UInt16}(pv) + 2, Ptr{UInt16}(pv), 2n)   # as UInt16s
    end
    s = UInt64(0)
    for x in f; s = s * 31 + reinterpret(UInt32, x); end
    for x in u; s = s * 31 + x; end
    return (s, bb_sum(v))
end

# dense arrays reinterpreted, collected and copied to (one copy of their bytes)
function bb_reinterpret(n::Int)
    img = bb_img(n)
    a = collect(reinterpret(UInt8, img))
    b = collect(reinterpret(BBN8, img))              # WGLMakie's flatten_buffer
    c = collect(reinterpret(UInt8, b))
    d = Vector{UInt8}(reinterpret(UInt8, vec(img)))  # MsgPack.Extension's convert
    e = collect(reinterpret(BBRGBA, a))
    f = collect(reinterpret(UInt8, Float32[i * 0.5f0 for i in 1:n]))
    g = collect(reinterpret(Float32, bb_bytes(4n)))
    gs = UInt64(0)
    for x in g; gs = gs * 31 + reinterpret(UInt32, x); end
    rgb = [BBRGB(BBN8(UInt8(i)), BBN8(UInt8(2i)), BBN8(UInt8(3i))) for i in 1:n]
    r = collect(reinterpret(UInt8, rgb))
    m = similar(img)
    copyto!(reinterpret(UInt8, m), bb_bytes(4 * 3n))
    big = copyto!(fill(0x55, 12n + 5), reinterpret(UInt8, img))
    short = try copyto!(zeros(UInt8, 2), reinterpret(UInt8, img)); 0 catch err; err isa BoundsError ? 1 : 2 end
    return (bb_sum(a), bb_sum(c), bb_sum(d), e == img, bb_sum(f), gs, bb_sum(r),
            m[n, 2].g, bb_sum(big), short, size(a), size(b))
end

# copies of reinterpreted arrays, each compared with Base's indexing of the arrays, element
# by element (the patch copies natively too, in the session of patches: the references are
# the elements), and their checksums
struct BBMix; a::Float32; b::UInt32; end           # no padding; leaves of two kinds
struct BBPad; a::UInt8; b::UInt16; end             # a byte of padding
struct BBPad2; x::UInt8; y::UInt16; end            # its layout
# an array with offset axes
struct BBOffset{T} <: AbstractVector{T}; a::Vector{T}; end
Base.axes(v::BBOffset) = (Base.IdentityUnitRange(0:length(v.a)-1),)
Base.size(v::BBOffset) = size(v.a)
Base.getindex(v::BBOffset, i::Int) = v.a[i + 1]
Base.setindex!(v::BBOffset, x, i::Int) = (v.a[i + 1] = x; v)
bb_same(a, b) = length(a) == length(b) && all(k -> a[k] === b[k], 1:length(a))
bb_same(a, b, ks) = all(k -> a[k] === b[k], ks)

# the copies the patch makes: between arrays and reinterpreted arrays (of `Array`s)
function bb_ra_covered(n::Int)
    img = bb_img(n)
    bytes = bb_bytes(12n)
    f32 = Float32[i * 0.5f0 for i in 1:n]
    r1 = reinterpret(UInt8, img); a1 = collect(r1)
    r2 = reinterpret(BBN8, img); a2 = collect(r2)
    r3 = reinterpret(UInt8, vec(img)); a3 = Vector{UInt8}(r3)
    r4 = reinterpret(BBRGBA, bytes); a4 = convert(Array, r4)
    r5 = reinterpret(reshape, UInt8, img); a5 = collect(r5)
    r6 = reinterpret(reshape, BBRGBA, reshape(bytes, 4, :)); a6 = collect(r6)
    r7 = reinterpret(Float32, bytes); a7 = collect(r7)
    r8 = reinterpret(UInt8, f32); a8 = collect(r8)
    mix = [BBMix(i * 1.5f0, UInt32(i)) for i in 1:n]
    r9 = reinterpret(UInt8, mix); a9 = collect(r9)
    r10 = reinterpret(BBMix, a9); a10 = collect(r10)
    wide = Int128[Int128(i) << 70 - i for i in 1:n]
    r11 = reinterpret(UInt64, wide); a11 = collect(r11)
    r12 = reinterpret(Int128, a11); a12 = collect(r12)
    # from and into arrays whose first element is not their memory's
    v = bb_bytes(4n + 3); popfirst!(v); popfirst!(v); popfirst!(v)
    r13 = reinterpret(Float32, v); a13 = collect(r13)
    d = fill(0x11, 4n + 2); popfirst!(d); popfirst!(d); copyto!(d, r8)
    # a parent grown since: the elements of its first bytes
    g = bb_bytes(8); r14 = reinterpret(Float32, g); push!(g, 0x09); a14 = collect(r14)
    # into a longer array; into a shorter one (a BoundsError, as Base's)
    big = copyto!(fill(0x55, 12n + 5), r1)
    short = try copyto!(zeros(UInt8, 2), r1); 0 catch err; err isa BoundsError ? 1 : 2 end
    # into reinterpreted arrays: of the same length, longer, shorter
    m = fill(BBRGBA(0, 0, 0, 0), n, 3); rm = reinterpret(UInt8, m); copyto!(rm, bytes)
    fz = zeros(UInt8, 4n + 4); rf = reinterpret(Float32, fz); copyto!(rf, f32)
    short2 = try copyto!(reinterpret(UInt8, fill(BBRGBA(0, 0, 0, 0), 1)), bytes); 0 catch err; err isa BoundsError ? 1 : 2 end
    ok = (bb_same(a1, r1), bb_same(a2, r2), bb_same(a3, r3), bb_same(a4, r4), bb_same(a5, r5),
          bb_same(a6, r6), bb_same(a7, r7), bb_same(a8, r8), bb_same(a9, r9), bb_same(a10, mix),
          bb_same(a11, r11), bb_same(a12, wide), bb_same(a13, r13), bb_same(d, r8),
          bb_same(a14, r14), length(a14) == 2, bb_same(big, r1, 1:12n), all(==(0x55), big[12n+1:end]),
          short == 1, bb_same(rm, bytes), m[1, 1] === r4[1], bb_same(rf, f32, 1:n),
          all(iszero, fz[4n+1:end]), short2 == 1)
    return (ok, (bb_sum(a1), bb_sum(a3), bb_sum(a8), bb_sum(a9), bb_sum(a11 .% UInt8), bb_sum(d),
                 bb_sum(big), bb_sum(rm), bb_sum(fz), size(a1), size(a5), size(a6)))
end

# copies with ranges, and with index styles given
function bb_ra_ranges(n::Int)
    img = bb_img(n)
    r = reinterpret(UInt8, img)
    bytes = bb_bytes(12n)
    d1 = copyto!(fill(0x22, 12n), 3, r, 5, 7)
    ref1 = fill(0x22, 12n); for i in 0:6; ref1[3 + i] = r[5 + i]; end
    m = fill(BBRGBA(0, 0, 0, 0), n, 3); rm = reinterpret(UInt8, m)
    copyto!(rm, 2, bytes, 4, 6)
    ref2 = zeros(UInt8, 12n); for i in 0:5; ref2[2 + i] = bytes[4 + i]; end
    rr = reinterpret(reshape, UInt8, img)
    d3 = zeros(UInt8, 4, n, 3)
    copyto!(d3, CartesianIndices((2:3, 1:n, 2:3)), rr, CartesianIndices((1:2, 1:n, 1:2)))
    ref3 = zeros(UInt8, 4, n, 3)
    for I in CartesianIndices((1:2, 1:n, 1:2)); ref3[I + CartesianIndex(1, 0, 1)] = rr[I]; end
    d4 = copyto!(IndexCartesian(), zeros(UInt8, 12n), IndexCartesian(), r)
    d5 = copyto!(IndexLinear(), zeros(UInt8, 4, 3n), IndexCartesian(), r)
    ok = (d1 == ref1, bb_same(rm, ref2), d3 == ref3, bb_same(d4, r), bb_same(d5, r))
    return (ok, (bb_sum(d1), bb_sum(rm), bb_sum(vec(d3)), bb_sum(d4), bb_sum(vec(d5))))
end

# the copies the patch does not make (Base's, element by element): parents that are views,
# strided or with offset axes, reshaped reinterpreted arrays, padded elements; and one it
# makes, of an array reinterpreted twice (Base reinterprets its parent)
function bb_ra_excluded(n::Int)
    img = bb_img(n)
    bytes = bb_bytes(12n)
    f32 = Float32[i * 0.5f0 for i in 1:n]
    rv = reinterpret(UInt8, view(img, 1:n, 2:3)); av = collect(rv)
    rs = reinterpret(UInt8, view(f32, 1:2:n)); as = collect(rs)
    rn = reinterpret(UInt8, reinterpret(BBN8, img)); an = collect(rn)
    rh = reshape(reinterpret(UInt8, img), :); ah = collect(rh); ah2 = copyto!(zeros(UInt8, 12n), rh)
    ro = reinterpret(Int8, BBOffset(bytes)); ao = copyto!(zeros(Int8, 12n), ro)
    pad = [BBPad(i % UInt8, UInt16(3i)) for i in 1:n]
    rp = reinterpret(BBPad2, pad); ap = collect(rp)
    padbytes = try collect(reinterpret(UInt8, pad)); 0 catch; 1 end
    m = fill(BBRGBA(0, 0, 0, 0), n, 3)
    copyto!(reinterpret(UInt8, view(m, :, 2:3)), bytes[1:8n])
    m2 = fill(BBRGBA(0, 0, 0, 0), n, 3)
    copyto!(view(reinterpret(UInt8, m2), 3:8), bytes[1:6])
    ok = (bb_same(av, rv), bb_same(as, rs), bb_same(an, rn), bb_same(ah, rh), bb_same(ah2, rh),
          all(k -> ao[k + 1] === ro[k], 0:12n-1), bb_same(ap, rp), padbytes == 1,
          bb_same(reinterpret(UInt8, m), [zeros(UInt8, 4n); bytes[1:8n]]),
          bb_same(reinterpret(UInt8, m2), [0x00; 0x00; bytes[1:6]; zeros(UInt8, 12n - 8)]))
    return (ok, (bb_sum(av), bb_sum(as), bb_sum(an), bb_sum(ah), bb_sum(reinterpret(UInt8, ao)),
                 ap[n].y, bb_sum(collect(reinterpret(UInt8, m)))))
end

# whether the patch's method copies `src` to `dest` (its signatures: not whether its
# elements have padding)
bb_patched(dest, src) = endswith(string(which(Base.copyto_unaliased!,
    Tuple{IndexLinear, typeof(dest), IndexLinear, typeof(src)}).file), "wasm-base.jl")

@testset "bulk copies of bytes" begin
    for n in (0, 1, 7, 4096, 70_001)
        @wtest bb_write(n)
    end
    for n in (1, 5, 1000)
        @wtest bb_misaligned(n)
        @wtest bb_read(n)
        @wtest bb_copies(n)
    end
    for n in (2, 5, 1000)
        @wtest bb_overlap(n)
    end
end

@testset "bulk copies of bytes: reinterpreted arrays" begin
    for n in (1, 3, 256)
        @wtest bb_reinterpret(n)
        for f in (bb_ra_covered, bb_ra_ranges, bb_ra_excluded)
            ok = f(n)[1]
            @test all(ok)
            all(ok) || @info "copies unlike their elements" f n ok
            @wtest f(n)
        end
    end
    img = bb_img(2)
    v = Float32[1, 2]
    @test bb_patched(zeros(UInt8, 8), reinterpret(UInt8, img))
    @test bb_patched(zeros(UInt8, 4, 2, 3), reinterpret(reshape, UInt8, img))
    @test bb_patched(fill(BBRGBA(0, 0, 0, 0), 2), reinterpret(BBRGBA, zeros(UInt8, 8)))
    @test bb_patched(reinterpret(UInt8, img), zeros(UInt8, 24))
    @test bb_patched(reinterpret(Float32, zeros(UInt8, 8)), v)
    @test !bb_patched(zeros(UInt8, 8), reinterpret(UInt8, view(img, :, 1)))
    @test !bb_patched(zeros(UInt8, 4), reinterpret(UInt8, view(v, 1:2:2)))
    # (a reinterpreted reinterpreted array is its parent reinterpreted: an `Array`'s)
    @test bb_patched(zeros(UInt8, 8), reinterpret(UInt8, reinterpret(BBN8, img)))
    @test !bb_patched(zeros(UInt8, 24), reshape(reinterpret(UInt8, img), :))
    @test !bb_patched(zeros(Int8, 8), reinterpret(Int8, BBOffset(zeros(UInt8, 8))))
    @test !bb_patched(reinterpret(UInt8, view(img, :, 1:2)), zeros(UInt8, 8))
    @test !bb_patched(view(reinterpret(UInt8, img), 1:8), zeros(UInt8, 8))
    @test !bb_patched(zeros(UInt16, 8), reinterpret(UInt8, img))      # other element types
    @test Base._bytes_copyable(UInt8, BBRGBA) && Base._bytes_copyable(UInt8, BBMix)
    @test !Base._bytes_copyable(BBPad2, BBPad)
end

# the hot paths of copies of 256 KiB: between two arrays in one function (one `array.copy`,
# the references), written to an IOBuffer (`unsafe_write` of a pointer: `Runtime.ptr_memmove`),
# an RGBA tile flattened as WGLMakie does and written as Bonito does
const BB_TILE = [BBRGBA(UInt8(i % 256), UInt8(j % 256), UInt8((i * j) % 256), 0xff) for i in 1:256, j in 1:256]
const BB_TILE_BYTES = bb_bytes(4 * 256 * 256)
const BB_TILE_F32 = Float32[i * 0.5f0 for i in 1:256*256]
const BB_DST = zeros(UInt8, 4 * 256 * 256)
const BB_IO = IOBuffer(; sizehint=4 * 256 * 256 + 64)
const BB_KEEP = Ref{Vector{UInt8}}(UInt8[])
bb_reset!(io::IOBuffer) = (io.size = 0; io.ptr = 1; io)
function bb_op(k::Int)
    if k == 0      # the references: 256 KiB copied between arrays, into one or a new one
        return length(copyto!(BB_DST, BB_TILE_BYTES))
    elseif k == 1
        BB_KEEP[] = copyto!(Vector{UInt8}(undef, 4 * 256 * 256), BB_TILE_BYTES)
        return length(BB_KEEP[])
    elseif k == 2  # 256 KiB of bytes written to a buffer
        return write(bb_reset!(BB_IO), BB_TILE_BYTES)
    elseif k == 3  # 256 KiB of Float32 written to a buffer
        return write(bb_reset!(BB_IO), BB_TILE_F32)
    elseif k == 4  # an RGBA tile as WGLMakie flattens it, written as Bonito writes it
        flat = collect(reinterpret(UInt8, collect(reinterpret(BBN8, BB_TILE))))
        return GC.@preserve flat unsafe_write(bb_reset!(BB_IO), Ptr{UInt8}(pointer(flat)), UInt(sizeof(flat)))
    end
    return 0
end
const BB_OPS = 0:4
# the median of `runs` runs (after `warm` more) of `reps` operations `k`, in ns per operation
function bb_time(k::Int, reps::Int, runs::Int, warm::Int)
    ts = Int[]
    for r in 1:warm+runs
        t = time_ns()
        for _ in 1:reps
            bb_op(k)
        end
        r > warm && push!(ts, Int(time_ns() - t) ÷ reps)
    end
    sort!(ts)
    return ts[(runs + 1) ÷ 2]
end

@testset "bulk copies of bytes: the hot paths" begin
    c = wcompile(bb_time, (Int, Int, Int, Int))
    for k in BB_OPS
        @test wasm_run(c, "bb_time", k, 1, 1, 0; rettype=Int) >= 0
    end
end

# timings (with WASMCODEGEN_TIMINGS=1: they depend on the machine and its load), as ratios
# to the copies into an array (k = 0) and into a new array (k = 1, whose memory is then
# touched for the first time, which costs more than the copy).
if get(ENV, "WASMCODEGEN_TIMINGS", "") == "1"
    @testset "bulk copies of bytes: timings" begin
        c = wcompile(bb_time, (Int, Int, Int, Int))
        t = Dict(k => max(wasm_run(c, "bb_time", k, 20, 21, 3; rettype=Int), 1) for k in BB_OPS)
        println("bulk copies of bytes, ms per 256 KiB (median of 21): copy into an array ", t[0] / 1e6,
                ", into a new array ", t[1] / 1e6, "; bytes to an IOBuffer ", t[2] / 1e6,
                " (", round(t[2] / t[0], digits=1), "x the first), Float32 to an IOBuffer ", t[3] / 1e6,
                " (", round(t[3] / t[0], digits=1), "x)",
                haskey(t, 4) ? string(", RGBA tile flattened and written ", t[4] / 1e6, " (",
                                      round(t[4] / t[1], digits=1), "x the second)") : "")
        @test t[2] < 30 * t[0]
        @test t[3] < 100 * t[0]
        haskey(t, 4) && @test t[4] < 12 * t[1]
    end
end
