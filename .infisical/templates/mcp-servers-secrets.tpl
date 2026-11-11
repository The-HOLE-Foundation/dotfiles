# mcp-servers-secrets.tpl: secrets from the "mcp-servers" project.
# Rendered to ~/.infisical/mcp-servers-secrets.env.
# Reader-only identity: can list and read, cannot modify.
#
# agent-run.sh fills in @PROJECT_ID@ and @RENDER_ENV@ from projects.conf.
# Keys are filtered to valid shell identifiers only.

{{- with listSecrets "@PROJECT_ID@" "@RENDER_ENV@" "/" }}
{{- range . }}
{{- if regexMatch "^[_a-zA-Z][_a-zA-Z0-9]*$" .Key }}
{{ .Key }}='{{ .Value | replace "'" "'\\''" }}'
{{- end }}
{{- end }}
{{- end }}
