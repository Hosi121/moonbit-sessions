import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { nativeEnv } from '../scripts/native-env.mjs';

const base = `http://127.0.0.1:${process.env.SERVICEKIT_PORT ?? 18083}`;
let child, logs = '';
async function eventually(f) {
  let last;
  for (let i = 0; i < 100; i++) {
    try { return await f(); } catch (error) { last = error; await new Promise(resolve => setTimeout(resolve, 20)); }
  }
  throw last;
}
before(async () => {
  child = spawn('_build/native/release/build/Hosi121/ws_session_example/ws_session_example.exe', [], {
    env: nativeEnv(), stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', text => logs += text);
  child.stderr.on('data', text => logs += text);
  await eventually(async () => assert.equal((await fetch(base + '/health')).status, 200));
});
after(async () => {
  child?.kill('SIGTERM');
  if (child && child.exitCode === null) await once(child, 'exit');
  assert.doesNotMatch(logs, /FAILED|AddressSanitizer|runtime error:/);
});
async function connect(path) {
  const ws = new WebSocket(base.replace('http', 'ws') + path);
  const messages = [];
  ws.addEventListener('message', event => messages.push(event.data));
  const closed = once(ws, 'close').then(([event]) => event.code);
  await once(ws, 'open');
  return { ws, messages, closed };
}
async function cleaned() {
  await eventually(async () => assert.equal(await (await fetch(base + '/health')).text(), '0'));
  assert.equal(await (await fetch(base + '/retired')).text(), 'true');
}
test('echoes Unicode; flushes queued data then final payload; invalidates escaped session', async () => {
  const { ws, closed } = await connect('/echo');
  const reply = once(ws, 'message');
  ws.send('日本語');
  assert.equal((await reply)[0].data, '日本語');
  ws.close(); await closed;
  const final = await connect('/finish');
  assert.equal(await final.closed, 1000);
  assert.deepEqual(final.messages, ['before', 'goodbye']);
  await cleaned();
});
test('bounds message count including empty messages, and UTF-8 bytes', async () => {
  const overflow = await connect('/overflow');
  assert.equal(await overflow.closed, 1006);
  const bytes = await connect('/bytes');
  assert.equal(await bytes.closed, 1006);
  await cleaned();
});
test('application maps ingress and handler failures to close codes, with cleanup', async () => {
  const large = await connect('/echo'); large.ws.send('x'.repeat(4097));
  assert.equal(await large.closed, 1009);
  const failure = await connect('/error');
  assert.equal(await failure.closed, 1011);
  const policy = await connect('/policy');
  assert.equal(await policy.closed, 1008);
  await cleaned();
});
test('two sessions have independent lifetimes', async () => {
  const first = await connect('/echo');
  const second = await connect('/echo');
  first.ws.close(); await first.closed;
  const reply = once(second.ws, 'message');
  second.ws.send('still open');
  assert.equal((await reply)[0].data, 'still open');
  second.ws.close(); await second.closed;
  await cleaned();
});
