# Printing with many arguments: a method of a function with varargs is specialized on at most
# `max_args` arguments (juliac's patch raises print's, println's and print_to_string's to 10),
# beyond which the rest is a `Vararg{Any}`, elements of type `Any`: calls juliac's verifier
# cannot resolve (`string(...)` of 14 pieces). 32 for the printing
# functions, and their methods defined again as Base's (the same code): so that what was
# inferred before the session, under the lower limits, is inferred again. Applied with
# juliac's trim patches (see `patches.jl`).
let
    for f in (print, println, Base.print_to_string, string, Base.string_with_env)
        setfield!(typeof(f).name, :max_args, Int32(32), :monotonic)
    end
    @eval Base begin
        function print(io::IO, xs...)
            lock(io)
            try
                for i in 1:nfields(xs)
                    print(io, xs[i])
                end
            finally
                unlock(io)
            end
            return nothing
        end
        println(io::IO, xs...) = print(io, xs..., "\n")
        function print_to_string(xs...)
            if isempty(xs)
                return ""
            end
            siz::Int = 0
            for i in 1:nfields(xs)
                siz += _str_sizehint(xs[i])
            end
            s = IOBuffer(sizehint=siz)
            for i in 1:nfields(xs)
                print(s, xs[i])
            end
            takestring!(s)
        end
        string(xs...) = print_to_string(xs...)
    end
end
