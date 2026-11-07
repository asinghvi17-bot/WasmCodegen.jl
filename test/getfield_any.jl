# `getfield` of a value whose type is not concrete (an abstract type, a `Union`, a `UnionAll`,
# `Any`): natively the `getfield` builtin finds the field by the value's type at run time;
# here the module's case for the value's type (reflection.jl `getfield_any_func!`), with the
# native errors.

module GetfieldAnyTests

using Test
using ..Main: @wtest, WasmCodegen, wcompile, wasm_run

abstract type Shape end
struct Circle <: Shape
    r::Float64
    name::String
end
struct Square <: Shape
    side::Int
    name::String
end
mutable struct Tri <: Shape
    a::Int
    name::String
    Tri(a::Int) = new(a)   # (`name` undefined)
    Tri(a::Int, name::String) = new(a, name)
end
struct Box{T}
    v::T
end

const SHAPES = Shape[Circle(1.5, "circle"), Square(2, "sq"), Tri(3, "tri"), Tri(4)]
const BOXES = Box[Box(1), Box("two"), Box(3.0), Box(nothing)]
const ANYS = Any[Circle(1.0, "x"), Box(7), (5, "a"), "str", 42]

# by name: a field every subtype has
shape_name(i::Int) = hash(SHAPES[i].name::String)
# by index: fields of different types
shape_first(i::Int) = (v = getfield(SHAPES[i], 1); v isa Float64 ? v : Float64(v::Int))
# a field some subtypes have: a FieldError for the others
shape_side(i::Int) = getfield(SHAPES[i], :side)::Int
shape_side_caught(i::Int) =
    try
        getfield(SHAPES[i], :side)::Int
    catch e
        e isa FieldError ? -1 : -2
    end
# a field not defined: an UndefRefError
shape_name_caught(i::Int) =
    try
        hash(SHAPES[i].name::String)
    catch e
        e isa UndefRefError ? UInt(1) : UInt(2)
    end
# an index out of the fields: a BoundsError
any_third_caught(i::Int) =
    try
        getfield(ANYS[i], 3)
        0
    catch e
        e isa BoundsError ? -1 : -2
    end
# of a UnionAll
box_kind(i::Int) = (v = BOXES[i].v; v isa Int ? 1 : v isa String ? 2 : v isa Float64 ? 3 : 4)
# of Any: a struct, a parametric struct, a tuple
any_first(i::Int) = (v = getfield(ANYS[i], 1); v isa Float64 ? 1 : v isa Int ? 2 : 3)
# of a small Union
union_first(i::Int) = (x = i > 0 ? Box(i) : Circle(1.0, "c"); Float64(getfield(x, 1)))
# a tuple whose concrete type the module does not have (an object of `Tuple`; compiled before
# the native run, which would leave an `NTuple{1000,Int}` in the image)
const HOLD = Any[()]
fallback_first(n::Int) = (HOLD[1] = tuple(collect(1:n)...); getfield(HOLD[1], 1)::Int + getfield(HOLD[1], 3)::Int)
function fallback_zero(n::Int)
    HOLD[1] = tuple(collect(1:n)...)
    try
        getfield(HOLD[1], 0)
    catch e
        return e isa BoundsError
    end
    return false
end
function fallback_name(n::Int)
    HOLD[1] = tuple(collect(1:n)...)
    try
        getfield(HOLD[1], :missing)
    catch e
        return e isa FieldError
    end
    return false
end
# the same, the tuple of a type not concrete
const HOLD_T = Tuple{Vararg{Int}}[()]
function fallback_name_t(n::Int)
    HOLD_T[1] = tuple(collect(1:n)...)
    try
        getfield(HOLD_T[1], :missing)
    catch e
        return e isa FieldError
    end
    return false
end
# a name of a field of a tuple of a type not concrete: a FieldError of the value's type
const TUPLES = Tuple{Vararg{Int}}[(1, 2, 3), (4, 5)]
function tuple_name(i::Int)
    try
        getfield(TUPLES[i], :missing)
    catch e
        return e isa FieldError && e.type === typeof(TUPLES[i])
    end
    return false
end
# a tuple of known length of an element type not concrete (`Type`): its fields by the value's
# type, at a constant index and at one known only at run time (as `print(io, xs...)` reads its
# arguments); out of bounds a BoundsError
const MIXED = Tuple{Type,String,Int}[(Int, "a", 1), (Vector{Float64}, "bcd", 2)]
mixed_const(i::Int) = (t = MIXED[i]; (getfield(t, 1) === Int, ncodeunits(getfield(t, 2)), getfield(t, 3)))
function mixed_at(i::Int, k::Int)
    v = getfield(MIXED[i], k)
    return v isa Type ? (v === Int ? 1 : 2) : v isa String ? 10 * ncodeunits(v) : 100 * (v::Int)
end
mixed_at_caught(i::Int, k::Int) =
    try
        mixed_at(i, k)
    catch e
        e isa BoundsError ? -1 : -2
    end
# of a tuple type with a parameter (a `UnionAll`), of two fields
const PAIRS = (Tuple{T,T} where T)[(1, 2), ("a", "bc")]
pair_at(i::Int, k::Int) = (v = getfield(PAIRS[i], k); v isa Int ? v : -ncodeunits(v::String))
# of a union of tuples (of different lengths): unsupported at an index known only at run time
const UNEQUAL = Union{Tuple{Int},Tuple{String,String}}[(1,), ("a", "bc")]
unequal_at(i::Int, k::Int) = getfield(UNEQUAL[i], k) isa String
# at an index not of type `Int` (natively a TypeError, or a FieldError for a name): unsupported
const INDICES = Any[1, :missing]
any_index_at(i::Int, j::Int) = getfield(MIXED[i], INDICES[j]) isa Int
# with an ordering (natively checked against the field's atomicity): unsupported
const ORDERS = [:not_atomic, :acquire]
ordered_at(i::Int, k::Int) = getfield(MIXED[i], k, ORDERS[i]) isa Int
# printed, a type among the values (`print` reads them at run-time indices of a tuple of type
# `Tuple{Type, String, Int64, Char}`)
mixed_string(i::Int) = hash(string(Box, "[", i, ']'))
# with a value of a type whose type object is not a ghost (`Core.TypeofBottom`)
const WITH_BOTTOM = Any[Union{}, (7,), Box(8)]
with_bottom(i::Int) = getfield(WITH_BOTTOM[i], 1)::Int
# of `Any`: a module (natively its global, by a name known only at run time, which a module
# cannot read: a trap there)
const MODS = Any[Base, Circle(1.0, "c")]
module_field(i::Int) = getfield(MODS[i], :name) isa String
# unsupported: with an ordering (natively checked against the field's atomicity); a field of
# a type object
ordered_field(i::Int) = getfield(SHAPES[i], :name, :acquire) isa String
const TYPES = Type[Int, String]
type_name(i::Int) = getfield(TYPES[i], :name) === Int.name
# of a constant module: its global
const_module_field(i::Int) = getfield(Base, :pi) * i

# a Dict of pairs of more types than inference keeps apart (the element of the pairs is the
# abstract `Pair{String}`), and of more than 31
function many_pairs(i::Int)
    p = ("a" => i, "b" => "x", "c" => 1.5, "d" => nothing, "e" => (i, i))
    d = Dict{String,Any}(p..., p..., p..., p..., p..., p..., p..., p...)
    return (length(d), d["a"]::Int, d["c"]::Float64, d["d"] === nothing, (d["e"]::Tuple{Int,Int})[2])
end

@testset "getfield of a value of a type not concrete" begin
    for i in 1:3
        @wtest shape_name(i)
        @wtest shape_side_caught(i)
    end
    @wtest shape_name_caught(4)
    for i in 1:4
        @wtest shape_first(i)
        @wtest box_kind(i)
    end
    @wtest shape_side(2)
    @wtest shape_side(1)   # (a FieldError, uncaught)
    for i in 1:5
        @wtest any_first(i)
        @wtest any_third_caught(i)
    end
    @wtest union_first(1)
    @wtest union_first(-1)
    @wtest many_pairs(7)
    @wtest tuple_name(1)
    @wtest tuple_name(2)
    for f in (fallback_first, fallback_zero, fallback_name, fallback_name_t)
        HOLD[1] = (); HOLD_T[1] = ()
        c = wcompile(f, (Int,))
        got = wasm_run(c, string(nameof(f)), 1000; rettype=Base.return_types(f, (Int,))[1])
        @test got === f(1000)
    end
    HOLD[1] = (); HOLD_T[1] = ()
    for i in 1:2
        @wtest mixed_const(i)
        @wtest mixed_string(i)
        for k in 0:4
            @wtest mixed_at_caught(i, k)
        end
        for k in 1:2
            @wtest pair_at(i, k)
        end
    end
    @wtest with_bottom(2)
    @wtest with_bottom(3)
    @wtest const_module_field(2)
    @wtest module_field(2)
    # (natively an UndefVarError; a module's field by a name known only at run time traps, as
    # for the runtime's other objects behind `Any`: DESIGN.md)
    @wtest module_field(1)
    for f in (ordered_field, type_name)
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, (Int,))
    end
    for f in (ordered_at, unequal_at, any_index_at)
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, (Int, Int))
    end
end

end
