# Elements at run-time indices of tuples of mixed types (`t[k]`, as `string` and `print` read
# their arguments), tested with `isa` and narrowed: no object for the union of the element
# types, also where a loop carries the element or an `if` merges it (`for x in t`). Results
# equal native, also where the element is used otherwise (boxed) or the index is out of bounds.

module SplitUnionTests

using Test
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen

# a String, compared by its length and bytes
digest(s::String) = (sizeof(s), foldl((h, b) -> 31h + b, codeunits(s); init=UInt64(7)))
kstr(i::Int) = digest(string("k", i % 1000))
# (at most four argument types: Julia 1.12 does not union-split `print` over more)
mixed_str(i::Int, x::Float64) = digest(string(i, "-", x, i % 3 == 0 ? 'c' : 'é'))
function mixed_sum(i::Int)
    t = (i, "abc", 2.5, nothing, Int32(i))
    s = 0.0
    for k in 1:length(t)
        x = t[k]
        if x isa Int
            s += 3x
        elseif x isa String
            s += sizeof(x)
        elseif x isa Float64
            s += x / 2
        elseif x isa Int32
            s -= x
        end
    end
    return s
end
# an index out of bounds: a BoundsError
function at_index(i::Int, k::Int)
    t = (i, "abc", 1.5)
    try
        x = t[k]
        return x isa Int ? x + 1 : x isa String ? sizeof(x) : 7
    catch e
        return e isa BoundsError && e.a === t && e.i === k ? -100 : -200
    end
end
# the selected member's own value, for each field of each kind of member
function payloads(i::Int, k::Int)
    t = (i % 2 == 0, Char(0x3b1 + i), Int8(-i), nothing, Int16(-300i), i, 2i, "é$i", Int32(i))
    x = t[k]
    x isa Bool && return 1000 + Int(x)
    x isa Char && return 2000 + Int(x)
    x isa Int8 && return 3000 + Int(x)
    x isa Nothing && return 4000
    x isa Int16 && return 5000 + Int(x)
    x isa Int && return 6000 + x
    x isa String && return 7000 + sizeof(x)
    return 8000 + Int(x::Int32)
end
# `isa` that the member type does not decide (of a type object): an object
const IntegerType = Type{<:Integer}
types_isa(k::Int) = (DataType[Int][1], 5)[k] isa IntegerType
# a field by its name at run time
by_name(i::Int, j::Int) = (x = getfield((a=i, b="xy"), (:a, :b, :c)[j]); x isa Int ? x : sizeof(x::String))
# the element read in a `catch` (an upsilon use): an object
function in_catch(i::Int, k::Int)
    t = (i, "abc")
    x = t[1]
    try
        x = t[k]
        x isa Int && k == 1 && throw(ArgumentError("one"))
        return x isa Int ? 0 : -1
    catch
        return x isa Int ? x : -2
    end
end
# the element also used as a value of the union: an object
const kept = Any[]
function escaping(i::Int, k::Int)
    empty!(kept)
    t = (i, "ab", 0.5)
    x = t[k]
    push!(kept, x)
    x isa Int && (i += x)
    return (i, kept[1] isa Int ? kept[1]::Int : kept[1] isa String ? sizeof(kept[1]::String) : -1)
end
# the same, through a narrowing to a smaller union
function escaping_narrowed(i::Int, k::Int)
    empty!(kept)
    x = (i, "ab", 0.5)[k]
    x isa Float64 && return -1
    push!(kept, x)
    return kept[1] isa Int ? kept[1]::Int : sizeof(kept[1]::String)
end
# the element through `iterate` (a φ of the union: a loop's carry)
function iterated_sum(i::Int)
    s = 0
    for x in (i, "abc", 'q')
        s += x isa Int ? x : x isa String ? sizeof(x) : Int(x)
    end
    return s
end
# in a loop of a loop
function nested_iter(n::Int)
    s = 0
    for i in 1:n
        for x in (i, "abc")
            s += x isa Int ? x : sizeof(x)
        end
    end
    return s
end
# carried members of each kind (no value, floats, small integers, strings)
function iterated_kinds(i::Int)
    s = 0.0
    for x in (nothing, 2.5 + i, Int32(i), nothing)
        s = 3s + (x isa Nothing ? 1 : x isa Float64 ? x : Int(x))
    end
    for x in (i % 2 == 0, "é$i", Int8(-i))
        s = 3s + (x isa Bool ? 10 + x : x isa String ? sizeof(x) : Int(x))
    end
    return s
end
# values of the member types merged by an `if`
function merged(i::Int)
    x = i % 3 == 0 ? i : i % 3 == 1 ? "abc" : 'q'
    return x isa Int ? x + 1 : x isa String ? sizeof(x) : Int(x)
end
# the element a loop leaves with (its result), from a value of a member type
function found_after(i::Int, k::Int)
    t = (i, "abc", 'q')
    y = t[1]
    for j in 1:3
        y = t[j]
        j == k && break
    end
    return y isa Int ? y : y isa String ? sizeof(y) : Int(y)
end
# carries assigned from one another (each read before either is assigned)
function rotated(i::Int, n::Int)
    t = (i, "abc", 'q')
    a, b = t[mod1(n, 3)], t[mod1(n + 1, 3)]
    for _ in 1:n
        a, b = b, a
    end
    return (a isa Int ? a : a isa String ? sizeof(a) : Int(a)) * 1000 +
           (b isa Int ? b : b isa String ? sizeof(b) : Int(b))
end
# a narrowing to a smaller union into a carry
function last_non_char(i::Int)
    y = (i, "s")[1 + (i & 1)]
    for x in (i, "abc", 'q', "de")
        x isa Char && continue
        y = x
        i > 5 && x isa Int && break
    end
    return y isa Int ? y : sizeof(y)
end
# a carry tested by its loop's condition
function until_char(i::Int, n::Int)
    t = (i, "abc", 'q')
    x = t[1 + (i & 1)]
    k = 1
    while !(x isa Char) && k < n
        k += 1
        x = t[mod1(k + i, 3)]
    end
    return (x isa Int ? x : x isa String ? sizeof(x) : Int(x)) + 1000k
end
# a carry also assigned a value of a union (not an element): an object
@noinline some_int(i::Int) = i > 3 ? i : nothing
function from_union(i::Int)
    y = some_int(i)
    for x in (i, "abc")
        (i + (x isa Int)) % 2 == 0 && (y = x)
    end
    return y isa Int ? y : y isa String ? sizeof(y) : -1
end
# a carried element also used as a value of the union: an object
function iterated_escaping(i::Int)
    empty!(kept)
    s = 0
    for x in (i, "ab")
        push!(kept, x)
        s += x isa Int ? x : sizeof(x)
    end
    return s + length(kept) + (kept[1] isa Int ? kept[1]::Int : 0)
end

# whether a function compiled for one of `names` boxes a value of type `T` (calls its helper)
function emits_box(c, names, @nospecialize(T))
    box = get(c.cgm.helpers, (:box, T), nothing)
    box === nothing && return false
    infos = [info for (mi, info) in c.cgm.funcs if mi.def isa Method && mi.def.name in names]
    isempty(infos) && error("no function compiled for ", names)
    return any(info -> any(i -> i.op === :call && i.imm[1] === box, info.func.body), infos)
end

@testset "split unions" begin
    for i in (0, 7, -12, 123456789)
        @wtest kstr(i)
        @wtest mixed_str(i, 0.25)
        @wtest mixed_sum(i)
        @wtest iterated_sum(i)
        @wtest nested_iter(i % 50)
        @wtest iterated_kinds(i)
        @wtest merged(i)
        @wtest merged(i + 1)
        @wtest merged(i + 2)
        @wtest last_non_char(i)
        @wtest last_non_char(i + 1)
        @wtest iterated_escaping(i)
    end
    for k in 0:4
        @wtest found_after(8, k)
        @wtest rotated(8, k)
        @wtest until_char(8, k)
        @wtest until_char(7, k)
        @wtest from_union(k + 2)
    end
    for k in (-1, 0, 1, 2, 3, 4, typemin(Int), typemax(Int))
        @wtest at_index(5, k)
    end
    for i in (1, 6), k in 1:9
        @wtest payloads(i, k)
    end
    for k in 1:2
        @wtest types_isa(k)
    end
    @wtest in_catch(4, 1)
    for j in 1:3
        @wtest by_name(3, j)
    end
    for k in 1:3
        @wtest escaping(4, k)
        @wtest escaping_narrowed(4, k)
    end
    # (Julia 1.12's `print_to_string` carries the element through a φ)
    @test !emits_box(wcompile(kstr, (Int,)), (:kstr, :print_to_string), Int)
    @test !emits_box(wcompile(mixed_sum, (Int,)), (:mixed_sum,), Int)
    @test !emits_box(wcompile(payloads, (Int, Int)), (:payloads,), Int)
    @test emits_box(wcompile(escaping, (Int, Int)), (:escaping,), Int)
    @test emits_box(wcompile(escaping_narrowed, (Int, Int)), (:escaping_narrowed,), Int)
    @test emits_box(wcompile(in_catch, (Int, Int)), (:in_catch,), Int)
    # carried by a loop, merged by an `if`
    for (f, at) in ((iterated_sum, (Int,)), (nested_iter, (Int,)), (merged, (Int,)), (found_after, (Int, Int)),
                    (rotated, (Int, Int)), (last_non_char, (Int,)), (until_char, (Int, Int)))
        @test !emits_box(wcompile(f, at), (nameof(f),), Int)
    end
    @test !emits_box(wcompile(iterated_kinds, (Int,)), (:iterated_kinds,), Float64)
    @test emits_box(wcompile(iterated_escaping, (Int,)), (:iterated_escaping,), Int)
end

end
