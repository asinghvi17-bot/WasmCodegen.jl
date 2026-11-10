// node run.mjs [jsbytes.wasm]: a message built in Julia, given to JavaScript in one call of
// the page's function `page.message`, and read 4 bytes per call of an export as before: the
// same bytes both ways, and the time of each for a message of 1 KiB
import fs from 'node:fs';
import { instantiate } from '../../js/julia.mjs';
const dir = new URL('.', import.meta.url).pathname;
let received = null;
const { instance } = await instantiate(fs.readFileSync(process.argv[2] ?? dir + 'jsbytes.wasm'), {
  imports: (host) => ({
    page: {
      // (a copy: the view is of the module's memory, which holds the message only until this returns)
      message: (offset, length) => { received = host.bytes(offset, length).slice(); },
      log: (offset, length) => console.log('from Julia:', host.string(offset, length)),
    },
  }),
});
const e = instance.exports;

// in one call
const push = () => { e.send_message(); return received; };
// by calls of an export, 4 bytes each
const pull = (n) => {
  const words = Int32Array.from({ length: Math.ceil(n / 4) }, (_, i) => e.message_word(i + 1));
  return new Uint8Array(words.buffer, 0, n);
};

const expected = (n) => Uint8Array.from({ length: n }, (_, i) => ((i + 1) * 7 + 3) & 255);
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
let ok = true;
for (const n of [0, 1, 1024, 65536]) {
  e.build_message(n);
  const a = push(), b = pull(n), x = expected(n);
  if (!same(a, x) || !same(b, x)) { ok = false; console.log(`MISMATCH for ${n} bytes`); }
}
e.send_text(1024);

// the time per message of 1 KiB: given (or read), and built then given (or read)
const n = 1024, reps = 20000;
const time = (f) => {
  for (let r = 0; r < 2000; r++) f();
  const t0 = performance.now();
  for (let r = 0; r < reps; r++) f();
  return (performance.now() - t0) / reps * 1000;
};
e.build_message(n);
const tPush = time(push), tPull = time(() => pull(n));
const tBuildPush = time(() => { e.build_message(n); return push(); });
const tBuildPull = time(() => pull(e.build_message(n)));
console.log(`1 KiB message, given in one call:        ${tPush.toFixed(2)} µs (built and given: ${tBuildPush.toFixed(2)} µs)`);
console.log(`1 KiB message, read by ${n / 4} export calls: ${tPull.toFixed(2)} µs (built and read:  ${tBuildPull.toFixed(2)} µs)`);
console.log(ok ? 'the same bytes both ways' : 'MISMATCH');
process.exit(ok ? 0 : 1);
