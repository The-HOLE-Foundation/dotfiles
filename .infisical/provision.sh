#!/usr/bin/env bash
# provision.sh: set up reader identities for the Infisical agent.
#
#   provision.sh                 provision every project in projects.conf
#   provision.sh <slug>...       provision only these projects
#   provision.sh import <slug>   store credentials for an identity you made
#                                yourself (for example in the Infisical UI)
#
# A human operator runs this. Provisioning (not import) uses the Infisical
# **Provisioner** machine identity, which must have:
#   - Organization-level role that can create projects
#   - Ability to create child machine identities and assign them roles
#
# The Provisioner identity NEVER reads secret values. It only provisions:
#   1. Projects (from projects.conf) with required environments
#   2. Child machine identities scoped to individual projects (reader-only)
#   3. Age-encrypts each child identity's client-id / client-secret into
#      children/<slug>/, and records the project ID in children/<slug>/project-id
#
# Afterwards it installs the per-project LaunchAgents (macOS), which run
# agent-run.sh <slug>. To add a project, add a line to projects.conf.
# Idempotent, but each run creates a new client secret for the identity.

set -euo pipefail

PROG="$(basename "$0")"

# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Configuration (environment)
# ──────────────────────────────────────────────────────────────────────────────

# The Provisioner's Universal Auth credentials (human-held). Not needed for import.
PROVISIONER_CLIENT_ID="${INFISICAL_PROVISIONER_CLIENT_ID:-}"
PROVISIONER_CLIENT_SECRET="${INFISICAL_PROVISIONER_CLIENT_SECRET:-}"

# Organization ID, required for identity creation. Not needed for import.
ORG_ID="${INFISICAL_ORG_ID:-}"

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

# Age recipient (public key) for the chezmoi age key.
age_recipient() {
  local age_key="$INFISICAL_AGE_KEY_PATH"
  [[ -f "$age_key" ]] || die "Age key not found at $age_key. Set INFISICAL_AGE_KEY_PATH."

  local recipient
  recipient="$(age-keygen -y "$age_key" 2>/dev/null | sed 's/#.*//' | tr -d '[:space:]')"
  if [[ -z "$recipient" ]]; then
    # Fallback: BSD grep doesn't support -P; use sed instead
    recipient="$(sed -n 's/^.*\(age1[^ ]*\).*/\1/p' "$age_key" 2>/dev/null | head -1)"
  fi
  [[ -n "$recipient" ]] || die "Could not determine age recipient from key file. Run: age-keygen"
  printf '%s' "$recipient"
}

# encrypt_child_credentials <slug> <client-id> <client-secret> <project-id>
# Writes children/<slug>/{client-id.age,client-secret.age,project-id}.
# Plaintext goes to age on stdin and is never written to disk.
encrypt_child_credentials() {
  local slug="$1" client_id="$2" client_secret="$3" project_id="$4"
  local child_dir="$CHILDREN_DIR/$slug"
  local recipient tmpdir
  recipient="$(age_recipient)"

  mkdir -p "$CHILDREN_DIR"
  chmod 700 "$CHILDREN_DIR"
  tmpdir="$(mktemp -d "$CHILDREN_DIR/cred.XXXXXX")"
  chmod 700 "$tmpdir"

  if ! printf '%s' "$client_id" | age -e -r "$recipient" -o "$tmpdir/client-id.age" \
    || ! printf '%s' "$client_secret" | age -e -r "$recipient" -o "$tmpdir/client-secret.age"; then
    rm -rf "$tmpdir"
    die "Failed to age-encrypt credentials for '$slug'"
  fi
  printf '%s\n' "$project_id" > "$tmpdir/project-id"
  chmod 600 "$tmpdir"/*

  # Replace the old set only once the new one is complete.
  rm -rf "$child_dir"
  mv "$tmpdir" "$child_dir"
  info "Credentials for '$slug' stored age-encrypted in $child_dir/"
}

# Fetch the child identity's client ID, create a new client secret, store both.
store_child_credentials() {
  local identity_id="$1" slug="$2" token="$3" project_id="$4"

  local auth_resp
  auth_resp="$(curl -sf "$INFISICAL_ADDRESS/api/v1/auth/universal-auth/identities/$identity_id" \
    -H "Authorization: Bearer $token")" || \
    die "Failed to get auth config for identity $identity_id."

  local client_id
  client_id="$(echo "$auth_resp" | jq -r '.identityUniversalAuth.clientId // empty')"
  [[ -n "$client_id" ]] || die "No clientId returned for identity $identity_id."

  local secret_resp client_secret=""
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
  [[ -n "$client_secret" ]] || die "Could not obtain client secret for identity $identity_id."

  encrypt_child_credentials "$slug" "$client_id" "$client_secret" "$project_id"
}

# provision.sh import <slug>: store credentials for an identity made by hand.
# Prompts without echo; the values are never printed or written in plaintext.
import_identity() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || die "usage: $PROG import <slug>"
  valid_slug "$slug" || die "invalid slug '$slug'"
  conf_get "$slug" || die "'$slug' is not in $PROJECTS_CONF. Add a line for it first."
  [[ -t 0 ]] || die "import needs an interactive terminal (it prompts for the credentials)."

  local project_id="$CONF_PROJECT_ID"
  if [[ "$project_id" == "-" ]]; then
    read -r -p "Infisical project ID (UUID) for '$slug': " project_id
  fi
  valid_project_id "$project_id" || die "invalid project ID"

  local client_id client_secret
  read -r -s -p "Universal Auth client ID: " client_id; echo >&2
  read -r -s -p "Universal Auth client secret: " client_secret; echo >&2
  [[ -n "$client_id" && -n "$client_secret" ]] || die "client ID and secret are both required"

  encrypt_child_credentials "$slug" "$client_id" "$client_secret" "$project_id"
}

install_agents() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    "$INFISICAL_DIR/install-launchagents.sh"
  else
    info "Not macOS: start an agent with $INFISICAL_DIR/agent-run.sh <slug>"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

provision() {
  info "Infisical provisioner bootstrap"
  info "Address: $INFISICAL_ADDRESS"
  [[ -n "$ORG_ID" ]] || die "INFISICAL_ORG_ID is required. Get it from your Infisical org settings."
  info "Org ID: $ORG_ID"

  local slugs=("$@")
  if [[ ${#slugs[@]} -eq 0 ]]; then
    local all
    all="$(conf_slugs)" || exit 1
    # shellcheck disable=SC2206  # slugs are validated, no spaces
    slugs=($all)
  fi

  local token
  token="$(provisioner_token)"

  local slug project_id child_id
  for slug in "${slugs[@]}"; do
    valid_slug "$slug" || die "invalid slug '$slug'"
    conf_get "$slug" || die "'$slug' is not in $PROJECTS_CONF. Add a line for it first."
    info "Processing project: $slug (environments: $CONF_ENVS, rendering $CONF_RENDER_ENV)"

    if [[ "$CONF_PROJECT_ID" != "-" ]]; then
      project_id="$CONF_PROJECT_ID"
    else
      project_id="$(ensure_project "$slug" "$token")"
    fi
    valid_project_id "$project_id" || die "bad project ID for '$slug'"

    ensure_environments "$project_id" "$CONF_ENVS" "$token"
    child_id="$(ensure_child_identity "$project_id" "$slug-agent" "$token")"
    store_child_credentials "$child_id" "$slug" "$token" "$project_id"
  done

  info ""
  info "Provisioning complete."
}

main() {
  case "${1:-}" in
    import)
      shift
      import_identity "$@"
      ;;
    -h | --help)
      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      provision "$@"
      ;;
  esac

  install_agents
  info "Check a rendered file by key name only:"
  info "  grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*=' ~/.infisical/<slug>-secrets.env"
}

main "$@"
