import type { EngineInterface } from 'claude-code'

export type Cli = { ok: boolean; text: string }

/** Runs `flightdeck <args>` for this tab, as the tab: the id comes from the tab's own environment. */
export async function flightdeck($: EngineInterface, args: string[]): Promise<Cli> {
  const cli = await $.env.get('FLIGHTDECK_CLI')
  const session = await $.env.get('FLIGHT_DECK_SESSION_ID')
  if (!cli || !session) return { ok: false, text: 'This is not a Flight Deck tab.' }
  try {
    const ran = await $.process.run([cli, ...args], {
      env: { FLIGHT_DECK_SESSION_ID: session },
      timeoutMs: 20_000,
    })
    if (ran.exitCode === 0) return { ok: true, text: ran.stdout.trim() }
    // The CLI prints a refusal as "flightdeck: <message>" on stderr, one such line per problem.
    const said = (ran.stderr || ran.stdout).trim().replace(/^flightdeck: /gm, '')
    return { ok: false, text: said || `flightdeck exited ${ran.exitCode}` }
  } catch (error) {
    return { ok: false, text: `Could not run flightdeck: ${String(error)}` }
  }
}

/** Inside a Flight Deck tab, where `flightdeck` can name this session. */
export async function inTab($: EngineInterface): Promise<boolean> {
  return Boolean((await $.env.get('FLIGHT_DECK_SESSION_ID')) && (await $.env.get('FLIGHTDECK_CLI')))
}
