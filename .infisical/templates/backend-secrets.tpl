# backend-secrets.tpl: secrets from the "backend" project.
# Rendered to ~/.infisical/backend-secrets.env, which dot_zshrc.tmpl sources.
# Reader-only identity: can list and read, cannot modify.
#
# agent-run.sh fills in @PROJECT_ID@ and @RENDER_ENV@ from projects.conf
# (render-env for backend is prod).

{{- /* Shell secrets, shell-safe single-quote escaping */ -}}
{{- with listSecrets "@PROJECT_ID@" "@RENDER_ENV@" "/" }}
{{- range . }}
{{- if or (eq .Key "POSTMAN_API_KEY") (eq .Key "MEM0_API_KEY") }}
export {{ .Key }}='{{ .Value | replace "'" "'\\''" }}'
{{- end }}
{{- end }}
{{- end }}
