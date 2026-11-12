"""
    ptr_owner(p::Ptr) -> Any

The object the pointer `p` points into (its owner: a `Memory`, a `String`, a `Ref`), or
`nothing` for a pointer without one (made from an integer). A primitive of the code generator
(`pointers.jl`: a pointer is an address and its owner); natively `nothing`, through an
inference barrier, so that code using it keeps both paths. With the owner, the low 32 bits of
the address are the byte offset into it (`ptr_offset`): copies through pointers whose origin
the code generator does not know can find the owner's memory once, not at each byte.
"""
@noinline ptr_owner(p::Ptr) = Base.inferencebarrier(nothing)

"The byte offset of the pointer `p` into its owner (the low 32 bits of its address)."
ptr_offset(p::Ptr) = Int(UInt64(UInt(p)) % UInt32)

"""
    owner_bytes(p::Ptr, n::Int) -> (Union{Nothing,Memory{UInt8},String}, Int)

The owner of `p` and the 1-based index of its byte at `p`, when the owner is a `Memory{UInt8}`
or a `String` holding the `n` bytes from `p`; else `(nothing, 0)`.
"""
@inline function owner_bytes(p::Ptr, n::Int)
    o = ptr_owner(p)
    i = ptr_offset(p)
    if o isa Memory{UInt8}
        return (0 <= n <= length(o) - i ? o : nothing), i + 1
    elseif o isa String
        return (0 <= n <= ncodeunits(o) - i ? o : nothing), i + 1
    end
    return nothing, 0
end
