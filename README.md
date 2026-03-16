# Query_RHSubs

A bash script for querying Red Hat subscription and inventory data via the Red Hat APIs.

## Requirements

- `curl`
- `jq`
- A Red Hat offline token from <https://access.redhat.com/management/api>

## Usage

```bash
export OFFLINE_TOKEN='your_token_here'
./rhsubs.sh [OPTIONS] [COMMAND]
```

Or pass the token inline:

```bash
./rhsubs.sh -t <token> [COMMAND]
```

## Commands

### HCC Inventory (Recommended for SCA Accounts)

| Command | Description |
| --- | --- |
| `inventory` | List all hosts from HCC Inventory |
| `inventory-host <id>` | Get details for a single host |

### Subscriptions — RHSM v2 (HCC)

| Command | Description |
| --- | --- |
| `export` | Download a CSV of all subscriptions (default) |
| `products` | List subscribed products |
| `status` | Subscription counts: active / expired / future |
| `organization` | Organization details |
| `manifests` | List manifests (Satellite/SAM) |
| `activation-keys` | List activation keys |

### Systems & Allocations — RHSM v1 (Customer Portal)

| Command | Description |
| --- | --- |
| `systems` | List registered systems |
| `system <uuid>` | Get details for a single system |
| `system-errata <uuid>` | List applicable errata for a system |
| `system-packages <uuid>` | List packages for a system |
| `system-pools <uuid>` | List pools for a system |
| `allocations` | List subscription allocations |
| `allocation <uuid>` | Get details for a single allocation |
| `allocation-pools <uuid>` | List pools for an allocation |
| `subscription-content-sets <n>` | List content sets for a subscription number |
| `subscription-systems <n>` | List systems consuming a subscription number |
| `cloud-access` | List enabled cloud access providers |
| `errata` | List all errata for your systems |

## Options

| Flag | Description |
| --- | --- |
| `-t, --token TOKEN` | Offline token (or set `OFFLINE_TOKEN` env var) |
| `-o, --output FILE` | Save export output to a file |
| `-s, --status STATUS` | Filter products by status: `active`, `expired`, `future` |
| `-l, --limit N` | Max results per page (default: 100) |
| `--offset N` | Pagination offset (default: 0) |
| `-f, --filter STRING` | Filter by name |
| `-u, --username STRING` | Filter systems by owner username |
| `--json` | Print raw JSON output |
| `-d, --debug` | Show HTTP status and raw API response |

## v1 vs v2 — Which Should I Use for Systems?

Red Hat has two APIs for systems data depending on your account configuration:

### RHSM v1 — Customer Portal (`/systems`)

- The older API at `api.access.redhat.com`
- Works for accounts **without** Simple Content Access (SCA) enabled
- Systems must be directly registered to Red Hat (via `subscription-manager register`)
- Satellite-managed systems appear here but with limited detail
- If your account has SCA enabled, this endpoint returns very few or no systems

### HCC Inventory (`inventory` command)

- The newer API at `console.redhat.com/api/inventory/v1`
- **Recommended for accounts with SCA enabled**
- Powers the Systems Inventory view in the Red Hat Hybrid Cloud Console
- Includes systems registered via Satellite, Insights, and direct registration
- Returns richer host metadata (OS, FQDN, reporter, etc.)
- If you uploaded systems through Satellite and expect thousands of hosts, use this command

**Not sure which to use?** Run `./rhsubs.sh organization` — if your org has Simple Content Access enabled, use `inventory`.
