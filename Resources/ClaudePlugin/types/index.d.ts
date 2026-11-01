/**
 * `flightdeck account list --json`, as `/switch-account` draws it. Mirrors FleetKit's
 * `WireAccountChoices` (Sources/FleetKit/AccountControlWire.swift).
 */
export type SwitchAccountChoice = {
  id: string
  displayName: string
  email?: string
  /** "underSoft" | "overSoft" | "overHard" | "unknown" */
  state: string
  isCurrent: boolean
  /** The account's newest rate-limit windows; `utilization` is 0...1. */
  windows?: { name: string; utilization: number; resetsAt?: number }[]
}

export type SwitchAccountPool = {
  id: string
  label: string
  isAssigned: boolean
  members: SwitchAccountChoice[]
}

export type SwitchAccountChoices = {
  agent: string
  current?: string
  /** When set, `pools` is that pool alone and `accounts` is empty: the project moves only within it. */
  assignedPool?: string
  pools: SwitchAccountPool[]
  accounts: SwitchAccountChoice[]
  currentAccount?: SwitchAccountChoice
  context?: { usedPercent: number; windowSize?: number }
}

declare module 'claude-code' {
  interface PluginState {
    'flight-deck': { switchAccount: SwitchAccountChoices | null }
  }
}
