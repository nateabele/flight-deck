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

/** A shell command that changes this session's budget through the CLI. */
const CHANGES_BUDGET = /\bflightdeck\b[^\n;|&]*\binfra\s+budget\s+(set|renew|clear|off|\$?\d)/

/** Registered by flight-deck.tsx, inside a Flight Deck tab only. */
export const command = {
  name: 'budget',
  description: "Show or set this session's cloud machine budget",
  argumentHint: '[usd | renew [usd] | clear]',
}

export const register: Register = on => {
  on('command.run', { command: 'budget' }, async ($, e) => {
    return { text: (await flightdeck($, budgetArgs(e.args))).text }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (CHANGES_BUDGET.test(e.command) && (await inTab($))) {
      return { deny: "This session's cloud budget is the user's to set: ask them to run /budget. `flightdeck infra budget` (no change) shows it." }
    }
    return next(e)
  })
}
