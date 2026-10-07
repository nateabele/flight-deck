# Cloud infra hosts (sub-project E) — design

Status: approved 2026-10-07. Builds on
[2026-10-03-remote-hosts-delegation-design.md](2026-10-03-remote-hosts-delegation-design.md)
(sub-projects A and C, shipped).

## 1. Goal and scope

Flight Deck can create a machine in the user's own cloud account, turn it into an ordinary
paired **host**, and destroy it again — so `flightdeck run --on gpu …`, recipes, services, port
forwards and artifacts all work on a machine that did not exist a minute ago, with no new
delegation machinery.

The rule for everything below: **reuse best-in-class open-source tools, and keep Flight Deck's
own surface to one new config table (`[infra.<name>]`), one CLI verb (`infra`) and one
Settings tab.**

In scope:
- Built-in presets for **AWS** (EC2) and **GCP** (Compute Engine), Linux, arm64 and x86_64,
  including GPU instance types.
- Bring-your-own OpenTofu modules for any cloud, behind a small module contract (§5.3).
- Zero-touch enrollment: a created machine pairs itself; nothing is typed.
- **Tailscale is optional.** When it is installed and running on the Mac, and configured
  once, machines join the user's tailnet automatically. Otherwise a locked-down public mode is
  used (§6).
- Tool binaries (OpenTofu, the AWS and gcloud CLIs) are used from `PATH` when present and a
  compatible version; otherwise Flight Deck fetches and verifies its own pinned copy (§4).
- Budgets: a Flight Deck–enforced spend cap from live price data, non-dollar guardrails, and
  a cost line on every command (§8).
- A guided setup that automates every step it can, down to opening the exact web page (§9).

Out of scope (v1): Mac instances (AWS EC2 Mac's 24-hour dedicated-host minimum makes it a
deliberate opt-in; possible later as a preset), Windows, Kubernetes, SkyPilot, Packer image
baking, shared remote OpenTofu state. §13 outlines them.

Success criteria:
1. From a clean Mac with only a cloud sign-in, `flightdeck infra up gpu` produces a host that
   `flightdeck host ls` shows online, and `flightdeck run --on gpu -- nvidia-smi` works.
2. `infra down gpu` leaves no billable resource behind, and `infra ls` would show one if it
   did.
3. No machine can outlive its TTL even if the Mac is asleep, offline or gone.
4. `infra up` refuses before creating anything when the worst-case cost would break a cap.

## 2. Architecture

```
delegate.toml [infra.gpu] ──► InfraService (controller, app) ──► ToolResolver ─► tofu / aws / gcloud
                                   │                                  (PATH or managed copy)
                                   ├─► TofuRunner ─► preset or user module ─► cloud API
                                   │        └─ user-data = cloud-init(enroll key, hostd install,
                                   │                                  TTL timer, optional tailscale)
                                   ├─► Enrollment: mint FleetDeviceKey → HostRegistry (Keychain)
                                   ├─► TailnetIntegration (optional) ─► Tailscale API / local CLI
                                   ├─► CostLedger + PriceCatalog ─► AWS Pricing / GCP Billing Catalog
                                   └─► Reaper: TTL, idle, budget, drift
machine boots ─► cloud-init ─► hostd-install.sh ─► `flightdeck-hostd enroll` ─► serve
                                                   └─► HostLink connects (existing A/C path)
```

### 2.1 Units

**HostKit** (Foundation-only, macOS + Linux, as today):
- `InfraConfig` — `[infra.<name>]` types and parsing, added to `DelegateConfigParser`.
- `CostModel` — pure: hourly rate × durations, worst-case cost, budget decisions (§8).
- `EnrollmentPayload` — the one-time enrollment file's format, shared by controller and hostd.
- `IdleTracker` — host-side: time since the last run, service, console session or sync ended.

**Controller** (`Sources/FlightDeck/Infra/`, new):
- `ToolResolver` — finds or provisions `tofu`, `aws`, `gcloud`, `tailscale` (§4).
- `TofuRunner` — runs `tofu init/plan/apply/destroy/output -json` in a per-machine workdir,
  streams `-json` progress, parses outputs. A protocol, so tests use a fake.
- `InfraService` — the per-machine state machine (§7) and every `infra.*` request.
- `InfraRegistry` — `Application Support/Flight Deck/infra.json` plus `infra/<name>/` workdirs.
- `CloudAccounts` — `AWSAccount` and `GCPAccount`: detect credentials, run sign-in, check
  quotas, list regions. One protocol, two conformers.
- `PriceCatalog` — hourly prices from the clouds' own price APIs, cached 24 h.
- `CostLedger` — per-machine rate segments persisted in `infra.json`; month-to-date totals.
- `TailnetIntegration` — reads local `tailscale status --json`; mints auth keys with the
  stored OAuth client; patches the policy file; signs nodes under Tailnet Lock (§6, §9).
- `Reaper` — enforces TTL, idle, caps and drift checks on a timer and at app launch.
- `CloudInitRenderer` — pure: renders user-data from an `EnrollmentPayload` and options.
- Presets as bundled OpenTofu modules: `Resources/Infra/presets/{aws-linux,gcp-linux}/`.

**hostd** (Linux package): a new `enroll` subcommand and idle reporting. No other change.

**CLI** (`Sources/FlightDeckCLI/`): `infra up|down|ls|doctor|extend`, cost lines, and
`run --on <infra>` auto-up.

**UI**: Settings → **Cloud** tab (accounts, Tailscale, budget, guardrails) and the setup sheet
(§9). Machines also appear in Settings → Hosts with a cloud badge and cost.

### 2.2 Trust boundaries

- Cloud credentials never pass through Flight Deck: OpenTofu's providers and the cloud CLIs
  read the user's own credential stores (AWS profiles/SSO cache, gcloud ADC). Flight Deck
  stores no cloud keys.
- Stored secrets (Keychain only): the Tailscale OAuth client, and each machine's host key as
  for any host.
- The enrollment key is in the machine's user-data (§5.2). Anyone who can read user-data
  already controls the cloud account; the key grants nothing beyond that machine.
- A machine can reach nothing on the tailnet except what the policy grants it (§6.1).

## 3. Configuration

### 3.1 Repo: `.flightdeck/delegate.toml`

```toml
[infra.gpu]
preset        = "aws-linux"          # or: module = "infra/gpu-box" (a dir in the repo)
region        = "us-east-1"
instance_type = "g6.xlarge"
arch          = "x86_64"             # preset only; default from instance_type
disk_gb       = 100
spot          = false
ttl           = "4h"                 # required; hard stop
idle          = "30m"                # destroy after this long with nothing running; default 30m
auto_up       = true                 # `run --on gpu` creates it on demand; default false
vars          = { }                  # extra variables for a user module
max_hourly    = 1.50                 # optional; required for a user module with no price (§8.1)
```

- `[infra.<name>]` names a host. `run --on gpu`, `recipe.host = "gpu"` and `default_host`
  resolve to it like any other host.
- Exactly one of `preset` / `module`. A `module` path must stay inside the repo.
- `ttl` is required: there is no unbounded machine. Parsed as `30m`, `4h`, `1d`.
- Unknown keys are errors, as for recipes.

### 3.2 User: Settings → Cloud (never in the repo)

Accounts (AWS profile, GCP project), Tailscale configuration, and the budget and guardrails of
§8. A repo cannot raise them: the repo asks, the user's settings decide.

## 4. Tool binaries

`ToolResolver` resolves each tool to a path and a version, once per app launch and on demand:

| Tool | Needed for | Compatible | If missing or incompatible |
|---|---|---|---|
| `tofu` | every infra command | `>= 1.8, < 2` | managed copy: pinned release from GitHub, SHA-256 compiled into the app, unpacked to `Application Support/Flight Deck/tools/tofu/<ver>/` |
| OpenTofu providers | every infra command | pinned in the presets' `.terraform.lock.hcl` | `tofu init` fetches them into a shared plugin cache under `tools/` |
| `aws` | AWS sign-in, quota and price checks | v2 `>= 2.15` | managed copy: the official pkg installed per-user (`installer -target CurrentUserHomeDirectory`) into `tools/aws/`; checksum pinned |
| `gcloud` | GCP sign-in, API enablement | `>= 480` | managed copy: the official macOS tarball into `tools/gcloud/`; checksum pinned |
| `tailscale` | tailnet mode only | `>= 1.70` | **never installed by Flight Deck** (it is a system network extension); absent means public mode |

Resolution order: `PATH` from the user's login shell, then `/opt/homebrew/bin`,
`/usr/local/bin`, and for Tailscale `/Applications/Tailscale.app/Contents/MacOS/Tailscale`;
the first one whose `--version` parses into the compatible range wins. Otherwise the managed
copy, downloading it on first need with progress shown in the CLI and the setup sheet.

- A user's own install is never modified, upgraded or shadowed for other programs: the
  managed copies live only under Application Support and are passed by absolute path.
- Every managed download is verified against a checksum compiled into the app before it is
  unpacked or run; a mismatch is a hard failure, never a retry from another source.
- Pinned versions and checksums live in one table (`ToolPins.swift`), updated with app
  releases. `infra doctor` shows each tool's path, version and source (`PATH` / managed).
- Bundling inside the app was rejected: about 250 MB of binaries most users never need, and
  every app update would re-ship them.

## 5. Provisioning

### 5.1 Lifecycle of `infra up`

1. **Preflight** (§10), entirely before any cloud call that creates something.
2. **Workdir**: copy the preset or module into `infra/<name>/module/` (a user module is
   re-copied each `up`), write `fd.auto.tfvars.json`.
3. **Enrollment**: mint a `FleetDeviceKey`; add a `HostRecord` named `<name>` in state
   `provisioning`; render user-data (§5.2).
4. **Network**: tailnet mode mints a one-time auth key (§6.1); public mode records this Mac's
   public IP for the firewall rule (§6.2).
5. `tofu init` (cached), `tofu apply -auto-approve -json`; progress streamed as one line per
   resource.
6. Read outputs: `fd_address`, `fd_instance_id`.
7. Wait for the host's `helloAck` over the existing `HostLink` (timeout 10 min, with the
   cloud's console output fetched and shown on failure).
8. State `ready`; print the cost line (§8.3).

`infra down` runs `tofu destroy`, removes the host record and Keychain key, deletes the
tailnet node if one remains, and closes the machine's cost segment.

### 5.2 cloud-init and enrollment

User-data (rendered by `CloudInitRenderer`, a pure function with golden-file tests):
1. On every boot (`bootcmd`), block the cloud metadata endpoint for every user but root:
   `169.254.169.254`, plus AWS's IPv6 `fd00:ec2::254` (GCP's `metadata.google.internal` is
   the same IPv4 address).
   The enrollment secret is the controller's long-term PSK for this host and user-data stays
   readable for the machine's whole life, so workloads must never reach it; firewall rules do
   not survive a reboot, hence every boot rather than once.
2. AWS only: arm the on-machine TTL (§7.2) first, before anything that can fail, so a
   machine whose install or enroll breaks still dies. GCP gets no on-machine timer; its preset's
   `max_run_duration` is the guarantee. The deadline is fixed at creation: `extend` cannot move
   it (plan deviation 6).
3. Write `/run/flightdeck/enroll.json` (`EnrollmentPayload`: controller slot, secret, name,
   idle threshold), mode 0600, as one pure-ASCII JSON line (every non-ASCII character
   `\u`-escaped, since YAML reads U+0085 and U+2028/9 as line breaks).
4. Run the release's `hostd-install.sh --sha256 <digest> --no-pair`, which installs hostd as a
   systemd user service with lingering on (the installer's existing path). The user manager is
   started (`systemctl start user@<uid>`) and `XDG_RUNTIME_DIR` set first, because
   `enable-linger` returns before the manager is up. `--no-pair` is new:
   the installer today ends by running `pair`, which would wait for a typed code.
5. `flightdeck-hostd enroll --file /run/flightdeck/enroll.json` adds the controller to
   `ControllerStore` and deletes the file. A failed enroll does not stop the steps after it
   (cloud-init's runcmd carries on); the TTL covers a machine that never enrolls.
6. Tailnet mode: install Tailscale from its official repo, `tailscale up --auth-key=…
   --hostname=fd-<name> --advertise-tags=tag:flightdeck-cloud`.

Hardening: AWS presets require IMDSv2 with hop limit 1; GCP metadata requires its header by
default. The enroll file lives on tmpfs and is deleted after use. `flightdeck-hostd enroll`
refuses a file older than 30 minutes or already used.

### 5.3 Module contract (presets and user modules)

Inputs (all provided by Flight Deck): `fd_name`, `fd_user_data`, `fd_labels` (map), and in
public mode `fd_allow_cidr` (this Mac's `/32`). Outputs: `fd_address` (required),
`fd_instance_id` (optional), `fd_hourly_usd` (optional; used when the price catalog cannot
price the machine). Every resource a module creates must carry `fd_labels`: they are what the
orphan check (§7.3) and the budget's tag scope find.

## 6. Networking

### 6.1 Tailnet mode (automatic when available)

Chosen when the local `tailscale status --json` reports `BackendState: Running` **and** a
Tailscale OAuth client is configured for that same tailnet. Each `up`:
- mints an auth key via the Tailscale API: single-use, preauthorized, **ephemeral**, tagged
  `tag:flightdeck-cloud`, expiring in 15 minutes;
- under Tailnet Lock, signs the new node with `tailscale lock sign` when this Mac is a
  trusted signer, or reports which device must;
- `fd_address` is the node's tailnet IP, read from the Tailscale API once it joins.

The policy grants only this user's devices access to `tag:flightdeck-cloud` on ports
47410–47411, and grants the tag nothing. Ephemeral nodes leave the tailnet on their own after
going offline, so destroyed machines do not accumulate.

If Tailscale is running but not configured, `infra up` uses public mode and prints one line
pointing at setup (§9). The tailnet name is checked against the OAuth client's tailnet;
mismatch refuses.

### 6.2 Public mode (the fallback)

The machine gets a public IP; its firewall admits TCP 47410 from this Mac's current public IP
(`/32`) only, nothing else inbound (no SSH). Delegation traffic is TLS-PSK with the
enrolled key, so the open port answers only this controller. When the Mac's public IP
changes (it moved networks), `HostLink`'s reconnect failures trigger a `tofu apply` that
updates `fd_allow_cidr`, then reconnect.

## 7. Lifecycle and safety

### 7.1 States

`planned → provisioning → enrolling → ready ⇄ idle → destroying → gone`, plus `failed`
(with the step and error) and `orphaned` (§7.3). Persisted in `infra.json`, so a relaunch
resumes or cleans up rather than forgetting a machine.

### 7.2 Nothing outlives its TTL

Enforced twice, so either side alone suffices:
- **Controller**: the `Reaper` destroys at TTL (after a warning notification 10 minutes
  before; `flightdeck infra extend gpu 1h` moves it, within the caps of §8).
- **Machine**: AWS presets set `instance_initiated_shutdown_behavior = "terminate"` and
  cloud-init enables a systemd timer, `OnCalendar=<UTC deadline>` with `Persistent=true`, that
  runs `systemctl poweroff` (an absolute timer, because a reboot clears a pending
  `shutdown -h +N`; `Persistent` fires it at boot if the deadline passed while stopped). GCP
  presets set `scheduling.max_run_duration` with `instance_termination_action = "DELETE"`, and
  GCP gets no on-machine timer: a guest poweroff only stops a GCE VM, which keeps billing its
  disk and halts `max_run_duration`, so a timer firing first would turn the DELETE into a leak.
  A sleeping or lost Mac therefore cannot leave a machine running. The machine's deadline is
  fixed at creation: `extend` cannot move it (plan deviation 6).

### 7.3 Idle, drift and orphans

- **Idle**: hostd's `IdleTracker` reports `idleSince` in `host.info`. The `Reaper` destroys a
  machine idle for its `idle` duration.
- **Drift**: a machine terminated by its own timer leaves OpenTofu state stale; `infra ls`
  and the `Reaper` run `tofu plan -refresh-only` and mark it `gone`.
- **Orphans**: `infra ls --orphans` (and `doctor`) query each configured account for resources
  carrying `flightdeck-owner=<this controller>` that no workdir knows, and offer
  `infra down --orphan <id>`.

## 8. Budgets and cost

### 8.1 The price of a machine

`PriceCatalog` gives an hourly USD rate per machine:
- **AWS**: the Pricing API (`GetProducts`, on-demand Linux, shared tenancy) plus the gp3 disk
  rate prorated per hour; spot uses `DescribeSpotPriceHistory` for the zone.
- **GCP**: the Cloud Billing Catalog API — predefined machine types price as vCPU and memory
  SKUs, GPUs and disks as their own SKUs; spot uses the spot SKUs.
- **User modules**: the module's `fd_hourly_usd` output, else the recipe's `max_hourly`. A
  machine with neither cannot be priced, and `up` refuses while any dollar cap is set.

Prices are cached 24 hours; a failed lookup with no cache refuses `up` while a cap is set.
All figures are labelled **est.**: they exclude egress, snapshots, taxes and discounts.

### 8.2 Spend caps (Flight Deck–enforced)

Settings → Cloud → Budget: a **monthly cap**, a **per-machine cap**, and a warning threshold
(default 80%). `CostLedger` records each machine's rate segments; month-to-date is the sum.

- **Before `up`**: worst case = rate × TTL. Refuse if it exceeds the per-machine cap, or if
  month-to-date + worst case exceeds the monthly cap. The refusal names the numbers and the
  setting to change. This is the important check: because every machine has a TTL, the
  worst case is known before anything is created.
- **`extend`** re-runs the same check for the new deadline.
- **While running**: at the warning threshold of either cap, a notification; at 100%, the
  machine is destroyed after a 5-minute warning that `extend` cannot override (raising the
  cap can).

### 8.3 Guardrails (no dollars needed)

In Settings, never in the repo:
- an **instance-type allowlist** per cloud (glob patterns; default: general-purpose families
  up to 16 vCPU and single-GPU families; anything else must be added);
- **max concurrent machines** (default 2);
- a **maximum TTL** (default 12h) and a **maximum idle** (default 2h).

A recipe asking for more is refused at preflight, naming the setting.

### 8.4 Visibility

Every `infra` command, and every `run`/`up`/`exec` aimed at a cloud host, prints one line on
stderr:

```
gpu · g6.xlarge · $0.80/h est. · up 1h12m · ~$0.96 · TTL 2h48m · month ~$14.20 of $50
```

`--json` outputs carry the same fields (`hourlyUsd`, `spentUsd`, `ttlRemaining`,
`monthUsd`, `monthCapUsd`). `infra ls` adds a total row. Settings → Hosts shows the rate and
spend beside each cloud host.

## 9. Guided setup

Settings → Cloud → **Set up…** opens a sheet: a checklist whose items turn green as live
checks (`infra doctor`'s) pass, each with its automation.

| Step | Automation |
|---|---|
| Tools | Resolved automatically; managed downloads show progress |
| AWS sign-in | Lists profiles and SSO sessions from `~/.aws/config`; runs `aws sso login` (opens the browser itself); validates with `sts get-caller-identity` |
| GCP sign-in | Runs `gcloud auth application-default login` (opens the browser); picks a project from `gcloud projects list`; enables the Compute Engine API via Service Usage, or opens its page when that is not permitted |
| Quota | Checks the chosen instance type's quota in the region (AWS Service Quotas; GCP region quotas incl. GPUs); opens the exact quota-increase page when it is too low |
| Tailscale: tailnet | Read from local `tailscale status` |
| Tailscale: policy | With a short-lived API access token the user pastes (one click to generate; the sheet opens the page), fetches the policy, shows the exact diff (tag owner + grant) and applies it with the API's ETag guard. Edits are text insertions by a HuJSON-aware tokenizer, preserving comments; if it cannot place them safely, it copies the snippet and opens the policy editor instead |
| Tailscale: OAuth client | Opens the OAuth clients page with a two-item checklist beside it; offers to read the ID and secret from the clipboard into the Keychain. Automated fully if probe P1 finds the API can create clients with the step above's token |
| Tailnet Lock | Detects it; signs automatically when this Mac is a signer |
| Budget | Defaults pre-filled (monthly $50, per-machine $10, 80%) |
| Test | Creates the cheapest preset machine with a 15-minute TTL, waits for pairing, runs `uname -a`, destroys it, and shows the time and the cost |

Every step is skippable: Tailscale entirely (public mode), either cloud, or the test.

## 10. Preflight (fail early)

Before any create, in order, each failure naming its fix: tools resolved; config valid; caps
and guardrails (§8); account credentials valid; region and instance type exist; quota
sufficient; price known (when caps are set); name not already in use (by this or another
repo); network mode decided (and, for tailnet mode, the OAuth client works). `infra doctor`
runs the same checks with no recipe and lists every result.

## 11. Testing

- **Unit (pure, in `test-unit.sh` / `test-hostkit.sh`)**: `InfraConfig` parsing and errors;
  `ToolResolver` against a fake `PATH` of scripts printing versions (compatible, too old,
  unparseable, missing) and a fake downloader with checksum mismatch; `CostModel` worst-case
  and cap decisions at boundaries; `CostLedger` month rollover; `CloudInitRenderer` golden
  files for both modes and clouds; the HuJSON patcher against comment-heavy policies (and its
  refusal cases); `EnrollmentPayload` expiry and one-use; `IdleTracker`.
- **Controller with fakes**: `InfraService`'s state machine with a fake `TofuRunner`
  (scripted outputs and failures at each step), fake accounts and price catalog; relaunch
  mid-provision resumes; TTL and idle reaping with a manual clock; public-IP change triggers a
  re-apply.
- **Presets**: `tofu validate` and `tofu plan` against mocked providers
  (`override_resource`/`mock_provider` in `tofu test`), asserting labels, IMDSv2, shutdown
  behaviour and `max_run_duration` are set.
- **hostd**: `enroll` in the Linux container (`test-hostd-linux.sh`), including reuse and
  expiry refusals; the interop gate gains an `enroll` mode.
- **Live, opt-in only**: `scripts/test-infra-live.sh aws|gcp`, refusing without
  `FD_INFRA_LIVE=1`; smallest instance, 15-minute TTL, runs the success criteria of §1 and
  asserts no labelled resource remains. Costs cents; never part of any default suite.

## 12. Probes before building

- **P1**: can the Tailscale API create an OAuth client (scoped, tagged) with a user API
  access token? Decides whether §9's OAuth step is a checklist or fully automatic.
- **P2**: GCP `max_run_duration` + `DELETE` through the OpenTofu Google provider works on
  spot and on-demand, including GPU types.
- **P3**: AWS per-user CLI install (`CurrentUserHomeDirectory`) works without admin rights on
  current macOS.
- **P4**: the GCP Billing Catalog SKU mapping for predefined machine types and GPUs matches
  the published price for three sample types within 1%.

## 13. Later (outline only)

- **SkyPilot** backend for cheapest-available GPU across clouds and spot recovery.
- **Packer** images with hostd, Docker and toolchains baked in (boot in seconds).
- **Remote OpenTofu state** (S3/GCS) so several Macs can manage the same machines.
- **Cloud budgets** created natively (AWS Budgets / GCP Budgets) as an authoritative backstop.
- **Mac instances** as an explicit preset.

## 14. Risks

- **Price estimates drift from bills** (egress, discounts). Mitigated by the "est." label,
  TTL-bounded worst case, and the native-budget follow-up.
- **A missed destroy costs money.** Mitigated by the double TTL (§7.2), idle reaping, orphan
  scan, and labels on every resource.
- **The HuJSON policy edit is the most fragile automation.** It always shows the diff, uses
  the ETag guard, and falls back to copy-and-open rather than rewriting the file.
- **Managed tool downloads depend on upstream release URLs.** Pinned checksums make a moved
  or altered asset fail loudly; the user can always put a compatible copy on `PATH`.
