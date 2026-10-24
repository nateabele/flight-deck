import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
const cli = process.argv[2];
assert(cli, 'pass the bundled flightdeck CLI, not the app executable');
const help = spawnSync(cli, ['peer', '--help'], { encoding: 'utf8', timeout: 5000 });
assert.equal(help.status, 0, help.stderr);
assert(help.stdout.includes('flightdeck peer send'));
const messages = [
  { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26' } },
  { jsonrpc: '2.0', id: 2, method: 'tools/list' },
];
const mcp = spawnSync(cli, ['peer', 'mcp'], { input: messages.map(x => JSON.stringify(x)).join('\n') + '\n', encoding: 'utf8', timeout: 5000 });
assert.equal(mcp.status, 0, mcp.stderr);
const replies = mcp.stdout.trim().split('\n').map(x => JSON.parse(x));
assert.equal(replies.find(x => x.id === 1).result.serverInfo.name, 'flightdeck-peer');
const tools = replies.find(x => x.id === 2).result.tools.map(x => x.name);
assert.deepEqual(tools, ['ListAgents', 'SendMessage', 'ReceiveMessages']);
assert(!tools.some(x => /approv|inbound|permission/i.test(x)));
const invalid = spawnSync(cli, ['peer', 'approve', 'message-id'], { encoding: 'utf8', timeout: 5000 });
assert.equal(invalid.status, 2);
console.log(JSON.stringify({ success: true, checkedAtUTC: new Date().toISOString(), checks: 7, tools }));
