import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { SwitchAccountChoices } from '../types'

// `claude plugin test Resources/ClaudePlugin`. The engine's bottom hooks stand in for the host:
// `process.run` plays the `flightdeck` CLI, `command.register` and `ui.open`/`ui.close` record.

const CHOICES: SwitchAccountChoices = {
  agent: 'claude',
  current: 'a1',
  assignedPool: 'team',
  pools: [
    {
      id: 'team',
      label: 'Team',
      isAssigned: true,
      members: [
        { id: 'a1', displayName: 'First', email: 'first@example.com', state: 'underSoft', isCurrent: true },
        { id: 'a2', displayName: 'Second', email: 'second@example.com', state: 'overHard', isCurrent: false },
      ],
    },
  ],
  accounts: [{ id: 'a3', displayName: 'Solo', state: 'unknown', isCurrent: false }],
}

const IN_TAB = { FLIGHT_DECK_SESSION_ID: 'tab-1', FLIGHTDECK_CLI: '/fd/flightdeck' }

type Ran = { argv: readonly string[]; env?: Record<string, string> }

/** Wires the host-side nouns the module calls and returns what it did to them. */
function host(on: On, cli: (argv: readonly string[]) => { exitCode: number; stdout?: string; stderr?: string }) {
  const seen = { ran: [] as Ran[], registered: [] as string[], opened: [] as string[], closed: [] as string[], toasts: [] as string[] }
  on('process.run', (_$, e) => {
    seen.ran.push({ argv: e.argv, env: e.init?.env })
    const out = cli(e.argv)
    return {
      value: { exitCode: out.exitCode, stdout: out.stdout ?? '', stderr: out.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => {
    seen.registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('ui.open', (_$, e) => {
    seen.opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    seen.closed.push(e.id)
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    seen.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', () => ({ value: undefined }))
  return seen
}

/** What the engine stamps on a command the person typed. */
const typed = (args: string) => ({
  command: 'switch-account',
  args,
  origin: { kind: 'composer' } as const,
  presentation: { isFullscreen: false, columns: 100 },
})

const startSession = ($: { session: { start: (e: { cwd: string; surface: 'terminal'; isInteractive: true }) => Promise<unknown> } }) =>
  $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })

test('registers /switch-account inside a Flight Deck tab only', async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, () => ({ exitCode: 0 }))
  await startSession($)
  expect(seen.registered).toEqual(['switch-account'])
})

test('registers nothing, and still lets session.start through, outside a Flight Deck tab', async ($, on) => {
  mock.env(on, {})
  const seen = host(on, () => ({ exitCode: 0 }))
  expect(await startSession($)).toEqual({ cwd: '/work' })
  expect(seen.registered).toEqual([])
})

test('with an argument it asks the CLI to switch, as this tab, and relays the message', async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, () => ({ exitCode: 0, stdout: 'Moving this conversation to “Second”.\n' }))
  const result = await $.command.run(typed('work@example.com'))
  expect(result.text).toBe('Moving this conversation to “Second”.')
  expect(seen.ran).toEqual([
    { argv: ['/fd/flightdeck', 'account', 'switch', '--', 'work@example.com'], env: { FLIGHT_DECK_SESSION_ID: 'tab-1' } },
  ])
})

test('a refusal reaches the user as the CLI said it, without the program prefix', async ($, on) => {
  mock.env(on, IN_TAB)
  host(on, () => ({ exitCode: 1, stderr: 'flightdeck: This conversation is mid-turn.\n' }))
  const result = await $.command.run(typed('Second'))
  expect(result.text).toBe('This conversation is mid-turn.')
})

test('bare, it lists, opens the picker and leaves the switch for a press', async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, argv => (argv.includes('list') ? { exitCode: 0, stdout: JSON.stringify(CHOICES) } : { exitCode: 0, stdout: 'Moving.' }))
  const result = await $.command.run(typed(''))
  expect(result.text).toContain('Pick an account or pool')
  expect(seen.opened).toEqual(['switch-account'])
  expect(seen.ran.map(r => r.argv.slice(1))).toEqual([['account', 'list', '--json']])
})

test('bare, a list that failed is the answer and no picker opens', async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, () => ({ exitCode: 1, stderr: 'flightdeck: cannot reach Flight Deck' }))
  const result = await $.command.run(typed(''))
  expect(result.text).toBe('cannot reach Flight Deck')
  expect(seen.opened).toEqual([])
})

test('the picker lists pools, then their accounts, then unpooled ones, on every surface', async ($, on) => {
  mock.env(on, IN_TAB)
  const seen = host(on, argv => (argv.includes('list') ? { exitCode: 0, stdout: JSON.stringify(CHOICES) } : { exitCode: 0, stdout: 'Moving.' }))
  await $.command.run(typed(''))

  for (const surface of ['terminal', 'desktop', 'mobile'] as const) {
    const ui = await $.ui.mount({
      plugin: 'flight-deck',
      surface,
      component: 'Pane',
      requestId: 'switch-account',
      props: { title: 'Switch account', isFocused: true, bodyColumns: 80, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} },
    })
    const rows = (await ui.findAll({ type: 'Button' })).map(b => b.key)
    expect(rows).toEqual(['pool:team', 'account:team:a1', 'account:team:a2', 'account:a3', 'cancel'])
    const current = await ui.find({ key: 'account:team:a1' })
    expect(current?.text).toContain('(current)')
    expect(current?.text).toContain('first@example.com')
    expect((await ui.find({ key: 'account:team:a2' }))?.text).toContain('over limit')

    // Choosing a pool closes the picker, asks for the pool by id, and says how it went.
    seen.ran.length = 0
    await ui.press({ key: 'pool:team' })
    expect(seen.closed.at(-1)).toBe('switch-account')
    expect(seen.ran.map(r => r.argv.slice(1))).toEqual([['account', 'switch', '--', 'team']])
    expect(seen.toasts.at(-1)).toBe('Moving.')

    // An account goes by its id, which no other account or pool can share.
    seen.ran.length = 0
    await ui.press({ key: 'account:a3' })
    expect(seen.ran.map(r => r.argv.slice(1))).toEqual([['account', 'switch', '--', 'a3']])
    await ui.unmount()
  }
})
