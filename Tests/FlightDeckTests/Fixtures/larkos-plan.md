# Harbor: hosted build agents for a small team

Harbor runs coding agents on shared infrastructure so a team can hand work to an agent and come back to a reviewed branch. This plan covers the first release: credentials, sandboxes, scheduling and review.

## 1. Goals

1. Let a team member start an agent from the web and watch it work, with the same **transcript** and **diff** views they get locally.
2. Let a scheduled agent run unattended overnight and leave a branch, a summary and a list of open questions by morning.
3. Keep every credential, log and artifact inside the team's own account; nothing is shared between teams.

## 2. Non-goals

- A general CI system. Harbor runs agents, not arbitrary pipelines; `make test` runs inside an agent's sandbox, not as a separate job.
- Billing. The first release records usage per member and per agent but charges nothing.

## 3. Feasibility gates

1. Confirm each model vendor's terms allow hosted use of a member's own credential, and record the evidence in the decision log before any code depends on it.
2. Prototype one sandbox per agent on the chosen runtime and measure cold start, memory ceiling and teardown time against the budgets in [the sizing note](https://example.test/harbor/sizing).
3. Run a week-long soak of scheduled agents against a throwaway repository and count failures by cause.

## 4. Credentials

1. Build a credential picker with separate **account sign-in** and **API key** paths for each supported vendor, and show which run modes each path supports. Validate keys server-side through the vendor's documented interface, store only an opaque reference in Harbor, and let members revoke or rotate a credential at any time.
2. For API keys, support member-owned, scoped keys where the vendor offers them. Route requests through the team's gateway, enforce each member's model list, rate limit and spend limit, and keep keys in the team vault. Never use one member's key for another member's agent.
3. For account sign-in, implement only the vendor-sanctioned flow and runtime confirmed in the feasibility gates. Isolate any signed-in runtime per member and stop generated code from reading its token store. Require explicit proof that the chosen mode permits hosted and unattended execution before enabling scheduled agents with it. Sign-in for interactive sessions can ship on its own if that is the supported scope.
4. Show the billing identity, the rate-limit owner, token expiry and any vendor-specific limits beside every credential. Never fall back silently from a sign-in to a paid key, or from one member's credential to another's.

## 5. Sandboxes

1. Give every agent its own sandbox with a fresh checkout, a writable scratch directory and no network access beyond the gateway and the repository host.
2. Mount secrets read-only at `/run/secrets` and expire them when the agent ends, so a crashed agent leaves nothing usable behind.
3. Cap CPU, memory and wall-clock time per agent, and record which cap ended a run so the summary can say so plainly.

## 6. Scheduling

1. Let a member schedule an agent with a prompt, a repository, a branch name and a time window; reject overlapping windows on the same branch.
2. Queue runs fairly across members so one person's batch cannot starve everyone else's interactive sessions.
3. Retry a run once after an infrastructure failure, never after the agent itself reports a failure, and say which happened.

## 7. Review

1. Open a draft pull request for every finished run, with the agent's summary as the description and its open questions as a checklist.
2. Link each pull request back to the full transcript, so a reviewer can see why a change was made, not only what changed.
3. Let a reviewer send a comment back to the same agent for another round, keeping its context, instead of starting over.

## 8. Observability

1. Record per-run timings for queueing, sandbox start, model calls and teardown, and chart them per team.
2. Alert the on-call member when a scheduled window ends with no run started, rather than when a run fails, because a silent skip is the failure nobody notices.

## 9. Security review

1. Threat-model the gateway, the vault and the sandbox boundary before the first external team is invited.
2. Run a third-party penetration test against a staging deployment with production-like data volumes but no real data.

## 10. Rollout

1. Dogfood with our own team for two weeks, interactive sessions only.
2. Turn on scheduled agents for our team once the soak in §3 shows fewer than one infrastructure failure per hundred runs.
3. Invite three design-partner teams, one at a time, a week apart.

## 11. Open questions

- Should a scheduled agent be allowed to push to a protected branch if every check passes, or always stop at a draft pull request?
- How long should transcripts be kept by default, and can a team shorten it?

## 12. Decision log

| Date | Decision | Evidence |
|---|---|---|
| — | Pending | — |
