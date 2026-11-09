# Building tuples of known length whose element types are not all known at compile time
# (`Tuple{Any}`, `Tuple{String, Any}`): natively `Core.tuple` makes their type at run time from
# the elements' (`jl_f_tuple`). Here such a tuple is an object of the module's concrete tuple
# type of its elements, found at run time (`tuple_canon_func!`), read by its type
# (`get_field_any!`); of a type no code names, `typeof` of it is the closed world's error.

module AbstractTupleTests

using Test
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen, LAST_OUTPUT

# a value of a type known only at run time
@noinline pick(i::Int) = i == 1 ? Base.inferencebarrier(1) : i == 2 ? Base.inferencebarrier("two") :
                         i == 3 ? Base.inferencebarrier(nothing) : Base.inferencebarrier(2.5)
@noinline small(i::Int)::Union{Int,String} = isodd(i) ? i : string(i)
@noinline id(x) = x

# the type `Core.tuple` gives, of the elements' types
function at_type(i::Int)
    t = (pick(i),)
    T = typeof(t)
    return (T === Tuple{Int}) + 2 * (T === Tuple{String}) + 4 * (T === Tuple{Nothing}) + 8 * (T === Tuple{Float64})
end
function at_type2(i::Int)
    t = (small(i), pick(i))
    T = typeof(t)
    return (T === Tuple{Int,Int}) + 2 * (T === Tuple{String,String}) + 4 * (T === Tuple{Int,Nothing}) +
           8 * (T === Tuple{String,Float64})
end
# a type object as an element: natively `Tuple{DataType}`, not `Tuple{Type{Int}}`
at_type_elem(i::Int) = (t = (typeof(pick(i)),); (typeof(t) === Tuple{DataType}, t[1] === Int, t[1] === String))
# (; exception = e): `splatnew` of `NamedTuple{names, typeof(t)}` at run time
function at_namedtuple(i::Int)
    nt = (; exception = pick(i), n = i)
    T = typeof(nt)
    return (T === @NamedTuple{exception::Int, n::Int}) + 2 * (T === @NamedTuple{exception::String, n::Int}) +
           4 * (nt.exception isa Nothing) + 8 * (nt.n == i)
end
@noinline kw(; exception, n = 0) = (exception isa Int ? 1 : exception isa String ? 2 : 3) + 10n
# (the `NamedTuple` types it may make, named by the program)
at_kwcall(i::Int) = kw(; exception = pick(i), n = i) +
    100 * (id(typeof((; exception = pick(i), n = i))) in (@NamedTuple{exception::Int, n::Int}, @NamedTuple{exception::String, n::Int}))

# the fields, at constant and run-time indices
function at_fields(i::Int)
    t = (pick(i), "s", small(i), pick(i + 1))
    s = 0
    for x in t
        s = 7s + (x isa Int ? 1 : x isa String ? sizeof(x) + 2 : x === nothing ? 3 : 4)
    end
    k = id(i) % 4 + 1
    return (s, length(t), sizeof(t[2]), t[k] isa String, nfields(t))
end
function at_bounds(i::Int)
    t = (pick(i), pick(i + 1))
    try
        return t[id(i) + 1] isa Int ? 1 : 2
    catch err
        return err isa BoundsError ? -1 : -2
    end
end

# isa, === and objectid (`==` and `hash` of the elements are calls of functions of `Any`s)
function at_compare(i::Int)
    t = (pick(i),)
    u = (pick(i),)
    return (t === (1,), t === ("two",), t === (nothing,), t === u, t === (2.5,),
            t isa Tuple{Int}, t isa Tuple{Union{String,Nothing}}, t isa Union{Nothing,Tuple{Int}},
            objectid(t) == objectid(u))
end
# narrowing on a union-split path (a PiNode where it may not hold)
function at_pi(i::Int)
    t = i > 2 ? (pick(i),) : nothing
    t === nothing && return 0
    return t[1] isa Int ? 1 : t[1] === nothing ? 3 : 4
end
# a union element back from the erased tuple
at_union_back(i::Int) = (t = (small(i), pick(i)); x = t[1]; x isa Int ? x : sizeof(x))

# stored: a field, a vector element, an image constant
struct AtHolder
    t::Tuple{Any}
    u::Tuple{String,Any}
end
const AT_CONST = Tuple{Any}[(1,), ("abc",), (nothing,)]
const AT_HOLDER = AtHolder((2.5,), ("k", 7))
function at_stored(i::Int)
    h = id(AtHolder((pick(i),), ("x", pick(i + 1))))
    v = Tuple{Any}[]
    push!(v, h.t); push!(v, (pick(i + 1),))
    c = AT_CONST[mod1(i, 3)]
    return (h.t[1] isa Int, h.u[2] isa String, v[2] === (pick(i + 1),), v[1] === h.t, c[1] isa String,
            AT_HOLDER.t === (2.5,), AT_HOLDER.u[2] === 7, id(h) === h)
end

# the varargs of printing: a small union, a `Type` of an abstract type (Tuple{String, Type{<:Integer}})
at_string(i::Int) = (s = string("a", small(i), 'c'); (sizeof(s), hash(s)))
@noinline itype(i::Int)::Type{<:Integer} = isodd(i) ? Int : UInt8
function at_error(i::Int)
    try
        error("value of type ", itype(i), "!")
    catch err
        s = (err::ErrorException).msg::String
        return (sizeof(s), hash(s))
    end
end

# a large tuple of one type as an object: of its own type, as before
at_large(i::Int) = (t = ntuple(k -> k * i, 70); x = id(t); (typeof(x) === NTuple{70,Int}, x === t, x[70]))

# a tuple whose concrete type no code of the module names: built, read and compared, but its
# `typeof` is the closed world's error
struct AtUnnamed
    a::Int
end
@noinline unnamed(i::Int) = Base.inferencebarrier(AtUnnamed(i))
# `isa` of a tuple type with free type variables: natively `<:` of the value's type, element by
# element (a free variable is opaque: `Int <: T` is false), also of a tuple whose concrete type
# the module does not have (an object of `Tuple`)
# (the type a constant of the code, as inference leaves one: not a global's binding)
@eval at_isa_free(i::Int) = let F = $(let T = TypeVar(:T); Tuple{T,T}; end)
    ((pick(i), pick(i)) isa F, (unnamed(i), i) isa F, (pick(i),) isa Tuple{Any})
end
function at_unnamed_ok(i::Int)
    t, u = (unnamed(i), i), (unnamed(i), id(i))
    return (t[1] isa AtUnnamed, (t[1]::AtUnnamed).a, t === u, t[2] === u[2], objectid(t) == objectid(u))
end
# `splatnew` of a type known only at run time: exactly its fields (natively an ArgumentError of
# too few or too many arguments, where `new` may leave fields out)
struct AtPart{T}
    a::T
    b::T
    AtPart{T}(a) where {T} = new{T}(a)
    AtPart{T}(a, b) where {T} = new{T}(a, b)
end
const AtPartType = Type{<:AtPart}
const AtTypeType = Union{Type{<:Type}, Type{String}, Type{Symbol}, Type{Memory{Int}}}
@noinline at_ptype(i::Int) = Base.inferencebarrier(i > 0 ? AtPart{Int} : AtPart{Float64})::AtPartType
@generated at_sn(i, t) = Expr(:splatnew, :(at_ptype(i)), :t)
at_arity_msg(e) = e isa ArgumentError ? (occursin("too few arguments (expected 2)", e.msg::String) ? -1 :
                                         occursin("too many arguments (expected 2)", e.msg::String) ? -2 : -3) : -4
at_splat1(a::Int) = try (at_sn(a, (a,)); 1) catch e; at_arity_msg(e) end
at_splat2(a::Int) = (p = at_sn(a, (a, a + 1)); p isa AtPart{Int} ? p.a + p.b : -1)
at_splat3(a::Int) = try (at_sn(a, (a, a, a)); 1) catch e; at_arity_msg(e) end
# (of the runtime's own types, of which `new` builds nothing: the number first, as natively)
@noinline at_rtype(i::Int) = Base.inferencebarrier(i == 1 ? UnionAll : i == 2 ? Union : i == 3 ? DataType :
                                                     i == 4 ? String : i == 5 ? Symbol : Memory{Int})::AtTypeType
@generated at_sn_rt(i, t) = Expr(:splatnew, :(at_rtype(i)), :t)
at_splat_rt(i::Int) = try (at_sn_rt(i, (1,)); 0) catch e; e isa ArgumentError ? 1 : e isa TypeError ? 2 : 3 end
# (compared with a type, as `<: Tuple` of it is folded by inference)
at_unnamed_typeof(i::Int) = id(typeof(id((unnamed(i),)))) === Tuple{Int}

# `isa` of tuples, some of concrete types no code names (objects of `Tuple`), against unions with
# tuple types, tuple types with free type variables or `Type` parameters, nested tuples, and of
# tuples of unknown length: natively `<:` of the type the elements make
@noinline opaque(x) = Base.inferencebarrier(x)
const AT_NUM_OR_PAIR = Union{Tuple{Number}, Tuple{T,T} where T}
function at_isa_union(i::Int)
    t = opaque((unnamed(i), opaque(i)))                 # Tuple{AtUnnamed,Int}
    u = opaque((opaque(i),))                            # Tuple{Int}
    n = opaque((opaque((unnamed(i), i)), "s"))          # Tuple{Tuple{AtUnnamed,Int},String}
    return (t isa Union{Nothing,Tuple{AtUnnamed,Int}}, t isa Union{Nothing,Tuple{AtUnnamed,Number}},
            t isa Union{Int,Tuple{AtUnnamed,String}}, u isa Union{Nothing,Tuple{Number}},
            u isa AT_NUM_OR_PAIR, n isa Union{Nothing,Tuple{Tuple{AtUnnamed,Int},String}},
            n isa Union{Nothing,Tuple{Tuple{AtUnnamed,String},String}}, t isa Union{Missing,Tuple{Any,Vararg{Int}}},
            n isa Union{Missing,Tuple{Tuple,AbstractString}}, t isa Union{Missing,Tuple{AtUnnamed,Vararg{String}}})
end
@eval function at_isa_freevars(i::Int)
    F1, F2, F3, F4, F5 = $(let T = TypeVar(:T), N = TypeVar(:N)
        (Tuple{Union{Int,T}}, Tuple{Any,Vararg{T}}, Tuple{T,T}, Tuple{Int,Vector{T}}, Tuple{Vararg{Int,N}})
    end)
    t, v, w = opaque((opaque(i),)), opaque((opaque(i), opaque(i))), opaque((unnamed(i),))
    return (t isa F1, t isa F2, v isa F2, v isa F3, t isa F3, w isa F1, w isa F2, opaque((i, Int[])) isa F4,
            v isa F5, t isa Union{Nothing,F1})
end
# a type object's element type is its kind: `(Int, 1)` is a `Tuple{DataType,Int}`
function at_isa_kinds(i::Int)
    t = opaque((opaque(i == 1 ? Int : String), unnamed(i)))
    return (t isa Tuple{Type{Int},AtUnnamed}, t isa Tuple{DataType,Any}, t isa Tuple{Type,AtUnnamed},
            t isa Union{Nothing,Tuple{Type{Int},AtUnnamed}}, t isa Union{Nothing,Tuple{DataType,AtUnnamed}})
end
# `objectid` of tuples, some of types no code names (objects of `Tuple`): as natively of their
# concrete types, of those types' hashes and layouts: of their bytes (no padding, no references),
# else of their elements' ids mixed (inline: from 0; references: their `objectid`)
struct AtByte
    a::UInt8
end
struct AtPad
    a::Int8
    b::Int64
end
function at_objectid(i::Int)
    return (objectid(opaque((unnamed(i), opaque(i)))),                 # 16 bytes
            objectid(opaque((opaque(Int32(i)), opaque(Int32(2i))))),   # 8 bytes
            objectid(opaque((opaque(AtByte(UInt8(i))),))),             # 1 byte
            objectid(opaque((opaque(Int8(i)), opaque(i)))),            # padding: by the elements
            objectid(opaque((opaque(i), "s"))),                        # a reference
            objectid(opaque((opaque((unnamed(i), i)), 2.5))),          # nested, of bytes
            objectid(opaque((opaque((unnamed(i), "x")), i))),          # nested, with a reference
            objectid(opaque((nothing, opaque(i)))),                     # a singleton
            objectid(opaque((opaque(Some("a")), opaque(i)))),          # inline, with a reference
            objectid(opaque((Int, opaque(i)))),                        # a type object
            objectid(opaque((opaque(AtPad(Int8(i), i)), opaque(i)))),  # inline, with padding
            objectid(opaque((opaque(1.5), opaque(-0.0)))),
            objectid(opaque((opaque(:sym), opaque(i)))),
            objectid(tuple(Any[unnamed(i), i, "z", (unnamed(i),)]...)),
            objectid(opaque((opaque(Union{}), opaque(i)))),            # an element of no size
            objectid(opaque((opaque(Union{}),))),
            objectid(opaque((opaque(VecElement(Float32(i))), opaque(VecElement(Float32(2i))),  # a vector: aligned
                             opaque(VecElement(Float32(3i)))))),
            objectid(opaque((opaque((opaque(VecElement(Float32(i))), opaque(VecElement(Float32(2i))))), opaque(Int32(i))))),
            objectid(opaque((opaque(VecElement(1.0i)), opaque(VecElement(2.0i)), opaque(VecElement(3.0i)), opaque(VecElement(4.0i))))),
            objectid(opaque((opaque(VecElement(Float32(i))), opaque(VecElement(Float32(2i))), opaque(Float32(i))))))
end
# (a vector of 2^16 bytes: its alignment stored natively in 16 bits, 0, so not aligned to in a tuple)
function at_largevec(n::Int)
    a = Any[VecElement(Float32(i)) for i in 1:n]
    t = opaque(tuple(a...))
    return objectid(opaque((opaque(Int32(7)), t)))
end

# `isa` against tuple types with bound type variables, natively by the types of the elements:
# the diagonal rule, a variable at two elements or more of one concrete type within its bounds
# (at one: of a type within its upper bound; at none: any), else as against the bounds
const AT_TA = Tuple{T,Vararg{T}} where T
const AT_TB = Tuple{Vararg{T}} where T<:Real
const AT_UTB = Union{Nothing,AT_TB}
const AT_TI = Tuple{Vararg{T}} where Int<:T<:Real
const AT_TPAIR = Tuple{T,T} where T
const AT_TSPAN = Tuple{T,S,T} where {T,S}
const AT_TCHAR = Tuple{T,Char} where Int<:T<:Real
# (not of the common shape: a variable in a parameter, a `Vararg` of a variable length)
const AT_TVEC = Tuple{Any,Vector{T}} where T
const AT_TVN = Tuple{Vararg{T,N}} where {T<:Real,N}
at_tb_strings(n::Int) = id(Any[tuple(fill("a", n)...)])[1] isa AT_TB
at_tb_union(n::Int) = id(Any[tuple(collect(1:n)...)])[1] isa AT_UTB
at_ta_vararg(n::Int) = tuple(Vector{Any}(collect(1:n))...) isa AT_TA
at_tb_ints(n::Int) = id(Any[tuple(collect(1:n)...)])[1] isa AT_TB
function at_diag(i::Int)
    x, y = opaque((opaque(i), opaque(2i))), opaque((opaque(i), opaque(2.5)))
    u, v = opaque((unnamed(i), unnamed(2i))), opaque((unnamed(i), opaque(i)))
    w, z = opaque((opaque(Int), opaque(String))), opaque((opaque(Int), opaque(Vector)))
    return (x isa AT_TPAIR, y isa AT_TPAIR, u isa AT_TPAIR, v isa AT_TPAIR, w isa AT_TPAIR, z isa AT_TPAIR,
            x isa AT_TI, y isa AT_TI, opaque((opaque(1.5),)) isa AT_TI, opaque((opaque(1.5), opaque(1.5))) isa AT_TI,
            opaque((opaque(i), 'c', opaque(3i))) isa AT_TSPAN, opaque((opaque(i), 'c', opaque(3.0))) isa AT_TSPAN,
            opaque((unnamed(i), opaque(i), unnamed(3i))) isa AT_TSPAN, opaque((opaque(1.5), 'c')) isa AT_TCHAR,
            opaque((opaque("a"), 'c')) isa AT_TCHAR, u isa AT_TA, v isa AT_TA, x isa AT_TB, y isa AT_TB)
end
function at_diag_vararg(n::Int)
    a = tuple(Any[1, 2, 3, 4.5][1:n]...)
    b = tuple(Any[unnamed(1), unnamed(2), "s", unnamed(3)][1:n]...)
    c = tuple(Any[1.5, 2.5, 3.5, 4.5][1:n]...)
    return (a isa AT_TA, a isa AT_TB, a isa AT_TI, b isa AT_TA, b isa AT_TPAIR, a isa AT_TPAIR,
            c isa AT_TI, c isa AT_TB, a isa AT_UTB, b isa AT_NUM_OR_PAIR, a isa AT_NUM_OR_PAIR)
end
# (a union with a member with type variables, ruled out by the elements, or of them)
function at_union_bound(i::Int)
    return (opaque((opaque("s"),)) isa AT_NUM_OR_PAIR, opaque((unnamed(i), unnamed(2i))) isa AT_NUM_OR_PAIR,
            opaque((unnamed(i), opaque(i))) isa AT_NUM_OR_PAIR, opaque((opaque((unnamed(i), i)),)) isa AT_NUM_OR_PAIR,
            opaque((opaque((unnamed(i), i)), opaque((unnamed(i), i)))) isa AT_NUM_OR_PAIR,
            tuple(Any["s", unnamed(i), i][1:i % 3 + 1]...) isa AT_NUM_OR_PAIR)
end
# (not of the common shape: false where the elements are not of the bounds)
at_shape_false(i::Int) = (opaque((unnamed(i), "s")) isa AT_TVEC, opaque((opaque("a"), opaque(i))) isa AT_TVN,
                          tuple(Any[unnamed(i), "s"]...) isa AT_TVEC)
# (where they are: the closed world's error; natively true)
at_shape_error(i::Int) = opaque((unnamed(i), [i])) isa AT_TVEC
# (variables of bounds of other variables: the bounds test, without comparing them)
const AT_DEP_DIRECT = Tuple{S} where {T<:Real,S<:T}
const AT_DEP_NESTED = Tuple{Vector{S}} where {T<:Real,S<:T}
at_dependent(i::Int) = (opaque(("s",)) isa AT_DEP_DIRECT, opaque((opaque(i),)) isa AT_DEP_NESTED,
                        opaque((opaque("s"),)) isa AT_DEP_NESTED)
# (a variable whose bound is a free variable, as some stock constants: compiled, the bounds test)
const AT_FREE_UPPER = let T = TypeVar(:T, Int, Real), S = TypeVar(:S, T)
    UnionAll(S, Tuple{S})
end
at_free_upper(i::Int) = opaque((opaque("s"),)) isa AT_FREE_UPPER
# (a tuple of a concrete type the module has, named here: by the module's types, as natively,
# whatever the bounds: `Real<:T`, no diagonal rule; `Int<:T<:Float64`, not ordered)
const AT_LOW = Tuple{Vararg{T}} where Real<:T<:Number
const AT_DISJOINT = Tuple{Vararg{T}} where Int<:T<:Float64
at_named_low(n::Int) = (t = tuple(Any[1, 2.5][1:n]...); (t isa AT_LOW, id(typeof(opaque(t))) === Tuple{Int,Float64}))
at_named_disjoint(n::Int) = (t = tuple(Any[1, 2][1:n]...); (t isa AT_DISJOINT, id(typeof(opaque(t))) === Tuple{Int,Int}))
at_named_object(i::Int) = (x = opaque((opaque(i), opaque(2.5))); (x isa AT_LOW, x isa AT_TB, id(typeof(x)) === Tuple{Int,Float64}))
# (of a type the module does not have: an abstract lower bound, no diagonal rule; a concrete
# tuple lower bound of a type the module does not have, of the elements' type)
struct AtReal <: Real
    x::Int
end
const AT_TUPLE_LOW = Tuple{T,T} where Tuple{AtUnnamed}<:T<:Tuple
function at_lower_bounds(i::Int)
    a, b = opaque((unnamed(i),)), opaque((unnamed(2i),))
    return (opaque((opaque(AtReal(i)), opaque(2.5))) isa AT_LOW, opaque((opaque(AtReal(i)), "s")) isa AT_LOW,
            tuple(Any[AtReal(i), 2.5, 1][1:i]...) isa AT_LOW, opaque((a, b)) isa AT_TUPLE_LOW,
            opaque((a, opaque((opaque(i),)))) isa AT_TUPLE_LOW, opaque((opaque((opaque(i),)), a)) isa AT_TUPLE_LOW)
end

# free type variables with a lower bound of tuples: natively `<:` of the lower bound
@eval function at_free_lower(i::Int)
    F, G = $(let T = TypeVar(:T, Tuple{Number}, Any); (Tuple{T}, Tuple{Union{Int,T}}); end)
    return (opaque((opaque((opaque(i),)),)) isa F, opaque((opaque((opaque("s"),)),)) isa F,
            opaque((opaque((unnamed(i),)),)) isa G, opaque((opaque((opaque(1.5),)),)) isa G,
            tuple(Any[(opaque(1.5),)]...) isa G, tuple(Any[(unnamed(i),)]...) isa G, opaque((opaque(i),)) isa G)
end
function at_isa_vararg(n::Int)
    t = tuple(Any[Int, opaque(n), unnamed(n)][1:n]...)
    return (t isa Union{Nothing,Tuple{DataType}}, t isa Tuple{Type{Int}}, t isa Tuple{DataType,Int},
            t isa Union{Tuple{Vararg{Type}},Nothing}, t isa Union{Missing,Tuple{DataType,Int,AtUnnamed}},
            t isa Tuple{Any,Vararg{Integer}})
end

@testset "tuples of abstract type" begin
    for i in 1:4
        @wtest at_type(i)
        @wtest at_type2(i)
        @wtest at_type_elem(i)
        @wtest at_fields(i)
        @wtest at_compare(i)
        @wtest at_pi(i)
        @wtest at_union_back(i)
        @wtest at_stored(i)
        @wtest at_string(i)
        @wtest at_error(i)
        @wtest at_unnamed_ok(i)
        @wtest at_isa_free(i)
        @wtest at_isa_union(i)
        @wtest at_isa_freevars(i)
        @wtest at_isa_kinds(i)
        @wtest at_objectid(i)
    end
    for n in 1:3
        @wtest at_isa_vararg(n)
    end
    @wtest at_largevec(3)
    @wtest at_largevec(16384)
    for n in (0, 1, 2, 17)
        @wtest at_tb_strings(n)
        @wtest at_tb_union(n)
        @wtest at_ta_vararg(n)
        @wtest at_tb_ints(n)
    end
    @wtest at_named_low(2)
    @wtest at_named_disjoint(2)
    for i in 1:3
        @wtest at_named_object(i)
        @wtest at_lower_bounds(i)
        @wtest at_diag(i)
        @wtest at_union_bound(i)
        @wtest at_shape_false(i)
        @wtest at_free_lower(i)
    end
    for n in 0:4
        @wtest at_diag_vararg(n)
    end
    # (not of the common shape, of an element of the bounds: the closed world's error)
    @test at_shape_error(1)
    let got = wasm_run(wcompile(at_shape_error, (Int,)), "at_shape_error", 1; rettype=Bool)
        @test got isa Tuple && got[1] === :trap
        @test occursin("isa of a tuple whose concrete type the module does not have", LAST_OUTPUT[])
    end
    @wtest at_dependent(1)
    @wtest at_free_upper(1)
    for i in 0:2
        @wtest at_bounds(i)
    end
    # (of the `NamedTuple` types code names: of an `Int` and of a `String`)
    for i in 1:2
        @wtest at_namedtuple(i)
        @wtest at_kwcall(i)
    end
    @wtest at_large(3)
    for a in (2, -2)
        @wtest at_splat1(a)
        @wtest at_splat3(a)
    end
    @wtest at_splat2(2)
    # (of an opaque layout, `String`, `Symbol`, `Memory`: the TypeError first, as natively)
    for i in 1:6
        @wtest at_splat_rt(i)
    end
    # (with trim = :safe: none of them is an unsupported construct)
    for (f, at) in ((at_type, (Int,)), (at_namedtuple, (Int,)), (at_fields, (Int,)), (at_string, (Int,)))
        @test isempty(WasmCodegen.compile(f, at).cgm.diagnostics)
    end
    # the closed world: natively `Tuple{AtUnnamed}`; here an error with a message
    @test !at_unnamed_typeof(1)
    @test at_namedtuple(4) == 8
    let got = wasm_run(wcompile(at_unnamed_typeof, (Int,)), "at_unnamed_typeof", 1; rettype=Bool)
        @test got isa Tuple && got[1] === :trap
        @test occursin("typeof of a tuple whose concrete type the module does not have", LAST_OUTPUT[])
    end
    # (a `NamedTuple` of a value whose tuple type no code names: `Tuple{Float64, Int}`, the
    # `typeof` of `NamedTuple{names}(t)`)
    let got = wasm_run(wcompile(at_namedtuple, (Int,)), "at_namedtuple", 4; rettype=Int)
        @test got isa Tuple && got[1] === :trap
        @test occursin("typeof of a tuple whose concrete type the module does not have", LAST_OUTPUT[])
    end
end

end
