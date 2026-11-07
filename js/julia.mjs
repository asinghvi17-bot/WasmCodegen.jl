// The JavaScript host of modules compiled by WasmCodegen (src/host.jl). A module compiled
// with `Config(host = :js)` (the default) imports the functions of the module "julia"; one
// compiled with `host = :wasi` imports WASI preview 1 ("wasi_snapshot_preview1"), which
// WASI runtimes (wasmtime, wasmer, Node's node:wasi) provide, and which this file provides
// too, for hosts without it (browsers, Cloudflare Workers): the arguments, the environment,
// the clocks, randomness and the standard streams. It has no filesystem: no directory is
// preopened, stdin is empty, and the other descriptors are errnos (`EBADF`).
//
//   import { instantiate } from './julia.mjs';
//   const { instance } = await instantiate(bytes);   // the module's output to the console
//   instance.exports.f(1.0);
//
// `instantiate` takes the module's bytes, a `Response`, or a compiled `WebAssembly.Module`
// (hosts that compile only ahead of time, as Workers do, import the module compiled).
//
// Options: `write(fd, bytes)` receives the module's output (fd 1: stdout, 2: stderr), a
// Uint8Array of UTF-8; by default it is written to the console line by line. `args` (an
// array of strings) and `env` (an object of strings) are WASI's arguments and environment
// (a WasmCodegen module reads the environment, not yet the arguments: its `ARGS` are still
// those of the process that compiled it).
//
// `imports` are the functions of the libraries the program declares (`Config(import_libraries)`),
// as import modules (`{ lib: { name: f } }`), or a function of the host returning them. A
// `Vector{UInt8}`, `String` or `Memory{UInt8}` argument of one is two arguments, the offset and
// the length of its bytes in the module's memory, which `host.bytes(offset, length)` gives as a
// Uint8Array (and `host.string(offset, length)` decoded from UTF-8). The bytes are the
// argument's until the function returns, or until it calls the module: copy them to keep them.
//
//   const { instance } = await instantiate(bytes, {
//     imports: (host) => ({ mylib: { send: (p, n) => deliver(host.bytes(p, n).slice()) } }),
//   });

const WASI_EBADF = 8, WASI_EINVAL = 28, WASI_ENOSYS = 52, WASI_ENOTDIR = 54, WASI_ENOTSOCK = 57,
  WASI_ENOTSUP = 58, WASI_ESPIPE = 70;
const FILETYPE_CHARACTER_DEVICE = 2;
const FDFLAG_APPEND = 1, FDFLAG_NONBLOCK = 4;
const FSTFLAG_ATIM = 1, FSTFLAG_ATIM_NOW = 2, FSTFLAG_MTIM = 4, FSTFLAG_MTIM_NOW = 8;
const RIGHT_FD_READ = 1n << 1n, RIGHT_FD_FDSTAT_SET_FLAGS = 1n << 3n, RIGHT_FD_WRITE = 1n << 6n,
  RIGHT_FD_FILESTAT_SET_TIMES = 1n << 23n, RIGHT_POLL_FD_READWRITE = 1n << 27n;

// The WASI preview 1 functions, all provided: those of a filesystem or sockets are errnos,
// as are `poll_oneoff` and the CPU-time clocks, which node:wasi has (WasmCodegen's runtime
// calls none of them)
const WASI_FUNCTIONS = [
  'args_get', 'args_sizes_get', 'environ_get', 'environ_sizes_get', 'clock_res_get', 'clock_time_get',
  'fd_advise', 'fd_allocate', 'fd_close', 'fd_datasync', 'fd_fdstat_get', 'fd_fdstat_set_flags',
  'fd_fdstat_set_rights', 'fd_filestat_get', 'fd_filestat_set_size', 'fd_filestat_set_times', 'fd_pread',
  'fd_prestat_get', 'fd_prestat_dir_name', 'fd_pwrite', 'fd_read', 'fd_readdir', 'fd_renumber', 'fd_seek',
  'fd_sync', 'fd_tell', 'fd_write', 'path_create_directory', 'path_filestat_get', 'path_filestat_set_times',
  'path_link', 'path_open', 'path_readlink', 'path_remove_directory', 'path_rename', 'path_symlink',
  'path_unlink_file', 'poll_oneoff', 'proc_exit', 'proc_raise', 'sched_yield', 'random_get', 'sock_accept',
  'sock_recv', 'sock_send', 'sock_shutdown',
];

/** `proc_exit(code)` of a WASI module: thrown out of the call that exits. */
export class WasiExit extends Error {
  constructor(code) {
    super(`exit with code ${code >>> 0}`);
    this.code = code >>> 0;
  }
}

// writes to the console, a line at a time, in the order written: an unfinished line is
// written when the other stream is written to, and by `flush()`
function consoleWriter() {
  const decoder = new TextDecoder();
  let fd = 1, buf = [];
  const emit = () => {
    (fd === 2 ? console.error : console.log)(decoder.decode(new Uint8Array(buf)));
    buf = [];
  };
  const write = (to, bytes) => {
    if (to !== fd) { if (buf.length) emit(); fd = to; }
    for (const b of bytes) {
      if (b === 10) emit();
      else buf.push(b);
    }
  };
  write.flush = () => { if (buf.length) emit(); };
  return write;
}

// the host clocks, in nanoseconds: monotonic, and since the Unix epoch
const monotonicNs = () => BigInt(Math.round(performance.now() * 1e6));
const realtimeNs = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

function fillRandom(bytes) {
  // getRandomValues fills at most 65536 bytes at a time
  for (let i = 0; i < bytes.length; i += 65536) crypto.getRandomValues(bytes.subarray(i, i + 65536));
}

// NUL-terminated UTF-8 strings, for args_get and environ_get
const cStrings = (strs) => strs.map((x) => new TextEncoder().encode(x + '\0'));

/**
 * The imports of a module (both interfaces), to instantiate it with:
 * `{ imports, attach(instance), flush(), bytes(offset, length), string(offset, length) }`.
 * `attach` gives the host the instance's memory, if it exports one (a WASI module, or one
 * passing bytes to `imports`), and runs a WASI module's initialization (`_initialize`), as
 * WASI hosts do; a JavaScript module initializes as it is instantiated.
 */
export function createHost({ write, args = [], env = {}, imports = {} } = {}) {
  const out = write ?? consoleWriter();
  const argv = cStrings(args.map(String));
  // (an undefined value is no variable, as for Node's WASI)
  const environ = cStrings(Object.entries(env).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}=${v}`));
  let memory = null;
  const view = () => new DataView(memory.buffer);
  const julia = {
    write_byte: (fd, b) => out(fd, Uint8Array.of(b)),
    entropy: () => {
      const w = new BigUint64Array(1);
      crypto.getRandomValues(w);
      return BigInt.asIntN(64, w[0]);
    },
    hrtime: monotonicNs,
    // seconds since the Unix epoch, to the microsecond (as gettimeofday's)
    clock_now: () => {
      const t = realtimeNs();
      return Number(t / 1000000000n) + Number((t % 1000000000n) / 1000n) * 1e-6;
    },
  };
  const sizes = (strs, countPtr, sizePtr) => {
    const v = view();
    v.setUint32(countPtr, strs.length, true);
    v.setUint32(sizePtr, strs.reduce((n, x) => n + x.length, 0), true);
    return 0;
  };
  const strings = (strs, ptrs, buf) => {
    const v = view(), bytes = new Uint8Array(memory.buffer);
    strs.forEach((x, i) => {
      v.setUint32(ptrs + 4 * i, buf, true);
      bytes.set(x, buf);
      buf += x.length;
    });
    return 0;
  };
  // the standard streams, until the module closes them
  const open = new Set([0, 1, 2]);
  const isStdio = (fd) => open.has(fd);
  // a function of a descriptor: no other descriptor than the standard streams is open
  const onFd = (f = () => WASI_ENOTSUP) => (fd, ...a) => (isStdio(fd) ? f(fd, ...a) : WASI_EBADF);
  // what the module set of each stream: its flags (append, nonblocking: the others no stream
  // keeps, natively) and its times
  const streams = [0, 1, 2].map(() => ({ flags: 0, atim: 0n, mtim: 0n, ctim: 0n }));
  const clockNs = (id) => (id === 0 ? realtimeNs() : id === 1 ? monotonicNs() : null);
  const wasi = {
    args_sizes_get: (countPtr, sizePtr) => sizes(argv, countPtr, sizePtr),
    args_get: (ptrs, buf) => strings(argv, ptrs, buf),
    environ_sizes_get: (countPtr, sizePtr) => sizes(environ, countPtr, sizePtr),
    environ_get: (ptrs, buf) => strings(environ, ptrs, buf),
    fd_write: onFd((fd, iovs, iovsLen, nwrittenPtr) => {
      if (fd === 0) return WASI_EBADF;
      let n = 0;
      // (the memory read again after each write: `write` may grow it)
      for (let i = 0; i < iovsLen; i++) {
        const v = view();
        const ptr = v.getUint32(iovs + 8 * i, true), len = v.getUint32(iovs + 8 * i + 4, true);
        out(fd, new Uint8Array(memory.buffer, ptr, len).slice());
        n += len;
      }
      view().setUint32(nwrittenPtr, n, true);
      return 0;
    }),
    // (stdin is empty: the end of the file)
    fd_read: onFd((fd, iovs, iovsLen, nreadPtr) => {
      if (fd !== 0) return WASI_EBADF;
      view().setUint32(nreadPtr, 0, true);
      return 0;
    }),
    fd_fdstat_get: onFd((fd, ptr) => {
      const v = view();
      new Uint8Array(memory.buffer, ptr, 24).fill(0);
      v.setUint8(ptr, FILETYPE_CHARACTER_DEVICE);
      v.setUint16(ptr + 2, streams[fd].flags, true);
      v.setBigUint64(ptr + 8, (fd === 0 ? RIGHT_FD_READ : RIGHT_FD_WRITE) | RIGHT_FD_FDSTAT_SET_FLAGS |
                              RIGHT_FD_FILESTAT_SET_TIMES | RIGHT_POLL_FD_READWRITE, true);
      return 0;
    }),
    fd_filestat_get: onFd((fd, ptr) => {
      new Uint8Array(memory.buffer, ptr, 64).fill(0);
      const v = view(), s = streams[fd];
      v.setUint8(ptr + 16, FILETYPE_CHARACTER_DEVICE);
      v.setBigUint64(ptr + 24, 1n, true);
      v.setBigUint64(ptr + 40, s.atim, true);
      v.setBigUint64(ptr + 48, s.mtim, true);
      v.setBigUint64(ptr + 56, s.ctim, true);
      return 0;
    }),
    // (the errnos of a terminal's or a pipe's descriptor, natively)
    fd_seek: onFd(() => WASI_ESPIPE),
    fd_tell: onFd(() => WASI_ESPIPE),
    fd_pread: onFd(() => WASI_ESPIPE),
    fd_pwrite: onFd(() => WASI_ESPIPE),
    fd_sync: onFd(() => WASI_EINVAL),
    fd_datasync: onFd(() => WASI_EINVAL),
    fd_filestat_set_size: onFd(() => WASI_EINVAL),
    fd_readdir: onFd(() => WASI_ENOTDIR),
    // (a stream closed is EBADF from then on)
    fd_close: onFd((fd) => { open.delete(fd); return 0; }),
    // (no directory is preopened: the descriptors after the standard streams are not open)
    fd_prestat_get: () => WASI_EBADF,
    fd_prestat_dir_name: () => WASI_EBADF,
    random_get(ptr, len) {
      fillRandom(new Uint8Array(memory.buffer, ptr, len));
      return 0;
    },
    clock_time_get(id, precision, ptr) {
      const t = clockNs(id);
      if (t === null) return WASI_EINVAL;
      view().setBigUint64(ptr, t, true);
      return 0;
    },
    // (a millisecond: hosts may coarsen `performance.now()` to it)
    clock_res_get(id, ptr) {
      if (clockNs(id) === null) return WASI_EINVAL;
      view().setBigUint64(ptr, 1000000n, true);
      return 0;
    },
    sched_yield: () => 0,
    // (the output written, as natively at an exit)
    proc_exit(code) { out.flush?.(); throw new WasiExit(code); },
    proc_raise: () => WASI_ENOSYS,
    poll_oneoff: () => WASI_ENOSYS,
    // (on a terminal or a pipe natively: its flags and times set, no advice or space for it)
    fd_fdstat_set_flags: onFd((fd, flags) => { streams[fd].flags = flags & (FDFLAG_APPEND | FDFLAG_NONBLOCK); return 0; }),
    fd_filestat_set_times: onFd((fd, atim, mtim, fst) => {
      if (fst & ~(FSTFLAG_ATIM | FSTFLAG_ATIM_NOW | FSTFLAG_MTIM | FSTFLAG_MTIM_NOW) ||
          (fst & FSTFLAG_ATIM && fst & FSTFLAG_ATIM_NOW) || (fst & FSTFLAG_MTIM && fst & FSTFLAG_MTIM_NOW)) return WASI_EINVAL;
      const s = streams[fd], now = realtimeNs();
      if (fst & FSTFLAG_ATIM) s.atim = BigInt.asUintN(64, atim); else if (fst & FSTFLAG_ATIM_NOW) s.atim = now;
      if (fst & FSTFLAG_MTIM) s.mtim = BigInt.asUintN(64, mtim); else if (fst & FSTFLAG_MTIM_NOW) s.mtim = now;
      s.ctim = now;
      return 0;
    }),
    fd_advise: onFd(() => WASI_ESPIPE),
    fd_allocate: onFd(() => WASI_ESPIPE),
    // (its directory's descriptor is its third argument)
    path_symlink: (oldPath, oldLen, fd) => (isStdio(fd) ? WASI_ENOTDIR : WASI_EBADF),
  };
  for (const name of WASI_FUNCTIONS) {
    if (name in wasi) continue;
    // a path is relative to a directory's descriptor: none is open; no stream is a socket
    wasi[name] = onFd(name.startsWith('path_') ? () => WASI_ENOTDIR :
                      name.startsWith('sock_') ? () => WASI_ENOTSOCK : undefined);
  }
  const host = {
    imports: { julia, wasi_snapshot_preview1: wasi },
    attach(instance) {
      if (!(instance.exports.memory instanceof WebAssembly.Memory)) return;
      memory = instance.exports.memory;
      instance.exports._initialize?.();
    },
    flush() { out.flush?.(); },
    // the bytes of an argument of a declared import, in the memory (a view: the memory's
    // buffer is another once the module grows it)
    bytes: (offset, length) => new Uint8Array(memory.buffer, offset >>> 0, length >>> 0),
    string: (offset, length) => new TextDecoder().decode(host.bytes(offset, length)),
  };
  for (const [lib, funcs] of Object.entries(typeof imports === 'function' ? imports(host) : imports)) {
    if (lib in host.imports) throw new Error(`imports: "${lib}" is a module of the host's own`);
    host.imports[lib] = funcs;
  }
  return host;
}

/**
 * Instantiate a module with this host, compiling it first if it is bytes or a Response:
 * `{ module, instance, host }`. `options` are `createHost`'s.
 */
export async function instantiate(source, options = {}) {
  const module = source instanceof WebAssembly.Module ? source :
    typeof Response !== 'undefined' && source instanceof Response ? await WebAssembly.compileStreaming(source) :
    await WebAssembly.compile(source);
  const host = createHost(options);
  const instance = await WebAssembly.instantiate(module, host.imports);
  host.attach(instance);
  return { module, instance, host };
}
