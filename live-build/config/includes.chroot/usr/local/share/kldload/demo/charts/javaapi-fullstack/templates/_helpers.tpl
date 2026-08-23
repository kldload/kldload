{{/*
Common helpers for the full-stack demo chart.

Convention: every resource is namespaced under {{ .Values.global.namespace }},
labelled via `commonLabels`, and selected via `selectorLabels`. The webui's
Demo Mode view filters on kldload.io/demo=javaapi-fullstack, so that label's
VALUE is load-bearing and must not be renamed without changing the webui too.

The Spring-era helpers (javaOpts, springDeployment, springService) were removed
in chart 2.0.0. They templated seven services against image tags that no longer
exist upstream, and nothing had been able to call them since build #46.
*/}}

{{- define "javaapi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "javaapi.commonLabels" -}}
helm.sh/chart: {{ include "javaapi.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: javaapi-fullstack
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
kldload.io/demo: "javaapi-fullstack"
{{- end -}}

{{/* The immutable subset that goes into Deployment.spec.selector. These cannot
     change between chart versions or the upgrade fails: selectors are one of
     the few genuinely immutable fields in the API. */}}
{{- define "javaapi.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: javaapi-fullstack
{{- end -}}

{{/* Database connection env, shared verbatim by both tracks. Both tracks point
     at the SAME database — that is the point of the demo, not an oversight. */}}
{{- define "javaapi.dbEnv" -}}
- name: DB_HOST
  value: postgres
- name: DB_PORT
  value: "5432"
- name: DB_NAME
  value: {{ .Values.postgres.database | quote }}
- name: DB_USER
  value: {{ .Values.postgres.credentials.user | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgres-credentials
      key: password
{{- end -}}

{{/* Identity injected via the downward API so a response can name the pod and
     node that served it. Without this the cutover is invisible in a browser:
     the page would look identical no matter which track answered. */}}
{{- define "javaapi.identityEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
{{- end -}}
