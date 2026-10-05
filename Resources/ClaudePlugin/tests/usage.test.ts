import { test, expect, mock } from 'claude-code/testing'
import type { On, SessionMeasureInput } from 'claude-code'

const measure: SessionMeasureInput = {
  context: { window: 200000 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 82.5, resetsAt: '2026-10-04T23:00:00.000Z' },
    { kind: 'seven_day', percentUsed: 31 },
  ],
  changed: ['rateLimits'],
}

type Write = { path: string; text: string }

// Hooks registered on the test's `on` sit beneath the plugin and stand for the engine: the
// fs.write one records instead of touching disk, the session.measure one is the chain's end.
// The test engine has no session of its own, so `session.id` is answered here too: without it the
// mod's `$.session.id()` throws, which the mod (rightly) swallows, and every write assertion
// would fail for a reason that looks like the mod's.
const SESSION_ID = '70500000-0000-0000-0000-000000000000'
function engine(on: On, writes: Write[]) {
  on('session.id', () => ({ value: SESSION_ID }))
  on('fs.write', (_$, e) => { writes.push({ path: e.path, text: e.text }); return { value: undefined } })
  on('session.measure', (_$, e) => ({ changed: e.changed }))
}

test('writes the windows to the tab file', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage', FLIGHT_DECK_SESSION_ID: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' })
  mock.clock(on, { now: Date.parse('2026-10-04T19:00:00.000Z') })
  engine(on, writes)
  const result = await $.session.measure(measure)
  expect(result.changed).toEqual(['rateLimits'])
  expect(writes.length).toBe(1)
  expect(writes[0].path).toBe('/fd/usage/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json')
  const body = JSON.parse(writes[0].text)
  expect(body.v).toBe(1)
  expect(body.tab).toBe('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE')
  expect(body.readAt).toBe('2026-10-04T19:00:00.000Z')
  expect(body.rateLimits).toEqual([
    { kind: 'five_hour', percentUsed: 82.5, resetsAt: '2026-10-04T23:00:00.000Z' },
    { kind: 'seven_day', percentUsed: 31, resetsAt: null },
  ])
})

test('falls back to the claude session id without a tab id', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage' })
  mock.clock(on, { now: Date.parse('2026-10-04T19:00:00.000Z') })
  engine(on, writes)
  await $.session.measure(measure)
  expect(writes[0].path).toBe(`/fd/usage/${SESSION_ID}.json`)
  expect(JSON.parse(writes[0].text).tab).toBe(null)
})

test('writes nothing outside Flight Deck', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, {})
  engine(on, writes)
  await $.session.measure(measure)
  expect(writes.length).toBe(0)
})

test('writes nothing off a subscription', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage', FLIGHT_DECK_SESSION_ID: 'T' })
  // The clock is mocked so that, without the mod's empty-windows guard, the write would succeed.
  // Unmocked, `$.clock.now()` throws, the mod swallows it, and this test would pass vacuously.
  mock.clock(on, { now: Date.parse('2026-10-04T19:00:00.000Z') })
  engine(on, writes)
  await $.session.measure({ ...measure, rateLimits: [] })
  expect(writes.length).toBe(0)
})

test('a failing write never breaks the chain', async ($, on) => {
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage', FLIGHT_DECK_SESSION_ID: 'T' })
  mock.clock(on, { now: Date.parse('2026-10-04T19:00:00.000Z') })
  on('session.id', () => ({ value: SESSION_ID }))
  // Counted so the test proves the write was attempted: a mod that never reached fs.write would
  // also "not break the chain".
  let attempts = 0
  on('fs.write', () => { attempts += 1; throw new Error('EACCES') })
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  const result = await $.session.measure(measure)
  expect(attempts).toBe(1)
  expect(result.changed).toEqual(['rateLimits'])
})
