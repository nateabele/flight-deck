import type { Register } from 'claude-code'

import { command as budgetCommand, register as budget } from './budget'
import { inTab } from './cli'
import { command as switchAccountCommand, register as switchAccount } from './switch-account'

// The plugin's one hooks module (hooks.json names exactly one, and a module hooks
// `session.start` once): each command lives in its own file, and is registered here only
// inside a Flight Deck tab, so a claude started anywhere else never offers a command that
// could do nothing.
export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    if (await inTab($)) {
      await $.command.register(switchAccountCommand)
      await $.command.register(budgetCommand)
    }
    return next(e)
  })

  switchAccount(on, options)
  budget(on, options)
}
