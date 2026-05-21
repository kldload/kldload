{{/*
Common helpers for javaapi-fullstack chart.

Convention: every resource is namespaced under {{ .Values.global.namespace }};
labels are emitted via `commonLabels` and selector labels via `selectorLabels`
so every resource is consistent and the webui Demo Mode view can filter on
`kldload.io/demo=javaapi-fullstack`.
*/}}

{{/* Chart name+version stamp on every resource — visible via kubectl describe */}}
{{- define "javaapi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels applied to every resource. The kldload.io/demo label is what
     the webui filters Argo Applications by for the presenter view. */}}
{{- define "javaapi.commonLabels" -}}
helm.sh/chart: {{ include "javaapi.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: javaapi-fullstack
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
kldload.io/demo: "javaapi-fullstack"
{{- end -}}

{{/* Selector labels — the immutable subset that goes into Deployment.spec.selector.
     These cannot change between chart versions or the rolling update breaks. */}}
{{- define "javaapi.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: javaapi-fullstack
{{- end -}}

{{/* Prometheus scrape annotations applied to every service that exposes
     /actuator/prometheus. Spring Boot Actuator + Micrometer ship a Prom
     endpoint for free; kldload's prometheus.yml scrape config picks up
     any pod with these annotations. */}}
{{- define "javaapi.scrapeAnnotations" -}}
{{- if .Values.observability.scrape }}
prometheus.io/scrape: "true"
prometheus.io/path: {{ .Values.observability.prometheusPath | quote }}
prometheus.io/port: {{ .Values.observability.prometheusPort | quote }}
{{- end }}
{{- end -}}

{{/* JVM tuning common to every Spring Boot service. G1GC + 100ms pause
     target hits the sweet spot for the small heaps we run (256-384 MB).
     OOM-on-error so a stuck JVM dies fast and gets restarted vs hanging
     in a degraded state that's invisible on dashboards. */}}
{{- define "javaapi.javaOpts" -}}
- name: JAVA_TOOL_OPTIONS
  value: "-Xmx384m -Xms256m -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp"
{{- end -}}

{{/* Spring service Deployment skeleton. All seven Spring services follow
     the same shape — only image + env + replicas differ. Calling this
     template from each service's manifest cuts ~80 lines of duplication. */}}
{{- define "javaapi.springDeployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  namespace: {{ .ctx.Values.global.namespace }}
  labels:
    {{- include "javaapi.commonLabels" .ctx | nindent 4 }}
    app: {{ .name }}
    kldload.io/component: {{ .component }}
spec:
  replicas: {{ .replicas | default 1 }}
  selector:
    matchLabels:
      {{- include "javaapi.selectorLabels" .ctx | nindent 6 }}
      app: {{ .name }}
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        {{- include "javaapi.commonLabels" .ctx | nindent 8 }}
        app: {{ .name }}
        kldload.io/component: {{ .component }}
      annotations:
        {{- include "javaapi.scrapeAnnotations" .ctx | nindent 8 }}
    spec:
      containers:
        - name: {{ .name }}
          image: {{ .image }}
          imagePullPolicy: {{ .ctx.Values.global.imagePullPolicy }}
          ports:
            - name: http
              containerPort: 8080
          env:
            {{- include "javaapi.javaOpts" .ctx | nindent 12 }}
            {{- if .extraEnv }}
            {{- toYaml .extraEnv | nindent 12 }}
            {{- end }}
          resources:
            {{- toYaml .resources | nindent 12 }}
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8080 }
            initialDelaySeconds: 30
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            initialDelaySeconds: 90
            periodSeconds: 15
{{- end -}}

{{/* Spring service ClusterIP — every service exposes port 8080 internally */}}
{{- define "javaapi.springService" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: {{ .ctx.Values.global.namespace }}
  labels:
    {{- include "javaapi.commonLabels" .ctx | nindent 4 }}
    app: {{ .name }}
spec:
  selector:
    {{- include "javaapi.selectorLabels" .ctx | nindent 4 }}
    app: {{ .name }}
  ports:
    - name: http
      port: 8080
      targetPort: 8080
{{- end -}}
