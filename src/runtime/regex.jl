# Base's regular expressions (`Base.PCRE`), with PCRE2's functions the program provides
# (`Config(foreign_functions)`): a Wasm module has no PCRE2 JIT, and so no JIT stacks or the
# match contexts that hold them.

"The match context of the module's PCRE2 calls: none (null: PCRE2's defaults)."
const MATCH_CONTEXT = Ref{Ptr{Cvoid}}(C_NULL)

"""
`Base.PCRE.get_local_match_context()`: `MATCH_CONTEXT`, not Base's per thread, which hold a JIT
stack each (and, in the image, pointers of the build process). Read rather than a constant, as
natively from Base's table (see `@wasm_method`).
"""
@wasm_method Base.PCRE.get_local_match_context() = MATCH_CONTEXT[]
