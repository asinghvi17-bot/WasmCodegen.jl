# `===` and `objectid` of values whose types are known only at run time (`jl_egal`,
# `jl_object_id`): a case function per type, called through a table by type id. Numbers by
# their bits (NaNs of different payloads, -0.0), strings and symbols by their bytes, mutable
# objects by identity, immutable ones by their fields (references, unions, nested tuples),
# type objects; and more types than a part of the table holds, so ids in later parts are read.

mutable struct TDMut
    x::Int
end
struct TDImm
    a::Int
    b::Any
end
struct TDUnion
    x::Union{Int,String,Nothing}
end

const TD_NAN2 = reinterpret(Float64, 0x7ff8000000000001)
const TD_MUT = TDMut(1)
const TD_VALS = Any[
    NaN, -NaN, TD_NAN2, NaN32, 0.0, -0.0, 0.0f0, -0.0f0, 1, 1.0, Int32(1), UInt8(1), 'a',
    "ab", "a" * "b", :ab, Symbol("a", "b"), (1, "ab"), (1, "a" * "b"), (1, 2.0), (1, (2, "x")),
    TD_MUT, TDMut(1), TD_MUT, [1], [1], Ref(1), TDImm(1, "x"), TDImm(1, "x" * ""), TDImm(1, TD_MUT),
    TDImm(1, TDMut(1)), TDImm(1, NaN), TDImm(1, -NaN), TDUnion(1), TDUnion("ab"), TDUnion("a" * "b"),
    TDUnion(nothing), Some(1), Some(nothing), nothing, missing, Int, Vector{Int}, Union{Int,String},
    (a = 1, b = "x"), (a = 1, b = "x" * ""), 1 // 2, 2 // 4, Val(3), Val(3), Core.svec(1, "a"),
    Core.svec(1, "a" * ""),
]

# a row of `===` with every value, as bits
function td_egal_row(i::Int)
    acc = UInt64(0)
    for j in eachindex(TD_VALS)
        acc = acc << 1 | UInt64(TD_VALS[i] === TD_VALS[j])
    end
    return acc
end

# objectid of an immutable value is computed from its contents, as natively
td_objectid(i::Int) = objectid(TD_VALS[i])
# of a mutable one: its own, the same each time and not another's
function td_objectid_mutable(i::Int, j::Int)
    a, b = TD_VALS[i], TD_VALS[j]
    return (objectid(a) == objectid(a), objectid(a) == objectid(b), a === b)
end

# values made at run time, compared with the image's and with each other
function td_runtime(k::Int)
    xs = Any[(k, string(k)), (k, string(k)), TDImm(k, string(k)), TDImm(k, string(k)),
             TDUnion(string(k)), TDUnion(k), Float64(k) * -0.0, Float64(k) * 0.0, TDMut(k)]
    acc = UInt64(0)
    for a in xs, b in xs
        acc = acc << 1 | UInt64(a === b)
    end
    return (acc, objectid(xs[1]) == objectid(xs[2]), objectid(xs[3]) == objectid(xs[4]),
            xs[1] === (1, "1"), TD_VALS[34] === xs[6])
end

# more types than a part of the table (`TYPE_TABLE_PART`): a tuple type per value, each with
# its case, whose ids are spread over several parts
const TD_MANY = Any[(Val{i}(), i, isodd(i) ? "o" : nothing) for i in 1:600]
# (the same values as other objects: `===` of two objects of one type, by its case)
const TD_MANY2 = Any[(Val{i}(), i, isodd(i) ? "o" * "" : nothing) for i in 1:600]
function td_many(i::Int, j::Int, step::Int)
    a, b = TD_MANY[i], TD_MANY[j]
    acc = UInt(0)
    for k in 1:step:length(TD_MANY)
        x = TD_MANY[k]
        acc = acc * 0x1f + objectid(x) + UInt(x === TD_MANY[k]) + UInt(x === TD_MANY[mod1(k + 1, end)]) +
              2 * UInt(x === TD_MANY2[k]) + 4 * UInt(objectid(x) == objectid(TD_MANY2[k]))
    end
    return (a === b, a === TD_MANY[i], a === TD_MANY2[i], b === TD_MANY2[i], objectid(a), objectid(a) == objectid(b), acc)
end

@testset "type dispatch" begin
    for i in eachindex(TD_VALS)
        @wtest td_egal_row(i)
    end
    for i in eachindex(TD_VALS)
        T = typeof(TD_VALS[i])
        if !ismutabletype(T)
            @wtest td_objectid(i)
        end
    end
    @wtest td_objectid_mutable(22, 22)
    @wtest td_objectid_mutable(22, 23)
    @wtest td_objectid_mutable(22, 24)
    @wtest td_objectid_mutable(25, 26)
    @wtest td_runtime(1)
    @wtest td_runtime(7)
    @wtest td_many(1, 1, 1)
    @wtest td_many(1, 2, 7)
    @wtest td_many(300, 300, 600)
    @wtest td_many(513, 513, 600)
    @wtest td_many(600, 599, 600)
end
