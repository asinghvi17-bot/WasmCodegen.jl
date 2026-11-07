# Collecting the closed world of code an entry point can run, as juliac does
# (`Compiler.typeinf_ext_toplevel`): a compilation queue drained by `CC.compile!` under
# the Wasm interpreter, which yields the (CodeInstance, CodeInfo) pairs of every function
# to compile.

"""
    ClosedWorld

The functions to compile: for every method instance, its CodeInstance and its optimized
source, in the order they were collected, and the entry points; inferred with the method
tables of the host's extensions `extensions` (see `WasmMethodTable`).
"""
struct ClosedWorld
    world::UInt
    extensions::Vector{Symbol}
    entries::Vector{Core.MethodInstance}
    order::Vector{Core.MethodInstance}
    sources::IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}
    "What the trim verifier reported (empty if verification was off or clean)."
    trim_report::Base.RefValue{String}
end

"""
    entry_instance(f, argtypes; world, extensions=()) -> MethodInstance

The method instance a call of `f` with arguments of types `argtypes` dispatches to in a
module whose host has the extensions `extensions` (a method of their tables or of
`Runtime.WASM_METHODS` where it has one).
"""
function entry_instance(@nospecialize(f), @nospecialize(argtypes::Tuple);
                        world::UInt=Base.get_world_counter(), extensions=())
    tt = Tuple{Core.Typeof(f),argtypes...}
    matches = CC.findall(tt, WasmMethodTable(world, extensions); limit=1)
    (matches === nothing || length(matches) != 1) &&
        error("no unique method for $tt")
    match = CC.getindex(matches, 1)::Core.MethodMatch
    return CC.specialize_method(match)
end

# `CC.compile!` takes whether code may link against code in images from Julia 1.13 on:
# the closed world does not
const COMPILE_KWARGS = VERSION >= v"1.13-" ? (; external_linkage=false) : (;)

"""
    collect_world(entries; world, verify=:warn, extensions=Symbol[]) -> ClosedWorld

Infer the entry method instances and everything they call, as juliac does, for a module
whose host has the extensions `extensions`. Calls kept as `:invoke`s of method instances
inference did not keep source for (error paths) are inferred too, to a fixpoint. With
`verify` (`:error`, `:warn` or `:off`), the result is checked with juliac's trim verifier,
which reports dynamic dispatch.
"""
function collect_world(entries::Vector{Core.MethodInstance};
                       world::UInt=Base.get_world_counter(), verify::Symbol=:warn,
                       extensions::Vector{Symbol}=Symbol[])
    w = ClosedWorld(world, extensions, entries, Core.MethodInstance[],
                    IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}(),
                    Ref(""))
    verify === :off ||
        (w.trim_report[] = trim_check(entries; world, onlywarn=verify === :warn, extensions))
    extend_world!(w, entries)
    return w
end

"""
    TrimFailure

The entry points are not trim-safe: juliac's verifier found dynamic dispatch (or other
constructs that need the Julia runtime) in the code they run.
"""
struct TrimFailure <: Exception
    report::String
end
Base.showerror(io::IO, e::TrimFailure) =
    print(io, "the code of the entry points is not trim-safe (as juliac --trim=safe checks):\n", e.report)

# the rounds of inferring invoke targets as entries in `trim_check`
const MAX_INVOKE_ROUNDS = 8

"""
    trim_check(entries; world, onlywarn=false, extensions=()) -> String

Check the entry points as `juliac --trim=safe` does: inference collects the code they run, as
`Compiler.typeinf_ext_toplevel` does, and juliac's verifier checks it. Returns the verifier's
report, and throws a [`TrimFailure`](@ref) if it found errors (unless `onlywarn`). This is the
subset of Julia the code generator targets.

The inference is the module's own (`WasmInterpreter`, see `verify_inference`): a call that
an overlay method table (`Runtime.WASM_METHODS`, an extension's) has a method for is
inferred, and inlined, as that method, so the
verifier checks the code the module compiles. (Native inference would inline the native body
of such a method into its callers, where it can no longer be told apart from their own code.)

An `:invoke` of a method instance without a code instance (one inferred only as part of a
recursion cycle, or whose cached code the patches invalidated) is a static call, which the
code generator compiles, but the verifier rejects it as unresolved: native inference does
not compile its target. Each such target is inferred as an entry of its own, and the invoke
made of its code instance; the verifier checks that code as any other. (For a few rounds: the
targets of a program whose specializations do not end, as recursive invokes of ever deeper
types, stay unresolved invokes.)

The check runs in the world of the code generator's own code (`COMPILER_WORLD`), as `compile`
does: a session of patches makes a newer world, in which that code (the inference of the
module's interpreter, the verifier) would be compiled again.
"""
trim_check(entries::Vector{Core.MethodInstance}; world::UInt=Base.get_world_counter(),
           onlywarn::Bool=false, extensions=()) =
    Base.invoke_in_world(COMPILER_WORLD[], trim_check_in_world, entries, world, onlywarn, extensions)

function trim_check_in_world(entries::Vector{Core.MethodInstance}, world::UInt, onlywarn::Bool, extensions)
    replacement = Replacements(world, extensions)
    roots = Any[entries...]
    codeinfos = verify_inference(roots, world, extensions)
    for _ in 1:MAX_INVOKE_ROUNDS
        # (and the methods of the overlay method tables the module compiles in place of the
        # native ones called, verified as entries)
        targets = filter(mi -> !(mi in roots),
                         [uncompiled_invoke_targets(codeinfos); replacement_targets(codeinfos, replacement)])
        isempty(targets) && break
        append!(roots, targets)
        codeinfos = verify_inference(roots, world, extensions)
    end
    link_invoke_targets!(codeinfos)
    io = IOBuffer()
    try
        redirect_stdout(devnull) do
            verify_trim(io, codeinfos, entries, replacement, onlywarn; world, extensions)
        end
    catch err
        err isa Core.TrimFailure || rethrow()
        throw(TrimFailure(String(take!(io))))
    end
    return String(take!(io))
end

"""
    verify_inference(roots, world, extensions=()) -> codeinfos

The (CodeInstance, CodeInfo) pairs of the code `roots` run, as `Compiler.typeinf_ext_toplevel`
collects them for juliac's verifier, inferred by the module's interpreter (`WasmInterpreter`):
with the methods of the overlay method tables (of the host's extensions `extensions` and
`Runtime.WASM_METHODS`) in place of the native ones they replace.
"""
function verify_inference(roots::Vector{Any}, world::UInt, extensions=())
    interp = WasmInterpreter(; world, extensions)
    codeinfos = Any[]
    wq = CC.CompilationQueue(; interp)
    ilq = CC.CompilationQueue(; interp)
    append!(wq, roots)
    CC.compile!(codeinfos, wq; invokelatest_queue=ilq, COMPILE_KWARGS...)
    CC.compile!(codeinfos, ilq; invokelatest_queue=ilq, COMPILE_KWARGS...)
    return codeinfos
end

# the code instances of `codeinfos` the verifier links invokes to, by method instance: those
# (native, or the module's interpreter's) valid in the current world, of the instance itself
# (`get_verify_typeinf_trim`'s)
function linkable_code(codeinfos::Vector{Any})
    now = Base.get_world_counter()
    code = IdDict{Core.MethodInstance,Core.CodeInstance}()
    for item in codeinfos
        item isa Core.CodeInstance && (item.owner === nothing || item.owner isa WasmCacheOwner) &&
            item.min_world <= now <= item.max_world &&
            CC.get_ci_mi(item) === item.def && (code[item.def] = item)
    end
    return code
end

# the statement's invoke target when it is a bare method instance (else nothing)
function invoked_instance(@nospecialize(st))
    ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
    Meta.isexpr(ex, :invoke) && ex.args[1] isa Core.MethodInstance || return nothing
    return ex.args[1]::Core.MethodInstance
end

# the method instances `codeinfos` invoke without a code instance of them in `codeinfos`
function uncompiled_invoke_targets(codeinfos::Vector{Any})
    code = linkable_code(codeinfos)
    targets = Core.MethodInstance[]
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        for st in (codeinfos[i + 1]::Core.CodeInfo).code
            mi = invoked_instance(st)
            mi === nothing || haskey(code, mi) || mi in targets || push!(targets, mi)
        end
    end
    return targets
end

# the invokes of a bare method instance with a code instance in `codeinfos`, of that code
# instance (in copies of the sources: they are inference's)
function link_invoke_targets!(codeinfos::Vector{Any})
    code = linkable_code(codeinfos)
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        src = codeinfos[i + 1]::Core.CodeInfo
        any(st -> (mi = invoked_instance(st); mi !== nothing && haskey(code, mi)), src.code) || continue
        src = copy(src)
        src.code = copy(src.code)
        for j in eachindex(src.code)
            st = src.code[j]
            mi = invoked_instance(st)
            (mi !== nothing && haskey(code, mi)) || continue
            ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
            linked = Expr(:invoke, code[mi], ex.args[2:end]...)
            src.code[j] = Meta.isexpr(st, :(=)) ? Expr(:(=), st.args[1], linked) : linked
        end
        codeinfos[i + 1] = src
    end
    return codeinfos
end

"""
    Replacements(world, extensions=())

The methods of the overlay method tables (of the host's extensions `extensions` and
`Runtime.WASM_METHODS`, as `WasmMethodTable`) that the module compiles in place of native
method instances (by `r(mi)`: the instance of the replacement, or `nothing`), looked up once
each.
"""
struct Replacements
    table::WasmMethodTable
    found::IdDict{Core.MethodInstance,Union{Nothing,Core.MethodInstance}}
end
Replacements(world::UInt, extensions=()) =
    Replacements(WasmMethodTable(world, extensions), IdDict{Core.MethodInstance,Union{Nothing,Core.MethodInstance}}())

function (r::Replacements)(mi::Core.MethodInstance)
    get!(r.found, mi) do
        m = mi.def
        m isa Method && !isdefined(m, :external_mt) || return nothing
        # (only the method a call of these types dispatches to is replaced: a less specific one
        # reached by `invoke` is compiled as it is)
        native = CC.findsup(mi.specTypes, CC.InternalMethodTable(r.table.world))[1]
        native isa Core.MethodMatch && native.method === m || return nothing
        match = CC.findsup(mi.specTypes, r.table)[1]
        match isa Core.MethodMatch && isdefined(match.method, :external_mt) &&
            any(mt -> mt === match.method.external_mt, r.table.tables) || return nothing
        return CC.specialize_method(match)
    end
end

# the callees of the `:invoke`s of `src`
function invoked_instances(src::Core.CodeInfo)
    callees = Core.MethodInstance[]
    for st in src.code
        Meta.isexpr(st, :(=)) && (st = st.args[2])
        Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify) || continue
        t = st.args[1]
        callee = t isa Core.CodeInstance ? CC.get_ci_mi(t) : t
        callee isa Core.MethodInstance && push!(callees, callee)
    end
    return callees
end

# the replacements of the native method instances `codeinfos` invoke
function replacement_targets(codeinfos::Vector{Any}, replacement::Replacements)
    targets = Core.MethodInstance[]
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        for callee in invoked_instances(codeinfos[i + 1]::Core.CodeInfo)
            r = replacement(callee)
            r === nothing || r in targets || push!(targets, r)
        end
    end
    return targets
end

# whether `mi` is `Runtime.map_type`, `map_type_symbol` or `map_type_value`, whose calls the
# code generator compiles to a table of its function's values, computed natively when it builds
# the module (`overlays.jl`): its body runs natively only
function compile_time_instance(mi::Core.MethodInstance)
    m = mi.def
    return m isa Method && m.module === Runtime && m.name in (:map_type, :map_type_symbol, :map_type_value)
end

# whether `mi` is `Runtime.original` (or its keyword body), which only the native bodies of
# replaced methods call, or a method of an overlay method table (`Runtime.WASM_METHODS`, an
# extension's): neither runs in the module unless the module's code reaches it
function only_if_reached(mi::Core.MethodInstance)
    m = mi.def
    m isa Method || return false
    Runtime.overlay_method(m) && return true
    return m.module === Runtime && (m.name === :original || startswith(String(m.name), "#original#"))
end

"""
    compiled_instances(codeinfos, entries, replacement, interp) -> (compiled, native_only)

The method instances of `codeinfos` that the module compiles: those the entries reach through
`:invoke`s and the callees the verifier looks up by a call's types (`deferred_callee`: a
finalizer, a `@cfunction`'s function, a `Threads.@threads` loop's body, by the module's
interpreter `interp`), where a call of a native method that a method of an overlay method
table replaces (`replacement`) reaches the replacement instead; and those reached only
through such native methods (`native_only`).
"""
function compiled_instances(codeinfos::Vector{Any}, entries::Vector{Core.MethodInstance},
                            replacement::Replacements, interp::WasmInterpreter)
    src = IdDict{Core.MethodInstance,Core.CodeInfo}()
    for i in 1:length(codeinfos)
        item = codeinfos[i]
        item isa Core.CodeInstance && (src[CC.get_ci_mi(item)] = codeinfos[i + 1]::Core.CodeInfo)
    end
    # the instances reached from `from`; unless `native`, a replaced one is pushed to
    # `replaced`, and its replacement reached instead
    function reach(from, replaced, native::Bool)
        reached = IdSet{Core.MethodInstance}()
        work = Core.MethodInstance[from...]
        while !isempty(work)
            mi = pop!(work)
            mi in reached && continue
            push!(reached, mi)
            ci = get(src, mi, nothing)
            ci === nothing && continue
            for callee in invoked_instances(ci)
                if !native && compile_time_instance(callee)
                    push!(replaced, callee)
                    continue
                end
                r = native ? nothing : replacement(callee)
                r === nothing ? push!(work, callee) : (push!(replaced, callee); push!(work, r))
            end
            native && continue
            # (the module's callbacks, finalizers and loop bodies, as the verifier finds them)
            sptypes = CC.sptypes_from_meth_instance(mi)
            for st in ci.code
                callee = deferred_callee(st, ci, sptypes, mi, interp)
                callee === nothing || push!(work, callee)
            end
        end
        return reached
    end
    replaced = Core.MethodInstance[]
    compiled = reach(entries, replaced, false)
    # (from the replaced native methods: what they call, replaced or not, runs natively only)
    native = reach(replaced, nothing, true)
    return compiled, IdSet{Core.MethodInstance}(mi for mi in native if !(mi in compiled))
end

# the callee of a statement of `src` (of `mi`) that the verifier looks up by the call's types
# (`get_verify_typeinf_trim`'s `caches`): the finalizer a `Core.finalizer` call registers, a
# `@cfunction`'s function, a `Threads.@threads` loop's body (Julia 1.13.2); found as the verifier
# finds it, by the module's interpreter `interp` (its world and overlay method tables, as the
# collection's). Else nothing.
function deferred_callee(@nospecialize(stmt), src::Core.CodeInfo, sptypes, mi::Core.MethodInstance,
                         interp::WasmInterpreter)
    Meta.isexpr(stmt, :(=)) && (stmt = stmt.args[2])
    cfunction = Meta.isexpr(stmt, :cfunction)
    if cfunction
        (length(stmt.args) == 5 && stmt.args[4] isa Core.SimpleVector) || return nothing
        atype = CC.argtypes_to_type(Any[CC.argextype(stmt.args[2], src, sptypes);
                                        Any[CC.sp_type_rewrap(T, mi, false) for T in stmt.args[4]]])
    elseif Meta.isexpr(stmt, :call) && 3 <= length(stmt.args) <= 5 &&
           CC.widenconst(CC.argextype(stmt.args[1], src, sptypes)) === typeof(Core.finalizer)
        atype = CC.argtypes_to_type(Any[CC.argextype(stmt.args[2], src, sptypes),
                                        CC.argextype(stmt.args[3], src, sptypes)])
    elseif VERSION >= v"1.13.2" && Meta.isexpr(stmt, :invoke)
        atype = CC.TrimVerifier.threads_deferred_call_type(stmt, src, sptypes)
        atype === nothing && return nothing
    else
        return nothing
    end
    callee = CC.compileable_specialization_for_call(interp, atype)
    callee === nothing && return nothing
    # (1.13's verifier: the instance covers the `@cfunction`'s types)
    VERSION >= v"1.13-" && cfunction && !(atype <: (callee.def::Method).sig) && return nothing
    return callee
end

# whether the error is an unresolved callee the verifier looks up by the call's types (see
# `deferred_callee`) that the module's inference did compile: the verifier looks these up
# among native code instances only, and `verify_inference`'s are the module's own
function callee_compiled(d, code::IdDict{Core.MethodInstance,Core.CodeInstance}, interp::WasmInterpreter)
    d.desc in ("unresolved finalizer registered", "unresolved cfunction",
               "unresolved `Threads.@threads` loop body") || return false
    callee = deferred_callee(d.codeinfo.code[d.stmtidx], d.codeinfo, d.sptypes, CC.get_ci_mi(d.codeinst), interp)
    return callee !== nothing && haskey(code, callee)
end

"""
    verify_trim(io, codeinfos, entries, replacement, onlywarn; world, extensions=())

juliac's verifier (`Compiler.verify_typeinf_trim`) of what the module compiles: the methods
of the overlay method tables in place of the native methods they replace (`trim_check` infers
them as entries), without the errors in those native methods, and in the code only they
reach. (Natively, such a method may call the method before the patches with
`Runtime.original`, which the verifier rejects.) A replaced method or `Runtime.original`
reached otherwise (from an entry) is verified too.

The calls are those of the module's inference (`verify_inference`), which already infers a
call of a replaced method as its replacement, and inlines the replacement where it inlines:
what is left of the bookkeeping below is for code that still reaches a native method a
replacement replaces (as `Runtime.original` does). The callees the verifier looks up by a
call's types among native code instances (finalizers, `@cfunction`s, `Threads.@threads` loop
bodies) are looked up among the module's, by its interpreter in `world` with the overlay
tables of `extensions` (`callee_compiled`).
"""
function verify_trim(io::IO, codeinfos::Vector{Any}, entries::Vector{Core.MethodInstance},
                     replacement::Replacements, onlywarn::Bool; world::UInt, extensions=())
    TV = CC.TrimVerifier
    errors, parents = TV.get_verify_typeinf_trim(codeinfos)
    interp = WasmInterpreter(; world, extensions)
    compiled, native_only = compiled_instances(codeinfos, entries, replacement, interp)
    code = linkable_code(codeinfos)
    filter!(errors) do e
        d = e.second
        d isa TV.CallMissing || return true
        callee_compiled(d, code, interp) && return false
        mi = CC.get_ci_mi(d.codeinst)
        return !(mi in native_only ||
                 ((only_if_reached(mi) || compile_time_instance(mi) || replacement(mi) !== nothing) &&
                  !(mi in compiled)))
    end
    # (the rest as `verify_typeinf_trim`)
    counts = [0, 0]
    io = IOContext{IO}(io)
    for (warn, desc) in errors
        severity = warn ? 2 : 1
        no = (counts[severity] += 1)
        printstyled(io, "Error #", no, ": "; color=Base.error_color(), bold=true)
        # (Julia 1.12's and 1.13.0's and 1.13.1's have no `warn`)
        VERSION >= v"1.13.2" ? TV.verify_print_error(io, desc, parents, warn) :
                              verify_print_error_1_12(io, desc, parents)
    end
    if counts[1] > 0 || counts[2] > 0
        print(io, "Trim verify finished with ")
        if counts[1] > 0
            printstyled(io, counts[1], counts[1] == 1 ? " error" : " errors"; color=Base.error_color(), bold=true)
        else
            print(io, counts[1], counts[1] == 1 ? " error" : " errors")
        end
        print(io, ", ")
        if counts[2] > 0
            printstyled(io, counts[2], counts[2] == 1 ? " warning" : " warnings"; color=Base.warn_color(), bold=true)
        else
            print(io, counts[2], counts[2] == 1 ? " warning" : " warnings")
        end
        print(io, ".\n")
        counts[1] > 0 && !onlywarn && throw(Core.TrimFailure())
    end
    return nothing
end

# Julia 1.12's verifier (and 1.13.0's and 1.13.1's) prints the stack of an error's statement by
# following the parents of its code instance without end where they make a cycle (a recursion
# through an entry, as `f(n) = n <= 0 ? g(n) : f(n - 1)`): it never returns, and its frames
# take all the memory.
# The frames as Julia 1.13.2's (`verify_create_stackframes`), which stops at a parent it visited.
function verify_print_error_1_12(io::IOContext{IO}, desc, parents)
    TV = CC.TrimVerifier
    desc isa TV.CallMissing || return TV.verify_print_error(io, desc, parents)
    scopes = TV.LineInfoNode[]
    frames = Base.StackTraces.StackFrame[]
    visited = Base.IdSet{Tuple{Core.CodeInstance,Int}}()
    parent = (desc.codeinst, desc.stmtidx)
    while true
        ci, idx = parent
        TV.append_scopes!(scopes, idx, ci.debuginfo, :var"unknown scope")
        for i in reverse(1:length(scopes))
            lno = scopes[i]
            def = lno.method
            def isa Union{Method,Core.CodeInstance,Core.MethodInstance} || (def = nothing)
            push!(frames, Base.StackTraces.StackFrame(TV.normalize_method_name(lno.method), lno.file,
                                                      lno.line, def, false, i != 1, 0))
        end
        empty!(scopes)
        parent = get(parents, ci, nothing)
        (parent === nothing || parent in visited) && break
        push!(visited, parent)
    end
    print(io, desc.desc, " from statement ")
    TV.verify_print_stmt(io, desc.codeinfo, desc.sptypes, desc.stmtidx)
    Base.show_backtrace(io, frames)
    print(io, "\n\n")
    return nothing
end

"""
    extend_world!(w, mis) -> ClosedWorld

Add the method instances `mis` and everything they call to the closed world `w` (the
code generator asks for the functions of its runtime this way).
"""
function extend_world!(w::ClosedWorld, mis::Vector{Core.MethodInstance})
    interp = WasmInterpreter(; world=w.world, extensions=w.extensions)
    codeinfos = Any[]
    wq = CC.CompilationQueue(; interp)
    ilq = CC.CompilationQueue(; interp)
    initial = [mi for mi in mis if !haskey(w.sources, mi)]
    append!(wq, initial)
    # Each method instance is asked for once: one that comes back without a source would
    # otherwise be missing, and asked for, again on every round, without end. Each round scans
    # only the functions it added. A target left without a source is not in the world: a call
    # to it that survives to emission is an unsupported construct there (get_function!).
    requested = Base.IdSet{Core.MethodInstance}(initial)
    scanned = length(w.order)
    trace = get(ENV, "WCG_COLLECT_TRACE", "") == "1"
    nround = 0
    t0 = time()
    while true
        nround += 1
        CC.compile!(codeinfos, wq; invokelatest_queue=ilq, COMPILE_KWARGS...)
        CC.compile!(codeinfos, ilq; invokelatest_queue=ilq, COMPILE_KWARGS...)
        for i in 1:2:length(codeinfos)
            ci, src = codeinfos[i], codeinfos[i+1]
            (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
            mi = CC.get_ci_mi(ci)
            haskey(w.sources, mi) && continue
            w.sources[mi] = (ci, src)
            push!(w.order, mi)
        end
        # the targets of `:invoke`s in the functions this round added that are not in the
        # world yet and were not asked for before
        missing = Core.MethodInstance[]
        for k in scanned+1:length(w.order), stmt in w.sources[w.order[k]][2].code
            Meta.isexpr(stmt, :invoke) || continue
            target = stmt.args[1]
            tmi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
            tmi isa Core.MethodInstance || continue
            haskey(w.sources, tmi) || tmi in requested || (push!(requested, tmi); push!(missing, tmi))
        end
        trace && println(stderr, "extend_world! round ", nround, ": world ", length(w.order), " (+",
                         length(w.order) - scanned, "), new :invoke targets ", length(missing), ", ",
                         round(time() - t0; digits = 1), " s")
        trace && flush(stderr)
        scanned = length(w.order)
        isempty(missing) && break
        empty!(codeinfos)
        append!(wq, missing)
    end
    # asked for, but inference kept no source for them
    unresolved = [mi for mi in requested if !haskey(w.sources, mi)]
    if trace && !isempty(unresolved)
        println(stderr, "extend_world!: ", length(unresolved), " :invoke targets without a source, e.g. ",
                join((sprint(show, mi; context = :limit => true) for mi in first(unresolved, 5)), "; "))
        flush(stderr)
    end
    return w
end
