import type { Register } from 'claude-code'

// Flight Control's usage meter (L3-U). claude raises `session.measure` after each turn and
// whenever a rate-limit window moves a whole point; this writes the windows to one file per
// tab, which Flight Deck reads to decide which account takes new work and when a swarm agent
// must be handed off.
//
// The file is named by FLIGHT_DECK_SESSION_ID (the tab) when Flight Deck set it, else by
// claude's own session id, which Flight Deck maps through the tab's pinned conversation.
// The mod never learns which account it runs on: Flight Deck knows that from the tab.
//
// No FLIGHT_DECK_USAGE_DIR means no Flight Deck (someone running claude with this plugin by
// hand): write nothing. A write that fails must never cost the session anything, so every path
// ends in next(e) — Flight Deck shows the account as "no reading" instead.
export const register: Register = (on) => {
  on('session.measure', async ($, e, next) => {
    if (e.rateLimits.length > 0) {
      try {
        const dir = await $.env.get('FLIGHT_DECK_USAGE_DIR')
        if (dir) {
          const tab = await $.env.get('FLIGHT_DECK_SESSION_ID')
          const session = await $.session.id()
          const readAt = new Date(await $.clock.now()).toISOString()
          const rateLimits = e.rateLimits.map((w) => ({ kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt ?? null }))
          const name = tab && tab.length > 0 ? tab : session
          await $.fs.write(`${dir}/${name}.json`, JSON.stringify({ v: 1, tab: tab ?? null, session, readAt, rateLimits }))
        }
      } catch {
        // Deliberately swallowed; see the header.
      }
    }
    return next(e)
  })
}
