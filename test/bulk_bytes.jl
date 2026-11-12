# Bulk copies of bytes: `memmove` between pointers whose arrays are known only at run time
# (`Runtime.ptr_memmove`: `write`/`unsafe_write` to an IOBuffer, `read!` from one, copies
# through pointers that crossed a call). Between a memory of bytes and a memory of wider
# elements, a loop over the elements; before, by 8-byte words through the pointers' owners
# (or byte by byte, misaligned): a `write` of 256 KiB of Float32 to an IOBuffer took ~2.4x as
# long in Node, a `read!` of them ~5x.

# a checksum of bytes, and their count
function bb_sum(v::AbstractArray{UInt8})
    h = 0xcbf29ce484222325
    for x in v
        h = (h ⊻ x) * 0x100000001b3
    end
    return (length(v), h)
end
bb_bytes(n) = UInt8[UInt8((i * 31 + (i >> 8)) % 256) for i in 1:n]

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

# copies between a memory of bytes and one of wider elements, both ways, of whole elements
# (element by element) and of parts of them (offset or length not a multiple of the element
# size: byte by byte), into destinations whose other bytes must be kept
function bb_partial_of(::Type{T}, n::Int) where {T}
    s = sizeof(T)
    src = bb_bytes(s * n + 2s)
    s0 = UInt64(0)
    for (off, len) in ((0, s * n), (s, s * (n - 1)), (0, s * n - 1), (1, s * n - 1),
                       (s - 1, s * n - s + 2), (3, 2), (s + 1, s * n - 3), (2, 1))
        (len < 0 || off + len + 1 > s * (n + 1)) && continue   # (within `w`)
        w = T[reinterpret(T, bb_bits(T, i)) for i in 1:n+1]
        b = zeros(UInt8, s * n + 2s + 8)
        GC.@preserve src w b begin
            pw, pb = Ptr{UInt8}(pointer(w)), pointer(b)
            bb_copy!(pw + off, pointer(src) + 3, len)      # bytes to elements
            bb_copy!(pb + 5, pw + off, len + 1)            # elements to bytes (one more)
            bb_copy!(pb + off, pw + s, len)                # elements to bytes at `off`
        end
        for x in w; s0 = s0 * 31 + UInt64(reinterpret(bb_uint(T), x)); end
        s0 = s0 * 31 + bb_sum(b)[2]
    end
    return s0
end
bb_uint(::Type{T}) where {T} = sizeof(T) == 8 ? UInt64 : sizeof(T) == 4 ? UInt32 : UInt16
bb_bits(::Type{T}, i::Int) where {T} = (UInt64(i) * 0x9e3779b97f4a7c15) % bb_uint(T)
bb_partial(n::Int) = (bb_partial_of(Float64, n), bb_partial_of(Float32, n), bb_partial_of(Float16, n),
                      bb_partial_of(Int64, n), bb_partial_of(UInt32, n), bb_partial_of(Int16, n))

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
    for n in (1, 3, 64)
        @test bb_partial(n) isa NTuple{6,UInt64}   # (natively: not an exception, which @wtest takes as a trap)
        @wtest bb_partial(n)
    end
end

# the hot paths of copies of 256 KiB: between two arrays in one function (one `array.copy`,
# the references), written to an IOBuffer (`unsafe_write` of a pointer: `Runtime.ptr_memmove`)
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
    end
    return 0
end
const BB_OPS = 0:3
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
                " (", round(t[3] / t[0], digits=1), "x)")
        @test t[2] < 30 * t[0]
        @test t[3] < 100 * t[0]
    end
end
