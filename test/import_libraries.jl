# Libraries of host imports a program declares (`Config(import_libraries)`, src/foreigncall.jl):
# a `ccall` of one is a call of the Wasm import `lib.name`, which a host of the program's own
# provides; other libraries are C libraries as before (unsupported), and the names of
# WasmCodegen's own imports cannot be declared.

implib_add(x::Int32, y::Int64) = ccall((:add, "implib_test"), Int64, (Int32, Int64), x, y)
implib_note(x::UInt32) = (ccall((:note, "implib_test"), Cvoid, (UInt32,), x); x + UInt32(1))
implib_both(x::Int32) = implib_add(x, Int64(1)) + ccall((:twice, "implib_other"), UInt64, (UInt64,), UInt64(x))
implib_float(x::Float64) = ccall((:half, "implib_test"), Float64, (Float64,), x)
# an import reached only through a case of the runtime: the `showerror` of an exception of the
# program's, which the host's error text calls by the exception's type
struct ImplibError <: Exception end
Base.showerror(io::IO, ::ImplibError) = (ccall((:note, "implib_test"), Cvoid, (UInt32,), UInt32(9)); print(io, "noted"))
implib_error_text(x::UInt32) = UInt32(length(WasmCodegen.Runtime.Host.error_text(ImplibError()))) + x

import_list(c) = sort!([(f.imported[1], f.imported[2], f.params, f.results)
                        for f in c.cgm.mod.funcs if f.imported !== nothing &&
                            f.imported[1] != "wasi_snapshot_preview1"]; by = x -> (x[1], x[2]))

# run `fn(args...)` of a WASI module with Node, the declared libraries given as JavaScript
# (`libs`: the source of an object of import modules), WASI's functions as stubs that do
# nothing: (result as a string, the host's log)
function run_import_libraries(c, fn, libs, args...)
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    write(joinpath(dir, "run.mjs"), """
    import fs from 'node:fs';
    const log = [];
    const libs = $libs;
    const mod = new WebAssembly.Module(fs.readFileSync('$(joinpath(dir, "m.wasm"))'));
    const imports = { ...libs, wasi_snapshot_preview1: {} };
    for (const i of WebAssembly.Module.imports(mod))
      if (i.module === 'wasi_snapshot_preview1') imports.wasi_snapshot_preview1[i.name] = () => 0;
    const instance = await WebAssembly.instantiate(mod, imports);
    instance.exports._initialize?.();
    const r = instance.exports.$fn($(join((a isa Union{Int64,UInt64} ? "$(a)n" : string(a) for a in args), ", ")));
    process.stdout.write(JSON.stringify({ r: String(r), log }));
    """)
    resp = JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))
    return String(resp["r"]), String[x for x in resp["log"]]
end

# run calls `(fn, args)` of a module with js/julia.mjs, the declared libraries given as
# JavaScript (`libs`: the source of a function of the host returning the import modules, or of
# the modules): (the results as strings, the host's log)
function run_js_bytes(c, libs, calls)
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    js_arg(a) = a isa Union{Int64,UInt64} ? "$(a)n" : a isa String ? repr(a) : string(a)
    write(joinpath(dir, "run.mjs"), """
    import fs from 'node:fs';
    import { instantiate } from $(repr(WasmCodegen.JS_HOST));
    const log = [];
    const b64 = (u8) => Buffer.from(u8).toString('base64');
    const { instance } = await instantiate(fs.readFileSync($(repr(joinpath(dir, "m.wasm")))),
                                           { imports: $libs });
    const r = [];
    $(join(("r.push(String(instance.exports.$fn($(join(map(js_arg, args), ", ")))));" for (fn, args) in calls), "\n"))
    process.stdout.write(JSON.stringify({ r, log }));
    """)
    resp = JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))
    return String[x for x in resp["r"]], String[x for x in resp["log"]]
end

# bytes for the host: `Vector{UInt8}`, `String` and `Memory{UInt8}` arguments of a declared
# import, passed as the offset and length of a copy in the linear memory
jsb_pattern(n::Int) = UInt8[(i * 7 + 3) % 256 for i in 1:n]
jsb_vector(n::Int) = (ccall((:send, "jsb_test"), Cvoid, (Vector{UInt8},), jsb_pattern(n)); n)
jsb_string(n::Int) = ccall((:text, "jsb_test"), Int32, (String,), repeat("αβc", n))
# (a vector whose first byte is not its memory's: deleted at the front)
jsb_offset(n::Int) = (v = jsb_pattern(n + 3); deleteat!(v, 1:3); ccall((:send, "jsb_test"), Cvoid, (Vector{UInt8},), v); n)
function jsb_mixed(n::Int)
    m = Memory{UInt8}(undef, 3)
    m[1] = 0x01; m[2] = 0x02; m[3] = 0xff
    return ccall((:mixed, "jsb_test"), Int64, (Int32, Vector{UInt8}, String, Int64, Memory{UInt8}),
                 Int32(-7), jsb_pattern(n), "x", Int64(n), m)
end
# (of a library named as an Object's property; a string that starts with U+FEFF)
jsb_bom(n::Int) = ccall((:text, "constructor"), Int32, (String,), string('\ufeff', "ab", n))
jsb_ints(v::Vector{Int}) = ccall((:send, "jsb_test"), Cvoid, (Vector{Int},), v)
jsb_ptr(v::Vector{UInt8}) = GC.@preserve v ccall((:send, "jsb_test"), Cvoid, (Ptr{UInt8},), pointer(v))

const JSB_LIB = """(host) => ({ jsb_test: {
  send: (p, n) => { log.push(`send \${p} \${n} ` + b64(host.bytes(p, n))); },
  text: (p, n) => { const s = host.string(p, n); log.push(`text \${p} \${n} ` + s); return s.length; },
  mixed: (a, p1, n1, p2, n2, k, p3, n3) => {
    log.push(`mixed \${a} \${k} \${p1} \${n1} \${p2} \${n2} \${p3} \${n3} ` +
             [host.bytes(p1, n1), host.bytes(p2, n2), host.bytes(p3, n3)].map(b64).join(' '));
    return BigInt(n1 + n2 + n3) + k;
  },
} })"""

# the calls logged by JSB_LIB: (name, the integers, the byte arguments)
function jsb_log(line)
    w = split(line, ' ')
    name = w[1]
    nbytes = name == "send" ? 1 : name == "mixed" ? 3 : 0
    name == "text" && return (name, parse.(Int, w[2:3]), join(w[4:end], ' '))
    nints = length(w) - 1 - nbytes
    return (name, parse.(Int, w[2:1+nints]), [base64decode(x) for x in w[2+nints:end]])
end

@testset "bytes for the host" begin
    entries = [(jsb_vector, (Int,)), (jsb_string, (Int,)), (jsb_offset, (Int,)), (jsb_mixed, (Int,))]
    c = WasmCodegen.compile(entries; config = WasmCodegen.Config(import_libraries = ["jsb_test"]))
    @test import_list(c) == [("jsb_test", "mixed", ValType[I32, I32, I32, I32, I32, I64, I32, I32], ValType[I64]),
                             ("jsb_test", "send", ValType[I32, I32], ValType[]),
                             ("jsb_test", "text", ValType[I32, I32], ValType[I32])]
    @test c.cgm.mod.memory !== nothing
    sizes = [0, 1, 7, 1024, 65536, 65537, 200_000]
    calls = vcat([("jsb_vector", Any[n]) for n in sizes], [("jsb_string", Any[n]) for n in (0, 1, 3, 30_000)],
                 [("jsb_offset", Any[n]) for n in (0, 5, 70_000)], [("jsb_mixed", Any[n]) for n in (0, 9)])
    r, log = run_js_bytes(c, JSB_LIB, calls)
    @test r == vcat(string.(sizes), [string(length(repeat("αβc", n))) for n in (0, 1, 3, 30_000)],
                    ["0", "5", "70000"], ["4", "22"])
    @test length(log) == length(calls)
    for ((fn, (n,)), line) in zip(calls, log)
        name, ints, b = jsb_log(line)
        if fn == "jsb_vector" || fn == "jsb_offset"
            # exactly the bytes, from the start of the memory
            @test name == "send" && ints == [0, n] && b == [jsb_pattern(n + (fn == "jsb_offset" ? 3 : 0))[end-n+1:end]]
        elseif fn == "jsb_string"
            s = repeat("αβc", n)
            @test name == "text" && ints == [0, sizeof(s)] && b == s
        else
            # each argument's bytes after the previous one's, from a multiple of 8
            o2 = (n + 7) & ~7
            @test name == "mixed" && ints == [-7, n, 0, n, o2, 1, o2 + 8, 3] &&
                  b == [jsb_pattern(n), Vector{UInt8}("x"), UInt8[0x01, 0x02, 0xff]]
        end
    end

    # for WASI: after the runtime's part of the memory (the same layout from there)
    c = WasmCodegen.compile([(jsb_vector, (Int,)), (jsb_string, (Int,)), (jsb_mixed, (Int,))];
                            config = WasmCodegen.Config(host = :wasi, import_libraries = ["jsb_test"]))
    r, log = run_js_bytes(c, JSB_LIB, [("jsb_vector", Any[300]), ("jsb_string", Any[2]),
                                       ("jsb_mixed", Any[0]), ("jsb_mixed", Any[9])])
    base = Int(WasmCodegen.Runtime.Staging.SIZE)
    @test r == ["300", "6", "4", "22"]
    @test jsb_log(log[1]) == ("send", [base, 300], [jsb_pattern(300)])
    @test jsb_log(log[2]) == ("text", [base, 10], "αβcαβc")
    for (n, line) in zip((0, 9), log[3:4])
        o2 = base + ((n + 7) & ~7)
        @test jsb_log(line) == ("mixed", [-7, n, base, n, o2, 1, o2 + 8, 3],
                                [jsb_pattern(n), Vector{UInt8}("x"), UInt8[0x01, 0x02, 0xff]])
    end

    # a library named as an Object's property, and a string that starts with U+FEFF (not a
    # byte order mark: the string's)
    c = WasmCodegen.compile(jsb_bom, (Int,); config = WasmCodegen.Config(import_libraries = ["constructor"]))
    lib = "(host) => ({ constructor: { text: (p, n) => { const s = host.string(p, n); log.push(`text \${p} \${n} ` + s); return s.length; } } })"
    r, log = run_js_bytes(c, lib, [("jsb_bom", Any[7])])
    @test r == ["4"] && jsb_log(log[1]) == ("text", [0, 6], "\ufeffab7")
    # entry points named as WASI's exports, which a host takes for them with the memory: refused
    for name in ("memory", "_initialize")
        @test_throws ArgumentError WasmCodegen.compile([Entry(jsb_vector, (Int,); name)];
                                                       config = WasmCodegen.Config(import_libraries = ["jsb_test"]))
    end
    @test WasmCodegen.compile([Entry(identity, (Int,); name = "_initialize")]).bytes isa Vector{UInt8}
    # (each argument from the next offset, as an i64: past 4 GiB a trap, not an offset that wraps)
    @test any(i -> i.op === :i64_gt_u, (i for f in c.cgm.mod.funcs for i in f.body))

    # other arrays, and pointers, are not bytes for the host
    for (f, at) in ((jsb_ints, (Vector{Int},)), (jsb_ptr, (Vector{UInt8},)))
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, at;
                                                                           config = WasmCodegen.Config(import_libraries = ["jsb_test"]))
    end
end

@testset "import libraries" begin
    wasi(; kw...) = WasmCodegen.Config(; host = :wasi, kw...)
    # a ccall of a declared library: the import lib.name, of the ccall's Wasm types
    add = WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi(import_libraries = ["implib_test"]))
    @test import_list(add) == [("implib_test", "add", ValType[I32, I64], ValType[I64])]
    lib = "{ implib_test: { add: (x, y) => { log.push(`add \${x} \${y}`); return BigInt(x) + y; } } }"
    @test run_import_libraries(add, "implib_add", lib, Int32(40), Int64(2)) == ("42", ["add 40 2"])
    # no result (Cvoid), an unsigned argument
    note = WasmCodegen.compile(implib_note, (UInt32,); config = wasi(import_libraries = ["implib_test"]))
    @test import_list(note) == [("implib_test", "note", ValType[I32], ValType[])]
    lib = "{ implib_test: { note: (x) => { log.push(`note \${x >>> 0}`); } } }"
    @test run_import_libraries(note, "implib_note", lib, UInt32(7)) == ("8", ["note 7"])
    # several libraries, each its own import module
    both = WasmCodegen.compile(implib_both, (Int32,); config = wasi(import_libraries = ["implib_test", "implib_other"]))
    @test import_list(both) == [("implib_other", "twice", ValType[I64], ValType[I64]),
                                ("implib_test", "add", ValType[I32, I64], ValType[I64])]
    lib = "{ implib_test: { add: (x, y) => BigInt(x) + y }, implib_other: { twice: (x) => 2n * x } }"
    @test run_import_libraries(both, "implib_both", lib, Int32(5)) == ("16", String[])

    # through a case of the runtime (compiled with the program's options)
    err = WasmCodegen.compile(implib_error_text, (UInt32,); config = wasi(import_libraries = ["implib_test"]))
    @test import_list(err) == [("implib_test", "note", ValType[I32], ValType[])]
    lib = "{ implib_test: { note: (x) => { log.push(`note \${x >>> 0}`); } } }"
    @test run_import_libraries(err, "implib_error_text", lib, UInt32(1)) == ("6", ["note 9"])

    # a library not declared is a C library, as before: unsupported
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi())
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(implib_add, (Int32, Int64);
                                                                       config = wasi(import_libraries = ["implib_other"]))
    # (with trim = :unsafe, a trap where it is, reported in the diagnostics)
    c = WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi(trim = :unsafe, on_unsupported = :trap))
    @test isempty(import_list(c)) && length(c.cgm.diagnostics) == 1
    # types other than 32- and 64-bit integers
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(implib_float, (Float64,);
                                                                       config = wasi(import_libraries = ["implib_test"]))

    # the names of WasmCodegen's own imports cannot be declared
    for name in ("wasi_snapshot_preview1", "julia", "julia_io", "julia_anything", "")
        @test_throws ArgumentError WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi(import_libraries = [name]))
    end
    # (for JavaScript too: integers are numbers and BigInts, and the module has no memory)
    js = WasmCodegen.compile(implib_add, (Int32, Int64); config = WasmCodegen.Config(import_libraries = ["implib_test"]))
    @test import_list(js) == [("implib_test", "add", ValType[I32, I64], ValType[I64])]
    @test js.cgm.mod.memory === nothing
    lib = "{ implib_test: { add: (x, y) => { log.push(`add \${x} \${y}`); return BigInt(x) + y; } } }"
    @test run_js_bytes(js, lib, [("implib_add", Any[Int32(40), Int64(2)])]) == (["42"], ["add 40 2"])
    # (an empty list changes nothing for either host)
    for host in (:js, :wasi)
        c = WasmCodegen.compile(implib_note, (UInt32,); config = WasmCodegen.Config(; host, trim = :unsafe, on_unsupported = :trap))
        @test isempty(import_list(c))
    end
end
