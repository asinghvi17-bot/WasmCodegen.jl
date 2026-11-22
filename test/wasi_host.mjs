// js/julia.mjs's WASI functions called directly, on a memory with sentinel bytes around each
// output: their records, errnos and strings. Prints the failed checks, one per line.
import { createHost, WasiExit } from '../js/julia.mjs';

const failures = [];
const check = (what, got, want) => {
  const g = JSON.stringify(got, (k, v) => (typeof v === 'bigint' ? `${v}n` : v)), w = JSON.stringify(want, (k, v) => (typeof v === 'bigint' ? `${v}n` : v));
  if (g !== w) failures.push(`${what}: ${g}, expected ${w}`);
};
const SENTINEL = 0xa5;
const memory = new WebAssembly.Memory({ initial: 1 });
const out = [];
// (an undefined value is no variable)
const host = createHost({ args: ['prog', '', 'ünï'], env: { A: '1', EMPTY: '', GONE: undefined, U: 'λ=x' },
                         write: (fd, b) => out.push([fd, ...b]) });
host.attach({ exports: { memory } });
const w = host.imports.wasi_snapshot_preview1;
const bytes = () => new Uint8Array(memory.buffer);
const view = () => new DataView(memory.buffer);
const fresh = () => bytes().fill(SENTINEL);
const untouched = (what, from, to) => check(`${what}: bytes outside the output`, bytes().slice(from, to).every((x) => x === SENTINEL), true);

// args and the environment: counts, sizes, pointers, NUL-terminated UTF-8
for (const [what, sizes, get, want] of [['args', w.args_sizes_get, w.args_get, ['prog', '', 'ünï']],
                                        ['environ', w.environ_sizes_get, w.environ_get, ['A=1', 'EMPTY=', 'U=λ=x']]]) {
  fresh();
  check(`${what}_sizes_get`, sizes(0, 4), 0);
  const n = view().getUint32(0, true), size = view().getUint32(4, true);
  const enc = want.map((x) => new TextEncoder().encode(x + '\0'));
  check(`${what} count and size`, [n, size], [want.length, enc.reduce((a, x) => a + x.length, 0)]);
  check(`${what}_get`, get(100, 200), 0);
  const ptrs = [...Array(n)].map((_, i) => view().getUint32(100 + 4 * i, true));
  const strs = ptrs.map((p) => { let e = p; while (bytes()[e] !== 0) e++; return new TextDecoder().decode(bytes().slice(p, e)); });
  check(`${what} strings`, strs, want);
  untouched(what, 200 + size, 300 + size);
}

// the standard streams: a character device; stdin empty
fresh();
check('fd_fdstat_get(1)', w.fd_fdstat_get(1, 8), 0);
check('fdstat', [view().getUint8(8), view().getUint16(10, true), view().getBigUint64(16, true) & (1n << 6n), view().getBigUint64(24, true)], [2, 0, 1n << 6n, 0n]);
untouched('fdstat', 32, 64); untouched('fdstat', 0, 8);
fresh();
check('fd_filestat_get(2)', w.fd_filestat_get(2, 8), 0);
check('filestat', [view().getUint8(8 + 16), view().getBigUint64(8 + 24, true), view().getBigUint64(8 + 32, true)], [2, 1n, 0n]);
untouched('filestat', 72, 128); untouched('filestat', 0, 8);
fresh();
view().setUint32(0, 64, true); view().setUint32(4, 16, true);
check('fd_read(0)', [w.fd_read(0, 0, 1, 32), view().getUint32(32, true)], [0, 0]);
check('fd_read(1)', w.fd_read(1, 0, 1, 32), 8);
bytes().set([104, 105], 64);
view().setUint32(0, 64, true); view().setUint32(4, 2, true);
check('fd_write(2)', [w.fd_write(2, 0, 1, 32), view().getUint32(32, true), out.at(-1)], [0, 2, [2, 104, 105]]);
check('fd_write(0)', w.fd_write(0, 0, 1, 32), 8);
check('fd_seek(1)', w.fd_seek(1, 0n, 0, 32), 70);
check('fd_tell(0)', w.fd_tell(0, 32), 70);
// (as a terminal's or a pipe's natively)
check('fd_pread(0)', w.fd_pread(0, 0, 1, 0n, 32), 70);
check('fd_pwrite(1)', w.fd_pwrite(1, 0, 1, 0n, 32), 70);
check('fd_sync(1)', w.fd_sync(1), 28);
check('fd_datasync(2)', w.fd_datasync(2), 28);
check('fd_filestat_set_size(1)', w.fd_filestat_set_size(1, 0n), 28);
check('fd_readdir(1)', w.fd_readdir(1, 64, 16, 0n, 32), 54);
check('sock_recv(1)', w.sock_recv(1, 0, 1, 0, 32, 48), 57);
// a stream's flags and times, as set (of the flags, those a stream keeps natively)
check('fd_fdstat_set_flags(1)', w.fd_fdstat_set_flags(1, 4 | 16), 0);
check('fd_fdstat_get(1) after', [w.fd_fdstat_get(1, 8), view().getUint16(10, true)], [0, 4]);
check('fd_filestat_set_times(1, both now and given)', w.fd_filestat_set_times(1, 0n, 0n, 1 | 2), 28);
check('fd_filestat_set_times(1, an unknown flag)', w.fd_filestat_set_times(1, 100n, 200n, 1 | 16), 28);
check('fd_filestat_set_times(1)', w.fd_filestat_set_times(1, 100n, 200n, 1 | 4), 0);
check('fd_filestat_get(1) after', [w.fd_filestat_get(1, 8), view().getBigUint64(8 + 40, true), view().getBigUint64(8 + 48, true)],
      [0, 100n, 200n]);
check('fd_filestat_set_times(1, mtime now)', w.fd_filestat_set_times(1, 0n, 0n, 8), 0);
check('mtime now', w.fd_filestat_get(1, 8) === 0 && view().getBigUint64(8 + 40, true) === 100n &&
      Math.abs(Number(view().getBigUint64(8 + 48, true)) / 1e9 - Date.now() / 1000) < 60, true);
check('fd_advise(0)', w.fd_advise(0, 0n, 0n, 0), 70);
check('fd_allocate(1)', w.fd_allocate(1, 0n, 1n), 70);
check('fd_fdstat_set_flags(3)', w.fd_fdstat_set_flags(3, 0), 8);

// no other descriptor is open; no directory is preopened
check('fd_prestat_get(3)', w.fd_prestat_get(3, 0), 8);
check('fd_write(3)', w.fd_write(3, 0, 1, 32), 8);
check('fd_close(5)', w.fd_close(5), 8);
check('path_open(3)', w.path_open(3, 0, 64, 2, 0, 0n, 0n, 0, 32), 8);
check('path_open(1)', w.path_open(1, 0, 64, 2, 0, 0n, 0n, 0, 32), 54);
check('path_symlink(.., fd 1, ..)', w.path_symlink(64, 2, 1, 64, 2), 54);
check('path_symlink(.., fd 9, ..)', w.path_symlink(1, 2, 9, 64, 2), 8);
check('poll_oneoff', w.poll_oneoff(0, 32, 1, 48), 52);
check('sock_recv(3)', w.sock_recv(3, 0, 1, 0, 32, 48), 8);
// a standard stream closed: closed as natively
check('fd_close(1)', w.fd_close(1), 0);
check('closed: fd_write(1)', w.fd_write(1, 0, 1, 32), 8);
check('closed: fd_fdstat_get(1)', w.fd_fdstat_get(1, 8), 8);
check('closed: fd_close(1)', w.fd_close(1), 8);
check('fd_write(2) after', w.fd_write(2, 0, 1, 32), 0);

// the clocks; after the memory grows
memory.grow(1);
fresh();
check('clock_time_get(0)', w.clock_time_get(0, 1n, 65536 + 8), 0);
const t = Number(view().getBigUint64(65536 + 8, true)) / 1e9;
check('realtime', Math.abs(t - Date.now() / 1000) < 60, true);
check('clock_res_get(1)', [w.clock_res_get(1, 65536 + 8), view().getBigUint64(65536 + 8, true)], [0, 1000000n]);
check('clock_time_get(2)', w.clock_time_get(2, 1n, 8), 28);
check('clock_res_get(3)', w.clock_res_get(3, 8), 28);
check('sched_yield', w.sched_yield(), 0);

// proc_exit: thrown, its code unsigned, the output flushed first
let flushed = 0;
const exiting = createHost({ write: Object.assign(() => {}, { flush: () => flushed++ }) });
exiting.attach({ exports: { memory } });
for (const [code, want] of [[3, 3], [-1, 4294967295]]) {
  try { exiting.imports.wasi_snapshot_preview1.proc_exit(code); failures.push(`proc_exit(${code}) returned`); }
  catch (e) { check(`proc_exit(${code})`, [e instanceof WasiExit, e.code], [true, want]); }
}
check('flushes at proc_exit', flushed, 2);

// a write that grows the memory: the next iovec and the count written read from the new one
const growing = new WebAssembly.Memory({ initial: 1 });
const grown = [];
const gh = createHost({ write: (fd, b) => { grown.push([...b]); growing.grow(1); } });
gh.attach({ exports: { memory: growing } });
{
  const v = new DataView(growing.buffer), b = new Uint8Array(growing.buffer);
  b.set([104, 105], 100); b.set([33], 200);
  v.setUint32(0, 100, true); v.setUint32(4, 2, true); v.setUint32(8, 200, true); v.setUint32(12, 1, true);
}
check('fd_write growing the memory', gh.imports.wasi_snapshot_preview1.fd_write(1, 0, 2, 16), 0);
check('written', [grown, new DataView(growing.buffer).getUint32(16, true)], [[[104, 105], [33]], 3]);

// a range outside the memory: EFAULT, nothing written to the stream or the memory
{
  const EFAULT = 21, END = memory.buffer.byteLength, out = [];
  const fh = createHost({ env: { A: '1' }, write: (fd, b) => out.push([fd, ...b]) });
  fh.attach({ exports: { memory } });
  const w = fh.imports.wasi_snapshot_preview1;
  fresh();
  view().setUint32(0, 100, true); view().setUint32(4, 2, true);          // a good iovec
  view().setUint32(8, END - 4, true); view().setUint32(12, 100, true);   // its bytes past the end
  check('fd_write: bytes outside the memory', w.fd_write(1, 0, 2, 16), EFAULT);
  check('fd_write: iovecs outside the memory', w.fd_write(1, END - 4, 1, 16), EFAULT);
  check('fd_write: count outside the memory', w.fd_write(1, 0, 1, END - 2), EFAULT);
  check('fd_write: more iovecs than the memory holds', w.fd_write(1, 0, 0x7fffffff, 16), EFAULT);
  check('nothing written', out, []);
  for (const [what, f] of [['fd_read', () => w.fd_read(0, 0, 0, END - 2)], ['random_get', () => w.random_get(END - 4, 100)],
                           ['random_get, negative', () => w.random_get(-8, 4)],
                           ['clock_time_get', () => w.clock_time_get(0, 0n, END - 4)], ['clock_res_get', () => w.clock_res_get(0, END - 4)],
                           ['fd_fdstat_get', () => w.fd_fdstat_get(1, END - 8)], ['fd_filestat_get', () => w.fd_filestat_get(1, END - 8)],
                           ['args_sizes_get', () => w.args_sizes_get(END - 2, 0)], ['environ_get', () => w.environ_get(END - 2, 0)]]) {
    check(`${what}: outside the memory`, f(), EFAULT);
  }
  // (nothing written before the range that is outside: the count, the pointers, the strings)
  const ah = createHost({ args: ['a', 'b'] });
  ah.attach({ exports: { memory } });
  const aw = ah.imports.wasi_snapshot_preview1;
  fresh();
  check('args_sizes_get: the size outside the memory', aw.args_sizes_get(0, END - 2), EFAULT);
  check('args_get: the strings outside the memory', aw.args_get(0, END - 2), EFAULT);
  check('args_get: the pointers outside the memory', aw.args_get(END - 4, 16), EFAULT);
  check('nothing written to the memory', Array.from(new Uint8Array(memory.buffer, 0, 32)), Array(32).fill(SENTINEL));
  // (the iovecs of a read, and their buffers, though nothing is read into them)
  check('fd_read: iovecs outside the memory', w.fd_read(0, END - 4, 1, 0), EFAULT);
  view().setUint32(32, END - 4, true); view().setUint32(36, 100, true);
  check('fd_read: a buffer outside the memory', w.fd_read(0, 32, 1, 0), EFAULT);
  check('fd_read: no count written', view().getUint32(0, true), 0xa5a5a5a5);
  view().setUint32(36, 4, true);
  check('fd_read: a buffer at the end of the memory', [w.fd_read(0, 32, 1, 0), view().getUint32(0, true)], [0, 0]);
  check('random_get: an empty range at the end of the memory', w.random_get(END, 0), 0);
  check('random_get: an empty range past it', w.random_get(END + 1, 0), EFAULT);
}
// offsets of the upper half of a memory of more than 2 GiB: negative i32s here
{
  const big = new WebAssembly.Memory({ initial: 32769 }), out = [];
  const bh = createHost({ write: (fd, b) => out.push([fd, ...b]) });
  bh.attach({ exports: { memory: big } });
  const w = bh.imports.wasi_snapshot_preview1, v = new DataView(big.buffer);
  const HALF = 0x80000000, END = big.buffer.byteLength, i32 = (x) => x | 0;
  check('clock_res_get: an offset over 2^31', [w.clock_res_get(0, i32(HALF)), v.getBigUint64(HALF, true)], [0, 1000000n]);
  check('random_get: an offset over 2^31', w.random_get(i32(HALF), 1), 0);
  check('random_get: an empty range at the end of the memory', w.random_get(i32(END), 0), 0);
  check('random_get: past the end of the memory', w.random_get(i32(END - 4), 8), 21);
  check('fd_fdstat_get: an offset over 2^31', [w.fd_fdstat_get(1, i32(HALF + 64)), v.getUint8(HALF + 64)], [0, 2]);
  v.setUint32(HALF + 16, HALF + 32, true); v.setUint32(HALF + 20, 2, true);
  new Uint8Array(big.buffer).set([104, 105], HALF + 32);
  check('fd_write: offsets over 2^31', [w.fd_write(1, i32(HALF + 16), 1, i32(HALF + 40)), v.getUint32(HALF + 40, true), out], [0, 2, [[1, 104, 105]]]);
  check('environ_sizes_get: offsets over 2^31', [w.environ_sizes_get(i32(HALF + 48), i32(HALF + 52)), v.getUint32(HALF + 48, true)], [0, 0]);
}
{
  // (an error of the host's `write` is not the module's)
  const failing = createHost({ write: () => { throw new RangeError('host'); } });
  failing.attach({ exports: { memory } });
  view().setUint32(0, 100, true); view().setUint32(4, 2, true);
  let thrown = null;
  try { failing.imports.wasi_snapshot_preview1.fd_write(1, 0, 1, 16); } catch (e) { thrown = e.message; }
  check('an error of write', thrown, 'host');
}
process.stdout.write(failures.map((f) => f + '\n').join(''));
