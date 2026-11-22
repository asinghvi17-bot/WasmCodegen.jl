# Base functions the runtime and the trim patches copy by hand (changed where the copy says):
# a change of Base's method must be looked at, and carried over to the copy. Each is pinned by a
# checksum of its lowered code on each supported Julia; where one fails, compare Base's method
# with the copy at the file named, then update the checksum (the failure prints the new one).

using Test, WasmCodegen

module BaseCopies

using WasmCodegen

# the world before the patches of a session, which replace some of the methods (and `show`'s)
base_world() = min(WasmCodegen.Runtime.PRE_PATCH_WORLD[], Base.get_world_counter())

# Base's method for the call
base_method(@nospecialize(f), @nospecialize(types)) =
    Base._which(Tuple{Core.Typeof(f),types...}; world=base_world()).method

# the statements of a method's lowered code (no line numbers), without the numbers of the
# generated names, which change with the code around the method
function lowered_text(m::Method)
    io = IOBuffer()
    for st in Base.uncompressed_ast(m).code
        Base.invoke_in_world(base_world(), show, io, st)
        println(io)
    end
    return replace(String(take!(io)), r"#\d+" => "#")
end

# the checksum of the lowered code of Base's method for `f(::types...)`, and of its keyword body
function checksum(@nospecialize(f), @nospecialize(types))
    m = base_method(f, types)
    text = lowered_text(m)
    body = Base.bodyfunction(m)
    if body !== nothing
        for bm in methods(body)
            text *= lowered_text(bm)
        end
    end
    return Base._crc32c(text)
end

const FS = Base.Filesystem
# (the copy, Base's function, the argument types of its method)
const COPIES = Any[
    ("src/trim/wasm-fs.jl _readdir", FS._readdir, (AbstractString,)),
    ("src/trim/wasm-fs.jl cd(f, dir)", FS.cd, (Function, AbstractString)),
    ("src/trim/wasm-fs.jl mktempdir", FS.mktempdir, (AbstractString,)),
    ("src/trim/wasm-fs.jl mktemp", FS.mktemp, (AbstractString,)),
    ("src/trim/wasm-fs.jl sendfile", FS.sendfile, (AbstractString, AbstractString)),
    ("src/trim/wasm-fs.jl walkdir", FS.walkdir, (String,)),
    ("src/trim/wasm-tasks.jl threading_run", Base.Threads.threading_run, (Function, Bool)),
    ("src/runtime/tasks.jl sync_end_wasm", Base.sync_end, (Channel{Any},)),
    ("src/runtime/tasks.jl timer_trywait", Base._trywait, (Timer,)),
    ("src/runtime/tasks.jl timer_close!", Base.close, (Timer,)),
    ("src/runtime/tasks.jl errormonitor_wasm", Base.errormonitor, (Task,)),
    ("src/runtime/env.jl iterate(::EnvDict)", Base.iterate, (Base.EnvDict, Int)),
]

# the checksums of `COPIES`, in its order, by Julia version (the latest patch releases)
const CHECKSUMS = Dict(
    (1, 12) => (0x00e45643, 0x60af36c9, 0x8627a189, 0x1995651c, 0x3b1d0b61, 0x606856fc, 0x982c254e,
                0x338454c7, 0x488c475d, 0x00419470, 0x4843143d, 0x71434f54),
    (1, 13) => (0x19a9fbe9, 0x354b69f0, 0xef8c5bf5, 0x0f2bfaf0, 0x3b1d0b61, 0xb122e146, 0x1a0e57ba,
                0x338454c7, 0x488c475d, 0xa986f9ab, 0x4843143d, 0xdef0a905),
)

end # module

@testset "Base functions copied by hand have not changed" begin
    pinned = get(BaseCopies.CHECKSUMS, (VERSION.major, VERSION.minor), nothing)
    if pinned === nothing
        @info "no checksums of Base's copied functions for this Julia" VERSION
    else
        for ((copy, f, types), sum) in zip(BaseCopies.COPIES, pinned)
            now = BaseCopies.checksum(f, types)
            now == sum || @info "Base's method changed: compare it with the copy" copy VERSION checksum = now
            @test now == sum
        end
    end
end
