import type { Register } from 'claude-code'

import { flightdeck, inTab } from './cli'

// `/budget`: this session's cloud budget (`flightdeck infra budget`, see InfraControlWire.swift).
// Flight Deck keeps and enforces it; this module only asks. The budget counts only the cloud
// machines this session created, and once they have spent it Flight Deck destroys them and
// refuses new ones.
//
//   /budget              where it stands
//   /budget 20           sets the cap to $20, keeping what was spent so far
//   /budget renew [20]   a fresh window from now, at $20 or the cap it has
//   /budget clear        no session budget (Settings → Cloud's caps still apply)
//
// The budget is the person's to set, not the agent's: a Bash call that would change it is
// refused here. A guardrail, as ControlScope is, not a boundary: the CLI itself takes it.

/** The `infra budget` operands a `/budget` argument line stands for. */
export function budgetArgs(line: string): string[] {
  const words = line.trim().split(/\s+/).filter(Boolean)
  return ['infra', 'budget', ...words]
}

/**
 * A shell command that changes this session's budget through the CLI. An amount is a whole
 * word, so a redirect after a bare `budget` (`2>&1`) is not read as $2.
 */
const CHANGES_BUDGET = /\bflightdeck\b[^\n;|&]*\binfra\s+budget\s+(set|renew|clear|off|\$?\d[\d.]*(?=$|[\s;|&)]))/

/**
 * The budget's one-line summary. The CLI answers in JSON when its stdout is not a terminal, as
 * here, and the summary is that JSON's `line`.
 */
function line(stdout: string): string {
  try {
    const parsed: unknown = JSON.parse(stdout)
    if (parsed && typeof parsed === 'object' && 'line' in parsed && typeof parsed.line === 'string') return parsed.line
  } catch {}
  return stdout
}

/** Registered by flight-deck.tsx, inside a Flight Deck tab only. */
export const command = {
  name: 'budget',
  description: "Show or set this session's cloud machine budget",
  argumentHint: '[usd | renew [usd] | clear]',
}

export const register: Register = on => {
  on('command.run', { command: 'budget' }, async ($, e) => {
    const ran = await flightdeck($, budgetArgs(e.args))
    return { text: ran.ok ? line(ran.text) : ran.text }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (CHANGES_BUDGET.test(e.command) && (await inTab($))) {
      return { deny: "This session's cloud budget is the user's to set: ask them to run /budget. `flightdeck infra budget` (no change) shows it." }
    }
    return next(e)
  })
}
