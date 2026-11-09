# Patches: methods of Base and the standard library redefined for trimmed programs, as
# juliac redefines them in its build process (`src/trim/`, from JuliaC.jl).
#
# They are real method definitions, not overlays: native inference, concrete evaluation
# and effects treat them as the methods they replace, so the code compiled is the code
# juliac compiles. To keep them from affecting the session, they are defined in a new world
# for the compilation only: the program is inferred in that world, while the compiler runs
# in the world before them, and they are deleted afterwards (deleting a method that
# replaced another restores it). A long-lived process can instead install them once, for
# its life (`install_trim_patches!`): then no compilation defines or deletes methods.

const TRIM_PATCHES = [joinpath(@__DIR__, "trim", "juliac-trim-base.jl"),
                      joinpath(@__DIR__, "trim", "juliac-trim-stdlib.jl"),
                      # the pseudo-runtime: what Wasm has no C runtime for
                      joinpath(@__DIR__, "trim", "wasm-base.jl"),
                      joinpath(@__DIR__, "trim", "wasm-io.jl"),
                      joinpath(@__DIR__, "trim", "wasm-paths.jl"),
                      joinpath(@__DIR__, "trim", "wasm-random.jl"),
                      joinpath(@__DIR__, "trim", "wasm-memory.jl"),
                      joinpath(@__DIR__, "trim", "wasm-versions.jl"),
                      joinpath(@__DIR__, "trim", "wasm-show.jl"),
                      joinpath(@__DIR__, "trim", "wasm-print.jl"),
                      joinpath(@__DIR__, "trim", "wasm-specialize.jl"),
                      joinpath(@__DIR__, "trim", "wasm-invokelatest.jl"),
                      joinpath(@__DIR__, "trim", "wasm-fs.jl")]

# the C runtime's scheduler on one thread, for `Config(tasks=:jspi)` (after the others)
const TASK_PATCHES = [joinpath(@__DIR__, "trim", "wasm-tasks.jl")]

# the constants the patches rebind (methods are restored by deleting their replacements)
const PATCHED_CONSTS = [(Base, :invokelatest)]

"""
The world the compiler runs in: the world when WasmCodegen was loaded. The compiler's
own (native) code is compiled for that world and stays valid there whatever is defined
or deleted later (the patches, the program, packages loaded after WasmCodegen), as
GPUCompiler isolates the compiler from the code it compiles. Programs are inferred in
the latest world.
"""
const COMPILER_WORLD = Ref{UInt}(typemax(UInt))

"The patches and bindings of the open session of patches (see `with_trim_patches`), or `nothing`."
const PATCH_SESSION = Ref{Any}(nothing)

latest_global(m::Module, s::Symbol) = Base.invoke_in_world(Base.get_world_counter(), getglobal, m, s)

"""
    with_trim_patches(f; patches=TRIM_PATCHES, bindings=[])

Define the patches in a new world, call `f(compiler_world, program_world)` in the world
before them (`compiler_world`), and remove them afterwards. The program is to be inferred
in `program_world`, where the patches are defined.

Compilations within `f` (calls of [`compile`](@ref)) share the patches: their programs
are inferred in the latest world (with the patches, and whatever `f` defined) and the
compiler runs in `compiler_world`. Defining and deleting the patches invalidates code
that depends on the methods they replace, so a session of several compilations is much
faster than patching each one (as juliac builds in one process).

The patch files are included in a module of their own, where `WasmCodegen` and each
`name => value` of `bindings` (the modules they patch, loaded before) are defined. They
may only define methods: the methods they define are deleted when the session ends,
whether `f` returns or throws, or a patch file throws while it is included (deleting a
method that replaced another restores it). A session within a session shares it, which
must then have the same patches and bindings.
"""
function with_trim_patches(f; patches=TRIM_PATCHES, bindings=Pair{Symbol,Any}[])
    key = (String[abspath(p) for p in patches], Pair{Symbol,Any}[bindings...])
    open_session = PATCH_SESSION[]
    if open_session !== nothing
        same_session(open_session, key) ||
            error("with_trim_patches: a session of patches is open with other patches or bindings " *
                  "(nested sessions must have the same ones)")
        # (an installed session: the stand-ins of this world's methods, see `resident_standins`)
        RESIDENT_PATCH_MODULE[] === nothing || isempty(RESIDENT_ADDED) || resident_standins(Base.get_world_counter())
        return f(COMPILER_WORLD[], Base.get_world_counter())
    end
    w0 = Base.get_world_counter()
    consts = [(m, s, getglobal(m, s)) for (m, s) in PATCHED_CONSTS]
    sandbox = Module(:WasmCodegenTrimPatches)
    w1 = w0
    try
        Core.eval(sandbox, :(Core.Compiler._verify_trim_world_age[] = $w0))
        # (runtime functions the patches call can call the originals natively in this world)
        Runtime.PRE_PATCH_WORLD[] = w0
        Core.eval(sandbox, :(const WasmCodegen = $(@__MODULE__)))
        for (name, value) in bindings
            Core.eval(sandbox, :(const $name = $(QuoteNode(value))))
        end
        try
            for file in patches
                Base.include(sandbox, file)
            end
        finally
            # (the patches' methods: those of the worlds up to this one)
            w1 = Base.get_world_counter()
        end
        PATCH_SESSION[] = key
        return f(COMPILER_WORLD[], Base.get_world_counter())
    finally
        PATCH_SESSION[] = nothing
        Runtime.PRE_PATCH_WORLD[] = typemax(UInt)
        added = Method[]
        Base.visit(Core.methodtable) do m
            w0 < m.primary_world <= w1 && push!(added, m)
        end
        foreach(Base.delete_method, added)
        # (the binding as of now: this code runs in the world before the patches)
        for (m, s, v) in consts
            latest_global(m, s) === v || Core.eval(m, :(const $s = $v))
        end
    end
end

# These stubs are valid for a closed Wasm program, but a resident native process
# must keep package loading, initialization and world-age switching working.
const NONRESIDENT_TRIM_NAMES = Set((
    :invokelatest_gr, :reinit_stdio, :init_active_project, :set_active_project,
    :start_sigint_listener, :enable_in_core!, :wait_forever,
    :disable_library_threading, :start_profile_listener, :__init__,
    :_artifact_str, :current_logger_for_env, :show_type_name, :show_function, :_show_type,
))

# The function of a method definition (a name, or a qualified `M.name`), including
# definitions wrapped in annotations.
function trim_method_callee(ex)
    ex isa Expr || return nothing
    if ex.head === :macrocall && ex.args[end] isa Expr &&
            ex.args[1] in (Symbol("@inline"), Symbol("@noinline"), Symbol("@assume_effects"))
        return trim_method_callee(ex.args[end])
    end
    ex.head in (:function, :(=)) || return nothing
    sig = ex.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    Meta.isexpr(sig, :call) || return nothing
    return sig.args[1]
end

# The name of a method definition's function.
function trim_method_name(ex)
    name = trim_method_callee(ex)
    Meta.isexpr(name, :.) && (name = name.args[end].value)
    return name isa Symbol ? name : nothing
end

# Applied before macro expansion, so @eval still supplies the original module
# scope and interpolation. Resident-safe definitions are included unchanged.
function resident_trim_expr(ex)
    ex isa Expr || return ex
    # Core.invokelatest is a builtin on supported Julia: preserve its binding.
    # @invokelatest's Julia wrapper below is supplied through WASM_METHODS.
    if ex.head === :const && Meta.isexpr(ex.args[1], :(=)) &&
            ex.args[1].args[1] === :invokelatest
        return nothing
    end
    name = trim_method_name(ex)
    # LazyLibraryPath's restricted implementation also belongs only to Wasm.
    lazy_string = name === :string && occursin("LazyLibraryPath", string(ex.args[1]))
    # Native type repr is executable Julia in package-loader subprocesses;
    # juliac's unqualified names are only valid for Wasm display. The enum
    # printer likewise restricts module contexts that native Julia supports.
    nonresident_show = name === :show &&
        (occursin("T::Type", string(ex.args[1])) || occursin("x::Enums.Enum", string(ex.args[1])))
    if name in NONRESIDENT_TRIM_NAMES || lazy_string || nonresident_show
        overlay = Expr(:macrocall, GlobalRef(Runtime, Symbol("@wasm_method")),
                       LineNumberNode(0), ex)
        # An overlay needs a function to attach to. Some Julia versions have no
        # function of the name natively (CHOLMOD/StyledStrings initializers,
        # `wait_forever` on 1.12): declare it without methods, natively as absent,
        # but for an initializer, which a module's loading calls: a native no-op
        # (the absent hook's behavior), also where a session left the function
        # without its method. Never run the trimmed body natively.
        trim_method_callee(ex) isa Symbol || return overlay
        if name === :__init__
            return quote
                if !(isdefined(@__MODULE__, :__init__) && hasmethod(__init__, Tuple{}))
                    __init__() = nothing
                end
                $overlay
            end
        end
        return quote
            if !isdefined(@__MODULE__, $(QuoteNode(name)))
                function $name end
            end
            $overlay
        end
    end
    return Expr(ex.head, map(resident_trim_expr, ex.args)...)
end

# whether a session's patches and bindings (by identity) are those of `key`
same_session(session, key) =
    session[1] == key[1] && length(session[2]) == length(key[2]) &&
    all(((a, b),) -> a.first === b.first && a.second === b.second, zip(session[2], key[2]))

"""
    install_trim_patches!(; patches=TRIM_PATCHES, bindings=[])

Define the patches once, for the life of the process: `compile` and `with_trim_patches` (with
the same patches and bindings) then share this session, and define or delete no method. For
a process that compiles one program after another while its packages stay loaded (a compile
server), or a system image (called from its precompile script, before the workload): a session
per compilation deletes the patches when it ends, which invalidates the native code of
everything that depends on the methods they replace, in every package loaded, and the next
compilation compiles it all again.

The process's own Base is patched for its life. The patches are real methods, as in a session
(inferred as juliac infers them), except those that would break the native process, which are
methods of `Runtime.WASM_METHODS` instead: the startup, initialization, project, artifact and
lazy-library stubs, the logger lookup, `invokelatest_gr`, and the simplified printers of types,
type names, functions and enums (the package loader sends `repr`s of types to precompilation
processes as code). `Base.invokelatest` keeps Core's binding; a program's calls of it compile
to direct calls, as juliac's rebinding makes them. `Runtime.original` calls the world before
the installation. A compilation of a world before the installation has none of the patches, and
Wasm code inferred in one world is not reused in another (`WasmCacheOwner`).

Calling it again with the same patches and bindings does nothing; with others, or in a session
of `with_trim_patches`, it throws. `TASK_PATCHES` (`Config(tasks = :jspi)`) need a session of
their own. The installation is not undone: if a patch file throws, discard the process.
"""
function install_trim_patches!(; patches=TRIM_PATCHES, bindings=Pair{Symbol,Any}[])
    key = (String[abspath(p) for p in patches], Pair{Symbol,Any}[bindings...])
    any(p -> p in abspath.(TASK_PATCHES), key[1]) &&
        error("install_trim_patches!: TASK_PATCHES require a transient session")
    if PATCH_SESSION[] !== nothing
        same_session(PATCH_SESSION[], key) || error("install_trim_patches!: another patch session is open")
        RESIDENT_PATCH_MODULE[] !== nothing ||
            error("install_trim_patches!: cannot make a transient session permanent")
        return nothing
    end
    w0 = Base.get_world_counter()
    sandbox = Module(:WasmCodegenResidentTrimPatches)
    Runtime.PRE_PATCH_WORLD[] = w0
    Core.eval(sandbox, :(Core.Compiler._verify_trim_world_age[] = $w0))
    Core.eval(sandbox, :(const WasmCodegen = $(@__MODULE__)))
    for (name, value) in bindings
        Core.eval(sandbox, :(const $name = $(QuoteNode(value))))
    end
    for file in key[1]
        Base.include(resident_trim_expr, sandbox, file)
    end
    Base.visit(m -> m.primary_world > w0 && push!(RESIDENT_OVERLAYS, m), Runtime.WASM_METHODS)
    # (each, of those of the world now, in place of the native method of its signature, which a
    # session's patch replaces; or one the process lacks natively)
    w = Base.get_world_counter()
    for o in RESIDENT_OVERLAYS
        current = CC._findall(o.sig, Runtime.WASM_METHODS, w, -1)
        current !== nothing && any(m -> m.method === o, current.matches) || continue
        natives = CC._findall(o.sig, nothing, w, -1)
        k = natives === nothing ? nothing : findfirst(m -> m.method.sig == o.sig, natives.matches)
        k === nothing ? push!(RESIDENT_ADDED, o) : (RESIDENT_REPLACED[natives.matches[k].method] = o)
    end
    isempty(RESIDENT_ADDED) || resident_standins(Base.get_world_counter())
    if Base.invoke_in_world(Base.get_world_counter(), isdefined, Base, :invokelatest_trimmed)
        DIRECT_INVOKELATEST[] = latest_global(Base, :invokelatest_trimmed)
    end
    RESIDENT_WORLD[] = w
    RESIDENT_PATCH_MODULE[] = sandbox
    PATCH_SESSION[] = key
    return nothing
end

# Keep the patch module reachable for system-image serialization.
const RESIDENT_PATCH_MODULE = Ref{Union{Nothing,Module}}(nothing)

# the patches installed as methods of `WASM_METHODS` (see `CC.findall(::WasmMethodTable)`): the
# native methods they replace, and those that replace none
const RESIDENT_OVERLAYS = Method[]
# the world of the installation: a compilation of an earlier world has none of the patches
# (in a system image's process, every world: see `__init__`)
const RESIDENT_WORLD = Ref{UInt}(typemax(UInt))
resident_at(world::UInt) = !isempty(RESIDENT_OVERLAYS) && world >= RESIDENT_WORLD[]
const RESIDENT_REPLACED = IdDict{Method,Method}()
const RESIDENT_ADDED = Method[]
# For the overlays that replace no native method, Julia's lookup of the methods of their functions
# with them (see `resident_matches`), in a world: a method table of stand-ins of those methods
# (each of the real one's signature, so with its static parameters), the world to look it up in,
# the real method of each, and the native methods it has stand-ins of. One per set of native
# methods, by the world looked up (a world before methods were defined has its own).
struct ResidentStandins
    table::Core.MethodTable
    world::UInt
    real::IdDict{Method,Method}
    mirrored::IdDict{Method,Nothing}
end
const RESIDENT_STANDINS = Dict{UInt,ResidentStandins}()
const RESIDENT_STANDINS_LOCK = ReentrantLock()

function resident_standins(world::UInt)
    @lock RESIDENT_STANDINS_LOCK begin
        standins = get(RESIDENT_STANDINS, world, nothing)
        standins === nothing || return standins
        natives = Method[]
        for o in RESIDENT_ADDED
            # (the methods of its function, or of its function's keyword method)
            P = Base.unwrap_unionall(o.sig).parameters
            F = P[1] === typeof(Core.kwcall) && length(P) >= 3 ? Tuple{P[1], Any, P[3], Vararg{Any}} : Tuple{P[1], Vararg{Any}}
            ms = Base._methods_by_ftype(Base.rewrap_unionall(F, o.sig), nothing, -1, world, true,
                                        Ref(typemin(UInt)), Ref(typemax(UInt)), Ref{Int32}(0))
            ms isa Vector && foreach(m -> any(x -> x === m.method, natives) || push!(natives, m.method), ms)
        end
        for s in values(RESIDENT_STANDINS)
            length(s.mirrored) == length(natives) && all(m -> haskey(s.mirrored, m), natives) &&
                return RESIDENT_STANDINS[world] = s
        end
        table = ccall(:jl_new_method_table, Any, (Any, Any), :ResidentStandins, @__MODULE__)::Core.MethodTable
        # (in the order they were defined, then the overlays, as in a session: the order of the matches
        # Julia's lookup does not order by specificity)
        sort!(natives; by=m -> m.primary_world)
        real, mirrored = IdDict{Method,Method}(), IdDict{Method,Nothing}()
        for m in natives
            mirrored[m] = nothing
            # (one an overlay has the signature of is the overlay's, as it would be replaced)
            any(o -> o.sig == m.sig, RESIDENT_ADDED) && continue
            r = get(RESIDENT_REPLACED, m, m)
            real[standin!(table, r.sig)] = r
        end
        for o in sort(RESIDENT_ADDED; by=o -> o.primary_world)
            real[standin!(table, o.sig)] = o
        end
        return RESIDENT_STANDINS[world] = ResidentStandins(table, Base.get_world_counter(), real, mirrored)
    end
end

# a method of the signature `sig` in `table`, which is only looked up (its code: `nothing`)
function standin!(table::Core.MethodTable, @nospecialize(sig))
    vars = TypeVar[]
    U = sig
    while U isa UnionAll
        push!(vars, U.var)
        U = U.body
    end
    n = length(U.parameters)
    src = copy(Base.uncompressed_ast(only(methods(identity))))
    src.slotnames = Symbol[Symbol("#self#"); [Symbol(:x, i) for i in 2:n]]
    src.slotflags = zeros(UInt8, n)
    isdefined(src, :nargs) && (src.nargs = n)
    isdefined(src, :isva) && (src.isva = Base.isvarargtype(U.parameters[end]))
    argdata = Core.svec(Core.svec(U.parameters...), Core.svec(vars...), LineNumberNode(0, :standin))
    return ccall(:jl_method_def, Any, (Any, Any, Any, Any), argdata, table, src, @__MODULE__)::Method
end

# what a program's `Base.invokelatest` is, juliac's `invokelatest_trimmed` (see `CC.optimize(::WasmInterpreter, ...)`)
const DIRECT_INVOKELATEST = Ref{Any}(nothing)
# (in the worlds of the installation, whether or not it has overlays)
direct_invokelatest(interp) = CC.get_inference_world(interp) >= RESIDENT_WORLD[] ? DIRECT_INVOKELATEST[] : nothing
is_resident_overlay(m::Method) = !isempty(RESIDENT_OVERLAYS) && any(r -> r === m, RESIDENT_OVERLAYS)
