# Bulk copies of bytes: `memmove` between pointers whose arrays are known only at run time
# (`jl_ptr_memmove`: `write`/`unsafe_write` to an IOBuffer, `read!` from one, copies through
# pointers that crossed a call), and copies between arrays and dense arrays reinterpreted
# (`collect(reinterpret(UInt8, img))`). Before, both went byte by byte through the owners of
# the pointers (`jl_ptr_store_byte`), ~10 ns a byte: a 256×256 RGBA tile serialized as
# WGLMakie and Bonito do took ~7 ms in Node.

struct BBRGBA; r::UInt8; g::UInt8; b::UInt8; a::UInt8; end   # as RGBA{N0f8}
struct BBN8; i::UInt8; end                                    # as N0f8
struct BBRGB; r::BBN8; g::BBN8; b::BBN8; end                  # as RGB{N0f8}

# a checksum of bytes, and their count
function bb_sum(v::AbstractVector{UInt8})
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

# misaligned ranges of wider elements (byte by byte through their arrays), written and read
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

@testset "bulk copies of bytes" begin
    for n in (0, 1, 7, 4096, 70_001)
        @wtest bb_write(n)
    end
    for n in (1, 5, 1000)
        @wtest bb_misaligned(n)
        @wtest bb_read(n)
        @wtest bb_copies(n)
    end
    for n in (1, 3, 256)
        @wtest bb_reinterpret(n)
    end
end

# timings, as ratios to copies of 256 KiB between two arrays in one function (one
# `array.copy`, as before), so independent of the machine: into an array, and into a new
# array (whose memory is then touched for the first time, which costs more than the copy).
# Before, a write of 256 KiB to an IOBuffer was ~300 times the first, an RGBA tile ~30
# times the second.
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
# the least time of 5 runs of `reps` operations `k`, in ns per operation
function bb_time(k::Int, reps::Int)
    best = typemax(Int)
    for _ in 1:5
        t = time_ns()
        for _ in 1:reps
            bb_op(k)
        end
        best = min(best, Int(time_ns() - t) ÷ reps)
    end
    return best
end

@testset "bulk copies of bytes: timings" begin
    c = wcompile(bb_time, (Int, Int))
    t = [max(wasm_run(c, "bb_time", k, 20; rettype=Int), 1) for k in 0:4]
    println("bulk copies of bytes, ms per 256 KiB: copy into an array ", t[1] / 1e6,
            ", into a new array ", t[2] / 1e6, "; bytes to an IOBuffer ", t[3] / 1e6,
            " (", round(t[3] / t[1], digits=1), "x the first), Float32 to an IOBuffer ", t[4] / 1e6,
            " (", round(t[4] / t[1], digits=1), "x), RGBA tile flattened and written ", t[5] / 1e6,
            " (", round(t[5] / t[2], digits=1), "x the second)")
    @test t[3] < 10 * t[1]
    @test t[4] < 60 * t[1]
    @test t[5] < 8 * t[2]
end
