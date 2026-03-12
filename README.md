# rhsubs — Red Hat Subscription Query Script

A single bash script for querying Red Hat subscription data across both APIs:

| API | Base URL | Used for |
| --- | --- | --- |
| HCC RHSM v2 | `console.redhat.com/api/rhsm/v2` | Subscription export, products, manifests, activation keys |
| Customer Portal RHSM v1 | `api.access.redhat.com/management/v1` | Systems, allocations, errata, pools |

## Prerequisites

- `curl` — pre-installed on macOS
- `jq` — `brew install jq`

## Setup

1. Visit [access.redhat.com/management/api](https://access.redhat.com/management/api) and click **Generate Token**

2. Store it in your environment:

   ```bash
   export OFFLINE_TOKEN='your_offline_token_here'
   ```

   Add that line to `~/.zshrc` or `~/.bash_profile` to persist it.

> **Security:** Treat tokens like passwords. Never commit them to version control. They expire after 30 days of inactivity.

---

## Usage

```text
./rhsubs.sh [OPTIONS] [COMMAND] [ARGS]

Default command: export
```

### Commands

```text
── Subscriptions (HCC RHSM v2) ─────────────────────────────────────────────
  export                        Download a CSV of all subscriptions (default)
  products                      List subscribed products
  status                        Subscription counts: active / expired / future
  organization                  Organization details
  manifests                     List manifests (Satellite/SAM)
  activation-keys               List activation keys

── Systems & Allocations (Customer Portal RHSM v1) ──────────────────────────
  systems                       List all registered systems
  system UUID                   Get details for a single system
  system-errata UUID            List applicable errata for a system
  system-packages UUID          List packages for a system
  system-pools UUID             List pools for a system

  allocations                   List subscription allocations
  allocation UUID               Get details for a single allocation
  allocation-pools UUID         List pools for an allocation

  subscription-content-sets N   List content sets for a subscription number
  subscription-systems N        List systems consuming a subscription number

  cloud-access                  List enabled cloud access providers
  errata                        List all errata for your systems
```

### Options

```text
  -t, --token TOKEN      Offline token (or set OFFLINE_TOKEN env var)
  -o, --output FILE      Save export output to a file (export command only)
  -s, --status STATUS    Filter products by status: active, expired, future
  -l, --limit N          Max results per page (default: 100)
  --offset N             Pagination offset (default: 0)
  -f, --filter STRING    Filter systems by name
  -u, --username STRING  Filter systems by owner username
  --json                 Print raw JSON output (v1 commands)
  -d, --debug            Show HTTP status and raw API response
```

---

## Examples

```bash
export OFFLINE_TOKEN='your_token_here'

# Subscription export (default — no command needed)
./rhsubs.sh
./rhsubs.sh -o subscriptions.csv

# Quick subscription summary
./rhsubs.sh status

# List products, optionally filtered by status
./rhsubs.sh products
./rhsubs.sh products -s active
./rhsubs.sh products -s expired

# Org details
./rhsubs.sh organization

# Manifests and activation keys
./rhsubs.sh manifests
./rhsubs.sh activation-keys

# List systems, drill into one
./rhsubs.sh systems
./rhsubs.sh system <uuid>
./rhsubs.sh system-errata <uuid>
./rhsubs.sh system-packages <uuid>

# Allocations
./rhsubs.sh allocations
./rhsubs.sh allocation <uuid>
./rhsubs.sh allocation-pools <uuid>

# Pagination
./rhsubs.sh -l 50 --offset 100 systems

# Filter systems by name
./rhsubs.sh -f web-server systems

# Raw JSON output
./rhsubs.sh --json systems

# Debug — show HTTP status and raw response
./rhsubs.sh --debug status
```

---

## Troubleshooting

| Error | Cause | Fix |
| --- | --- | --- |
| `401 / 403` | Expired access token | Re-run — a fresh token is fetched each time |
| `429 Rate Limited` | Too many requests | Wait and retry |
| HTML response | Hit a browser UI route, not an API route | Ensure the URL contains `/api/` |

## Resources

- [API Token Generator](https://access.redhat.com/management/api)
- [HCC RHSM v2 API Catalog](https://developers.redhat.com/api-catalog/api/rhsm)
- [Customer Portal API Docs](https://docs.redhat.com/en/documentation/subscription_central/1-latest/html/using_apis_in_red_hat_subscription_management/index)
