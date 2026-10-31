import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// `claude plugin test Resources/ClaudePlugin`. `process.run` plays the `flightdeck` CLI and
// `tool.call` the engine's own Bash.

const IN_TAB = { FLIGHT_DECK_SESSION_ID: 'tab-1', FLIGHTDECK_CLI: '/fd/flightdeck' }

function host(on: On, cli: { exitCode: number; stdout?: string; stderr?: string }) {
  const seen = { ran: [] as (readonly string[])[], bash: [] as string[] }
  on('process.run', (_$, e) => {
    seen.ran.push(e.argv)
    return {
      value: { exitCode: cli.exitCode, stdout: cli.stdout ?? '', stderr: cli.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('tool.call', (_$, e) => {
    if (e.tool === 'Bash') seen.bash.push(e.command)
    return { result: {} }
  })
  return seen
}

const typed = (args: string) => ({
  command: 'budget',
  args,
  origin: { kind: 'composer' } as const,
  presentation: { isFullscreen: false, columns: 100 },
})

test('each form asks the CLI for this tab and relays its line', async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, { exitCode: 0, stdout: 'session budget $20.00 · spent ~$0.00 · $20.00 left\n' })
  for (const args of ['', '20', 'renew', 'renew 5', 'clear']) {
    expect((await $.command.run(typed(args))).text).toBe('session budget $20.00 · spent ~$0.00 · $20.00 left')
  }
  expect(seen.ran.map(argv => argv.slice(1))).toEqual([
    ['infra', 'budget'],
    ['infra', 'budget', '20'],
    ['infra', 'budget', 'renew'],
    ['infra', 'budget', 'renew', '5'],
    ['infra', 'budget', 'clear'],
  ])
})

test('a refusal reaches the user line by line, without the program prefix', async ($, on) => {
  mock.env(on, IN_TAB)
  host(on, { exitCode: 125, stderr: 'flightdeck: one\nflightdeck: two\n' })
  expect((await $.command.run(typed('0'))).text).toBe('one\ntwo')
})

test("the agent cannot change the session's budget from Bash", async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, { exitCode: 0 })
  for (const command of ['flightdeck infra budget 500', 'flightdeck infra budget renew', '/fd/flightdeck infra budget set $9', 'flightdeck infra budget clear']) {
    const ran = await $.tool.call({ tool: 'Bash', command })
    expect(ran.deny).toContain('/budget')
  }
  await $.tool.call({ tool: 'Bash', command: 'flightdeck infra budget' })
  await $.tool.call({ tool: 'Bash', command: 'flightdeck infra budget show --json' })
  expect(seen.bash).toEqual(['flightdeck infra budget', 'flightdeck infra budget show --json'])
})

test('outside a Flight Deck tab Bash is left alone', async ($, on) => {
  mock.env(on, {})
  const seen = host(on, { exitCode: 0 })
  await $.tool.call({ tool: 'Bash', command: 'flightdeck infra budget 500' })
  expect(seen.bash).toEqual(['flightdeck infra budget 500'])
})
