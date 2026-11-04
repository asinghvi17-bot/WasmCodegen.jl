# Printing with many arguments: a method of a function with varargs is specialized on at most
# `max_args` arguments (juliac's patch raises print's, println's and print_to_string's to 10),
# beyond which the rest is a `Vararg{Any}`, elements of type `Any`: calls juliac's verifier
# cannot resolve (`string(...)` of 14 pieces). 32 for the printing functions, and their
# methods defined again as Base's (the definitions of the Julia installation's Base sources):
# so that what was inferred before the session, under the lower limits, is inferred again.
# Applied with juliac's trim patches (see `patches.jl`).

let file = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base", "strings", "io.jl")
    for f in (print, println, Base.print_to_string, string, Base.string_with_env)
        setfield!(typeof(f).name, :max_args, Int32(32), :monotonic)
    end
    # (the definitions of `print(io::IO, xs...)`, `println(io::IO, xs...)`,
    # `print_to_string(xs...)` and `string(xs...)`, by their signatures)
    sigs = (:(print(io::IO, xs...)), :(println(io::IO, xs...)), :(print_to_string(xs...)), :(string(xs...)))
    found = Any[]
    for ex in Meta.parseall(read(file, String); filename=file).args
        # (without its docstring)
        Meta.isexpr(ex, :macrocall) && ex.args[1] == GlobalRef(Core, Symbol("@doc")) && (ex = ex.args[end])
        (Meta.isexpr(ex, :function) || Meta.isexpr(ex, :(=))) && ex.args[1] in sigs && push!(found, ex)
    end
    length(found) == length(sigs) || error("wasm-print.jl: not every printing method found in $file")
    foreach(def -> Core.eval(Base, def), found)
end
