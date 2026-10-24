import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, stat, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createConnection, createServer } from 'node:net';
import assert from 'node:assert/strict';

const binary = process.argv[2];
assert(binary, 'pass the compiled flightdeck-peer helper');
const root = await mkdtemp(join(tmpdir(), 'fd-peer-test-'));
const children = [];
let checks = 0;
function check(value, message) { assert(value, message); checks++; }
async function start(name, mode = 'prompting', sessionId = crypto.randomUUID()) {
  const home = join(root, name);
  await mkdir(join(home, 'sessions'), { recursive: true, mode: 0o700 });
  const child = spawn(binary, ['serve', '--session', sessionId, '--name', name,
    '--agent', 'codex', '--mode', mode, '--config', home, '--socket-dir', join(root, 'socks'),
    '--state-dir', join(root, name + '-state')], { stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child);
  let pending = '', error = '', next = 0;
  const events = [], waiters = new Map();
  child.stderr.on('data', b => { error += b; });
  child.stdout.on('data', b => {
    pending += b;
    let at;
    while ((at = pending.indexOf('\n')) >= 0) {
      const event = JSON.parse(pending.slice(0, at)); pending = pending.slice(at + 1);
      if (event.id && waiters.has(event.id)) { waiters.get(event.id)(event); waiters.delete(event.id); }
      else events.push(event);
    }
  });
  async function until(predicate) {
    const end = Date.now() + 5000;
    while (Date.now() < end) {
      const found = events.find(predicate);
      if (found) return found;
      if (child.exitCode !== null || child.signalCode) throw Error('helper exited: ' + error);
      await new Promise(r => setTimeout(r, 10));
    }
    throw Error('timed out: ' + JSON.stringify(events) + ' ' + error);
  }
  const ready = await until(e => e.type === 'ready');
  async function call(method, params = {}) {
    const id = ++next;
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { waiters.delete(id); reject(Error('RPC timeout ' + method)); }, 5000);
      waiters.set(id, value => { clearTimeout(timer); value.error ? reject(Error(value.error)) : resolve(value.result); });
    });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    return result;
  }
  return { child, ready, call, until, events, home };
}
try {
  const a = await start('alpha');
  const b = await start('beta');
  check(a.ready.pid !== b.ready.pid, 'one real PID per endpoint');
  check((await stat(a.ready.socket)).mode % 0o1000 === 0o600, 'socket private');
  const record = JSON.parse(await readFile(join(a.home, 'sessions', a.ready.pid + '.json')));
  check(record.procStart === execFileSync('/bin/ps', ['-p', '' + a.ready.pid, '-o', 'lstart='],
    { encoding: 'utf8', env: { ...process.env, TZ: 'UTC', LC_ALL: 'C' } }).trim(), 'UTC fingerprint');
  check(record.peerProtocol === 1 && record.messagingSocketPath === a.ready.socket, 'native registry');
  check((await readdir(join(a.home, 'sessions'))).some(n => n.endsWith('.key')), 'native authentication key');
  const sent = await a.call('send', { to: 'uds:' + b.ready.socket, session_id: b.ready.sessionId, message: 'héllo 🌍' });
  const message = await b.until(e => e.type === 'message');
  check(message.text.includes('héllo 🌍'), 'UTF-8 round trip');
  check(message.from === 'uds:' + a.ready.socket, 'native reply address');
  check(message.text.includes('not from your user'), 'peer provenance');
  await b.call('status', { status: 'busy' });
  const subscription = await a.call('send', { to: 'uds:' + b.ready.socket, notify_when_idle: true });
  await b.call('status', { status: 'idle' });
  const notice = await a.until(e => e.type === 'idle_notice');
  check(notice.frame.state === 'idle' && notice.frame.orig_msg_id === subscription.subscription_id, 'native idle correlation');
  const c = await start('bypass', 'bypass');
  const held = await a.call('send', { to: 'uds:' + c.ready.socket, message: 'secret-held-body' });
  await c.until(e => e.type === 'held');
  await a.until(e => e.type === 'receipt' && e.frame.status === 'held');
  const inbox = await c.call('receive', { after: 0 });
  check(!JSON.stringify(inbox).includes('secret-held-body'), 'held body redacted');
  check(!c.events.some(e => e.type === 'message'), 'cross-class not delivered');
  await c.call('approve', { message_id: held.msg_id, accept: true });
  await c.until(e => e.type === 'message');
  await a.until(e => e.type === 'receipt' && e.frame.status === 'delivered');
  check(true, 'operator release and native delivered receipt');
  // A replay of the same native frame must never start a second host turn.
  const frame = { msgV: 1, msg_id: sent.msg_id, type: 'user', from: 'uds:' + a.ready.socket,
    message: { role: 'user', content: `<cross-session-message from="uds:${a.ready.socket}" from-name="alpha" from-mode="prompting">\nhéllo 🌍\n</cross-session-message>` }, priority: 'next' };
  await a.call('post', { to: 'uds:' + b.ready.socket, frames: [frame] });
  await new Promise(r => setTimeout(r, 100));
  check(b.events.filter(e => e.type === 'message').length === 1, 'message deduplication');
  // A forged address cannot claim another live sender's PID.
  const forged = { ...frame, msg_id: crypto.randomUUID(), from: 'uds:' + c.ready.socket };
  await a.call('post', { to: 'uds:' + b.ready.socket, frames: [forged] });
  await new Promise(r => setTimeout(r, 100));
  check(b.events.filter(e => e.type === 'message').length === 1, 'verified sender PID');
  // Exercise authentication with a real Node-owned return socket, so a PID rejection
  // cannot accidentally make a broken authentication implementation look correct.
  const returnPath = join(root, 'socks', process.pid + '.sock');
  const returnSocket = createServer(c => { c.resume(); });
  await new Promise((resolve, reject) => { returnSocket.once('error', reject); returnSocket.listen(returnPath, resolve); });
  await chmod(returnPath, 0o600);
  const keyName = (await readdir(join(b.home, 'sessions'))).find(n => n.endsWith('.key'));
  const key = JSON.parse(await readFile(join(b.home, 'sessions', keyName)));
  const authFrame = { ...frame, msg_id: crypto.randomUUID(), from: 'uds:' + returnPath,
    message: { role: 'user', content: `<cross-session-message from="uds:${returnPath}" from-name="auth-test" from-mode="prompting">\nAUTH_BODY\n</cross-session-message>` } };
  async function raw(lines) {
    await new Promise((resolve, reject) => {
      const client = createConnection(b.ready.socket);
      client.once('error', reject); client.once('connect', () => client.end(lines)); client.once('close', resolve);
    });
  }
  await raw(JSON.stringify({ type: 'auth', token: '0'.repeat(32) }) + '\n' + JSON.stringify(authFrame) + '\n');
  await new Promise(r => setTimeout(r, 100));
  check(!b.events.some(e => e.type === 'message' && e.text.includes('AUTH_BODY')), 'wrong token blocks a verified PID');
  await raw(JSON.stringify({ type: 'auth', token: key.peerToken }) + '\n' + JSON.stringify(authFrame));
  await b.until(e => e.type === 'message' && e.text.includes('AUTH_BODY'));
  check(true, 'native authentication and final fragment delivered');
  await new Promise(resolve => returnSocket.close(resolve));
  const pending = await b.call('pending');
  check(pending.messages.length === 2, 'typed acknowledgement is distinct from transport acceptance');
  await b.call('host-accepted', { message_id: sent.msg_id });
  check((await b.call('pending')).messages.length === 1, 'host acknowledgement retires just its message');
  b.child.stdin.end(); await new Promise(r => b.child.once('exit', r));
  const restarted = await start('beta', 'prompting', b.ready.sessionId);
  check((await restarted.call('pending')).messages.some(e => e.text.includes('AUTH_BODY')), 'pending host delivery survives helper restart');
  await a.call('post', { to: 'uds:' + restarted.ready.socket, frames: [frame] });
  await new Promise(r => setTimeout(r, 100));
  check(!restarted.events.some(e => e.type === 'message'), 'deduplication survives restart');
  // Finish a complete JSON frame at EOF, even without a final newline.
  const decoder = await a.call('decode-test', { chunks: ['{"value":"🌍"}\n{', '"tail":true}'] });
  check(decoder.length === 2 && decoder[1].tail, 'final fragment parser');
  const rss = execFileSync('/bin/ps', ['-p', '' + a.ready.pid, '-o', 'rss=,%cpu='], { encoding: 'utf8' }).trim();
  console.log(JSON.stringify({ checks, idle_helper_rss_kib_cpu: rss, helper: binary }));
  check(!(await readdir(join(b.home, 'sessions'))).some(n => n === b.ready.pid + '.json'), 'EOF cleans native registry');
  console.log(`PEER NATIVE PASS (${checks} assertions)`);
} finally {
  for (const child of children) child.stdin.end();
  await Promise.all(children.map(child => child.exitCode !== null ? null : new Promise(r => child.once('exit', r))));
  await rm(root, { recursive: true, force: true });
}
