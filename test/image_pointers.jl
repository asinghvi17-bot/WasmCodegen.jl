# Pointers of the build process in the image: addresses without an owner, which mean nothing
# in the module. Null pointers (and -1) are serialized; where native images reset pointers
# (mutable objects' `Ptr` fields, `Ptr`s boxed in their fields, memories' elements:
# src/image.jl `image_field`), null; another is an unsupported construct, unless its field is
# allowlisted (`Config(image_pointer_fields)`).

module ImagePointers
struct PtrHolder
    p::Ptr{UInt8}
    n::Int
end
global g_null_cstring::Cstring = reinterpret(Cstring, C_NULL)
global g_cstring::Cstring = reinterpret(Cstring, Ptr{UInt8}(UInt(0x10)))
global g_holder::PtrHolder = PtrHolder(Ptr{UInt8}(UInt(0x1000)), 3)
global g_null_holder::PtrHolder = PtrHolder(C_NULL, 4)
mutable struct MutablePtrHolder
    p::Ptr{UInt8}
end
const MPH = MutablePtrHolder(Ptr{UInt8}(UInt(0x2000)))
read_mph() = UInt(MPH.p)
null_cstring() = reinterpret(UInt, g_null_cstring) == 0
read_cstring() = reinterpret(UInt, g_cstring)
read_holder() = UInt(g_holder.p) + UInt(g_holder.n)
read_null_holder() = UInt(g_null_holder.p) + UInt(g_null_holder.n)
# a pointer boxed where the field is a union or `Any`
mutable struct UnionPtrHolder
    p::Union{Nothing,Ptr{UInt8}}
end
struct AnyPtrHolder
    p::Any
end
const UPH = UnionPtrHolder(Ptr{UInt8}(UInt(0x3000)))
# (globals, not constants, of immutable holders: inference would fold their reads)
global APH::AnyPtrHolder = AnyPtrHolder(Ptr{UInt8}(UInt(0x4000)))
read_uph() = (p = UPH.p; p === nothing ? UInt(0) : UInt(p))
read_aph() = UInt(APH.p::Ptr{UInt8})
# C strings in fields
struct CstrHolder
    s::Cstring
    w::Cwstring
end
global CSH::CstrHolder = CstrHolder(reinterpret(Cstring, Ptr{UInt8}(UInt(0x5000))), reinterpret(Cwstring, C_NULL))
read_csh() = (reinterpret(UInt, CSH.s), reinterpret(UInt, CSH.w))
# an allowlisted field and a Memory holding the same pointer: the Memory's is rejected
mutable struct MixedRoot
    h::UnionPtrHolder
    m::Memory{Ptr{UInt8}}
end
const MIXED = MixedRoot(UPH, let m = Memory{Ptr{UInt8}}(undef, 1); m[1] = Ptr{UInt8}(UInt(0x3000)); m end)
read_mixed() = (p = MIXED.h.p; (p === nothing ? UInt(0) : UInt(p)) + UInt(MIXED.m[1]))
global NULL_CSH::CstrHolder = CstrHolder(reinterpret(Cstring, C_NULL), reinterpret(Cwstring, C_NULL))
read_null_csh() = (reinterpret(UInt, NULL_CSH.s), reinterpret(UInt, NULL_CSH.w))

# where native image serialization resets pointers (src/staticdata.c `jl_write_values`): the
# values a package image holds natively (checked on Julia 1.12.7, 1.13.0-rc4, 1.13.3), not the
# build process's (globals, not constants: inference would fold reads of `const` fields)
p(n) = Ptr{Cvoid}(n % UInt)
u(x) = UInt(x)
mutable struct Reset
    p::Ptr{Cvoid}
    a::Any
    u::Union{Nothing,Ptr{Cvoid}}
end
mutable struct ConstPtr
    const q::Ptr{Cvoid}
end
mutable struct ConstAny
    const b::Any
end
mutable struct TupleAny
    t::Tuple{Any,Int}
end
struct InlineAny
    p::Ptr{Cvoid}
    a::Any
end
global RESET::Reset = Reset(p(1), p(3), nothing)
global MINUS1::Reset = Reset(p(-1), p(-1), p(-1))
global CONST_PTR::ConstPtr = ConstPtr(p(2))
global CONST_ANY::ConstAny = ConstAny(p(4))
global TUPLE_ANY::TupleAny = TupleAny((p(5), 1))
global PTRS::Vector{Ptr{Cvoid}} = Ptr{Cvoid}[p(7), p(-1), p(0)]
global ANYS::Vector{Any} = Any[p(8)]
global INLINES::Vector{InlineAny} = InlineAny[InlineAny(p(0), p(11))]
global INLINE_REF::Base.RefValue{InlineAny} = Ref(InlineAny(p(0), p(13)))
read_reset() = (u(RESET.p), u(RESET.a::Ptr{Cvoid}))
read_minus1() = (u(MINUS1.p), u(MINUS1.a::Ptr{Cvoid}), u(MINUS1.u::Ptr{Cvoid}))
read_const_ptr() = u(CONST_PTR.q)
read_const_any() = u(CONST_ANY.b::Ptr{Cvoid})
read_tuple_any() = u(TUPLE_ANY.t[1]::Ptr{Cvoid})
read_ptrs() = (u(PTRS[1]), u(PTRS[2]), u(PTRS[3]))
read_anys() = u(ANYS[1]::Ptr{Cvoid})
read_inlines() = (u(INLINES[1].p), u(INLINES[1].a::Ptr{Cvoid}))
read_inline_ref() = (u(INLINE_REF[].p), u(INLINE_REF[].a::Ptr{Cvoid}))
# stored inline natively, an object here (more leaves than `MAX_INLINE_LEAVES`): reset as
# where it is stored
struct Wide
    a::Any
    pad::NTuple{64,Int}
end
global WIDES::Vector{Wide} = [Wide(p(1), ntuple(_ -> 0, 64))]
global WIDE_REF::Base.RefValue{Wide} = Ref(Wide(p(2), ntuple(_ -> 0, 64)))
read_wides() = u(WIDES[1].a::Ptr{Cvoid})
read_wide_ref() = u(WIDE_REF[].a::Ptr{Cvoid})
# ... also where it is reached again while it is serialized (a cycle: a memory element, or a
# mutable object's field, set once every global exists)
struct WideCycle
    a::Any
    pad::NTuple{64,Int}
    back::Any
end
global WIDE_CYCLE::Base.RefValue{WideCycle} = let m = Memory{WideCycle}(undef, 1)
    w = WideCycle(p(1), ntuple(_ -> 0, 64), m)
    m[1] = w
    Ref(w)
end
read_wide_cycle() = (u(WIDE_CYCLE[].a::Ptr{Cvoid}), u((WIDE_CYCLE[].back::Memory{WideCycle})[1].a::Ptr{Cvoid}))
mutable struct WideHolder
    w::WideCycle
    WideHolder() = new()
end
global WIDE_BACKS::Vector{WideCycle} = let h = WideHolder()
    h.w = WideCycle(p(3), ntuple(_ -> 0, 64), h)
    [h.w]
end
read_wide_backs() = (u(WIDE_BACKS[1].a::Ptr{Cvoid}), u((WIDE_BACKS[1].back::WideHolder).w.a::Ptr{Cvoid}))
# a large tuple's pointers (inline natively, an array here): kept
global BIG_REF::Base.RefValue{NTuple{33,Ptr{Cvoid}}} = Ref(ntuple(_ -> p(3), 33))
global BIG_ANY::Vector{Any} = Any[ntuple(_ -> p(4), 33)]
read_big_ref(i::Int) = u(BIG_REF[][i])
read_big_any(i::Int) = u((BIG_ANY[1]::NTuple{33,Ptr{Cvoid}})[i])
# global variables (a binding's value): reset; a constant: kept
global G_PTR = p(5)
global G_TYPED::Ptr{Cvoid} = p(6)
global G_ANY::Any = p(7)
global G_MINUS1::Ptr{Cvoid} = p(-1)
const C_PTR = p(8)
read_globals() = (u(G_PTR::Ptr{Cvoid}), u(G_TYPED), u(G_ANY::Ptr{Cvoid}), u(G_MINUS1))
read_const_global() = u(C_PTR)
end

@testset "image pointers" begin
    P = ImagePointers
    # null pointers (C_NULL), of any pointer type, are serialized
    @wtest P.null_cstring()
    @wtest P.read_null_holder()
    # another pointer is an unsupported construct (it was a compiler crash for Cstring)
    for f in (P.read_cstring, P.read_holder)
        err = try
            WasmCodegen.compile(f, ())
            nothing
        catch e
            e
        end
        @test err isa WasmCodegen.UnsupportedConstructs
        @test err isa WasmCodegen.UnsupportedConstructs &&
              occursin("a pointer of the build process in the image", sprint(showerror, err))
    end
    # unless its field is allowlisted: its address as it is
    c = WasmCodegen.compile(P.read_holder, (); config=WasmCodegen.Config(image_pointer_fields=[(P.PtrHolder, :p)]))
    @test wasm_run(c, "read_holder"; rettype=UInt) == UInt(0x1003)
    # a field of a mutable object: null, as native images hold it (but allowlisted)
    @test wasm_run(WasmCodegen.compile(P.read_mph, ()), "read_mph"; rettype=UInt) == 0
    c = WasmCodegen.compile(P.read_mph, (); config=WasmCodegen.Config(image_pointer_fields=[(P.MutablePtrHolder, :p)]))
    @test wasm_run(c, "read_mph"; rettype=UInt) == UInt(0x2000)
    # boxed in a union or `Any` field: rejected, or as it is when allowlisted
    for (f, H, addr) in ((P.read_uph, P.UnionPtrHolder, 0x3000), (P.read_aph, P.AnyPtrHolder, 0x4000))
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, ())
        c = WasmCodegen.compile(f, (); config=WasmCodegen.Config(image_pointer_fields=[(H, :p)]))
        @test wasm_run(c, string(nameof(f)); rettype=UInt) == UInt(addr) == f()
    end
    # (a memory's `Ptr` elements: null, as native images hold them)
    c = WasmCodegen.compile(P.read_mixed, (); config=WasmCodegen.Config(image_pointer_fields=[(P.UnionPtrHolder, :p)]))
    @test wasm_run(c, "read_mixed"; rettype=UInt) == UInt(0x3000)
    # C strings in fields: null ones serialized, another as it is when allowlisted
    @wtest P.read_null_csh()
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_csh, ())
    c = WasmCodegen.compile(P.read_csh, (); config=WasmCodegen.Config(image_pointer_fields=[(P.CstrHolder, :s)]))
    @test wasm_run(c, "read_csh"; rettype=Tuple{UInt,UInt}) == (UInt(0x5000), UInt(0)) == P.read_csh()
end

@testset "image pointers reset as natively (shell-first $shell)" for shell in (false, true)
    P = ImagePointers
    config = WasmCodegen.Config(shell_first_mutables = shell)
    run(f, RT) = wasm_run(WasmCodegen.compile(f, (); config), string(nameof(f)); rettype=RT)
    T2, T3 = Tuple{UInt,UInt}, Tuple{UInt,UInt,UInt}
    # a mutable object's `Ptr` field and a `Ptr` in its field of type `Any`: null; -1 kept
    @test run(P.read_reset, T2) == (0, 0)
    @test run(P.read_minus1, T3) == (typemax(UInt), typemax(UInt), typemax(UInt))
    # a `const` `Ptr` field: null before Julia 1.13.3, whose images keep it (an address here)
    if VERSION < v"1.13.3"
        @test run(P.read_const_ptr, UInt) == 0
    else
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_const_ptr, (); config)
    end
    # kept natively, so an address here: a `const` field's boxed `Ptr`, a tuple object's
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_const_any, (); config)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_tuple_any, (); config)
    # a memory's `Ptr` elements, boxed ones, and those in the reference slots of its inline
    # elements, or of an inline value in a mutable object's field
    @test run(P.read_ptrs, T3) == (0, typemax(UInt), 0)
    @test run(P.read_anys, UInt) == 0
    @test run(P.read_inlines, T2) == (0, 0)
    @test run(P.read_inline_ref, T2) == (0, 0)
    # stored inline natively, an object here: reset as where it is stored
    @test run(P.read_wides, UInt) == 0
    @test run(P.read_wide_ref, UInt) == 0
    @test run(P.read_wide_cycle, T2) == (0, 0)
    @test run(P.read_wide_backs, T2) == (0, 0)
    # a large tuple's pointers: kept natively, so addresses here
    for f in (P.read_big_ref, P.read_big_any)
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, (Int,); config)
    end
    # global variables: null, but for -1; a constant's pointer is kept (folded into the code)
    @test run(P.read_globals, Tuple{UInt,UInt,UInt,UInt}) == (0, 0, 0, typemax(UInt))
    @test run(P.read_const_global, UInt) == 8 == P.read_const_global()
end

# the runtime's Unicode tables have no unused capacity (the image serializes all of a Memory)
@testset "image: Unicode tables" begin
    U = WasmCodegen.Runtime.UnicodeData
    for name in (:CATEGORY, :ID_CHAR, :ID_START_CHAR, :BOUNDCLASS, :INDIC_CONJUNCT, :IS_UPPER,
                 :CHARWIDTH, :IS_LOWER, :TO_UPPER, :TO_LOWER, :TO_TITLE)
        for v in getfield(U, name)
            @test length(v.ref.mem) == length(v)
        end
    end
end
