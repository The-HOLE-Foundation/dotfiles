# mcp-servers-secrets.tpl — secrets from the "mcp-servers" project
# Reader-only identity: can list and read, cannot modify.
#
# Environment used: dev → all MCP server credentials
# Output file: mcp-secrets.env (consumed by run_once_after_install-project-legal.sh.tmpl)
#
# NOTE: Project ID is bound by provision.sh during provisioning.
# Keys are filtered to valid shell identifiers only.

{{- with listSecrets "<mcp-servers-project-id>" "dev" "/" }}
{{- range . }}
{{- if match "^[_a-zA-Z][_a-zA-Z0-9]*$" .Key }}
{{ .Key }}='{{ .Value | replace "'" "'\\''" }}'
{{- end }}
{{- end }}
{{- end }}
