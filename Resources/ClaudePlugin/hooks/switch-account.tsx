import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { SwitchAccountChoice, SwitchAccountChoices } from '../types'

// `/switch-account`: moves this conversation to another account or pool, in this same tab.
// Flight Deck does the move (`flightdeck account switch`, see docs/ARCHITECTURE.md); this module
// only asks for it. It registers only inside a Flight Deck tab, so a claude started anywhere
// else never offers a command that could do nothing.
//
// Flight Deck answers a switch first and moves second (it retires THIS claude process), so a
// successful run's text is the last thing this session says before it is replaced.

const PANE = 'switch-account'
const choices = atom({ plugin: 'flight-deck', key: 'switchAccount' } as const, null)

type Cli = { ok: boolean; text: string }

/** Runs `flightdeck <args>` for this tab, as the tab: the id comes from the tab's own environment. */
async function flightdeck($: EngineInterface, args: string[]): Promise<Cli> {
  const cli = await $.env.get('FLIGHTDECK_CLI')
  const session = await $.env.get('FLIGHT_DECK_SESSION_ID')
  if (!cli || !session) return { ok: false, text: 'This is not a Flight Deck tab.' }
  try {
    const ran = await $.process.run([cli, ...args], {
      env: { FLIGHT_DECK_SESSION_ID: session },
      timeoutMs: 20_000,
    })
    if (ran.exitCode === 0) return { ok: true, text: ran.stdout.trim() }
    // The CLI prints a refusal as "flightdeck: <message>" on stderr.
    const said = (ran.stderr || ran.stdout).trim().replace(/^flightdeck: /, '')
    return { ok: false, text: said || `flightdeck exited ${ran.exitCode}` }
  } catch (error) {
    return { ok: false, text: `Could not run flightdeck: ${String(error)}` }
  }
}

/** Closes the picker, asks for the move, and says how it went. */
async function choose($: EngineInterface, target: string) {
  await $.ui.close({ id: PANE })
  const ran = await flightdeck($, ['account', 'switch', '--', target])
  $.ui.toast(ran.text)
  if (!ran.ok) $.ui.log(ran.text)
}

const STATE: Record<string, string> = {
  underSoft: 'under limit',
  overSoft: 'near limit',
  overHard: 'over limit',
}

function describe(account: SwitchAccountChoice, indent: string): string {
  const email = account.email ? ` ${account.email}` : ''
  const mark = account.isCurrent ? '* ' : '  '
  const state = STATE[account.state] ?? 'usage unknown'
  return `${indent}${mark}${account.displayName}${email} - ${state}${account.isCurrent ? ' (current)' : ''}`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if ((await $.env.get('FLIGHT_DECK_SESSION_ID')) && (await $.env.get('FLIGHTDECK_CLI'))) {
      await $.command.register({
        name: 'switch-account',
        description: 'Move this conversation to another account or pool',
        argumentHint: '[email | account | pool]',
      })
    }

    return next(e)
  })

  on('command.run', { command: 'switch-account' }, async ($, e) => {
    const target = e.args.trim()
    if (target) return { text: (await flightdeck($, ['account', 'switch', '--', target])).text }

    const listed = await flightdeck($, ['account', 'list', '--json'])
    if (!listed.ok) return { text: listed.text }
    let parsed: SwitchAccountChoices
    try {
      parsed = JSON.parse(listed.text) as SwitchAccountChoices
    } catch {
      return { text: 'Flight Deck sent a list of accounts this command could not read.' }
    }
    await update($, choices, () => parsed)
    const rows = parsed.pools.reduce((sum, pool) => sum + 1 + pool.members.length, 0) + parsed.accounts.length
    await $.ui.open({ id: PANE, title: 'Switch account', focus: true, closeOnEscape: true, rows: Math.min(rows + 3, 24) })

    return { text: 'Pick an account or pool to move this conversation to. Esc closes the picker.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const list = await read($, choices)
    if (list === null) return <Text dimColor>Nothing to choose from.</Text>

    return (
      <Box flexDirection="column">
        <Text bold>Move this conversation to...</Text>
        {list.pools.map(pool => (
          <Box flexDirection="column" key={`pool-box:${pool.id}`}>
            <Button key={`pool:${pool.id}`} plain onPress={() => choose($, pool.id)}>
              {`${pool.label} - pool, first account under its limit${pool.isAssigned ? ' (this project)' : ''}`}
            </Button>
            {pool.members.map(account => (
              <Button key={`account:${pool.id}:${account.id}`} plain onPress={() => choose($, account.id)}>
                {describe(account, '    ')}
              </Button>
            ))}
          </Box>
        ))}
        {list.accounts.length > 0 && list.pools.length > 0 && <Text dimColor>No pool</Text>}
        {list.accounts.map(account => (
          <Button key={`account:${account.id}`} plain onPress={() => choose($, account.id)}>
            {describe(account, list.pools.length > 0 ? '  ' : '')}
          </Button>
        ))}
        <Button key="cancel" plain role="dismiss" onPress={() => $.ui.close({ id: PANE })}>
          Cancel
        </Button>
      </Box>
    )
  })
}
