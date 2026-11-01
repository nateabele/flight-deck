// Opt-in: a dedicated Claude tab must be created through flightdeck before running this.
// No project edits or permission changes are requested. The fixture has no model or tools.
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const exec = promisify(execFile);
const [binary, session] = process.argv.slice(2);
assert(binary && session, 'pass helper binary and dedicated Flight Deck Claude tab UUID');
const fdBinary = process.env.FLIGHTDECK_CLI || join(homedir(), '.local/bin/flightdeck');
const fd = async (...args) => (await exec(fdBinary, args, { timeout: 15000, maxBuffer: 8 * 1024 * 1024 })).stdout;
const configs = [];
for (const name of await readdir(homedir())) {
  if (name !== '.claude' && !name.startsWith('.claude-')) continue;
  const path = join(homedir(), name);
  if ((await stat(join(path, 'sessions')).catch(() => null))?.isDirectory()) configs.push(path);
}
const root = await mkdtemp('/private/tmp/flightdeck-native-interop-');
const run = crypto.randomUUID().slice(0, 8), name = 'flightdeck-native-test-' + run;
let active;
async function start(mode) {
  const process = spawn(binary, ['serve', '--session', crypto.randomUUID(), '--name', name,
    '--agent', 'codex', '--mode', mode, '--state-dir', join(root, mode),
    ...configs.flatMap(path => ['--config', path])], { stdio: ['pipe', 'pipe', 'pipe'] });
  const events = [], requests = new Map();
  let pending = '', stderr = '', next = 0;
  process.stderr.on('data', data => { stderr += data; });
  process.stdout.on('data', data => {
    pending += data;
    let end;
    while ((end = pending.indexOf('\n')) >= 0) {
      const frame = JSON.parse(pending.slice(0, end)); pending = pending.slice(end + 1);
      if (frame.id && requests.has(frame.id)) { requests.get(frame.id)(frame); requests.delete(frame.id); }
      else events.push(frame);
    }
  });
  async function wait(predicate, label, timeout = 90000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const event = events.find(predicate);
      if (event) { console.log('PASS ' + label); return event; }
      if (process.exitCode !== null) throw Error('helper exited: ' + stderr);
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw Error('timeout: ' + label + '\n' + JSON.stringify(events));
  }
  async function call(method, params = {}) {
    const id = ++next;
    const reply = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { requests.delete(id); reject(Error('helper RPC timeout')); }, 10000);
      requests.set(id, frame => { clearTimeout(timer); frame.error ? reject(Error(frame.error)) : resolve(frame.result); });
    });
    process.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    return reply;
  }
  const ready = await wait(e => e.type === 'ready', 'native helper ready', 10000);
  return { process, events, ready, wait, call,
    stop: async () => { if (process.exitCode !== null) return; process.stdin.end(); await new Promise(r => process.once('exit', r)); } };
}
const hello = 'FD_NATIVE_HELLO_' + run, reply = 'FD_NATIVE_REPLY_' + run;
try {
  await fd('rename', session, 'Flight Deck native messaging test ' + run);
  active = await start('prompting');
  await fd('send', session, '--', `This is a dedicated user-authorized native messaging test. Do not edit files, change settings, run shell commands, or contact any other session. Use native ListAgents to find exactly "${name}", then native SendMessage to that peer with message "${hello}". If it is held, do not approve or retry it; simply finish. Later, if this same test peer asks for "${reply}", reply with exactly that text through native SendMessage to its from address.`);
  const first = await active.wait(e => e.type === 'message' || e.type === 'held', 'Claude discovers helper and sends through native tools');
  if (first.type === 'held') {
    const frame = await active.call('held-body', { message_id: first.message_id });
    assert(frame.message.content.includes('from-mode="bypass"'));
    // Match the test sender's observed mode. Never change the real Claude tab's permissions.
    await active.stop();
    active = await start('bypass');
  }
  let native;
  for (const config of configs) for (const file of await readdir(join(config, 'sessions'))) {
    if (!/^\d+\.json$/.test(file)) continue;
    const record = JSON.parse(await readFile(join(config, 'sessions', file), 'utf8').catch(() => '{}'));
    if (record.sessionId?.toLowerCase() === session.toLowerCase()) native = record;
  }
  assert(native?.messagingSocketPath, 'dedicated Claude session has a native inbox');
  const sent = await active.call('send', { to: 'uds:' + native.messagingSocketPath,
    session_id: native.sessionId, message: `FD_NATIVE_ROUNDTRIP_${run}: Reply with exactly ${reply} using native SendMessage to this sender's from address. Do not edit files or change permissions.`, notify_when_idle: true });
  await active.wait(e => e.type === 'message' && e.text?.includes(reply), 'native helper wakes Claude and receives a native reply');
  await active.wait(e => e.type === 'idle_notice' && e.frame.orig_msg_id === sent.subscription_id, 'Claude sends a correlated native idle notice');
  assert(!active.events.some(e => e.type === 'receipt' && e.frame.status === 'held'), 'matching native modes must not need approval');
  await active.call('status', { status: 'idle' });
  console.log(JSON.stringify({ success: true, testedAtUTC: new Date().toISOString(), claudeVersion: native.version,
    fixture: name, session, helperPID: active.ready.pid, checks: 4, evidenceDirectory: root }));
} finally {
  await active?.stop();
}
