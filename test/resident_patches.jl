# `install_trim_patches!`: the patches installed once, for the process's life. A compilation
# after it defines no method, and compiles the module a session of its own compiles; the
# process itself keeps Base's printing, package loading and `invokelatest`. (In a worker of its
# own: the installation is not undone.)

module ResidentTarget
struct Point
    x::Float64
    y::Float64
end
norm2(p::Point) = sqrt(p.x^2 + p.y^2)
digest(s::String) = (sizeof(s), hash(s))
described(n::Int) = digest(string("n = ", n, ", ", norm2(Point(n, 2n)), ", ", [n, n + 1]))
type_named(n::Int) = digest(string(n > 0 ? Int : Float64, " ", Vector{Pair{Base.PkgId,Int}}))
@enum Fruit apple banana
fruit_named(n::Int) = digest(string(n == 1 ? apple : banana))
bottom_named(n::Int) = digest(string(n > 0 ? Union{} : Int))
@enum Shade light dark
@noinline Base.show(io::IO, s::Shade) = print(io, s === light ? "a light shade" : "a dark shade")
shade_shown(n::Int) = digest(sprint(show, n == 1 ? light : dark))
shade_invoked(n::Int) = digest(sprint((io, s) -> invoke(show, Tuple{IO,Shade}, io, s), n == 1 ? light : dark))
@enum Tone high low
Base.show(io::IO, t::Tone) = (print(io, t === high ? "high" : "low"); 17)
tone_returned(n::Int) = show(IOBuffer(), n == 1 ? high : low)
latest_target(x::Int) = 2x + 1
kw_target(x::Int; k::Int=0) = 10x + k
latest_called(n::Int) = Base.@invokelatest(latest_target(n)) + Base.invokelatest(latest_target, n)
latest_splat(n::Int) = Base.invokelatest(latest_target, ntuple(_ -> n, Val(1))...)
latest_kw(n::Int) = Base.invokelatest(kw_target, n; k=3) + Base.@invokelatest(kw_target(n; k=4))
latest_nested(n::Int) = Base.invokelatest(Base.invokelatest, latest_target, n)
const SINK = Ref{Any}(1)
dynamic(n::Int) = SINK[] + n
# a method of the program's more specific than the one a patch replaces (`show(::IO, ::Enum)`),
# by Julia's specificity though not by subtyping (varargs)
@enum Mood calm
Base.show(io::IO, xs::Mood...) = 17
mood_shown(n::Int) = show(IOBuffer(), calm) === 17 ? n : -n
# a call ambiguous between a method of the program's and the one a patch replaces: natively
# a MethodError (here, a call the module does not compile, as in a session)
@enum Hue red
struct HueSink <: IO end
Base.show(::HueSink, x) = nothing
hue_ambiguous(n::Int) = try
        show(HueSink(), red)
        n
    catch e
        e isa MethodError ? 2n : 3n
    end
# `Base.invokelatest` as a value, one of the callees of a call
latest_helper(f, x) = f(x) + 1
latest_union(n::Int) = (n > 0 ? Base.invokelatest : latest_helper)(latest_target, n) +
                       (n < 0 ? Base.invokelatest : latest_helper)(latest_target, n)
# the builtin as the value of other bindings, which the patches do not rebind (only
# `Base.invokelatest`): one object; and `Core.invokelatest` called, the builtin, as in a session
const SAVED_LATEST = Core.invokelatest
const BOXED_LATEST = (Core.invokelatest,)
latest_alias(n::Int) = SAVED_LATEST === BOXED_LATEST[1] ? n : -n
core_latest(n::Int) = Core.invokelatest(latest_target, n)
# the binding imported (renamed, and by `using`): `Base.invokelatest`'s, which the patches
# rebind; a module's own binding of the builtin of that name is another
module Imported
using Base: invokelatest
import Base: invokelatest as il
using ..ResidentTarget: latest_target
latest_imported(n::Int) = invokelatest(latest_target, n) + il(latest_target, n)
end
latest_imported(n::Int) = Imported.latest_imported(n)
module OwnLatest
const invokelatest = Core.invokelatest
own_latest(n::Int) = invokelatest === Core.invokelatest ? n : -n
end
own_latest(n::Int) = OwnLatest.own_latest(n)
end

session_worlds(compiler_world, program_world) = (compiler_world, program_world)

# the sections of a module: id => contents, in order
function wasm_sections(bytes::Vector{UInt8})
    sections = Pair{UInt8,Vector{UInt8}}[]
    i = 9
    while i <= length(bytes)
        id = bytes[i]
        i += 1
        n, shift = 0, 0
        while true
            b = bytes[i]
            i += 1
            n |= Int(b & 0x7f) << shift
            shift += 7
            b < 0x80 && break
        end
        push!(sections, id => bytes[i:i+n-1])
        i += n
    end
    return sections
end

@testset "resident trim patches" begin
    T = WasmCodegen.Runtime
    R = ResidentTarget
    programs = [(R.described, 3, Tuple{Int,UInt}), (R.type_named, 1, Tuple{Int,UInt}),
                (R.fruit_named, 2, Tuple{Int,UInt}), (R.bottom_named, 1, Tuple{Int,UInt}),
                (R.shade_shown, 1, Tuple{Int,UInt}), (R.shade_invoked, 2, Tuple{Int,UInt}),
                (R.tone_returned, 1, Int), (R.latest_called, 4, Int), (R.latest_splat, 4, Int),
                (R.latest_kw, 4, Int), (R.latest_nested, 4, Int), (R.mood_shown, 2, Int),
                (R.hue_ambiguous, 1, Int), (R.latest_union, 4, Int), (R.latest_alias, 2, Int),
                (R.core_latest, 4, Int), (R.latest_imported, 4, Int), (R.own_latest, 3, Int),
                (R.dynamic, 5, Int)]
    config = test_config(trim=:unsafe)
    compiled(f) = WasmCodegen.compile(f, (Int,); config)
    diagnostics(c) = [(sprint(show, mi), sprint(showerror, e)) for (mi, e) in c.cgm.diagnostics]
    result(c, f, n, rettype) = wasm_run(c, string(nameof(f)), n; rettype)
    # (Base's, before the installation)
    pkg = Base.PkgId(Base.UUID("a6a1e1a2-3b4c-4d5e-8f90-0a1b2c3d4e5f"), "ResidentProbe")
    listed = mktempdir()
    foreach(name -> touch(joinpath(listed, name)), ("b.jl", "a.txt", "é"))
    natively() = [repr(pkg => "path"), repr([pkg]), sprint(show, Vector{Pair{Base.PkgId,Int}}), repr(R.apple),
                  sprint(show, R.norm2), sprint(show, Base.Order.Forward), Base.active_project(), pwd(), readdir(listed)]
    native = natively()
    # each in a session of its own
    stock = [compiled(f) for (f, _, _) in programs]
    # the methods defined since world `w`
    defined_since(w) = (ms = Method[]; Base.visit(m -> m.primary_world > w && push!(ms, m), Core.methodtable); ms)

    w0 = Base.get_world_counter()
    @test WasmCodegen.install_trim_patches!() === nothing
    w1 = Base.get_world_counter()
    @test w1 > w0 && T.PRE_PATCH_WORLD[] == w0

    @testset "installing again" begin
        w = Base.get_world_counter()
        @test WasmCodegen.install_trim_patches!() === nothing
        @test isempty(defined_since(w))
        # (other patches, or the tasks', are another session)
        extra = joinpath(@__DIR__, "patches", "greeting.jl")
        @test_throws ErrorException WasmCodegen.install_trim_patches!(patches=[WasmCodegen.TRIM_PATCHES; extra])
        @test_throws ErrorException WasmCodegen.install_trim_patches!(patches=[WasmCodegen.TRIM_PATCHES; WasmCodegen.TASK_PATCHES])
        @test_throws ErrorException WasmCodegen.with_trim_patches(() -> nothing; patches=[extra])
        w = Base.get_world_counter()
        @test WasmCodegen.with_trim_patches(session_worlds) == (WasmCodegen.COMPILER_WORLD[], w)
        @test isempty(defined_since(w))
    end

    @testset "compilations: no new world, the same module" begin
        for ((f, n, rettype), s) in zip(programs, stock)
            w = Base.get_world_counter()
            c = compiled(f)
            @test isempty(defined_since(w))
            cs, ss = wasm_sections(c.bytes), wasm_sections(s.bytes)
            @test first.(cs) == first.(ss)
            # (the code, types, imports and exports; data and globals hold addresses and unused
            # capacity of the build process's objects)
            for id in (0x01, 0x02, 0x03, 0x07, 0x0a)
                @test filter(p -> p.first == id, cs) == filter(p -> p.first == id, ss)
            end
            @test diagnostics(c) == diagnostics(s)
            @test result(c, f, n, rettype) == result(s, f, n, rettype)
        end
        @test !isempty(diagnostics(stock[end]))
        # (and what native Julia computes, but for the names of types and enums, which juliac's
        # patches print their own way)
        for ((f, n, rettype), s) in zip(programs, stock)
            f in (R.type_named, R.fruit_named, R.bottom_named, R.hue_ambiguous, R.core_latest, R.dynamic) && continue
            @test result(s, f, n, rettype) == f(n)
        end
        # (the ambiguity, as natively with the method the patch replaces: no method matches)
        sig = Tuple{typeof(show), R.HueSink, R.Hue}
        w = Base.get_world_counter()
        found = Core.Compiler.findall(sig, WasmCodegen.WasmMethodTable(w))
        @test isempty(Base._methods_by_ftype(sig, -1, w)) && found !== nothing && isempty(found.matches)
        @test (try show(R.HueSink(), R.red); 1 catch e; e isa MethodError ? 2 : 3 end) == 2
    end

    @testset "the process keeps Base's behavior" begin
        @test natively() == native
        # (the method a runtime function calls natively: the one before the installation)
        @test T.original(pwd) == pwd() == native[8]
        @test Base.invoke_in_world(w0, which, pwd, Tuple{}).module === Base.Filesystem
        @test which(pwd, Tuple{}).primary_world > w0
        @test Base.invokelatest(Base.PCRE.get_local_match_context) != C_NULL && occursin(r"a+b", "caab")
        # (a module's initializer, which a system image calls at startup, still has its method:
        # also one a session left without it)
        for M in Base.loaded_modules_array()
            isdefined(M, :__init__) || continue
            init = Base.invokelatest(getglobal, M, :__init__)
            init isa Function && @test Base.invokelatest(hasmethod, init, Tuple{})
        end
    end

    @testset "invokelatest of methods defined after the installation" begin
        Core.eval(R, :(defined_later(x::Int) = 10x))
        @test Base.@invokelatest(R.defined_later(4)) == 40
        @test Base.invokelatest(getglobal(R, :defined_later), 5) == 50
        Core.eval(R, :(latest_target(x::Int) = 3x))
        @test Base.@invokelatest(R.latest_target(2)) == 6
    end

    # (the patches as a new process installs them: where a function an overlay attaches to is
    # not native, not left behind by a session that deleted its method)
    @testset "installing in a new process" begin
        # (again with the same bindings, by identity: a NaN is one)
        code = "using WasmCodegen; install_trim_patches!(bindings=Pair{Symbol,Any}[:s => NaN]); " *
               "install_trim_patches!(bindings=Pair{Symbol,Any}[:s => NaN]); " *
               "print(repr(Base.PkgId(Base.UUID(1), \"X\") => 1), ' ', sprint(show, Vector{Union{}}))"
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
        @test read(cmd, String) == string(repr(Base.PkgId(Base.UUID(1), "X") => 1), ' ', sprint(show, Vector{Union{}}))
    end

    # (overlays that replace no native method, patches of other signatures, in a process of its
    # own: looked up as Julia's lookup does with them defined, compared with the same methods
    # defined natively (`Native1`, `Native2`), and with a session's module)
    @testset "overlays of other signatures" begin
        mktempdir() do dir
            patch = joinpath(dir, "added.jl")
            write(patch, "Target1.wait_forever(x::Int, y) = 10\nTarget2.wait_forever(x, y::Number) = 2\n" *
                         "Target3.wait_forever(x, y::Number) = 2\n" *
                         "Target4.wait_forever(x::T, y::S) where {S<:AbstractString,T<:Number} = T === Int ? 11 : 22\n" *
                         "Target4.wait_forever(x::Number, y) = 33\nTarget5.wait_forever(x::Number) = 3\n")
            script = joinpath(dir, "added_run.jl")
            write(script, """
                include($(repr(joinpath(@__DIR__, "harness.jl"))))
                const CC = Core.Compiler
                # the native methods, and the patch's: in the session, a method of another signature
                # (Target3: two methods ambiguous over `(Number, Number)`, but of `(Int, Int)` a third;
                # Target4: the patch also replaces a method, with its static parameters in another order)
                common = [:(wait_forever(x, y::Int) = 20), :(wait_forever(x::Number, y::String) = 1),
                          :(wait_forever(x::Int, y::Int) = 3)]
                for (T, N, defs, patched) in ((:Target1, :Native1, common, [:(wait_forever(x::Int, y) = 10)]),
                                              (:Target2, :Native2, common, [:(wait_forever(x, y::Number) = 2)]),
                                              (:Target3, :Native3, [:(wait_forever(x::Number, y) = 1), :(wait_forever(x::Int, y::Int) = 3)],
                                               [:(wait_forever(x, y::Number) = 2)]),
                                              (:Target4, :Native4,
                                               [:(wait_forever(x::T, y::S) where {T<:Number,S<:AbstractString} = T === Int ? 11 : 22)],
                                               [:(wait_forever(x::T, y::S) where {S<:AbstractString,T<:Number} = T === Int ? 11 : 22),
                                                :(wait_forever(x::Number, y) = 33)]))
                    @eval module \$T end
                    @eval module \$N end
                    for M in (getglobal(Main, T), getglobal(Main, N)), def in defs
                        Core.eval(M, def)
                    end
                    foreach(def -> Core.eval(getglobal(Main, N), def), patched)
                end
                # (and a method defined after the installation: a world before it has not got it)
                module Target5
                wait_forever(x::Integer) = 1
                end
                Target5_latest(n::Int) = Target5.wait_forever(n)
                mutable struct Box
                    x::Number
                end
                mutable struct IntegerBox
                    x::Integer
                end
                mutable struct TextBox
                    s::AbstractString
                end
                # (a call's value, or -1 for a MethodError: none, or an ambiguous one)
                caught(f) = try f() catch e; e isa MethodError ? -1 : -2 end
                targets, references = (:Target1, :Target2, :Target3, :Target4), (:Native1, :Native2, :Native3, :Native4)
                for M in (targets..., references...)
                    @eval begin
                        @noinline \$(Symbol(M, :_dispatch))(a::Box, b::Box) = \$M.wait_forever(a.x, b.x)
                        \$(Symbol(M, :_boxed))(n::Int) = caught(() -> \$(Symbol(M, :_dispatch))(Box(n), Box(n)))
                        \$(Symbol(M, :_mixed))(n::Int) = caught(() -> \$M.wait_forever(n, "s")) + 100 * caught(() -> \$M.wait_forever(1.5, n))
                        \$(Symbol(M, :_called))(n::Int) = caught(() -> \$M.wait_forever(n, 2.5))
                        \$(Symbol(M, :_invoked))(n::Int) = caught(() -> invoke(\$M.wait_forever, Tuple{Int,Int}, n, n))
                        @noinline \$(Symbol(M, :_typed))(a::IntegerBox) = \$M.wait_forever(a.x, "s")
                        \$(Symbol(M, :_param))(n::Int) = caught(() -> \$(Symbol(M, :_typed))(IntegerBox(n)))
                        @noinline \$(Symbol(M, :_text))(n::Int, a::TextBox) = \$M.wait_forever(n, a.s)
                        \$(Symbol(M, :_static))(n::Int) = caught(() -> \$(Symbol(M, :_text))(n, TextBox("s")))
                    end
                end
                const BINDINGS = Pair{Symbol,Any}[:Target1 => Target1, :Target2 => Target2, :Target3 => Target3,
                                                  :Target4 => Target4, :Target5 => Target5]
                config = test_config(trim=:unsafe, extra_patches=[$(repr(patch))], patch_bindings=BINDINGS)
                programs = (:_boxed, :_mixed, :_called, :_invoked, :_param, :_static)
                fs = [getglobal(Main, Symbol(T, s)) for T in targets for s in programs]
                natives = [getglobal(Main, Symbol(N, s))(3) for N in references for s in programs]
                run(f; world...) = (c = WasmCodegen.compile(f, (Int,); config, world...);
                          (wasm_run(c, string(nameof(f)), 3; rettype=Int), length(c.cgm.diagnostics)))
                stock = map(run, fs)
                install_trim_patches!(patches=[WasmCodegen.TRIM_PATCHES; $(repr(patch))], bindings=BINDINGS)
                resident = map(run, fs)
                # the lookups, as of the methods defined natively: the matches (by their signatures but
                # the function, and their static parameters: as a set, since the order of methods ambiguous
                # with one another is the table's, and in an order of specificity), whether ambiguous, and
                # `invoke`'s
                w = Base.get_world_counter()
                table = WasmCodegen.WasmMethodTable(w)
                tail(m) = string(Base.unwrap_unionall(m.method.sig).parameters[2:end], m.sparams)
                lookups = Bool[]
                for (T, N) in ((Target1, Native1), (Target2, Native2), (Target3, Native3), (Target4, Native4)), args in
                        ((Number, Number), (Int, Int), (Float64, Float64), (Int, Float64), (Float64, Int),
                         (Any, Number), (Int, Any), (Any, Any), (Int, String), (Integer, Integer), (Number, String))
                    r = CC.findall(Tuple{typeof(T.wait_forever), args...}, table)
                    n = CC._findall(Tuple{typeof(N.wait_forever), args...}, nothing, w, -1)
                    ordered = r !== nothing && all(((i, j),) -> !Base.morespecific(r.matches[j].method, r.matches[i].method),
                                                   [(i, j) for i in eachindex(r.matches) for j in i+1:length(r.matches)])
                    push!(lookups, ordered && n !== nothing && sort(map(tail, r.matches)) == sort(map(tail, n.matches)) &&
                                   r.ambig == n.ambig)
                    rs, _ = CC.findsup(Tuple{typeof(T.wait_forever), args...}, table)
                    ns, _ = CC._findsup(Tuple{typeof(N.wait_forever), args...}, nothing, w)
                    push!(lookups, (rs === nothing) == (ns === nothing) && (rs === nothing || tail(rs) == tail(ns)))
                end
                # a method defined since, in the latest world and in the one before it, and natively
                wold = Base.get_world_counter()
                @eval Target5 wait_forever(x::Int) = 2
                worlds = (run(Target5_latest)[1], run(Target5_latest; world=wold)[1],
                          Base.invokelatest(Target5_latest, 3), Base.invoke_in_world(wold, Target5_latest, 3))
                print(repr((stock, resident, natives, lookups, worlds)))
                """)
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`
            stock, resident, natives, lookups, worlds = eval(Meta.parse(read(cmd, String)))
            @test resident == stock
            @test all(lookups)
            # (and natively with the methods defined, where a session's module computes it: not a
            # dynamic call, nor `invoke` of an ambiguous one)
            for (k, (r, d)) in enumerate(stock)
                d == 0 && @test resident[k][1] == natives[k]
            end
            @test count(((_, d),) -> d == 0, stock) >= 18
            # (the call of two methods ambiguous over its types, of another more specific of its values)
            @test resident[13][1] == natives[13] == 3
            # (the static parameters of a method the patch replaces, declared in another order: of a
            # call of an abstract argument type; of one by dispatch, which a session's module does not
            # compile either, natively 11)
            @test resident[24][1] == natives[24] == 11
            @test resident[23] == stock[23] && natives[23] == 11
            # (the methods of the world compiled: one defined since only in the latest)
            @test worlds == (2, 1, 2, 1)
        end
    end

    @testset "precompiling a package" begin
        mktempdir() do dir
            pkgdir = joinpath(dir, "ResidentProbe")
            mkpath(joinpath(pkgdir, "src"))
            write(joinpath(pkgdir, "Project.toml"), "name = \"ResidentProbe\"\nuuid = \"$(pkg.uuid)\"\n")
            write(joinpath(pkgdir, "src", "ResidentProbe.jl"),
                  "module ResidentProbe\n@enum Shade light dark\nprobe() = (Shade, Pair{Base.PkgId,Int})\nend\n")
            depot = joinpath(dir, "depot")
            pushfirst!(LOAD_PATH, dir)
            pushfirst!(DEPOT_PATH, depot)
            try
                cache = Base.compilecache(pkg)
                @test (cache isa Tuple ? cache[1] : cache) isa String
                M = Base.require(pkg)
                @test Base.invokelatest(getglobal(M, :probe)) == (getglobal(M, :Shade), Pair{Base.PkgId,Int})
            finally
                popfirst!(LOAD_PATH)
                popfirst!(DEPOT_PATH)
            end
        end
    end
end
