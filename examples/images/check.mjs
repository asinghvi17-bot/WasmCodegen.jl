// node --experimental-wasm-exnref check.mjs [images.wasm]: filter the cases of cases.json
// (written by native.jl) with the module and compare the pixels with native Julia's
// (reference.bin): equal, or within 1 in a channel where floating-point sums round differently
import fs from 'node:fs';
const dir = new URL('.', import.meta.url).pathname;
const { H, W, cases, separable } = JSON.parse(fs.readFileSync(dir + 'cases.json', 'utf8'));
const ref = new Int32Array(fs.readFileSync(dir + 'reference.bin').buffer.slice(0));
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2] ?? dir + 'images.wasm'), {});
const e = instance.exports;
const testPixel = (y, x) => ((x * 7 + y * 3) % 256) | (((x * y) % 256) << 8) | ((((x ^ y) * 5) % 256) << 16);
e.img_resize(H, W);
for (let y = 1; y <= H; y++) for (let x = 1; x <= W; x++) e.img_set((y - 1) * W + x, testPixel(y, x));
let bad = 0, near = 0, total = 0;
cases.forEach(([p, n, s, b, g, post, gain], k) => {
  e.kernel_preset(p, n, s);
  if (e.kernel_separable() !== separable[k]) { bad++; console.log(`case ${k}: separable ${e.kernel_separable()}, native ${separable[k]}`); }
  e.filter_image(b, g, post, gain);
  let worst = 0, diffs = 0;
  for (let i = 0; i < H * W; i++) {
    const a = e.out_get(i + 1), r = ref[k * H * W + i];
    if (a === r) continue;
    const d = Math.max(...[0, 8, 16].map(sh => Math.abs(((a >> sh) & 255) - ((r >> sh) & 255))));
    worst = Math.max(worst, d); diffs++;
  }
  total += H * W; near += diffs;
  if (worst > 1) { bad++; console.log(`MISMATCH case ${k} [${cases[k]}]: ${diffs} pixels differ, by up to ${worst}`); }
});
// timing: a 512 × 512 Gaussian blur (7 × 7, separable) and a 5 × 5 sharpening (not)
e.img_resize(512, 512);
for (let y = 1; y <= 512; y++) for (let x = 1; x <= 512; x++) e.img_set((y - 1) * 512 + x, testPixel(y, x));
for (const [p, n, name] of [[3, 7, 'Gaussian blur'], [4, 5, 'sharpen']]) {
  e.kernel_preset(p, n, 1.5);
  e.filter_image(1, 0, 1, 1.0);
  let best = Infinity;
  for (let r = 0; r < 20; r++) { const t0 = performance.now(); e.filter_image(1, 0, 1, 1.0); best = Math.min(best, performance.now() - t0); }
  console.log(`wasm: ${name} ${n} × ${n} on 512 × 512: ${best.toFixed(1)} ms`);
}
console.log(`${cases.length} cases, ${total} pixels: ${bad ? bad + ' mismatched' : 'all match'} (${near} within 1)`);
process.exit(bad ? 1 : 0);
