{{- define "kazoo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kazoo.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "kazoo.labels" -}}
app.kubernetes.io/name: {{ include "kazoo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ include "kazoo.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "kazoo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kazoo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

# component selector label shared by every pod in the stack
{{- define "kazoo.componentLabels" -}}
app: {{ include "kazoo.name" . }}
{{- end -}}

# image string for a component: a flat "repository:tag" (or "host/repo:tag")
# in values.yaml, with optional global.imageRegistry prepended when set
# (replaces the leading registry of a full image ref, keeps the repo path).
# usage: {{ include "kazoo.image" (dict "ctx" . "name" "couchdb") }}
{{- define "kazoo.image" -}}
{{- $name := .name -}}
{{- $ctx := .ctx -}}
{{- $img := index $ctx.Values $name -}}
{{- $reg := $ctx.Values.global.imageRegistry -}}
{{- if $reg -}}
{{- $ref := $img.image | toString -}}
{{- if contains "/" $ref -}}
{{- printf "%s/%s" $reg (trimPrefix (printf "%s/" (first (splitList "/" $ref))) $ref) -}}
{{- else -}}
{{- printf "%s/%s" $reg $ref -}}
{{- end -}}
{{- else -}}
{{- printf "%s" $img.image -}}
{{- end -}}
{{- end -}}

# imagePullPolicy for every container (single global knob)
{{- define "kazoo.imagePullPolicy" -}}
{{- .Values.global.imagePullPolicy -}}
{{- end -}}

# Effective Crossbar API base baked into Monster-UI app registration.
# Explicit monsterUi.crossbarApiUrl wins; else derived from the kazooApps
# HTTPRoute host (each app's own kazooCore.httpRoute + scheme from its tls);
# final fallback localhost.
{{- define "kazoo.crossbarApiUrl" -}}
{{- if .Values.monsterUi.crossbarApiUrl -}}
{{- .Values.monsterUi.crossbarApiUrl -}}
{{- else if and .Values.kazooCore.httpRoute.enabled .Values.kazooCore.httpRoute.hostname -}}
{{- printf "%s://%s/v2" (ternary "https" "http" .Values.kazooCore.httpRoute.tls) .Values.kazooCore.httpRoute.hostname -}}
{{- else -}}
http://localhost:8000/v2
{{- end -}}
{{- end -}}

# HTTPRoute .spec.rules: the default backendRef rule for the component's
# Service, followed by any user-supplied rules (matches/filters/backendRefs).
# usage: include "kazoo.httpRouteRules" (dict "ctx" . "comp" "kazooCore"
#   "svcName" <service helper output> "port" <service port>)
{{- define "kazoo.httpRouteRules" -}}
{{- $comp := .comp -}}
{{- $ctx := .ctx -}}
{{- $rules := list (dict "backendRefs" (list (dict "name" .svcName "port" .port))) -}}
{{- range index $ctx.Values $comp "httpRoute" "rules" -}}
{{- $rules = append $rules . -}}
{{- end -}}
{{- toYaml $rules -}}
{{- end -}}

# container imagePullSecrets block (omitted when empty)
{{- define "kazoo.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets -}}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ .name }}
{{- end }}
{{- end -}}
{{- end -}}

# Secret name every pod reads creds from -- secrets.existingSecret when set
# (a pre-created Secret with the same keys as templates/secrets.yaml), else
# the one this chart templates from the plain secrets.* values.
{{- define "kazoo.secret.name" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "kazoo.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "kazoo.secretValue" -}}
{{- printf "%s" . | toString -}}
{{- end -}}

# Service name from values.<component>.service.name -- the in-cluster DNS name
# pods use (RABBIT_HOST/COUCH_HOST/...). Falls back to the bare component key
# when the map is absent so the chart stays renderable with minimal values.
# usage: {{ include "kazoo.service" (dict "ctx" . "name" "couchdb") }}
{{- define "kazoo.service" -}}
{{- $name := .name -}}
{{- $ctx := .ctx -}}
{{- $comp := default (dict) (index $ctx.Values $name) -}}
{{- $svcName := default $name (index (default (dict) $comp.service) "name") -}}
{{- printf "%s" $svcName -}}
{{- end -}}

# Headless Service name backing the subdomain (values.subdomain)
{{- define "kazoo.subdomainSvc" -}}
{{- include "kazoo.fullname" . -}}
{{- end -}}

# The in-cluster FQDN suffix for subdomain-based node names, e.g.
# "kazoo.default.svc.cluster.local"
{{- define "kazoo.subdomainFqdnSuffix" -}}
{{- printf "%s.%s.svc.cluster.local" .Values.subdomain .Release.Namespace -}}
{{- end -}}

# Service `ports:` block from a list of ServicePort-shaped values entries
# (name/port/targetPort/protocol/nodePort). targetPort defaults to port and
# protocol defaults to TCP, same as the Kubernetes API itself; nodePort is
# only emitted when set AND the Service type actually honors it (the API
# server rejects a nodePort on a ClusterIP Service outright).
# usage: {{ include "kazoo.servicePorts" (dict "ports" .Values.couchdb.service.ports "type" .Values.couchdb.service.type) | nindent 2 }}
{{- define "kazoo.servicePorts" -}}
{{- $type := .type -}}
ports:
{{- range .ports }}
  - name: {{ .name }}
    port: {{ .port }}
    targetPort: {{ .targetPort | default .port }}
    protocol: {{ .protocol | default "TCP" }}
    {{- if and .nodePort (or (eq $type "NodePort") (eq $type "LoadBalancer")) }}
    nodePort: {{ .nodePort }}
    {{- end }}
{{- end }}
{{- end -}}

# Pod container `ports:` block from the same list of values entries.
# containerPort mirrors targetPort (what the container actually listens on),
# not the Service-facing `port`, so the Service and the pod can never drift
# apart even if someone overrides `port` alone.
# usage: {{ include "kazoo.containerPorts" .Values.couchdb.service.ports | nindent 10 }}
{{- define "kazoo.containerPorts" -}}
ports:
{{- range . }}
  - name: {{ .name }}
    containerPort: {{ .targetPort | default .port }}
    protocol: {{ .protocol | default "TCP" }}
{{- end }}
{{- end -}}

# Full Service manifest for a "simple" list-ports component (couchdb,
# rabbitmq, postgres, kazooCore, monsterUi, kamailio): metadata, spec
# passthrough (type/externalTrafficPolicy/loadBalancerIP/
# loadBalancerSourceRanges/labels/annotations), selector, and ports -- all
# driven by <name>.service.* in values.yaml. FreeSWITCH is excluded: its
# ports are generated (RTP range), not a flat list, so it keeps its own
# explicit block in freeswitch's Service template.
# usage: {{ include "kazoo.simpleService" (dict "ctx" . "name" "couchdb" "component" "couchdb") }}
# `component` is the pod selector label value (kazooCore's is "kazoo-apps",
# monsterUi's is "monster-ui"; every other component matches `name`).
{{- define "kazoo.simpleService" -}}
{{- $ctx := .ctx -}}
{{- $name := .name -}}
{{- $component := .component -}}
{{- $svc := (index $ctx.Values $name).service -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "kazoo.service" (dict "ctx" $ctx "name" $name) }}
  labels:
    {{- include "kazoo.labels" $ctx | nindent 4 }}
    {{- if $svc.labels }}
    {{- toYaml $svc.labels | nindent 4 }}
    {{- end }}
  {{- if $svc.annotations }}
  annotations:
    {{- toYaml $svc.annotations | nindent 4 }}
  {{- end }}
spec:
  type: {{ $svc.type }}
  {{- if $svc.externalTrafficPolicy }}
  externalTrafficPolicy: {{ $svc.externalTrafficPolicy }}
  {{- end }}
  {{- if $svc.loadBalancerIP }}
  loadBalancerIP: {{ $svc.loadBalancerIP }}
  {{- end }}
  {{- if $svc.loadBalancerSourceRanges }}
  loadBalancerSourceRanges:
    {{- toYaml $svc.loadBalancerSourceRanges | nindent 4 }}
  {{- end }}
  selector:
    {{- include "kazoo.selectorLabels" $ctx | nindent 4 }}
    component: {{ $component }}
  {{- include "kazoo.servicePorts" (dict "ports" $svc.ports "type" $svc.type) | nindent 2 }}
{{- end -}}