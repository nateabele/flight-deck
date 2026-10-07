# Cloud infra hosts: probe findings (P1 to P4)

Date: 2026-10-07. Research only. No cloud or Tailscale API was called, nothing was installed, no credentials were used.
Each finding says how it was verified: **doc** (read on an official page this session), **third party** (price aggregator), or **memory** (not re-verified; treat as unverified).

## P1: Tailscale OAuth-client creation by API

**Question.** Can an OAuth client be created through `POST /api/v2/tailnet/{tailnet}/keys` with `keyType: "client"`, or through any other endpoint?

**Answer. Not confirmed; plan as "no".**
- The OAuth clients page documents one way to create a client: the admin console, Trust credentials page, "Credential", "OAuth" (doc).
- Nothing in the OAuth clients page, the API access-token page or the search results describes an API call that creates an OAuth client (doc). The interactive API reference at `tailscale.com/api` is a JavaScript page that the fetch tool could not render, so the `keyType` enum of the keys endpoint was NOT read directly. Absence of evidence, not proof of absence.
- What the docs do confirm: an OAuth client with the `auth_keys` scope MUST be given one or more tags, and it creates auth keys with `POST /api/v2/tailnet/:tailnet/keys` (doc). The token endpoint is `https://api.tailscale.com/api/v2/oauth/token`; an access token lives one hour (doc).
- Access tokens (the "API keys" made on the Keys page) are created by an Owner, Admin, IT admin or Network admin, with a 1 to 90 day expiry (doc).

**Sources.**
- https://tailscale.com/docs/features/oauth-clients
- https://tailscale.com/docs/reference/tailscale-api
- https://tailscale.com/api (not renderable by the fetch tool)

**Consequence.** Treat P1 as "no". Task 18's OAuth step stays the manual checklist (admin console, Trust credentials, OAuth, scope `auth_keys`, at least one tag). Do not build an automatic path. If someone later reads the live API reference and finds a `client` key type, Task 18 can add the automatic path without changing other tasks. Open item for Nate: confirm in the interactive API reference whether `keyType` accepts `client`.

## P2: GCP `max_run_duration` with `instance_termination_action = DELETE`

**Question.** Does `google_compute_instance` support `scheduling { max_run_duration, instance_termination_action }`, and what are the limits?

**Answer. Yes.**
- `max_run_duration` and `instance_termination_action` (`STOP` or `DELETE`) are arguments of the `scheduling` block (doc).
- Provider version: search results say the fields arrived in provider 5.37.0 (2024-07-08) and were promoted from the beta provider to GA later (one result says 7.46.1). Treat the version numbers as **third party / unverified**. Safe rule for the plan: require `hashicorp/google` `>= 7.46` (or any version whose docs show the field on `google_compute_instance`) and let `tofu init` fail fast otherwise. The upstream issue 13005 that asked for the feature was opened 2022-11-10.
- Standard, Spot and GPU VMs all support it (doc). Spot VMs default the termination action to `STOP`; `instance_termination_action` is required for all other VMs (doc).
- Limits: minimum 30 seconds, maximum 120 days; termination may run up to 30 seconds late; not for legacy preemptible VMs (doc).
- `provisioning_model` takes `STANDARD`, `SPOT`, `FLEX_START`, `RESERVATION_BOUND`. `FLEX_START` needs `automatic_restart = false`, `instance_termination_action = DELETE` and a `max_run_duration` (doc).
- GPUs: "GPU accelerators can only be used with `on_host_maintenance` set to TERMINATE" (doc). A `g2` machine type has its L4 attached, so the module must set `on_host_maintenance = "TERMINATE"` for it.
- `SPOT` requires `preemptible = true` and `automatic_restart = false` per the provider docs (doc).
- VMs with local SSD and action `STOP` also need `on_instance_stop_action` (doc). Not relevant to the plan's machine types, which use persistent disk only.

**Sources.**
- https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance
- https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime
- https://github.com/hashicorp/terraform-provider-google/issues/13005

**Consequence.** The GCP module (hard TTL by `DELETE`) is viable as specified. The module must: set `max_run_duration` from the lease, set `instance_termination_action = "DELETE"`, set `on_host_maintenance = "TERMINATE"` and `automatic_restart = false` whenever the machine type is `g2-*`, and pin a provider constraint. Add a note to the GCP module task: when the module is validated, run `tofu validate` against the pinned version to confirm the field is accepted (no cloud call needed).

## P3: per-user AWS CLI install on macOS

**Question.** What is the no-sudo install, its choices XML and the binary path?

**Answer.** (doc, current AWS CLI user guide)
- AWS now also documents an install script that installs for the current user by default: `curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash`. It installs to `$HOME/.local/share/aws-cli` and symlinks in `$HOME/.local/bin` (override with `XDG_DATA_HOME`, `XDG_BIN_HOME`). `--system` makes it all-users.
- The pkg route the brief names is also documented as "Command line - Current user":

```
installer -pkg AWSCLIV2.pkg -target CurrentUserHomeDirectory -applyChoiceChangesXML choices.xml
```

`choices.xml` (replace the path; the folder MUST already exist or the command fails):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <array>
    <dict>
      <key>choiceAttribute</key>
      <string>customLocation</string>
      <key>attributeSetting</key>
      <string>/Users/EXAMPLE</string>
      <key>choiceIdentifier</key>
      <string>default</string>
    </dict>
  </array>
</plist>
```

- Resulting binary: `<attributeSetting>/aws-cli/aws` (and `.../aws-cli/aws_completer`). Example: `attributeSetting` = `/Users/EXAMPLE/.flightdeck/tools` gives `/Users/EXAMPLE/.flightdeck/tools/aws-cli/aws`.
- In this mode the installer does NOT create symlinks. Flight Deck should call the binary by absolute path and must not rely on `PATH`.
- Install paths must have no spaces (that rule is stated for the Linux `-i`/`-b` flags; keep the same rule here as a precaution, since "Application Support" contains a space).
- `aws update` updates in place and keeps the current-user choice.
- Debug log of the pkg install: `/var/log/install.log`.

**Sources.** https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

**Consequence.** Pick an install dir WITHOUT spaces (for example `~/.flightdeck/tools`, not `~/Library/Application Support/...`). The installer step in the plan should: write `choices.xml`, `mkdir -p` the folder, run `installer` with `CurrentUserHomeDirectory`, and record the absolute `aws-cli/aws` path. The `install.sh` route is simpler (no XML, no `mkdir`) but its curl-pipe-bash shape and `XDG` paths are less pinned; prefer the pkg route if the task needs a verified, versioned download, otherwise the script. Not verified: whether `installer` with `CurrentUserHomeDirectory` prompts for authorization on macOS 26 (cannot test without installing).

## P4: GCP SKU mapping and fixture prices (us-central1)

**Question.** Which Cloud Billing Catalog SKU description patterns map to `e2`, `n2`, `g2` vCPU, RAM and `nvidia-l4` GPU, and what are the on-demand prices?

**Answer.**
- Catalog structure (doc): SKU = display name + service ID + product taxonomy + geo taxonomy; prices carry a currency code, tiered rates, a unit (hours, gibibyte months), and an aggregation interval. The doc example for Compute Engine's service ID is `6F81-5844-456A` (the page itself calls it illustrative; confirm with the services list at implementation time). Doc example display names: "L4 GPU attached to Spot Preemptible VMs running in Hong Kong", "Sole Tenancy Instance Ram running in Turin".
- Description patterns for on-demand, **memory, not re-verified** (the fetch tool could not read the SKU listing). Use as regexes and keep the fixture tolerant:
  - `E2 Instance Core running in Americas`, `E2 Instance Ram running in Americas`
  - `N2 Instance Core running in Americas`, `N2 Instance Ram running in Americas`
  - `G2 Instance Core running in Americas`, `G2 Instance Ram running in Americas`
  - `Nvidia L4 GPU running in Americas`
  - Spot variants add `Spot Preemptible` ("... attached to Spot Preemptible VMs ..."). Commitment SKUs say `Commitment`. Exclude both.
  - "Americas" is the multi-region label; the SKU's `serviceRegions` list is what includes `us-central1`. Match on `serviceRegions`, not on the description.
- Whole-machine on-demand prices, us-central1, Linux (third party aggregators, consistent across two sources each):

| Machine type | vCPU / RAM | USD per hour | Source |
|---|---|---|---|
| `e2-standard-2` | 2 / 8 GiB | 0.067 | devzero, spendark |
| `n2-standard-4` | 4 / 16 GiB | 0.1942 (0.194) | cloudprice.net, devzero |
| `g2-standard-4` | 4 / 16 GiB + 1 x L4 | 0.7068 | holori, economize.cloud |

- Component rates implied by the n2 numbers (cloudprice.net): about 0.0486 per vCPU-hour and 0.0121 per GiB-hour as an average. Recalled list rates, **memory**: N2 core 0.031611, N2 RAM 0.004237, E2 core 0.02181159, E2 RAM 0.00292353 (these reproduce 0.1942 and 0.0670 exactly, which supports them). G2 per-component rates and the L4 rate were not obtained; do not put them in a fixture as facts.
- Google's own pricing pages (`cloud.google.com/compute/all-pricing`, `.../vm-instance-pricing`) were too large for the fetch tool, so these are not first-party quotes.

**Sources.**
- https://docs.cloud.google.com/billing/docs/how-to/get-pricing-information-api
- https://cloudprice.net/gcp/compute/instances/n2-standard-4
- https://calculator.holori.com/gcp/vm/g2-standard-4/us-central1?os=Linux
- https://www.devzero.io/instances/gcp/e2-standard-2
- https://www.economize.cloud/resources/gcp/pricing/compute-engine/g2-standard-4/

**Consequence.** Task 11 fixtures: build a synthetic SKU list whose per-unit prices are the recalled E2 and N2 list rates above (they sum to the whole-machine numbers), and assert the estimator returns about 0.0670, 0.1942 and (for g2) a value you choose in the fixture, labelled as a fixture value. Use a tolerance of 0.001 USD per hour. For g2, use a fixture-only split (for example L4 = 0.5600 per hour, remainder across the G2 core and RAM SKUs summing to 0.7068) and say so in the test comment; the real catalog must be checked once by a human before release. Match SKUs by `serviceRegions` and a description regex, never by exact string. No task changes beyond Task 11's fixture numbers.

## Summary of plan impact

| Probe | Result | Plan change |
|---|---|---|
| P1 | No documented API to create OAuth clients | Task 18 keeps the manual checklist; confirm in the live API reference if desired |
| P2 | Supported, GA, DELETE allowed, GPU needs TERMINATE | GCP module: g2 sets `on_host_maintenance = "TERMINATE"`; pin provider constraint |
| P3 | pkg with choices XML works, no symlink created | Absolute binary path; install dir without spaces |
| P4 | Prices found via aggregators; SKU patterns partly from memory | Task 11 uses synthetic fixtures with tolerance; one human check on the real catalog |
