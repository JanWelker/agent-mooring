{{- define "claude-agent.fullname" -}}
claude-{{ required "session is required" .Values.session }}
{{- end -}}

{{/* Effective repository list, space-separated: repos plus the deprecated repo, deduplicated. Empty string when none. */}}
{{- define "claude-agent.repos" -}}
{{- $l := .Values.repos | default list -}}
{{- if .Values.repo -}}{{- $l = append $l .Values.repo -}}{{- end -}}
{{- join " " (uniq $l) -}}
{{- end -}}

{{- define "claude-agent.selectorLabels" -}}
app.kubernetes.io/name: claude-agent
app.kubernetes.io/instance: {{ include "claude-agent.fullname" . }}
{{- end -}}

{{- define "claude-agent.labels" -}}
{{ include "claude-agent.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "claude-agent.serviceAccountName" -}}
{{- if eq .Values.kubernetes.access "read" -}}
claude-reader
{{- else if eq .Values.kubernetes.access "write" -}}
claude-writer
{{- else -}}
{{ include "claude-agent.fullname" . }}
{{- end -}}
{{- end -}}

{{- define "claude-agent.claimName" -}}
{{- .Values.persistence.existingClaim | default (include "claude-agent.fullname" .) -}}
{{- end -}}

{{/* The chart's managed settings, with .Values.settings merged over them. */}}
{{- define "claude-agent.managedSettings" -}}
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

{{- define "claude-agent.https" -}}
toPorts:
  - ports:
      - port: "443"
        protocol: TCP
{{- end -}}
