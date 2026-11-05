# Building an `Expr` (`Core._expr`): as natively, its errors included. Splatting into `Expr` is
# a call of a function that is not a builtin through `Core._apply_iterate`, which juliac's
# verifier reports ("unresolved call to function"): so is it here.

module ExprPrograms
built(n::Int) = (e = Expr(:call, :f, n, 2n); 1000 * (e.head === :call) + 100 * length(e.args) + e.args[2]::Int + e.args[3]::Int)
# no arguments, and an argument of a type of the program's
struct Item
    k::Int
end
bare(n::Int) = (e = Expr(:block); length(e.args) + n)
held(n::Int) = (Expr(:quote, Item(n)).args[1]::Item).k
const HEAD = Ref{Any}(1)
bad_head(n::Int) = try Core._expr(HEAD[], n); 0 catch e; e isa TypeError && e.func === :Expr && e.expected === Symbol ? 1 : 2 end
no_head(n::Int) = try Core._expr(); 0 catch e; e isa ArgumentError ? 1 : 2 end
splat(n::Int) = Expr(:block, Any[n, n + 1]...).args[1]::Int
end

@testset "Expr construction" begin
    P = ExprPrograms
    @wtest P.built(3)
    @wtest P.bare(3)
    @wtest P.held(3)
    @wtest P.bad_head(3)
    @wtest P.no_head(3)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.splat, (Int,); config = WasmCodegen.Config(verify = :off))
end
