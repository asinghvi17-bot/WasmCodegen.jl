// js/macrotask.mjs where there is no setImmediate (a browser): the MessageChannel fallback runs `fn` in a
// later turn, in order, after the timers that are due, and a cancelled one does not run.
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
process.stdout.write(out.join('\n') + '\n');
process.exit(0);
