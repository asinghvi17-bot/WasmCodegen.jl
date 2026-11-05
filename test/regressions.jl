# Programs that were compiled wrong: identity, layouts, pointers, undefined values, tuples of
# unknown length, varargs with type objects, and LAPACK's extreme magnitudes

using LinearAlgebra

@noinline rg_id(x) = x
const RI = Core.Intrinsics

# type objects keep their native objectid: keys of an IdDict built at compile time
const RG_TYPEKEYS = IdDict{Any,Int}(Int => 1, Union{Int,Nothing} => 2, Vector => 3, Union{} => 4)
const RG_TYPES = Any[Int, Union{Int,Nothing}, Vector, Union{}, Float64]
rg_typekeys(i::Int) = (get(RG_TYPEKEYS, RG_TYPES[i], -1), objectid(RG_TYPES[i]) == objectid(RG_TYPES[min(i + 1, 5)]))

# a Bool is one bit for the intrinsics (true is -1 signed)
rg_bool(x::Bool, y::Bool) = (RI.sext_int(Int64, x), RI.slt_int(x, y), RI.sitofp(Float64, x), RI.ctlz_int(x),
                             RI.checked_sadd_int(x, y), RI.shl_int(x, 1), RI.ashr_int(x, 5))
rg_bool_sdiv(x::Bool, y::Bool) = try RI.checked_sdiv_int(x, y) catch e; e isa DivideError ? false : true end

# pointers: === by address, clearing references through them
struct RGPtr; p::Ptr{UInt8}; n::Int; end
function rg_ptr_egal(i::Int)
    a = UInt8[1, 2, 3]
    GC.@preserve a begin
        p, q = pointer(a, i), Ptr{UInt8}(UInt(pointer(a, 2)))
        v = Any[p, q, RGPtr(p, 1), RGPtr(q, 1)]
        (v[1] === v[2], v[3] === v[4])
    end
end
function rg_null_store(i::Int)
    a = Any[1, 2, 3]
    m = Union{String,Vector{Int}}["a", [1], "c"]
    GC.@preserve a m begin
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(a)), C_NULL, i)
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(m)) + 8 * (i - 1), C_NULL)
    end
    (isassigned(a, 1), isassigned(a, 2), isassigned(a, 3), isassigned(m, 2), Int(pointer(m, 3) - pointer(m, 1)))
end

# memset and memmove of parts of elements stored with padding
function rg_memset(n::Int)
    a = [(UInt8(17), UInt64(123))]
    b = [ntuple(_ -> (Int8(1), Int16(2)), 3), ntuple(_ -> (Int8(1), Int16(2)), 3)]
    GC.@preserve a b begin
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), pointer(a), 0, n)
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), pointer(b), 0, n)
    end
    (a[1], b[1][1], b[1][3], b[2][1])
end
function rg_memmove(n::Int)
    a = [(UInt8(17), UInt64(123))]
    b = [(UInt8(5), UInt64(6))]
    GC.@preserve a b unsafe_copyto!(Ptr{UInt8}(pointer(b)), Ptr{UInt8}(pointer(a)), n)
    b[1]
end

# a typed global of a tuple with a union element (stored boxed)
global rg_utuple::Tuple{Union{Int,Nothing},Tuple{Union{Float64,Nothing},Int}} = (nothing, (2.5, 3))
rg_union_tuple_global(i::Int) = (rg_utuple[1] === nothing, rg_utuple[2][1]::Float64 + i, rg_utuple[2][2])

# values never stored: zero bits where Julia stores them inline without references, else
# undefined (UndefRefError); (memories of isbits elements are not zeroed natively, but those
# of unions are)
struct RGS; x::Int; s::String; end
mutable struct RGM; x::Union{Nothing,Int}; y::String; z::Some{Union{Nothing,Int}}; RGM() = new(); end
struct RGI; a::Int; u::Union{Nothing,Float64}; RGI(a) = new(a); end
rg_undef_ref(n::Int) = (try Vector{RGS}(undef, n)[1].x catch e; e isa UndefRefError ? -1 : -2 end,
                        try Vector{Tuple{String,String}}(undef, n)[1]; 0 catch e; e isa UndefRefError ? -1 : -2 end)
rg_undef_zero(n::Int) = (isassigned(Vector{Ptr{Cvoid}}(undef, n), 1), (Vector{Ptr{Cvoid}}(undef, n)[1]; true),
                         ismissing(Vector{Union{Missing,Float64}}(undef, n)[n]),
                         count(isnothing, Vector{Union{Nothing,Int}}(undef, n)),
                         Vector{Some{Union{Nothing,Int}}}(undef, n)[1].value === nothing,
                         typeof(Vector{Union{Int8,Int32}}(undef, n)[1]) === Int8)
rg_undef_fields(i::Int) = (m = RGM(); (isdefined(m, :x), isdefined(m, :z), isdefined(m, :y),
                                         try m.y; 0 catch e; e isa UndefRefError ? i : -1 end))
# (fields of unions `new` is not given: zero bits from Julia 1.13 on, uninitialized before)
rg_unset_union_fields(i::Int) = (m = RGM(); s = rg_id(RGI(i)); (m.x === nothing, m.z.value === nothing, s.u === nothing))

# errors of memory sizes, and shifts by 128-bit counts
rg_memsize(n::Int) = try length(Vector{Int}(undef, n)) catch e; e isa ArgumentError ? -1 : -2 end
rg_shift128(x::Int64, n::UInt128) = (x << n, x >> n, x >>> n, Int8(x) << n)

# tuples of unknown length (from splatting) as objects: of their concrete types
rg_vt_isa(n::Int) = (x = rg_id(Any[(collect(1:n)...,)])[1];
                     (x isa Tuple{Int,Int}, x isa NTuple{3,Int}, x isa Tuple{Vararg{Int}}, x === (1, 2), x === (1, 2, 3)))
rg_vt_egal(n::Int) = (v = collect(1:n); w = collect(1:3); (tuple(v...) === (1, 2, 3), tuple(v...) === tuple(w...)))
rg_vt_abstract(i::Int) = (x = rg_id(Any[(i, "x"), (1.5,), ("y", 2)])[i];
                          (x isa Tuple ? length(x) : -1, x isa Tuple{Int,Vararg} ? x[1] : -1,
                           x isa Tuple ? objectid(x) == objectid((i, "x")) : false))
rg_vt_vararg(i::Int) = (u = rg_id(Any[(i, 2.5, 3.5), (i, 2.5, "x"), (i,), ("s", 1.0)])[i]::Tuple;
                        (u isa Tuple{Int,Vararg{Float64}}, u isa Tuple{Int,Vararg{String}}, u isa Tuple{Any,Any,Vararg{Any}}))
rg_vt_iddict(n::Int) = (d = IdDict{Any,Int}(); d[(collect(1:n)...,)] = 4;
                        (get(d, (collect(1:n)...,), -1), get(d, (collect(1:n+1)...,), -1)))
rg_vt_large(n::Int) = (x = rg_id(Any[(collect(1:n)...,)])[1]; (x isa NTuple{70,Int}, x === ntuple(identity, 70)))
# (of concrete types the module does not have: objects of `Tuple`, whatever their elements'
# storage, tested and converted by their elements)
rg_vt_absent(n::Int) = (x = rg_id(Any[tuple(collect(1:n)...)])[1];
                        (x isa Tuple{Int,Vararg{Int}}, x isa Tuple{Vararg{Real}}, x isa Tuple{Vararg{String}},
                         length(x::Tuple), (y = x::Tuple{Vararg{Int}}; s = 0; for i in 1:length(y); s += y[i]; end; s)))
rg_vt_absent_egal(n::Int) = (v = Vector{Any}(undef, 2); v[1] = tuple(collect(1:n)...); v[2] = tuple(Vector{Any}(collect(1:n))...);
                             v = rg_id(v); (v[1] === v[2], objectid(v[1]) == objectid(v[2])))
# (large tuples as tuples of unknown length of other storage, and back; in the image)
const RG_BIG = ntuple(identity, 70)
global rg_big::Tuple = ntuple(identity, 70)
rg_vt_storage(n::Int) = (x = tuple(Vector{Any}(collect(1:n))...)::NTuple{70,Int};
                         (length(rg_id(Any[RG_BIG])[1]::Tuple), x[1] + x[70], length(rg_big), rg_big[70]::Int))
# (a field of a tuple type of unknown length, from the image and made at run time)
struct RGVt; t::Tuple{Vararg{Union{Int,String}}}; end
const RG_VT = RGVt((3, "a"))
rg_vt_field(n::Int) = (a = rg_id(Any[RGVt((n, "a"))])[1]; b = rg_id(Any[RG_VT])[1]; (a === b, objectid(a) == objectid(b)))

# singular values and symmetric eigenvalues of extreme magnitudes (scaled, as LAPACK does)
rg_svd(x::Float64) = (s = svdvals([x 2x; 3x 4x]); (s[1] / x, s[2] / x, svdvals(fill(x, 1, 1))[1] / x))
rg_eig(x::Float64) = (e = eigvals(Symmetric([2x x 0; x 3x x; 0 x 4x])); (e[1] / x, e[2] / x, e[3] / x))

# varargs with a `Type{X}` element, packed in a tuple of the type native codegen gives them
# (`Tuple{DataType, Float64}`; `Tuple{Type{UInt64}, Float64}`, the signature's, is no value's
# type), then boxed (an `InexactError`'s arguments, with a union element too)
@noinline rg_pick(c::Bool) = c ? 1.5 : 1
rg_bits(a) = (a isa Tuple{DataType,Float64}, a isa Tuple{DataType,Int}, a isa Tuple{Any,Float64},
              typeof(a) === Tuple{DataType,Float64})
rg_type_tuple(c::Bool) = rg_bits(InexactError(:ceil, UInt64, rg_pick(c)).args)
# varargs with a type object, packed as native codegen packs them: of 65 elements (no longer
# inline, as a tuple of the signature's types would be)
struct RgHold
    a
end
@noinline rg_hold(args...) = RgHold(args)
@eval rg_type_many(x::Float64) = (h = rg_hold(UInt64, $(fill(:x, 64)...)); (h.a[2]::Float64) + (h.a[65]::Float64) + (h.a[1] === UInt64))
# an entry point with varargs and a type object: its export takes the arguments as a function
# without varargs would (no parameter for the type object)
rg_ventry(xs...) = xs[2]::Float64 + (xs[1] === Int)
# and one whose method's signature is wider than the entry's (`@nospecialize`): the entry's
Base.@nospecializeinfer rg_nsentry(@nospecialize(x), ys::Int...) = (x::Int) + 10 * length(ys) + 100 * ys[1]
Base.@nospecializeinfer rg_nsentry1(@nospecialize(x)) = (x::Int) + 1
const RG_XS = (Inf, 1)
function rg_type_tuple_loop(i::Int)
    r = (false, false, false, false)
    k = 0
    for x in RG_XS
        (k += 1) == i || continue
        r = try ceil(UInt64, x * 1000); r catch e; rg_bits((e::InexactError).args) end
    end
    return r
end

@testset "regressions" begin
    for i in 1:5
        @wtest rg_typekeys(i)
    end
    for (x, y) in ((true, false), (true, true), (false, true))
        @wtest rg_bool(x, y)
        @wtest rg_bool_sdiv(x, y)
    end
    @wtest rg_ptr_egal(1); @wtest rg_ptr_egal(2)
    @wtest rg_null_store(2); @wtest rg_null_store(3)
    for n in (1, 9, 12, 13, 16)
        @wtest rg_memset(n)
    end
    @wtest rg_memmove(1); @wtest rg_memmove(16)
    @wtest rg_union_tuple_global(1)
    @wtest rg_undef_ref(2)
    @wtest rg_undef_zero(3)
    @wtest rg_undef_fields(3)
    VERSION >= v"1.13-" && @wtest rg_unset_union_fields(3)
    @wtest rg_memsize(-1); @wtest rg_memsize(3)
    @wtest rg_shift128(-5, UInt128(2)); @wtest rg_shift128(-5, UInt128(1) << 70)
    for n in 2:3
        @wtest rg_vt_isa(n)
        @wtest rg_vt_egal(n)
        @wtest rg_vt_iddict(n)
    end
    for i in 1:3
        @wtest rg_vt_abstract(i)
    end
    for i in 1:4
        @wtest rg_vt_vararg(i)
    end
    @wtest rg_vt_large(70); @wtest rg_vt_large(3)
    @wtest rg_vt_absent(2); @wtest rg_vt_absent(17)
    @wtest rg_vt_absent_egal(17)
    @wtest rg_vt_storage(70)
    @wtest rg_vt_field(3); @wtest rg_vt_field(4)
    @wtest rg_type_tuple(true); @wtest rg_type_tuple(false)
    @wtest rg_type_tuple_loop(1); @wtest rg_type_tuple_loop(2)
    @wtest rg_type_many(1.5)
    @test wasm_run(wcompile(rg_ventry, (Type{Int}, Float64)), "rg_ventry", 1.5; rettype = Float64) === rg_ventry(Int, 1.5)
    @test wasm_run(wcompile(rg_nsentry, (Int, Int)), "rg_nsentry", 3, 4; rettype = Int) === rg_nsentry(3, 4)
    @test wasm_run(wcompile(rg_nsentry1, (Int,)), "rg_nsentry1", 3; rettype = Int) === rg_nsentry1(3)
    for x in (1.0, 1e100, 1e-100, 1e200, 1e-200, 1e300, 1e-300)
        @wtest_approx rg_svd(x)
        @wtest_approx rg_eig(x)
    end
end
