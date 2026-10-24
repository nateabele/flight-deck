import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import assert from 'node:assert/strict';
const binary = process.argv[2], count = Number(process.argv[3] || 16);
assert(binary && count > 0 && count <= 64);
const root = await mkdtemp('/private/tmp/fd-peer-footprint-');
const children = [];
try {
  await Promise.all(Array.from({ length: count }, (_, index) => new Promise((resolve, reject) => {
    const child = spawn(binary, ['serve', '--session', crypto.randomUUID(), '--name', 'footprint-' + index,
      '--agent', 'codex', '--state-dir', root + '/' + index, '--socket-dir', root + '/socks'], { stdio: ['pipe', 'pipe', 'pipe'] });
    children.push(child);
    let buffer = '';
    const timer = setTimeout(() => reject(Error('helper startup timeout')), 10000);
    child.on('error', reject);
    child.stderr.on('data', b => process.stderr.write(b));
    child.stdout.on('data', b => {
      buffer += b;
      if (buffer.includes('\n')) { clearTimeout(timer); resolve(); }
    });
  })));
  const pids = children.map(c => c.pid).join(',');
  function sample() {
    return execFileSync('/bin/ps', ['-p', pids, '-o', 'pid=,rss=,time='], { encoding: 'utf8' }).trim().split('\n').map(line => {
      const [pid, rss, cpuTime] = line.trim().split(/\s+/);
      const [minutes, seconds] = cpuTime.split(':').map(Number);
      return { pid: +pid, rssKiB: +rss, cpuSeconds: minutes * 60 + seconds };
    });
  }
  await new Promise(r => setTimeout(r, 2000));
  const before = sample();
  await new Promise(r => setTimeout(r, 10000));
  const after = sample();
  const rss = after.reduce((n, x) => n + x.rssKiB, 0);
  const cpuDelta = after.reduce((n, x) => n + x.cpuSeconds - before.find(y => y.pid === x.pid).cpuSeconds, 0);
  console.log(JSON.stringify({ measuredAtUTC: new Date().toISOString(), helpers: count,
    meanRSSMiB: +(rss / count / 1024).toFixed(2), totalRSSMiB: +(rss / 1024).toFixed(2),
    aggregateIdleCPUSecondsOver10s: +cpuDelta.toFixed(3), maxRSSMiB: +(Math.max(...after.map(x => x.rssKiB)) / 1024).toFixed(2) }));
} finally {
  for (const child of children) child.stdin.end();
  await Promise.all(children.map(child => child.exitCode !== null ? null : new Promise(r => child.once('exit', r))));
  await rm(root, { recursive: true, force: true });
}
