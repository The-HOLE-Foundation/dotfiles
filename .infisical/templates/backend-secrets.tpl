# backend-secrets.tpl — secrets from the "backend" project
# Reader-only identity: can list and read, cannot modify.
#
# Environments used:
#   prod  → POSTMAN_API_KEY, MEM0_API_KEY      (for zshrc)
#   dev   → TAILSCALE_AUTHKEY_SERVER             (for bootstrap scripts)
#
# NOTE: Project ID is bound by provision.sh during provisioning.
# Replace <backend-project-id> with the actual Infisical project UUID.

{{- /* Production secrets for shell — encoded as safe shell literals */ -}}
{{- with listSecrets "<backend-project-id>" "prod" "/" }}
{{- range . }}
{{- if or (eq .Key "POSTMAN_API_KEY") (eq .Key "MEM0_API_KEY") }}
export {{ .Key }}='{{ .Value | replace "'" "''" }}'
{{- end }}
{{- end }}
{{- end }}
