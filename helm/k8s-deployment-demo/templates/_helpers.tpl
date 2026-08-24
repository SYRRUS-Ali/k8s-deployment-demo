{{- define "k8s-deployment-demo.commonLabels" -}}
app.kubernetes.io/instance: {{ .Values.labels.instance }}
app.kubernetes.io/part-of: {{ .Values.labels.instance }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}