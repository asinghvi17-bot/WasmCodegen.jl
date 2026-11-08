// The embedder's handles of js/julia_io.mjs (`events.external`, `ready`, `polling`), as a host library uses them,
// without a Julia module: `poll` is called from a tiny Wasm module that only forwards to the import (a suspension
// needs a Wasm frame under WebAssembly.promising). Prints "what: true|false" per check (test/tasks.jl).
import { makeJuliaIOEvents } from '../js/julia_io.mjs';

const mem = new WebAssembly.Memory({ initial: 1 });
const events = makeJuliaIOEvents({ memory: mem });
const dv = new DataView(mem.buffer);
const out = [];
const check = (what, ok) => out.push(`${what}: ${!!ok}`);

let closed = 0, cancelled = 0;
const a = events.external({ onClose: () => { closed++; } });
const b = events.external({ onCancel: () => { cancelled++; } });
check('a pending external handle is not ready', events.handleState(a).ready === false && events.handleState(a).kind === 'external');
check('ready makes it ready (once)', events.ready(a) === true && events.handleState(a).ready && events.ready(a) === true);
function pollModule() {
  // (module (import "io" "poll" (func $p (param i32 i32 i64 i32 i32) (result i32)))
  //         (memory (import "io" "mem") 1) (func (export "poll") (param i32 i32 i64 i32 i32) (result i32)
  //           local.get 0 local.get 1 local.get 2 local.get 3 local.get 4 call $p))
  const type = [0x60, 5, 0x7f, 0x7f, 0x7e, 0x7f, 0x7f, 1, 0x7f];
  const sec = (id, body) => [id, body.length, ...body];
  const str = (s) => [s.length, ...[...s].map((c) => c.charCodeAt(0))];
  const types = sec(1, [1, ...type]);
  const imports = sec(2, [2, ...str('io'), ...str('poll'), 0, 0, ...str('io'), ...str('mem'), 2, 0, 1]);
  const funcs = sec(3, [1, 0]);
  const exps = sec(7, [1, ...str('poll'), 0, 1]);
  const body = [0, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0x10, 0, 0x0b];
  const code = sec(10, [1, body.length, ...body]);
  return new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, ...types, ...imports, ...funcs, ...exps, ...code]);
}
const inst = new WebAssembly.Instance(new WebAssembly.Module(pollModule()), { io: { poll: events.imports.poll, mem } });
const poll = WebAssembly.promising(inst.exports.poll);
// interest [a, b] at 0, out at 64
const pollOf = async (hs, timeout) => {
  hs.forEach((h, i) => dv.setInt32(4 * i, h, true));
  const n = await poll(0, hs.length, BigInt(timeout), 64, 8);
  return [...Array(Math.max(n, 0))].map((_, i) => dv.getInt32(64 + 4 * i, true));
};
check('a poll finds the ready one only', JSON.stringify(await pollOf([a, b], 0)) === JSON.stringify([a]));
// a poll that suspends until b is ready
setTimeout(() => events.ready(b), 20);
const t0 = performance.now();
const pending = pollOf([b], -1);
await new Promise((r) => setTimeout(r, 5));
const wasPolling = events.polling();
const got = await pending;
check('an indefinite poll waits until ready() (polling() meanwhile)', wasPolling && !events.polling() && got[0] === b && performance.now() - t0 >= 15);
const c = events.external({ onCancel: () => { cancelled++; } });
events.imports.cancel(c);
check('cancel: ready, cancelled, onCancel', events.handleState(c).ready && events.handleState(c).cancelled && cancelled === 1);
events.imports.close(a);
check('close: onClose, and ready() of a closed handle is false', closed === 1 && events.ready(a) === false);
// a poll of pending externals only does not fail (they can become ready)
const d = events.external({ onClose: () => { closed++; } });
setTimeout(() => events.ready(d), 5);
check('a pending external handle can become ready (no EINVAL)', (await pollOf([d], -1))[0] === d);
const e = events.external({ onClose: () => { closed++; } });
events.stop();
check('stop: the open external handles closed', closed === 3);
process.stdout.write(out.join('\n') + '\n');
