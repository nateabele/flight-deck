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
  assignedPool?: string
  pools: SwitchAccountPool[]
  accounts: SwitchAccountChoice[]
}

declare module 'claude-code' {
  interface PluginState {
    'flight-deck': { switchAccount: SwitchAccountChoices | null }
  }
}
