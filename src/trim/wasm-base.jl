# The pseudo-runtime's patches of Base: code that natively reflects on types or memory at run
# time, made to do so at compile time. Applied with juliac's trim patches (see `patches.jl`).

let Runtime = WasmCodegen.Runtime
    @eval Base begin
        # reinterpreting isbits values: by their leaves (see `runtime/reinterpret.jl`)
        @inline function _reinterpret(::Type{Out}, x::In) where {Out, In}
            isbitstype(Out) || throw(ArgumentError("Target type for `reinterpret` must be isbits"))
            isbitstype(In) || throw(ArgumentError("Source type for `reinterpret` must be isbits"))
            inpackedsize = $(Runtime.packedsize)(In)
            outpackedsize = $(Runtime.packedsize)(Out)
            inpackedsize == outpackedsize ||
                throw(ArgumentError(LazyString("Packed sizes of types ", Out, " and ", In,
                    " do not match; got ", outpackedsize, " and ", inpackedsize, ", respectively.")))
            if $(Runtime.struct_subpadding)(Out, In)
                return $(Runtime.reinterpret_bits)(Out, x)
            else
                return _reinterpret_padding(Out, x)
            end
        end
        # copies between arrays and dense arrays reinterpreted (`collect(reinterpret(UInt8, img))`,
        # `Vector{UInt8}(r)`, `copyto!(reinterpret(UInt8, img), bytes)`), of elements without
        # padding: one `memmove` of their bytes (an `array.copy`). Base copies each element
        # through `Ref`s and pointers, which LLVM makes registers; in Wasm each `Ref` would be
        # an object, its bytes read and written through pointers by their owner.
        # `copyto_unaliased!` copies all of `src` to the first `length(src)` elements of `dest`
        # (by linear index, whatever the index styles: both start at 1); a reinterpreted
        # `Array` (no view, offset or stride: those are other types of parent, as nested or
        # reshaped reinterpreted arrays are) has its parent's bytes, from its first, its size
        # computed from its parent's (`length(r) * sizeof(T) <= sizeof(r.parent)`). Copies
        # with ranges (`copyto!(dest, i, src, j, n)`, of `CartesianIndices`) are Base's loops.
        @inline _bytes_copyable(::Type{T}, ::Type{S}) where {T, S} =
            isbitstype(T) && isbitstype(S) &&
                $(Runtime.packedsize)(T) == sizeof(T) && $(Runtime.packedsize)(S) == sizeof(S)
        function copyto_unaliased!(deststyle::IndexStyle, dest::Array{T}, srcstyle::IndexStyle,
                                   src::ReinterpretArray{T, N, S, <:Array}) where {T, N, S}
            _bytes_copyable(T, S) ||
                return invoke(copyto_unaliased!, Tuple{IndexStyle, AbstractArray, IndexStyle, AbstractArray},
                              deststyle, dest, srcstyle, src)
            isempty(src) && return dest
            length(dest) >= length(src) || throw(BoundsError(dest, LinearIndices(src)))
            GC.@preserve dest src unsafe_copyto!(Ptr{UInt8}(pointer(dest)),
                Ptr{UInt8}(pointer(src.parent)), UInt(length(src) * sizeof(T)))
            return dest
        end
        function copyto_unaliased!(deststyle::IndexStyle, dest::ReinterpretArray{T, N, S, <:Array},
                                   srcstyle::IndexStyle, src::Array{T}) where {T, N, S}
            _bytes_copyable(T, S) ||
                return invoke(copyto_unaliased!, Tuple{IndexStyle, AbstractArray, IndexStyle, AbstractArray},
                              deststyle, dest, srcstyle, src)
            isempty(src) && return dest
            length(dest) >= length(src) || throw(BoundsError(dest, LinearIndices(src)))
            GC.@preserve dest src unsafe_copyto!(Ptr{UInt8}(pointer(dest.parent)),
                Ptr{UInt8}(pointer(src)), UInt(length(src) * sizeof(T)))
            return dest
        end
        # a call in the latest world (to keep it unspecialized natively): a direct call, which
        # specializes it on the type, so its reflection is done at compile time
        _typeinfo_implicit(@nospecialize(T)) = typeinfo_implicit(T)::Bool
        # printing a type: juliac's (which reflects on the type, see juliac-trim-base.jl),
        # computed at compile time: a constant for a type known then, else from a table of
        # the module's types (`Runtime.simple_type_name`, the same text as `_show_type`)
        Base.@assume_effects :foldable _type_name(@nospecialize(T::Type)) =
            $(Runtime.map_type_symbol)($(Runtime.simple_type_name), T)
        show(io::IO, T::Type) = print(io, _type_name(T))
        # the hash of a type (`hash(::Type)`, and so `hash` of the values that hash their type,
        # as `hash(::Base.SHA1)` does): the C runtime's `jl_type_hash`, from a table of the
        # module's types computed at compile time (`Runtime.type_hash`), so the hashes are the
        # native ones (also for the Dicts in the image)
        Base.@assume_effects :foldable _jl_type_hash(@nospecialize(T::Type)) =
            ($(Runtime.map_type_value)($(Runtime.type_hash), T)::$(Runtime.TypeHash)).h
        # showing a function or an enum: the bindings that name it, and their visibility from
        # `show`'s default module, at compile time (`Runtime.function_show`/`enum_show`);
        # another module in the `IOContext`'s `:module` is not in Wasm
        function show_function(io::IO, f::Function, compact::Bool, fallback::Function)
            s = $(Runtime.map_type_value)($(Runtime.function_show), typeof(f))::$(Runtime.FunctionShow)
            if s.fallback
                fallback(io, f)
            elseif compact
                print(io, s.name)
            elseif s.bound && s.value === f
                mod = get(io, :module, UsesBaseOnly)
                visible = mod === s.mod || (mod === UsesBaseOnly ? s.visible :
                    error("show of a function with an IOContext :module other than Base.UsesBaseOnly is not in Wasm"))
                visible || print(io, s.mod, ".")
                show_sym(io, s.name)
            else
                fallback(io, f)
            end
        end
        function show(io::IO, x::Enums.Enum)
            sym = Enums._symbol(x)
            if !(get(io, :compact, false)::Bool)
                from = get(io, :module, Main)
                s = $(Runtime.map_type_value)($(Runtime.enum_show), typeof(x))::$(Runtime.EnumShow)
                # (a value not of an instance, `<invalid #n>`, is no binding: never visible)
                visible = from === nothing ? false : from === s.def ? sym in s.names : from === Main ? sym in s.visible :
                    error("show of an enum with an IOContext :module other than Main is not in Wasm")
                if !visible
                    show(io, s.def)
                    print(io, ".")
                end
            end
            print(io, sym)
        end
        # (`typesplit` reflects on and makes types: a table of the module's types instead)
        nonnothing_nonmissing_typeinfo(io::IO) =
            $(Runtime.map_type)($(Runtime.nonnothing_nonmissing), get(io, :typeinfo, Any))
        function _show_type_param(io::IO, @nospecialize(p))
            if p isa Int
                show(io, p)
            elseif p isa Type
                _show_type(io, p)
            elseif p isa Symbol
                print(io, ":")
                print(io, p)
            elseif p isa TypeVar
                print(io, p.name)
            else
                print(io, "?")
            end
        end
        function _show_type(io::IO, @nospecialize(T::Type))
            if T isa DataType
                print(io, T.name.name)
                if T !== T.name.wrapper && length(T.parameters) > 0
                    print(io, "{")
                    first = true
                    for p in T.parameters
                        first || print(io, ", ")
                        first = false
                        _show_type_param(io, p)
                    end
                    print(io, "}")
                end
            elseif T isa Union
                print(io, "Union{")
                _show_type_param(io, T.a)
                print(io, ", ")
                _show_type_param(io, T.b)
                print(io, "}")
            elseif T isa UnionAll
                _show_type(io, T.body::Type)
                print(io, " where ")
                print(io, T.var.name)
            end
        end
    end
end
