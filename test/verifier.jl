# juliac's trim verifier (`trim_check`, `Config(verify)`) and the methods of
# `Runtime.WASM_METHODS` and of the extensions' tables: the module's own code is verified. (In
# the session of trim patches of the tests: the compilations use it, rather than one each.)

# a method of `Runtime.WASM_METHODS`: the native method it replaces (and what only that
# reaches) is not verified, as the module compiles the replacement instead; the same code
# reached from an entry is
module ReplacedTarget
import WasmCodegen
@noinline helper(x::Int) = Base.inferencebarrier(x) + 1
@noinline replaced(x::Int)::Int = helper(x)
WasmCodegen.Runtime.@wasm_method replaced(x::Int) = x + 1
through_replaced(x::Int) = replaced(x) * 2
direct(x::Int) = helper(x)::Int * 2
# a replacement is verified: this one calls the dynamic helper
@noinline replaced_dynamic(x::Int)::Int = x + 1
WasmCodegen.Runtime.@wasm_method replaced_dynamic(x::Int) = helper(x)::Int
through_dynamic(x::Int) = replaced_dynamic(x) * 2
# a replaced method whose native body calls another one, whose native body calls the helper
@noinline outer(x::Int)::Int = inner(x)
@noinline inner(x::Int)::Int = helper(x)
WasmCodegen.Runtime.@wasm_method outer(x::Int) = x + 1
WasmCodegen.Runtime.@wasm_method inner(x::Int) = x + 2
through_outer(x::Int) = outer(x) * 2
# a less specific method reached by `invoke` is not the one a replacement replaces
@noinline invoked(x::Number)::Int = helper(Int(x))
invoked(x::Int) = x + 1
WasmCodegen.Runtime.@wasm_method invoked(x::Int) = x + 1
through_invoke(x::Int) = invoke(invoked, Tuple{Number}, x)
# a replaced method native inference inlines into its caller (a keyword method's positional
# method): the verifier checks the replacement, not the native body that would be inlined (the
# same value, by a dynamic call)
@inline kwreplaced(x::Int; k::Int = 1)::Int = helper(x) - 1 + k
WasmCodegen.Runtime.@wasm_method kwreplaced(x::Int; k::Int = 1) = x + k
through_kw(x::Int) = kwreplaced(x) * 2
# a finalizer registered by Base (an IOStream's `close`): the verifier finds it among the
# module's own code
first_byte(path::String) = (io = open(path); try read(io, UInt8) finally close(io) end)
# a `@cfunction` of a function the module's inference compiles
inc(x::Int32) = x + Int32(1)
via_cfunction(x::Int32) = ccall(@cfunction(inc, Int32, (Int32,)), Int32, (Int32,), x)
# a finalizer the module compiles from an extension's table
cleanup(r::Base.RefValue{Int}) = (r[] = 0; nothing)
Base.Experimental.@MethodTable(FinalizerTable)
Base.Experimental.@overlay FinalizerTable cleanup(r::Base.RefValue{Int}) = (r[] = 0; nothing)
registered(n::Int) = (r = Ref(n); Core.finalizer(cleanup, r); r)
# an overlaid `@cfunction` callback and an extension's finalizer with a dynamic call in their
# bodies (the native ones have none): the verifier checks the bodies the module compiles
cb_dynamic(x::Int32)::Int32 = x + Int32(1)
WasmCodegen.Runtime.@wasm_method cb_dynamic(x::Int32)::Int32 = Base.inferencebarrier(x) + Int32(1)
via_cb_dynamic(x::Int32) = ccall(@cfunction(cb_dynamic, Int32, (Int32,)), Int32, (Int32,), x)
cleanup_dynamic(r::Base.RefValue{Int}) = (r[] = 0; nothing)
Base.Experimental.@overlay FinalizerTable cleanup_dynamic(r::Base.RefValue{Int}) =
    (r[] = (Base.inferencebarrier(1) + 1)::Int - 2; nothing)
registered_dynamic(n::Int) = (r = Ref(n); Core.finalizer(cleanup_dynamic, r); r)
# an unresolved call in a recursion through the entry: its report ends (Julia 1.12's verifier
# follows the recursion's parents without end)
recursive_dynamic(n::Int)::Int = n <= 0 ? Base.inferencebarrier(n) + 1 : recursive_dynamic(n - 1)
end

@testset "methods of WASM_METHODS and the verifier" begin
    T = ReplacedTarget
    c = WasmCodegen.compile(T.through_replaced, (Int,); config=WasmCodegen.Config(verify=:error))
    @test wasm_run(c, "through_replaced", 20; rettype=Int) == T.through_replaced(20) == 42
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.direct, (Int,); config=WasmCodegen.Config(verify=:error))
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.through_dynamic, (Int,); config=WasmCodegen.Config(verify=:error))
    c = WasmCodegen.compile(T.through_outer, (Int,); config=WasmCodegen.Config(verify=:error))
    @test wasm_run(c, "through_outer", 20; rettype=Int) == T.through_outer(20) == 42
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.through_invoke, (Int,); config=WasmCodegen.Config(verify=:error))
    c = WasmCodegen.compile(T.through_kw, (Int,); config=WasmCodegen.Config(verify=:error))
    @test wasm_run(c, "through_kw", 20; rettype=Int) == T.through_kw(20) == 42
    @test WasmCodegen.trim_check([WasmCodegen.entry_instance(T.first_byte, (String,))]) isa String
    c = WasmCodegen.compile(T.via_cfunction, (Int32,); config=WasmCodegen.Config(verify=:error))
    @test wasm_run(c, "via_cfunction", Int32(41); rettype=Int32) == T.via_cfunction(Int32(41)) == 42
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.via_cb_dynamic, (Int32,); config=WasmCodegen.Config(verify=:error))
    R = WasmCodegen.Runtime
    try
        WasmCodegen.with_trim_patches() do _, w
            R.EXTENSION_METHODS[:test_finalizers] = T.FinalizerTable
            mi = WasmCodegen.entry_instance(T.registered, (Int,); world=w)
            @test WasmCodegen.trim_check([mi]; world=w, extensions=[:test_finalizers]) isa String
            mi = WasmCodegen.entry_instance(T.registered_dynamic, (Int,); world=w)
            @test_throws WasmCodegen.TrimFailure WasmCodegen.trim_check([mi]; world=w, extensions=[:test_finalizers])
        end
    finally
        delete!(R.EXTENSION_METHODS, :test_finalizers)
    end
    report = WasmCodegen.trim_check([WasmCodegen.entry_instance(T.recursive_dynamic, (Int,))]; onlywarn=true)
    @test occursin("unresolved call", report) && occursin("recursive_dynamic", report)
end
