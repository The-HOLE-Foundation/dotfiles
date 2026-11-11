# lib.sh: shared helpers for the .infisical/ scripts. Source it; don't run it.
# Must stay compatible with macOS /bin/bash 3.2, which launchd uses.
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this

INFISICAL_DIR="${INFISICAL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CHILDREN_DIR="${INFISICAL_CHILDREN_DIR:-$INFISICAL_DIR/children}"
PROJECTS_CONF="${INFISICAL_PROJECTS_CONF:-$INFISICAL_DIR/projects.conf}"
INFISICAL_AGE_KEY_PATH="${INFISICAL_AGE_KEY_PATH:-$HOME/.config/chezmoi/key.txt}"
INFISICAL_ADDRESS="${INFISICAL_ADDRESS:-https://app.infisical.com}"
AGENT_LABEL_PREFIX="${INFISICAL_AGENT_LABEL_PREFIX:-com.hole.infisical-agent}"

# launchd starts jobs with a bare PATH; Homebrew lives outside it.
case ":$PATH:" in
  *:/opt/homebrew/bin:*) ;;
  *) PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" ;;
esac
export PATH

valid_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
valid_env() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
valid_project_id() { [[ "$1" =~ ^[A-Za-z0-9-]+$ ]]; }

# Print the slugs in projects.conf, one per line.
conf_slugs() {
  [[ -r "$PROJECTS_CONF" ]] || { echo "projects.conf not found: $PROJECTS_CONF" >&2; return 1; }
  awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$PROJECTS_CONF"
}

# conf_get <slug>: set CONF_ENVS, CONF_RENDER_ENV and CONF_PROJECT_ID.
# Returns 1 if the slug isn't listed or its line is malformed.
conf_get() {
  local slug="$1" line
  line="$(awk -v s="$slug" '!/^[[:space:]]*(#|$)/ && $1 == s { print; exit }' "$PROJECTS_CONF")"
  [[ -n "$line" ]] || return 1
  # shellcheck disable=SC2034  # read by callers
  read -r _ CONF_ENVS CONF_RENDER_ENV CONF_PROJECT_ID _ <<< "$line"
  [[ -n "${CONF_ENVS:-}" && -n "${CONF_RENDER_ENV:-}" && -n "${CONF_PROJECT_ID:-}" ]] || {
    echo "projects.conf: line for '$slug' needs 4 columns: slug envs render-env project-id" >&2
    return 1
  }
}

# A project is ready to run when both encrypted credentials exist.
child_ready() {
  [[ -f "$CHILDREN_DIR/$1/client-id.age" && -f "$CHILDREN_DIR/$1/client-secret.age" ]]
}
