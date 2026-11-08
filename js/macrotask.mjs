// A macrotask: `fn` after the host's event loop has turned (its timers and I/O run first).
// `setImmediate` where the host has it (Node, Bun, Deno); in a browser, a message of a
// `MessageChannel` (a task, and not clamped as `setTimeout(fn, 0)` is). Used by `julia_io.mjs`
// and `julia_task.mjs`, so that both run in browsers too.

let channel = null;
const queued = new Map(); // (the MessageChannel fallback) id -> fn
let lastId = 0;

function post(fn) {
  if (channel === null) {
    channel = new MessageChannel();
    channel.port1.onmessage = (e) => {
      const f = queued.get(e.data);
      if (f !== undefined) { queued.delete(e.data); f(); }
    };
  }
  const id = ++lastId;
  queued.set(id, fn);
  channel.port2.postMessage(id);
  return id;
}

/** Run `fn` in a later turn of the event loop; returns what `cancelMacrotask` takes. */
export const macrotask = typeof globalThis.setImmediate === 'function' ? (fn) => globalThis.setImmediate(fn) : post;

/**
 * Cancel a macrotask that has not run. (There is no reset of the whole queue: the module is
 * shared by every `julia_io` and `julia_task` instance of the page, and a message that arrives
 * removes its entry, so the queue is empty again as soon as the messages have been delivered.
 * An instance that ends cancels the macrotasks it queued.)
 */
export const cancelMacrotask = typeof globalThis.clearImmediate === 'function'
  ? (t) => globalThis.clearImmediate(t) : (id) => { queued.delete(id); };
