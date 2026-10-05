{{- define "agent-mooring.fullname" -}}
claude-{{ required "session is required" .Values.session }}
{{- end -}}

{{/* Effective repository list, space-separated: repos plus the deprecated repo, deduplicated. Empty string when none. */}}
{{- define "agent-mooring.repos" -}}
{{- $l := .Values.repos | default list -}}
{{- if .Values.repo -}}{{- $l = append $l .Values.repo -}}{{- end -}}
{{- join " " (uniq $l) -}}
{{- end -}}

{{/* "true" when the session needs the GitHub token and egress: any repository or the skills repository. Empty otherwise. */}}
{{- define "agent-mooring.github" -}}
{{- if or (include "agent-mooring.repos" .) .Values.skills.repo -}}true{{- end -}}
{{- end -}}

{{/* "true" when any token Secret is mounted. */}}
{{- define "agent-mooring.tokens" -}}
{{- if or (include "agent-mooring.github" .) .Values.argocd.enabled -}}true{{- end -}}
{{- end -}}

{{/* repository:tag, with @digest when image.digest is set. */}}
{{- define "agent-mooring.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}{{ if .Values.image.digest }}@{{ .Values.image.digest }}{{ end }}
{{- end -}}

{{- define "agent-mooring.selectorLabels" -}}
app.kubernetes.io/name: agent-mooring
app.kubernetes.io/instance: {{ include "agent-mooring.fullname" . }}
{{- end -}}

{{- define "agent-mooring.labels" -}}
{{ include "agent-mooring.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "agent-mooring.serviceAccountName" -}}
{{- if eq .Values.kubernetes.access "read" -}}
claude-reader
{{- else if eq .Values.kubernetes.access "write" -}}
claude-writer
{{- else -}}
{{ include "agent-mooring.fullname" . }}
{{- end -}}
{{- end -}}

{{/* The Secret the TLS sidecar serves: tls.existingSecret or the chart's Certificate. */}}
{{- define "agent-mooring.tlsSecretName" -}}
{{- .Values.tls.existingSecret | default (printf "%s-tls" (include "agent-mooring.fullname" .)) -}}
{{- end -}}

{{- define "agent-mooring.claimName" -}}
{{- .Values.persistence.existingClaim | default (include "agent-mooring.fullname" .) -}}
{{- end -}}

{{/* The chart's managed settings, with .Values.settings merged over them. */}}
{{- define "agent-mooring.managedSettings" -}}
{{- $defaults := dict
  "env" (dict "DISABLE_AUTOUPDATER" "1")
  "remoteControlAtStartup" true
  "attribution" (dict "commit" "" "pr" "" "sessionUrl" false)
  "includeCoAuthoredBy" false
  "permissions" (dict
    "allow" (list
      "Bash(kubectl get *)" "Bash(kubectl describe *)" "Bash(kubectl logs *)"
      "Bash(kubectl auth can-i *)" "Bash(kubectl top *)"
      "Bash(gh pr checks *)" "Bash(gh pr view *)" "Bash(gh pr list *)"
      "Bash(gh run view *)" "Bash(gh run list *)" "Bash(gh run watch *)"
      "Bash(argocd app get *)" "Bash(argocd app list *)" "Bash(argocd app diff *)")
    "deny" (list
      "Bash(gh pr merge --admin *)" "Bash(gh pr merge * --admin *)" "Bash(gh pr merge * --admin)"
      "Bash(git push * main)" "Bash(git push * HEAD:main)" "Bash(git push * main:main)"
      "Bash(git push --force *)" "Bash(git push -f *)"
      "Bash(kubectl delete namespace *)" "Bash(kubectl delete ns *)"))
  "hooks" (dict
    "SessionStart" (list (dict "hooks" (list (dict "type" "command" "command" "/usr/local/bin/agent-session-start" "timeout" 30)))))
-}}
{{- mergeOverwrite $defaults (deepCopy .Values.settings) | toPrettyJson -}}
{{- end -}}

{{- define "agent-mooring.https" -}}
toPorts:
  - ports:
      - port: "443"
        protocol: TCP
{{- end -}}
