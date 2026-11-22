# Bytes of mutable objects through pointers (jl_ptr_load_byte/jl_ptr_store_byte) when a field
# is a large isbits value (more than MAX_INLINE_LEAVES leaves): a reference to a tuple's array
# or to a boxed immutable value (the byte helpers were invalid Wasm before)
mutable struct BigBuf            # NTuple{100,UInt8}: a tuple's array of bytes
    buf::NTuple{100,UInt8}
    pad::UInt32
    x::Int
end
mutable struct BigWords          # NTuple{80,UInt32}: a tuple's array of words
    x::UInt64
    w::NTuple{80,UInt32}
end
struct Wide                      # 70 leaves, not one element type: a boxed immutable
    a::NTuple{40,UInt16}
    b::NTuple{30,UInt32}
end
mutable struct BigWide
    x::UInt32
    w::Wide
    y::UInt32
end

# weighted sum of `n` bytes from `p` (a pointer with no static origin)
@noinline function wsum(p::Ptr{UInt8}, offs)
    s = 0
    for o in offs
        s = 31 * s + Int(unsafe_load(p + o)) + o
    end
    return s
end
@noinline poke(p::Ptr{UInt8}, o::Int, v::UInt8) = (unsafe_store!(p + o, v); nothing)

function bigbuf(n::Int)
    m = BigBuf(ntuple(i -> UInt8((i * 7 + n) % 256), Val(100)), 0xa1b2c3d4, n * 1000003)
    GC.@preserve m wsum(Ptr{UInt8}(pointer_from_objref(m)), [0:99; 100:103; 104:111])
end
function bigwords(n::Int)
    m = BigWords(0x0102030405060708 + n, ntuple(i -> UInt32(i * 0x01010101 + n), Val(80)))
    GC.@preserve m wsum(Ptr{UInt8}(pointer_from_objref(m)), 0:sizeof(BigWords)-1)
end
function bigwide(n::Int)
    w = Wide(ntuple(i -> UInt16(i * 257 + n), Val(40)), ntuple(i -> UInt32(i * 65537 + n), Val(30)))
    m = BigWide(0xdeadbeef, w, UInt32(n))
    GC.@preserve m wsum(Ptr{UInt8}(pointer_from_objref(m)), 0:sizeof(BigWide)-1)
end
# a store into the fields of such an object: into a large field, into a copy of the tuple's
# array or the box (values other values may hold)
function bigbuf_store(o::Int)
    m = BigBuf(ntuple(i -> UInt8(i), Val(100)), 0, 0)
    GC.@preserve m poke(Ptr{UInt8}(pointer_from_objref(m)), o, 0x5a)
    return m.x + Int(m.pad) + Int(m.buf[1])
end
function bigbuf_shared(o::Int)
    t = ntuple(i -> UInt8(i), Val(100))
    m, m2 = BigBuf(t, 0, 0), BigBuf(t, 0, 0)
    before = m.buf
    GC.@preserve m poke(Ptr{UInt8}(pointer_from_objref(m)), o, 0x5a)
    return Int(m.buf[o+1]) + 1000Int(before[o+1]) + 1000000Int(m2.buf[o+1]) + Int(t[o+1]) + Int(sum(m.buf))
end
function bigwords_store(o::Int)
    m = BigWords(0x0102030405060708, ntuple(i -> UInt32(i * 0x01010101), Val(80)))
    GC.@preserve m begin
        p = Ptr{UInt8}(pointer_from_objref(m))
        poke(p, o, 0x5a); poke(p, o + 5, 0xa5)
        wsum(p, 0:sizeof(BigWords)-1)
    end
end
# elements of a large tuple stored whole (StaticArrays' `setindex!` of an `MArray`)
mutable struct BigMat
    data::NTuple{81,Float64}
    BigMat() = new()
end
@noinline setel!(m::BigMat, x::Float64, i::Int) =
    GC.@preserve m unsafe_store!(Base.unsafe_convert(Ptr{Float64}, pointer_from_objref(m)), x, i)
function bigmat(x::Float64)
    m = BigMat()
    for i in 1:81
        setel!(m, x + i, i)
    end
    t = m.data
    setel!(m, -1.0, 81)
    return (sum(t), sum(m.data), t[81], m.data[81])
end
function bigref_store(k::Int)
    r = Ref{NTuple{80,UInt8}}(ntuple(i -> UInt8(i), Val(80)))
    GC.@preserve r unsafe_store!(Ptr{UInt8}(Base.unsafe_convert(Ptr{NTuple{80,UInt8}}, r)), 0xff, k)
    return Int(r[][k]) + Int(r[][k+1])
end

# a Ref of a large isbits struct with pointer fields: bytes
# of its numeric leaves read, of its pointers too (null), through a pointer with no static
# origin
struct ManyFields
    a::NTuple{20,Int8}
    p::Ptr{UInt8}
    b::NTuple{50,Int16}
    q::Ptr{Cvoid}
    c::UInt64
end
function ref_manyfields(n::Int)
    r = Ref(ManyFields(ntuple(i -> Int8(i + n), Val(20)), C_NULL, ntuple(i -> Int16(i * 300 + n), Val(50)), C_NULL, 0x1122334455667788))
    GC.@preserve r wsum(Ptr{UInt8}(pointer_from_objref(r)), [0:19; 24:31; 32:131; 136:143; 144:151])
end
# a store into a byte of a large field (a box holding tuples' arrays): the value read
# before keeps its bytes
function bigwide_store(o::Int)
    w = Wide(ntuple(i -> UInt16(i), Val(40)), ntuple(i -> UInt32(i), Val(30)))
    m = BigWide(0x01020304, w, 0x05060708)
    GC.@preserve m begin
        p = Ptr{UInt8}(pointer_from_objref(m))
        poke(p, o, 0x5a)
        return Int(m.x) + Int(m.y) + wsum(p, 0:sizeof(BigWide)-1) + Int(sum(w.a)) + Int(sum(w.b)) +
               Int(sum(m.w.a)) + Int(sum(m.w.b))
    end
end
# a box holding scalars and a tuple's array: the box and the array are both copied
struct DeepIn
    s::NTuple{64,UInt8}
    t::NTuple{80,UInt16}
    z::UInt32
end
mutable struct BigDeep
    x::UInt32
    d::DeepIn
    y::UInt32
end
function bigdeep_store(o::Int)
    d = DeepIn(ntuple(i -> UInt8(i), Val(64)), ntuple(i -> UInt16(i * 257), Val(80)), 0x0a0b0c0d)
    m = BigDeep(0x01020304, d, 0x05060708)
    GC.@preserve m begin
        p = Ptr{UInt8}(pointer_from_objref(m))
        poke(p, o, 0x5a); poke(p, (o + 70) % sizeof(BigDeep), 0xa5)
        return wsum(p, 0:sizeof(BigDeep)-1) + Int(sum(d.s)) + Int(sum(d.t)) + Int(d.z) +
               Int(sum(m.d.s)) + Int(sum(m.d.t)) + Int(m.d.z)
    end
end
# a store into the numeric leaves of a boxed struct with pointers; into a pointer's address
# there, a trap (the copy would keep the owner of the address replaced)
function ref_manyfields_store(o::Int)
    r = Ref(ManyFields(ntuple(i -> Int8(i), Val(20)), C_NULL, ntuple(i -> Int16(i * 300), Val(50)), C_NULL, 0x1122334455667788))
    GC.@preserve r begin
        p = Ptr{UInt8}(pointer_from_objref(r))
        poke(p, o, 0x5a)
        return wsum(p, [0:19; 32:131; 144:151])
    end
end
# a field of a union of isbits types is stored inline, not as isbits leaves: its bytes (the
# value's and the selector's) are not addressable, a pointer access traps
mutable struct BigUnion
    buf::NTuple{65,UInt8}
    u::Union{UInt8,UInt16}
    x::Int
end
function bigunion_load(o::Int)
    m = BigUnion(ntuple(i -> UInt8(i), Val(65)), UInt16(0x1234), 7)
    GC.@preserve m unsafe_load(Ptr{UInt8}(pointer_from_objref(m)) + o)
end
function bigunion_store(o::Int)
    m = BigUnion(ntuple(i -> UInt8(i), Val(65)), UInt16(0x1234), 7)
    GC.@preserve m unsafe_store!(Ptr{UInt8}(pointer_from_objref(m)) + o, 0x5a)
    return Int(m.u) + m.x
end
# a pointer stored into or loaded from a pointer field of a mutable object through a pointer
# keeps its owner
mutable struct PHold
    n::Int
    p::Ptr{UInt8}
end
@noinline field_ptr(h::PHold) = Ptr{Ptr{UInt8}}(pointer_from_objref(h)) + 8
function owner_store(k::Int)
    a = UInt8[11, 21]; b = UInt8[12, 22]
    h = PHold(k, pointer(a))
    GC.@preserve a b h begin
        unsafe_store!(field_ptr(h), pointer(b) + k)
        return Int(unsafe_load(h.p)) + (h.p == pointer(b) + k ? 100 : 0)
    end
end
function owner_load(k::Int)
    a = UInt8[11, 21]
    h = PHold(k, pointer(a) + k)
    GC.@preserve a h Int(unsafe_load(unsafe_load(field_ptr(h))))
end
# (the out-parameter of a C function)
@noinline out_ptr!(r::Ref{Ptr{UInt8}}, p::Ptr{UInt8}) = (unsafe_store!(Base.unsafe_convert(Ptr{Ptr{UInt8}}, r), p); nothing)
function owner_ref(k::Int)
    a = UInt8[11, 21]; b = UInt8[12, 22]
    r = Ref(pointer(a))
    GC.@preserve a b r begin
        out_ptr!(r, pointer(b) + k)
        return Int(unsafe_load(r[]))
    end
end
function owner_memory(k::Int)
    a = UInt8[11, 21]; b = UInt8[12, 22]
    v = [pointer(a), pointer(a)]
    GC.@preserve a b v begin
        unsafe_store!(pointer(v), pointer(b) + k, 2)
        return Int(unsafe_load(v[2])) + 100Int(unsafe_load(unsafe_load(pointer(v), 2)))
    end
end
# (between two elements of a memory of pointers, a trap: their bytes are not addressable)
function owner_memory_misaligned(k::Int)
    a = UInt8[11, 21]
    v = [pointer(a), pointer(a)]
    GC.@preserve a v begin
        k == 0 && return Int(unsafe_load(unsafe_load(pointer(v) + 8)))
        k == 1 && (unsafe_store!(pointer(v) + 1, pointer(a)); return 1)
        return Int(unsafe_load(pointer(v) + 1) == C_NULL)
    end
end
# (clearing an element of a memory of references: at the element only)
function clear_ref_misaligned(k::Int)
    v = Any[Ref(1), Ref(2)]
    GC.@preserve v unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(v)) + k, C_NULL)
    return Int(isassigned(v, 1)) + 2Int(isassigned(v, 2))
end
# (a pointer between two elements passed to a call that does not access it)
import LinearAlgebra
function blas_empty_misaligned(k::Int)
    a = [1.0, 2.0]; b = [3.0, 4.0]
    GC.@preserve a b LinearAlgebra.BLAS.blascopy!(0, pointer(a) + k, 1, pointer(b), 1)
    return b[1] + b[2]
end
# the bytes of an address stored otherwise (as an integer, byte by byte) carry no owner: the
# field's pointer can be read and compared, not dereferenced
function owner_bytes(k::Int)
    a = UInt8[11, 21]; b = UInt8[12, 22]
    h = PHold(k, pointer(a))
    GC.@preserve a b h begin
        unsafe_store!(Ptr{UInt}(field_ptr(h)), UInt(pointer(b)))
        k == 0 && return Int(h.p == pointer(b))
        return Int(unsafe_load(h.p))
    end
end
function owner_byte(k::Int)
    a = UInt8[11, 21]
    h = PHold(k, pointer(a))
    GC.@preserve a h begin
        unsafe_store!(Ptr{UInt8}(field_ptr(h)), unsafe_load(Ptr{UInt8}(field_ptr(h))) + 0x01)
        k == 0 && return Int(h.p == pointer(a) + 1)
        return Int(unsafe_load(h.p))
    end
end
# SHA hashes (a smoke test of code reading bytes through pointers)
import SHA
sha_hashes(k::Int) = (s = repeat("abc", k); (hash(SHA.sha512(s)), hash(SHA.sha256(s)), hash(SHA.sha1(s))))

@testset "pointer bytes of large isbits fields" begin
    @wtest ref_manyfields(3)
    @wtest bigwide_store(0)      # x: a small field
    for o in (4, 7, 83, 84, 85, 203)    # inside w: its tuples of 2- and 4-byte elements
        @wtest bigwide_store(o)
    end
    @wtest bigwide_store(204)    # y
    D = Int(fieldoffset(BigDeep, 2))
    for o in (0, D, D + 63, D + 64, D + 65, D + 150, D + 224, D + 227)   # x, d's s, t, z
        @wtest bigdeep_store(o)
    end
    for o in (3, 40, 131, 150)
        @wtest ref_manyfields_store(o)
    end
    r = wasm_run(wcompile(ref_manyfields_store, (Int,)), "ref_manyfields_store", 24; rettype=Int)   # p
    @test r isa Tuple && r[1] === :trap
    for k in (0, 1)
        @wtest owner_store(k)
        @wtest owner_load(k)
        @wtest owner_ref(k)
        @wtest owner_memory(k)
    end
    @wtest owner_memory_misaligned(0)
    for k in (1, 2)
        r = wasm_run(wcompile(owner_memory_misaligned, (Int,)), "owner_memory_misaligned", k; rettype=Int)
        @test r isa Tuple && r[1] === :trap
    end
    @wtest clear_ref_misaligned(0)
    @wtest clear_ref_misaligned(8)
    r = wasm_run(wcompile(clear_ref_misaligned, (Int,)), "clear_ref_misaligned", 7; rettype=Int)
    @test r isa Tuple && r[1] === :trap
    @wtest blas_empty_misaligned(1)
    for f in (owner_bytes, owner_byte)
        c = wcompile(f, (Int,))
        @test wasm_run(c, string(f), 0; rettype=Int) == f(0) == 1
        r = wasm_run(c, string(f), 1; rettype=Int)
        @test r isa Tuple && r[1] === :trap
    end
    @wtest sha_hashes(1)
    @wtest sha_hashes(100)
    @test sizeof(BigBuf) == 112 && sizeof(BigWords) == 328 && sizeof(BigWide) == 208
    @wtest bigbuf(3)
    @wtest bigwords(5)
    @wtest bigwide(7)
    @wtest bigbuf_store(104)     # x
    @wtest bigbuf_store(100)     # pad
    @wtest bigbuf_store(0)       # buf
    for o in (0, 37, 99)
        @wtest bigbuf_shared(o)
    end
    for o in (8, 9, 150, 322)
        @wtest bigwords_store(o)
    end
    @wtest bigmat(1.5)
    @wtest bigref_store(5)
    U, X = Int(fieldoffset(BigUnion, 2)), Int(fieldoffset(BigUnion, 3))
    @wtest bigunion_load(3)
    @wtest bigunion_load(X)
    @wtest bigunion_store(X)
    for o in U:X-1
        r = wasm_run(wcompile(bigunion_load, (Int,)), "bigunion_load", o; rettype=UInt8)
        @test r isa Tuple && r[1] === :trap
        r = wasm_run(wcompile(bigunion_store, (Int,)), "bigunion_store", o; rettype=Int)
        @test r isa Tuple && r[1] === :trap
    end
end
