# Copies of bytes through pointers whose origin the code generator does not know (pointers held
# in a vector): `memmove` between memories of bytes (either direction, overlapping or not), from
# a String, from a memory of wider elements (byte by byte, as before); and IOStream reads and
# writes through such pointers, through the stream's buffer and around it.

function pc_sum(a)
    acc = 0
    for x in a
        acc = (acc * 31 + Int(x)) % 1_000_000_007
    end
    return acc
end

function pc_memmove(n::Int, d::Int, s::Int)
    a = UInt8[(i * 7) % 251 for i in 1:300_000]
    b = UInt8[(i * 13) % 251 for i in 1:300_000]
    ps = Ptr{UInt8}[pointer(a), pointer(b)]
    GC.@preserve a b begin
        unsafe_copyto!(ps[1] + d, ps[2] + s, n)        # between memories
        unsafe_copyto!(ps[1] + d, ps[1] + s, n)        # within one: overlapping when |d - s| < n
        unsafe_copyto!(ps[1] + s, ps[1] + d, n)        # and the other way
    end
    return (pc_sum(a), pc_sum(b))
end

function pc_from_string(k::Int)
    s = string("abcdefghij"^20, k)
    a = zeros(UInt8, 300)
    ps = Ptr{UInt8}[pointer(a), pointer(s)]
    GC.@preserve a s begin
        unsafe_copyto!(ps[1] + 3, ps[2], sizeof(s))
        unsafe_copyto!(ps[1], ps[2] + k, 5)
    end
    return pc_sum(a)
end

# a pointer into a memory of 16-bit elements: copied byte by byte, as before
function pc_from_wider(k::Int)
    c = UInt16[i * 257 + k for i in 1:100]
    a = zeros(UInt8, 300)
    ps = Ptr{UInt8}[pointer(a), Ptr{UInt8}(pointer(c))]
    GC.@preserve a c begin
        unsafe_copyto!(ps[1] + 1, ps[2] + 1, 150)
        unsafe_copyto!(ps[2], ps[1] + 7, 20)
    end
    return (pc_sum(a), pc_sum(c))
end

# the owner a copy finds once (`Runtime.owner_bytes`): in Wasm the memory of bytes or the String
# a pointer is into, natively none (`nothing` by design: the runtime keeps both paths)
function pc_owner(k::Int)
    a = zeros(UInt8, 16); s = string("abc", k)
    ps = Ptr{UInt8}[pointer(a), pointer(s)]
    GC.@preserve a s begin
        (oa, ia) = WasmCodegen.Runtime.owner_bytes(ps[1] + 3, 13)
        (os, is) = WasmCodegen.Runtime.owner_bytes(ps[2] + 1, 3)
        (on, _) = WasmCodegen.Runtime.owner_bytes(ps[1] + 3, 14)   # (past the owner's end: none)
        return (oa === a.ref.mem, ia, os === s, is, on === nothing)
    end
end

@testset "copies through pointers" begin
    @test pc_owner(1) == (false, 0, false, 0, true)
    @test wasm_run(wcompile(pc_owner, (Int,)), "pc_owner", 1; rettype = Tuple{Bool,Int,Bool,Int,Bool}) ==
          (true, 4, true, 2, true)
    @wtest pc_memmove(0, 0, 0)
    @wtest pc_memmove(100, 0, 50)        # overlapping, destination first
    @wtest pc_memmove(100, 50, 0)        # overlapping, source first
    @wtest pc_memmove(64, 0, 1000)       # apart
    @wtest pc_memmove(200_000, 10, 99_000)
    @wtest pc_from_string(3)
    @wtest pc_from_string(17)
    @wtest pc_from_wider(1)
end

module PtrCopiesIO

using Test
using ..Main: wasm_run, WasmCodegen

const ROOT = realpath(mktempdir(; cleanup=true))
cfg = WasmCodegen.Config(host=:wasi)

checksum(a) = (acc = 0; for x in a; acc = (acc * 31 + Int(x)) % 1_000_000_007; end; acc)

function io_copies(k::Int)
    path = joinpath(ROOT, string("copies", k))
    data = UInt8[(i * 31 + k) % 256 for i in 1:70_000]
    s = String(UInt8[(i % 26) + 0x61 for i in 1:5000])
    ps = Ptr{UInt8}[pointer(data), pointer(s)]
    GC.@preserve data s begin
        open(path, "w") do io
            unsafe_write(io, ps[1], 70_000)       # more than the buffer holds
            unsafe_write(io, ps[2] + 3, 100)      # from a String, into the buffer
            unsafe_write(io, ps[1] + 5, 10)
        end
    end
    buf = zeros(UInt8, 80_000)
    q = Ptr{UInt8}[pointer(buf)]
    GC.@preserve buf begin
        open(path) do io
            unsafe_read(io, q[1], 10)             # through the buffer
            unsafe_read(io, q[1] + 20, 69_000)    # more than the buffer holds
            unsafe_read(io, q[1] + 70_000, 1100)
        end
    end
    rm(path)
    return Int32(checksum(buf) % 1_000_000)
end

@testset "IOStream reads and writes through pointers" begin
    c = WasmCodegen.compile(io_copies, (Int,); config=cfg)
    for k in (1, 2)
        @test wasm_run(c, "io_copies", k; rettype=Int32, preopens=Dict(ROOT => ROOT)) == io_copies(k)
    end
end

end
