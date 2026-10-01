#!/usr/bin/env bash
# provision.sh — Bootstrap Infisical infrastructure for dotfiles.
#
# This script is run ONCE (idempotent) by a human operator who has access to
# the Infisical **Provisioner** machine identity. That identity must have:
#   - Organization-level role that can create projects
#   - Ability to create child machine identities and assign them roles
#
# The Provisioner identity NEVER reads secret values. It only provisions:
#   1. Projects (backend, godocs, mcp-servers) with required environments
#   2. Child machine identities scoped to individual projects (reader-only)
#   3. Age-encrypts each child identity's client-id / client-secret

set -euo pipefail

PROG="$(basename "$0")"
INFISICAL_DIR="$(cd "$(dirname "$0")" && pwd)"
CHILDREN_DIR="$INFISICAL_DIR/children"

# ──────────────────────────────────────────────────────────────────────────────
# Configuration — override via environment or edit below
# ──────────────────────────────────────────────────────────────────────────────

# Path to the Provisioner's Universal Auth credentials (human-held).
PROVISIONER_CLIENT_ID="${INFISICAL_PROVISIONER_CLIENT_ID:-}"
PROVISIONER_CLIENT_SECRET="${INFISICAL_PROVISIONER_CLIENT_SECRET:-}"
INFISICAL_ADDRESS="${INFISICAL_ADDRESS:-https://app.infisical.com}"

# Organization ID — required for identity creation API.
ORG_ID="${INFISICAL_ORG_ID:-}"
if [[ -z "$ORG_ID" ]]; then
  echo "⚠ INFISICAL_ORG_ID not set. Get it from your Infisical org settings." >&2
  echo "   Export it as: export INFISICAL_ORG_ID=<your-org-id>" >&2
fi

# Which projects to ensure exist. Each entry: "<slug>:<env1>,<env2>"
PROJECTS=(
  "backend:dev,prod"
  "godocs:dev"
  "mcp-servers:dev"
)

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

err() { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

info() { printf '→ %s\n' "$*" >&2; }

# Authenticate as the Provisioner and return a Bearer token.
provisioner_token() {
  if [[ -z "$PROVISIONER_CLIENT_ID" || -z "$PROVISIONER_CLIENT_SECRET" ]]; then
    die "Set INFISICAL_PROVISIONER_CLIENT_ID and INFISICAL_PROVISIONER_CLIENT_SECRET env vars."
  fi

  # CR fix: Use jq to build JSON safely (avoids quote/backslash injection)
  local resp
  resp="$(curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/auth/universal-auth/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg cid "$PROVISIONER_CLIENT_ID" --arg csec "$PROVISIONER_CLIENT_SECRET" \
       '{clientId: $cid, clientSecret: $csec}')" 2>/dev/null)" || \
    die "Failed to authenticate as Provisioner. Check credentials."

  echo "$resp" | jq -r '.accessToken'
}

# Ensure a project exists; return its UUID.
ensure_project() {
  local slug="$1" token="$2"
  local resp
  resp="$(curl -sf "$INFISICAL_ADDRESS/api/v1/projects?includeRoles=true" \
    -H "Authorization: Bearer $token")" || \
    die "Failed to list projects."

  local existing
  existing="$(echo "$resp" | jq -r --arg s "$slug" \
    '.projects[] | select(.slug == $s) | .id')"

  if [[ -n "$existing" ]]; then
    info "Project '$slug' already exists (id: $existing)"
    echo "$existing"
    return
  fi

  info "Creating project '$slug'..."
  local create_resp
  create_resp="$(curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/projects" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "$slug" --arg slug "$slug" \
       '{projectName: $name, slug: $slug}')" 2>/dev/null)" || \
    die "Failed to create project '$slug'."

  echo "$create_resp" | jq -r '.project.id'
}

# Ensure environments exist on a project.
ensure_environments() {
  local project_id="$1" envs_csv="$2" token="$3"
  IFS=',' read -ra envs <<< "$envs_csv"

  # Fetch current environments
  local env_list
  env_list="$(curl -sf "$INFISICAL_ADDRESS/api/v1/projects/$project_id/environments" \
    -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.environments[].slug' 2>/dev/null || true)"

  for env in "${envs[@]}"; do
    if echo "$env_list" | grep -qx "$env"; then
      info "  Environment '$env' already exists on project '$project_id'"
    else
      info "  NOTE: Environment '$env' will be auto-created on first secret write."
    fi
  done
}

# Create (or ensure exists) a child machine identity with reader role on a project.
ensure_child_identity() {
  local project_id="$1" child_name="$2" token="$3"

  # CR fix: Use memberships/identities endpoint, parse identityMemberships response
  local resp
  resp="$(curl -sf "$INFISICAL_ADDRESS/api/v1/projects/$project_id/memberships/identities?offset=0&limit=100" \
    -H "Authorization: Bearer $token")" || \
    die "Failed to list identity memberships for project $project_id."

  local existing_id
  existing_id="$(echo "$resp" | jq -r --arg n "$child_name" \
    '.identityMemberships[] | select(.identity.name == $n) | .identity.id')"

  if [[ -n "$existing_id" ]]; then
    info "Child identity '$child_name' already exists (id: $existing_id)"
    echo "$existing_id"
    return 0
  fi

  info "Creating child identity '$child_name' for project '$project_id'..."
  local create_resp
  create_resp="$(curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/identities" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "$child_name" --arg org "$ORG_ID" \
       '{name: $name, organizationId: $org}')" 2>/dev/null)" || \
    die "Failed to create child identity."

  local new_id
  new_id="$(echo "$create_resp" | jq -r '.identity.id')"

  # Add Universal Auth method to the child identity.
  curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/auth/universal-auth/identities/$new_id" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{}' >/dev/null || \
    die "Failed to add Universal Auth to child identity."

  # CR fix: Use project membership endpoint with role field
  curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/projects/$project_id/memberships/identities/$new_id" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"role":"viewer"}' >/dev/null || \
    die "Failed to assign viewer role to child identity."

  echo "$new_id"
}

# Fetch and age-encrypt child credentials into a secure temp directory.
store_child_credentials() {
  local identity_id="$1" child_name="$2" token="$3"
  local child_dir="$CHILDREN_DIR/$child_name"
  mkdir -p "$child_dir"

  # Read clientId from .identityUniversalAuth.clientId
  local auth_resp
  auth_resp="$(curl -sf "$INFISICAL_ADDRESS/api/v1/auth/universal-auth/identities/$identity_id" \
    -H "Authorization: Bearer $token")" || \
    die "Failed to get auth config for identity $identity_id."

  local client_id
  client_id="$(echo "$auth_resp" | jq -r '.identityUniversalAuth.clientId')"

  if [[ -z "$client_id" ]]; then
    die "No clientId returned for identity $identity_id."
  fi

  # Create a client secret via POST /client-secrets endpoint
  local client_secret=""
  local secret_resp
  secret_resp="$(curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/auth/universal-auth/identities/$identity_id/client-secrets" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null)" || warn "Could not create client secret (may already exist)."

  if [[ -n "$secret_resp" ]]; then
    client_secret="$(echo "$secret_resp" | jq -r '.clientSecret // empty')"
  fi

  # If no secret yet, try regenerating
  if [[ -z "$client_secret" ]]; then
    secret_resp="$(curl -sf -X POST "$INFISICAL_ADDRESS/api/v1/auth/universal-auth/identities/$identity_id/client-secrets" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d '{"regenerate": true}' 2>/dev/null)" || true
    client_secret="$(echo "$secret_resp" | jq -r '.clientSecret // empty')"
  fi

  if [[ -z "$client_secret" ]]; then
    die "Could not obtain client secret for identity $identity_id."
  fi

  # CR fix: Write plaintext creds into a secure mktemp dir, clean up on exit
  local tmpdir
  tmpdir="$(mktemp -d -p "$CHILDREN_DIR" "cred.XXXXXX")"
  chmod 700 "$tmpdir"
  trap 'rm -rf "$tmpdir"' EXIT INT TERM

  printf '%s' "$client_id" > "$tmpdir/client-id"
  printf '%s' "$client_secret" > "$tmpdir/client-secret"

  # Derive recipient from key file using age-keygen -y (BSD-compatible)
  local age_key="${INFISICAL_AGE_KEY_PATH:-$HOME/.config/chezmoi/key.txt}"
  if [[ ! -f "$age_key" ]]; then
    die "Age key not found at $age_key. Set INFISICAL_AGE_KEY_PATH."
  fi

  local recipient
  recipient="$(age-keygen -y "$age_key" 2>/dev/null | sed 's/#.*//' | tr -d '[:space:]')"
  if [[ -z "$recipient" ]]; then
    # Fallback: BSD grep doesn't support -P; use sed instead
    recipient="$(sed -n 's/^.*\(age1[^ ]*\).*/\1/p' "$age_key" 2>/dev/null | head -1)"
  fi
  if [[ -z "$recipient" ]]; then
    die "Could not determine age recipient from key file. Run: age-keygen"
  fi

  # Encrypt both files unconditionally, delete plaintext only after both succeed
  if ! age -e -r "$recipient" -o "$tmpdir/client-id.age" "$tmpdir/client-id" 2>/dev/null; then
    die "Failed to encrypt client-id"
  fi
  if ! age -e -r "$recipient" -o "$tmpdir/client-secret.age" "$tmpdir/client-secret" 2>/dev/null; then
    die "Failed to encrypt client-secret"
  fi

  # Move encrypted files to permanent location
  rm -rf "$child_dir"
  mv "$tmpdir" "$child_dir"
  chmod 700 "$child_dir"
  chmod 600 "$child_dir"/*

  # Remove trap since we moved the dir
  trap - EXIT INT TERM

  info "Credentials for '$child_name' stored age-encrypted in $child_dir/"
}

# Generate a child agent config for a given project.
generate_child_config() {
  local child_name="$1" project_slug="$2"
  local child_dir="$CHILDREN_DIR/$child_name"

  # Determine output filename based on project type
  local output_file
  case "$project_slug" in
    backend)     output_file="backend-secrets.env" ;;
    godocs)      output_file="r2-creds.env" ;;
    mcp-servers) output_file="mcp-secrets.env" ;;
    *)           output_file="${project_slug}-secrets.env" ;;
  esac

  # CR fix: Use absolute paths, concrete destination, no chezmoi expressions
  cat > "$INFISICAL_DIR/agent-${project_slug}.yaml" <<EOF
# Infisical Agent config for the '$project_slug' project.
# Reader-only — fetches secrets but cannot create or modify anything.
# Credentials are decrypted at startup by a wrapper script.

infisical:
  address: "$INFISICAL_ADDRESS"
  exit-after-auth: false
  revoke-credentials-on-shutdown: false
  retry-strategy:
    max-retries: 5
    max-delay: "10s"
    base-delay: "500ms"

auth:
  type: "universal-auth"
  config:
    client-id: "$child_dir/client-id.age"
    client-secret: "$child_dir/client-secret.age"

templates:
  - source-path: "$INFISICAL_DIR/templates/${project_slug}-secrets.tpl"
    destination-path: "\$HOME/.infisical/${output_file}"
    config:
      polling-interval: "5m"
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

main() {
  info "Infisical provisioner bootstrap"
  info "Address: $INFISICAL_ADDRESS"
  info "Org ID: $ORG_ID"

  if [[ -z "$ORG_ID" ]]; then
    die "INFISICAL_ORG_ID is required. Set it and re-run."
  fi

  local token
  token="$(provisioner_token)"

  for project_spec in "${PROJECTS[@]}"; do
    IFS=':' read -r slug envs_csv <<< "$project_spec"
    info "Processing project: $slug (environments: $envs_csv)"

    local project_id
    project_id="$(ensure_project "$slug" "$token")"

    ensure_environments "$project_id" "$envs_csv" "$token"

    local child_id
    child_id="$(ensure_child_identity "$project_id" "$slug-agent" "$token")"

    store_child_credentials "$child_id" "$slug" "$token"

    generate_child_config "$slug" "$slug"
  done

  info ""
  info "Provisioning complete."
  info "Next steps:"
  info "  1. Copy .infisical/agent-<project>.yaml → ~/.config/infisical/agent-<project>.yaml"
  info "  2. Start each agent: infisical agent --config ~/.config/infisical/agent-<project>.yaml"
  info "  3. Verify rendered files: ls ~/.infisical/*-secrets.env"
}

main "$@"
