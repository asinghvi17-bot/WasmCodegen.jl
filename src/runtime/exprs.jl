# The arguments of `Expr`s the code generator builds: `Core._expr` (`Expr(head, args...)`, see
# `builtins.jl`), with native Julia's errors (`jl_f__expr`).

module Exprs

"A `Vector{Any}` of `n` undefined elements, the arguments of a new `Expr`."
expr_args(n::Int) = Vector{Any}(undef, n)

set_arg!(v::Vector{Any}, i::Int, @nospecialize(x)) = (@inbounds v[i] = x; nothing)

"The head `h` of an `Expr`: a `Symbol`, else a TypeError."
expr_head(@nospecialize(h)) = h isa Symbol ? h : throw(TypeError(:Expr, "", Symbol, h))

"`Core._expr()`, without a head."
@noinline throw_no_head() = throw(ArgumentError("Expr: too few arguments (expected 1)"))

end
