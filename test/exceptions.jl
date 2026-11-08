# try/catch: Julia's exceptions on Wasm's (see src/exceptions.jl)

struct CodedError <: Exception
    code::Int
end

function catch_div(a::Int, b::Int)
    try
        return div(a, b)
    catch
        return -999
    end
end
function catch_bounds(i::Int)
    v = [1, 2, 3]
    try
        v[i]
    catch e
        e isa BoundsError ? -1 : -2
    end
end
function catch_memory_bounds(i::Int)
    m = Memory{Int}(undef, 3)
    fill!(m, 4)
    try
        m[i]
    catch e
        e isa BoundsError ? -1 : -2
    end
end
function catch_finally(i::Int)
    r = Ref(0)
    try
        try
            i > 2 && error("big")
            r[] += 1
        finally
            r[] += 10
        end
    catch
        r[] += 100
    end
    r[]
end
function catch_parse(i::Int)
    s = ("12", "-7", "x", "")[i]
    try
        parse(Int, s)
    catch e
        e isa ArgumentError ? -1 : -2
    end
end
function catch_rethrow(i::Int)
    try
        try
            i > 1 && throw(DomainError(i))
            0
        catch
            rethrow()
        end
    catch e
        e isa DomainError ? (e.val::Int) * 10 : -1
    end
end
function catch_custom(i::Int)
    s = 0
    for k in 1:i
        try
            k % 3 == 0 && throw(CodedError(k))
            s += k
        catch e
            s -= (e::CodedError).code
        end
    end
    s
end
function catch_message(i::Int)
    try
        i > 0 && error("bad ", i)
        0
    catch e
        ncodeunits((e::ErrorException).msg::String)
    end
end
function catch_typeassert(i::Int)
    x = Any[1, "s", 2.5][i]
    try
        (x::Int) + 1
    catch e
        e isa TypeError ? -1 : -2
    end
end
function catch_overflow(i::Int)
    try
        Base.checked_add(typemax(Int) - 1, i)
    catch e
        e isa OverflowError ? -1 : -2
    end
end
function catch_inexact(i::Int)
    try
        Int(Int8(i * 50))
    catch e
        e isa InexactError ? -1 : -2
    end
end
function return_finally(i::Int, r::Base.RefValue{Int})
    try
        i > 1 && return 100
        r[] += 1
    finally
        r[] += 10
    end
    return r[]
end
return_through_finally(i::Int) = (r = Ref(0); return_finally(i, r) + 1000 * r[])
function catch_nested(i::Int)
    acc = 0
    try
        try
            i == 1 && throw(CodedError(1))
            acc += 1
        catch
            acc += 10
            i == 1 && rethrow()
        end
        i == 2 && throw(CodedError(2))
    catch e
        acc += (e::CodedError).code * 100
    end
    acc
end
# an exception nothing catches
uncaught(i::Int) = i > 0 ? throw(CodedError(i)) : (try i catch; -1 end)

# a local assigned in a `try` and used after it: its handler argument is undefined on the
# path where the `try` ran no assignment (typed `Union{}` when nothing but the undefined
# value and an `Int` reach it)
@noinline try_step(n::Int) = n > 100 ? throw(ArgumentError("big")) : n + 1
function try_local1(n::Int)   # the catch returns
    local x
    try
        x = try_step(n)
    catch
        return -1
    end
    return x
end
function try_local2(n::Int)   # assigned before the try
    x = 0
    ok = true
    try
        x = try_step(n)
    catch
        ok = false
    end
    return ok ? x : -1
end
function try_local3(n::Int)   # assigned in both branches
    local x
    try
        x = try_step(n)
    catch
        x = -1
    end
    return x
end
function try_local4(n::Int)   # the catch falls through
    local x
    ok = true
    try
        x = try_step(n)
    catch
        ok = false
    end
    return ok ? x : -1
end
function try_local_map(n::Int)
    local x
    ok = true
    try
        x = map(try_step, (n, n + 1))
    catch
        ok = false
    end
    return ok ? x[1] + x[2] : -1
end
function try_local_nested(n::Int)
    local x, z
    ok = true
    ok2 = true
    try
        try
            x = try_step(n)
        catch
            ok = false
        end
        z = try_step(n * 2)
    catch
        ok2 = false
    end
    return (ok ? x : -1) + (ok2 ? z : -10)
end
function try_local_read_in_catch(n::Int)   # the handler argument read in the catch
    y = n
    try
        y = try_step(y)
        y = try_step(y * 50)
    catch
        return y * 1000
    end
    return y
end

@testset "exceptions" begin
    for b in -1:1
        @wtest catch_div(7, b)
    end
    @wtest catch_div(typemin(Int), -1)
    for i in 0:4
        @wtest catch_bounds(i)
        @wtest catch_memory_bounds(i)
        @wtest catch_finally(i)
        @wtest catch_custom(i + 3)
        @wtest catch_inexact(i)
        @wtest return_through_finally(i)
    end
    for i in 1:4
        @wtest catch_parse(i)
    end
    for i in 0:3
        @wtest catch_rethrow(i)
        @wtest catch_message(i)
        @wtest catch_nested(i)
    end
    for i in 1:3
        @wtest catch_typeassert(i)
    end
    for i in 0:2
        @wtest catch_overflow(i)
    end
    @wtest uncaught(0)
    @wtest uncaught(1)
    # a local assigned in a `try`, used after it
    for n in (3, 60, 300)
        @wtest try_local1(n)
        @wtest try_local2(n)
        @wtest try_local3(n)
        @wtest try_local4(n)
        @wtest try_local_map(n)
        @wtest try_local_read_in_catch(n)
    end
    for n in (3, 60, 99, 300)
        @wtest try_local_nested(n)
    end
    # what a program needs of exceptions decides how they are compiled
    @test wcompile(catch_div, (Int, Int)).cgm.exceptions === :control
    @test wcompile(catch_message, (Int,)).cgm.exceptions === :values
end
