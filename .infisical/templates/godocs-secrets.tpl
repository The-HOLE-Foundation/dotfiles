# godocs-secrets.tpl: secrets from the "godocs" project.
# Rendered to ~/.infisical/godocs-secrets.env, which
# run_once_after_install-project-godocs.sh.tmpl reads.
# Reader-only identity: can list and read, cannot modify.
#
# agent-run.sh fills in @PROJECT_ID@ and @RENDER_ENV@ from projects.conf.

{{- with listSecrets "@PROJECT_ID@" "@RENDER_ENV@" "/" }}
{{- range . }}
{{- if or (eq .Key "R2_ACCESS_KEY_ID") (eq .Key "R2_SECRET_ACCESS_KEY") (eq .Key "R2_ACCOUNT_ID") }}
{{ .Key }}='{{ .Value | replace "'" "'\\''" }}'
{{- end }}
{{- end }}
{{- end }}
