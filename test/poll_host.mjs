// js/julia_io.mjs's `poll` called (through a module: it suspends) with ranges of the memory
// it has and has not: the count of the ready handles, or `-EINVAL`. Prints the failed
// checks, one per line.
import { makeJuliaIOEvents } from '../js/julia_io.mjs';

const failures = [];
const check = (what, got, want) => { if (got !== want) failures.push(`${what}: ${got}, expected ${want}`); };
const memory = new WebAssembly.Memory({ initial: 1 });
const events = makeJuliaIOEvents({ memory });
// (module (import "e" "poll" (func (param i32 i32 i64 i32 i32) (result i32)))
//   (func (export "poll") (param i32 i32 i64 i32 i32) (result i32)
//     (call 0 (local.get 0) (local.get 1) (local.get 2) (local.get 3) (local.get 4))))
const wasm = Uint8Array.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
  1, 10, 1, 0x60, 5, 0x7f, 0x7f, 0x7e, 0x7f, 0x7f, 1, 0x7f,
  2, 10, 1, 1, 0x65, 4, 0x70, 0x6f, 0x6c, 0x6c, 0, 0,
  3, 2, 1, 0,
  7, 8, 1, 4, 0x70, 0x6f, 0x6c, 0x6c, 0, 1,
  10, 16, 1, 14, 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0x10, 0, 0x0b]);
const { instance } = await WebAssembly.instantiate(wasm, { e: { poll: events.imports.poll } });
const poll = WebAssembly.promising(instance.exports.poll);
const END = memory.buffer.byteLength, EINVAL = 28;
new DataView(memory.buffer).setInt32(0, 999, true); // (a handle the host does not know: ready)

check('one handle, room for one', await poll(0, 1, 0n, END - 4, 1), 1);
check('room for two past the end', await poll(0, 1, 0n, END - 4, 2), -EINVAL);
// (a capacity whose size in bytes is no i32)
check('room for 2^30 past the end', await poll(0, 1, 0n, END - 4, 2 ** 30), -EINVAL);
check('room for 2^30 at the end', await poll(0, 1, 0n, END, 2 ** 30), -EINVAL);
check('room for 2^30 + 1 past the end', await poll(0, 1, 0n, END - 4, 2 ** 30 + 1), -EINVAL);
check('room for -1 past the end', await poll(0, 1, 0n, END - 4, -1), -EINVAL);
check('interest past the end', await poll(END - 4, 2, 0n, 16, 2), -EINVAL);

// timers overdue when a poll that waits starts, before the event loop turned: all of them
// are ready when it returns, in the order of their deadlines
{
  const dv = new DataView(memory.buffer);
  const hs = [30_000_000n, 10_000_000n, 10_000_000n].map((ns) => events.imports.timer_start(ns));
  hs.forEach((h, i) => dv.setInt32(4 * i, h, true));
  const t0 = performance.now();
  while (performance.now() - t0 < 60);
  check('overdue timers, before a turn', await poll(0, 3, 0n, 64, 3), 0);
  check('overdue timers, waited for', await poll(0, 3, -1n, 64, 3), 3);
  const got = [0, 1, 2].map((i) => dv.getInt32(64 + 4 * i, true));
  check('overdue timers, their order', got.join(), [hs[1], hs[2], hs[0]].join());
  hs.forEach((h) => events.imports.close(h));
}

// a timer armed and a timer of an earlier deadline started after the loop turned, both overdue
{
  const dv = new DataView(memory.buffer);
  const a = events.imports.timer_start(80_000_000n);
  await new Promise((r) => setImmediate(r));
  const b = events.imports.timer_start(10_000_000n);
  dv.setInt32(0, a, true); dv.setInt32(4, b, true);
  const t0 = performance.now();
  while (performance.now() - t0 < 100);
  check('an armed and a starting timer, waited for', await poll(0, 2, -1n, 64, 2), 2);
  check('an armed and a starting timer, their order', [dv.getInt32(64, true), dv.getInt32(68, true)].join(), [b, a].join());
  [a, b].forEach((h) => events.imports.close(h));
}

// the same within a poll with a timeout, which elapses before the loop turns
{
  const dv = new DataView(memory.buffer);
  const spin = (ms) => { const end = performance.now() + ms; while (performance.now() < end); };
  const a = events.imports.timer_start(80_000_000n);
  await new Promise((r) => setImmediate(r));
  await new Promise((done) => setImmediate(async () => {
    const b = events.imports.timer_start(10_000_000n);
    dv.setInt32(0, a, true); dv.setInt32(4, b, true);
    spin(100);
    const p = poll(0, 2, 1_000_000n, 64, 2);
    spin(10);
    check('an armed and a starting timer, the timeout elapsed', await p, 2);
    check('an armed and a starting timer, the timeout elapsed, their order', [dv.getInt32(64, true), dv.getInt32(68, true)].join(), [b, a].join());
    [a, b].forEach((h) => events.imports.close(h));
    done();
  }));
}

// a timeout shorter than the clock's resolution
{
  const h = events.imports.timer_start(200_000_000n);
  new DataView(memory.buffer).setInt32(0, h, true);
  const t0 = performance.now();
  check('a timeout of a nanosecond', await poll(0, 1, 1n, 64, 1), 0);
  check('a timeout of a nanosecond, in time', performance.now() - t0 < 100, true);
  events.imports.close(h);
}

if (failures.length) console.log(failures.join('\n'));
