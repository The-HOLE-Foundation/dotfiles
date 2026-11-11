# _default.tpl: used for any project without templates/<slug>-secrets.tpl.
# Exports every key at path "/" of the project's render-env, so
#   source ~/.infisical/<slug>-secrets.env
# puts them all in the environment. Keys that aren't valid shell names are
# skipped. Copy this to templates/<slug>-secrets.tpl to pick keys instead.
#
# agent-run.sh fills in @PROJECT_ID@ and @RENDER_ENV@ from projects.conf.

{{- with listSecrets "@PROJECT_ID@" "@RENDER_ENV@" "/" }}
{{- range . }}
{{- if match "^[_a-zA-Z][_a-zA-Z0-9]*$" .Key }}
export {{ .Key }}='{{ .Value | replace "'" "'\\''" }}'
{{- end }}
{{- end }}
{{- end }}
