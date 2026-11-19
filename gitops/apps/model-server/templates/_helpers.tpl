{{- define "ms.computeclass" -}}{{ .Values.project }}-{{ .Values.tier }}{{- end -}}
{{- define "ms.decode" -}}{{ .Values.release }}-vllm-decode{{- end -}}

{{- define "ms.selectorLabels" -}}
llm-d.ai/inference-pool: {{ .Values.release }}
llm-d.ai/role: decode
{{- end -}}

{{- define "ms.partOf" -}}
app.kubernetes.io/part-of: {{ .Values.project }}
{{- end -}}

{{- define "ms.labels" -}}
{{ include "ms.selectorLabels" . }}
{{ .Values.project }}/tier: {{ .Values.tier }}
{{ include "ms.partOf" . }}
{{- end -}}
