#!/bin/bash

################################################################################
# Red Hat Subscription Query Script
#
# Combines the HCC RHSM v2 API and the Customer Portal RHSM v1 API.
#
#   v2 base: https://console.redhat.com/api/rhsm/v2
#   v1 base: https://api.access.redhat.com/management/v1
#
# Requirements:
#   - curl
#   - jq
#   - Offline token from https://access.redhat.com/management/api
################################################################################

SSO_TOKEN_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
CLIENT_ID="rhsm-api"
V2_BASE="https://console.redhat.com/api/rhsm/v2"
V1_BASE="https://api.access.redhat.com/management/v1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [COMMAND] [ARGS]

Default command: export

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

OPTIONS:
  -t, --token TOKEN      Offline token (or set OFFLINE_TOKEN env var)
  -o, --output FILE      Save export output to a file (export command only)
  -s, --status STATUS    Filter products by status: active, expired, future
  -l, --limit N          Max results per page (default: 100)
  --offset N             Pagination offset (default: 0)
  -f, --filter STRING    Filter systems by name
  -u, --username STRING  Filter systems by owner username
  --json                 Print raw JSON output (v1 commands)
  -d, --debug            Show HTTP status and raw API response
  -h, --help             Show this help message

ENVIRONMENT VARIABLES:
  OFFLINE_TOKEN          Red Hat offline token

EXAMPLES:
  export OFFLINE_TOKEN='your_token_here'

  $(basename "$0")                            # download subscription CSV
  $(basename "$0") export -o subs.csv        # save CSV to file
  $(basename "$0") status                     # active/expired/future counts
  $(basename "$0") products -s active         # active products only
  $(basename "$0") organization               # org details
  $(basename "$0") systems                    # list registered systems
  $(basename "$0") system-errata <uuid>       # errata for a system
  $(basename "$0") allocations                # list allocations
  $(basename "$0") -l 50 systems              # paginate results
  $(basename "$0") -f web-server systems      # filter by name
  $(basename "$0") --json systems             # raw JSON output
  $(basename "$0") --debug status             # show HTTP details
EOF
    exit 0
}

##############################################################################
# Helpers
##############################################################################

err()  { echo -e "${RED}$*${NC}" >&2; }
ok()   { echo -e "${GREEN}$*${NC}" >&2; }
info() { echo -e "${CYAN}$*${NC}" >&2; }
warn() { echo -e "${YELLOW}$*${NC}" >&2; }

require_jq() {
    if ! command -v jq &>/dev/null; then
        err "jq is required but not installed. Install: brew install jq"
        exit 1
    fi
}

##############################################################################
# Auth
##############################################################################

get_access_token() {
    local offline_token=$1
    if [[ -z "$offline_token" ]]; then
        err "Offline token is required."
        err "Provide it via -t/--token or the OFFLINE_TOKEN environment variable."
        err "Generate one at: https://access.redhat.com/management/api"
        exit 1
    fi

    info "Authenticating..."

    local tmpfile http_code body
    tmpfile=$(mktemp)

    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X POST "$SSO_TOKEN_URL" \
        -d "grant_type=refresh_token" \
        -d "client_id=$CLIENT_ID" \
        -d "refresh_token=$offline_token")
    body=$(cat "$tmpfile"); rm -f "$tmpfile"

    if [[ "$http_code" != "200" ]]; then
        err "Authentication failed (HTTP $http_code)."
        err "$(echo "$body" | jq -r '.error_description // .error // .' 2>/dev/null || echo "$body")"
        err "Generate a new token at: https://access.redhat.com/management/api"
        exit 1
    fi

    local token
    token=$(echo "$body" | jq -r '.access_token // empty')
    if [[ -z "$token" ]]; then
        err "Could not extract access token."
        err "$body"
        exit 1
    fi

    echo "$token"
}

##############################################################################
# API request
# Usage: api_get <full_url> [accept_header]
# Result stored in API_BODY; returns 0 on success, 1 on error.
##############################################################################

API_BODY=""

api_get() {
    local url=$1 accept=${2:-"application/json"}
    API_BODY=""

    local tmpfile http_code
    tmpfile=$(mktemp)

    info "GET $url"

    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Accept: $accept" \
        --compressed \
        "$url")
    API_BODY=$(cat "$tmpfile"); rm -f "$tmpfile"

    if [[ "$DEBUG" == "true" ]]; then
        warn "HTTP $http_code  →  $url"
        echo "$API_BODY" >&2
        echo "" >&2
    fi

    case "$http_code" in
        200|201|204) return 0 ;;
        400)
            err "Error 400 Bad Request: $url"
            err "$(echo "$API_BODY" | jq -r '.message // .error // .' 2>/dev/null || echo "$API_BODY")"
            return 1 ;;
        401|403)
            err "Error $http_code Unauthorized. Re-run to refresh your token."
            return 1 ;;
        404)
            err "Error 404 Not Found: $url"
            return 1 ;;
        429)
            err "Error 429 Rate Limited: $(echo "$API_BODY" | jq -r '.message // "Too many requests"' 2>/dev/null)"
            return 1 ;;
        *)
            err "Error HTTP $http_code: $url"
            err "$(echo "$API_BODY" | jq -r '.message // .error // .' 2>/dev/null || echo "$API_BODY")"
            return 1 ;;
    esac
}

build_query() {
    local extra=${1:-}
    local q="?limit=${LIMIT}&offset=${OFFSET}"
    [[ -n "$extra" ]] && q="${q}&${extra}"
    echo "$q"
}

# Print formatted rows from a jq filter; fall back to raw JSON on failure.
print_table() { echo "$API_BODY" | jq -r "$1" 2>/dev/null || echo "$API_BODY" | jq '.'; }

output_json() { echo "$API_BODY" | jq '.'; }

##############################################################################
# V2 Commands (HCC)
##############################################################################

cmd_export() {
    info "Fetching subscription CSV export..."
    api_get "${V2_BASE}/products/export" "text/csv" || exit 1

    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$API_BODY" > "$OUTPUT_FILE"
        ok "Saved to $OUTPUT_FILE"
    else
        echo "$API_BODY"
    fi
}

cmd_products() {
    info "Fetching products..."
    local extra=""
    [[ -n "$STATUS_FILTER" ]] && extra="status=${STATUS_FILTER}"
    local qs
    qs=$(build_query "$extra")

    api_get "${V2_BASE}/products${qs}" || exit 1

    echo ""
    echo "Subscribed Products:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .products // .) |
        if type == "array" then .[] else . end |
        "  Name:     \(.name // "N/A")
  SKU:      \(.sku // "N/A")
  Status:   \(.status // "N/A")
  Quantity: \(.quantity // "N/A")
  Start:    \(.startDate // "N/A")
  End:      \(.endDate // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_status() {
    info "Fetching subscription status summary..."
    api_get "${V2_BASE}/products/status" || exit 1

    echo ""
    echo "Subscription Status Summary:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .) |
        "  Active:       \(.active // "N/A")
  Expired:      \(.expired // "N/A")
  Future Dated: \(.futureDated // "N/A")"'
}

cmd_organization() {
    info "Fetching organization details..."
    api_get "${V2_BASE}/organization" || exit 1

    echo ""
    echo "Organization:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .) |
        "  ID:          \(.id // "N/A")
  Name:        \(.name // "N/A")
  SCA Enabled: \(.simpleContentAccess // "N/A")"'
}

cmd_manifests() {
    info "Fetching manifests..."
    local qs
    qs=$(build_query)
    api_get "${V2_BASE}/manifests${qs}" || exit 1

    local count
    count=$(echo "$API_BODY" | jq -r '.pagination.count // (.body | length) // 0' 2>/dev/null)
    echo ""
    echo "Manifests ($count results):"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .manifests // .) |
        if type == "array" then .[] else . end |
        "  UUID:    \(.uuid // "N/A")
  Name:    \(.name // "N/A")
  Type:    \(.type // "N/A")
  Version: \(.version // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_activation_keys() {
    info "Fetching activation keys..."
    api_get "${V2_BASE}/activation_keys" || exit 1

    local count
    count=$(echo "$API_BODY" | jq -r '.body | length // 0' 2>/dev/null)
    echo ""
    echo "Activation Keys ($count):"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .) |
        if type == "array" then .[] else . end |
        "  Name:  \(.name // "N/A")
  Role:  \(.role // "N/A")
  SLA:   \(.serviceLevel // "N/A")
  Usage: \(.usage // "N/A")
  SCA:   \(.contentAccessMode // "N/A")
────────────────────────────────────────────────────────────────"'
}

##############################################################################
# V1 Commands (Customer Portal)
##############################################################################

cmd_systems() {
    info "Querying systems..."
    local extra=""
    [[ -n "$FILTER" ]]   && extra+="filter=${FILTER}&"
    [[ -n "$USERNAME" ]] && extra+="username=${USERNAME}&"
    extra="${extra%&}"
    local qs
    qs=$(build_query "$extra")

    api_get "${V1_BASE}/systems${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    local count
    count=$(echo "$API_BODY" | jq -r '.pagination.count // (.body | length) // 0' 2>/dev/null)
    echo ""
    echo "Systems ($count results, offset $OFFSET):"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .systems // .) |
        if type == "array" then .[] else . end |
        "  UUID:         \(.uuid // "N/A")
  Name:         \(.name // "N/A")
  Type:         \(.type // "N/A")
  Created:      \(.created // "N/A")
  Last Checkin: \(.lastCheckin // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_system() {
    local uuid=$1
    [[ -z "$uuid" ]] && { err "system UUID required."; exit 1; }
    info "Querying system $uuid..."

    api_get "${V1_BASE}/systems/${uuid}?include=facts" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "System $uuid:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .) |
        "  UUID:         \(.uuid // "N/A")
  Name:         \(.name // "N/A")
  Type:         \(.type // "N/A")
  Created:      \(.created // "N/A")
  Last Checkin: \(.lastCheckin // "N/A")
  Entitlements: \(.entitlementCount // "N/A")"'
}

cmd_system_errata() {
    local uuid=$1
    [[ -z "$uuid" ]] && { err "system UUID required."; exit 1; }
    info "Querying errata for system $uuid..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/systems/${uuid}/errata${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Errata for System $uuid:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .errata // .) |
        if type == "array" then .[] else . end |
        "  Advisory: \(.advisoryName // "N/A")
  Type:     \(.advisoryType // "N/A")
  Synopsis: \(.synopsis // "N/A")
  Date:     \(.date // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_system_packages() {
    local uuid=$1
    [[ -z "$uuid" ]] && { err "system UUID required."; exit 1; }
    info "Querying packages for system $uuid..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/systems/${uuid}/packages${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Packages for System $uuid:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .packages // .) |
        if type == "array" then .[] else . end |
        "  \(.name // "N/A")-\(.version // "")-\(.release // "") (\(.arch // "N/A"))"'
}

cmd_system_pools() {
    local uuid=$1
    [[ -z "$uuid" ]] && { err "system UUID required."; exit 1; }
    info "Querying pools for system $uuid..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/systems/${uuid}/pools${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Pools for System $uuid:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .pools // .) |
        if type == "array" then .[] else . end |
        "  Pool:     \(.id // "N/A")
  SKU:      \(.productId // "N/A")
  Name:     \(.productName // "N/A")
  Quantity: \(.quantity // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_allocations() {
    info "Querying allocations..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/allocations${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    local count
    count=$(echo "$API_BODY" | jq -r '.pagination.count // (.body | length) // 0' 2>/dev/null)
    echo ""
    echo "Allocations ($count results, offset $OFFSET):"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .allocations // .) |
        if type == "array" then .[] else . end |
        "  UUID:         \(.uuid // "N/A")
  Name:         \(.name // "N/A")
  Type:         \(.type // "N/A")
  Version:      \(.version // "N/A")
  SCA:          \(.simpleContentAccess // "N/A")
  Entitlements: \(.entitlementQuantity // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_allocation() {
    local uuid=$1
    [[ -z "$uuid" ]] && { err "allocation UUID required."; exit 1; }
    info "Querying allocation $uuid..."

    api_get "${V1_BASE}/allocations/${uuid}?include=entitlements" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Allocation $uuid:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .) |
        "  UUID:         \(.uuid // "N/A")
  Name:         \(.name // "N/A")
  Type:         \(.type // "N/A")
  Version:      \(.version // "N/A")
  SCA:          \(.simpleContentAccess // "N/A")
  Entitlements: \(.entitlementsAttachedQuantity // "N/A")
  Created By:   \(.createdBy // "N/A")
  Created:      \(.createdDate // "N/A")
  Modified:     \(.lastModified // "N/A")"'
}

cmd_allocation_pools() {
    local uuid=$1
    [[ -z "$uuid" ]] && { err "allocation UUID required."; exit 1; }
    info "Querying pools for allocation $uuid..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/allocations/${uuid}/pools${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Pools for Allocation $uuid:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .pools // .) |
        if type == "array" then .[] else . end |
        "  Pool ID:    \(.id // "N/A")
  SKU:        \(.productId // "N/A")
  Name:       \(.productName // "N/A")
  Quantity:   \(.quantity // "N/A")
  Start Date: \(.startDate // "N/A")
  End Date:   \(.endDate // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_subscription_content_sets() {
    local sub_num=$1
    [[ -z "$sub_num" ]] && { err "subscription number required."; exit 1; }
    info "Querying content sets for subscription $sub_num..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/subscriptions/${sub_num}/contentSets${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Content Sets for Subscription $sub_num:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '(.body // .) | if type == "array" then .[] else . end | "  \(.)"'
}

cmd_subscription_systems() {
    local sub_num=$1
    [[ -z "$sub_num" ]] && { err "subscription number required."; exit 1; }
    info "Querying systems consuming subscription $sub_num..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/subscriptions/${sub_num}/systems${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Systems Consuming Subscription $sub_num:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .systems // .) |
        if type == "array" then .[] else . end |
        "  UUID: \(.uuid // "N/A")
  Name: \(.name // "N/A")
────────────────────────────────────────────────────────────────"'
}

cmd_cloud_access() {
    info "Querying cloud access providers..."
    api_get "${V1_BASE}/cloud_access_providers/enabled" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    echo ""
    echo "Enabled Cloud Access Providers:"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .) |
        if type == "array" then .[] else . end |
        "  Provider:   \(.name // "N/A")
  Short Name: \(.shortName // "N/A")
  Accounts:   \(.accounts | length // 0)
────────────────────────────────────────────────────────────────"'
}

cmd_errata() {
    info "Querying errata..."
    local qs
    qs=$(build_query)

    api_get "${V1_BASE}/errata${qs}" || exit 1
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then output_json; return; fi

    local count
    count=$(echo "$API_BODY" | jq -r '.pagination.count // (.body | length) // 0' 2>/dev/null)
    echo ""
    echo "Errata ($count results, offset $OFFSET):"
    echo "────────────────────────────────────────────────────────────────"
    print_table '
        (.body // .errata // .) |
        if type == "array" then .[] else . end |
        "  Advisory: \(.advisoryName // "N/A")
  Type:     \(.advisoryType // "N/A")
  Synopsis: \(.synopsis // "N/A")
  Date:     \(.date // "N/A")
────────────────────────────────────────────────────────────────"'
}

##############################################################################
# Main
##############################################################################

main() {
    require_jq

    local offline_token="" command=""
    local args=()
    OUTPUT_FILE=""
    STATUS_FILTER=""
    OUTPUT_FORMAT="text"
    FILTER=""
    USERNAME=""
    LIMIT=100
    OFFSET=0
    DEBUG=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--token)    offline_token="$2"; shift 2 ;;
            -o|--output)   OUTPUT_FILE="$2";   shift 2 ;;
            -s|--status)   STATUS_FILTER="$2"; shift 2 ;;
            -l|--limit)    LIMIT="$2";         shift 2 ;;
            --offset)      OFFSET="$2";        shift 2 ;;
            -f|--filter)   FILTER="$2";        shift 2 ;;
            -u|--username) USERNAME="$2";      shift 2 ;;
            --json)        OUTPUT_FORMAT="json"; shift ;;
            -d|--debug)    DEBUG=true;         shift ;;
            -h|--help)     usage ;;
            -*) err "Unknown option: $1"; usage ;;
            *)
                if [[ -z "$command" ]]; then
                    command="$1"
                else
                    args+=("$1")
                fi
                shift ;;
        esac
    done

    [[ -z "$offline_token" ]] && offline_token="${OFFLINE_TOKEN:-}"
    [[ -z "$command" ]] && command="export"

    ACCESS_TOKEN=$(get_access_token "$offline_token")
    export ACCESS_TOKEN
    ok "Authenticated successfully."

    case "$command" in
        # V2 — HCC
        export)                   cmd_export ;;
        products)                 cmd_products ;;
        status)                   cmd_status ;;
        organization)             cmd_organization ;;
        manifests)                cmd_manifests ;;
        activation-keys)          cmd_activation_keys ;;
        # V1 — Customer Portal
        systems)                  cmd_systems ;;
        system)                   cmd_system "${args[0]:-}" ;;
        system-errata)            cmd_system_errata "${args[0]:-}" ;;
        system-packages)          cmd_system_packages "${args[0]:-}" ;;
        system-pools)             cmd_system_pools "${args[0]:-}" ;;
        allocations)              cmd_allocations ;;
        allocation)               cmd_allocation "${args[0]:-}" ;;
        allocation-pools)         cmd_allocation_pools "${args[0]:-}" ;;
        subscription-content-sets) cmd_subscription_content_sets "${args[0]:-}" ;;
        subscription-systems)     cmd_subscription_systems "${args[0]:-}" ;;
        cloud-access)             cmd_cloud_access ;;
        errata)                   cmd_errata ;;
        *)  err "Unknown command: $command"; usage ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
