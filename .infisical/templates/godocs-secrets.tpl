# godocs-secrets.tpl — secrets from the "godocs" project
# Reader-only identity: can list and read, cannot modify.
#
# Environment used: dev → R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID
# Output file: r2-creds.env (consumed by run_once_after_install-project-godocs.sh.tmpl)
#
# NOTE: Project ID is bound by provision.sh during provisioning.

{{- with listSecrets "<godocs-project-id>" "dev" "/" }}
{{- range . }}
{{- if or (eq .Key "R2_ACCESS_KEY_ID") (eq .Key "R2_SECRET_ACCESS_KEY") (eq .Key "R2_ACCOUNT_ID") }}
{{ .Key }}='{{ .Value | replace "'" "''" }}'
{{- end }}
{{- end }}
{{- end }}
