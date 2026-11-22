// js/macrotask.mjs where there is no setImmediate (a browser): the MessageChannel fallback runs `fn` in a
// later turn, in order, after the timers that are due, and a cancelled one does not run. And julia_io's
// events and julia_task load and run without it, and without importing node: modules.
// Prints "what: true|false" per check (test/tasks.jl).
delete globalThis.setImmediate;
delete globalThis.clearImmediate;
const { macrotask, cancelMacrotask } = await import('../js/macrotask.mjs');

const out = [];
const check = (what, ok) => out.push(`${what}: ${!!ok}`);
const ran = [];
const a = macrotask(() => ran.push('a'));
const b = macrotask(() => ran.push('b'));
const c = macrotask(() => ran.push('c'));
check('not run synchronously', ran.length === 0);
cancelMacrotask(b);
await new Promise((r) => setTimeout(r, 20));
check('run in order, the cancelled one not', ran.join('') === 'ac');
// (a macrotask that queues another: the next turn)
let nested = null;
macrotask(() => { macrotask(() => { nested = 'inner'; }); nested = 'outer'; });
await new Promise((r) => setTimeout(r, 20));
check('a macrotask queued from one runs too', nested === 'inner');
cancelMacrotask(a); // (already run: nothing)
check('cancelling one that has run is harmless', true);
const fs = process.getBuiltinModule('node:fs');
const js = (f) => fs.readFileSync(new URL('../js/' + f, import.meta.url), 'utf8');
check('julia_io, julia_task and macrotask import no node: module',
      ['julia_io.mjs', 'julia_task.mjs', 'macrotask.mjs'].every((f) => !/^\s*import[^;]*['"]node:/m.test(js(f))));
const { makeJuliaIOEvents } = await import('../js/julia_io.mjs');
await import('../js/julia_task.mjs');
const events = makeJuliaIOEvents({ memory: new WebAssembly.Memory({ initial: 1 }) });
const h = events.imports.timer_start(1_000_000n);
await new Promise((r) => setTimeout(r, 30));
check("julia_io's timers fire on the fallback (their start's turn is a macrotask)", events.handleState(h).ready);
process.stdout.write(out.join('\n') + '\n');
process.exit(0);
