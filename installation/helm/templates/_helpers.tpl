{{/*
Chart name.
*/}}
{{- define "marble.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. With release name "marble" and chart "marble" this
collapses to "marble", giving Services "marble-api" / "marble-frontend".
*/}}
{{- define "marble.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "marble.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels. Call with: (dict "ctx" . "component" "api")
*/}}
{{- define "marble.labels" -}}
helm.sh/chart: {{ include "marble.chart" .ctx }}
{{ include "marble.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: marble
{{- end -}}

{{- define "marble.selectorLabels" -}}
app.kubernetes.io/name: {{ include "marble.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "marble.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "marble.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding sensitive values (chart-created unless an existing one is given).
*/}}
{{- define "marble.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- include "marble.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Backend image ref.
*/}}
{{- define "marble.backendImage" -}}
{{- printf "%s:%s" .Values.image.backend.repository .Values.image.backend.tag -}}
{{- end -}}

{{- define "marble.frontendImage" -}}
{{- printf "%s:%s" .Values.image.frontend.repository .Values.image.frontend.tag -}}
{{- end -}}

{{/*
SSR -> API URL. Defaults to internal cluster DNS of the api Service in the
release namespace (never exposed to the browser). Override via urls.apiUrl.
*/}}
{{- define "marble.apiUrl" -}}
{{- if .Values.urls.apiUrl -}}
{{- .Values.urls.apiUrl -}}
{{- else -}}
{{- printf "http://%s-api.%s.svc.cluster.local:%v" (include "marble.fullname" .) .Release.Namespace .Values.common.port -}}
{{- end -}}
{{- end -}}

{{/*
Shared backend env (api-server + worker). Call with:
  (dict "ctx" $ "component" "server")  or  (dict "ctx" $ "component" "worker")
Sensitive values are read from the Secret via secretKeyRef; non-sensitive are inlined.
Optional env is only rendered when set, so Marble's own defaults apply.
*/}}
{{- define "marble.backendEnv" -}}
{{- $ := .ctx -}}
{{- $component := .component -}}
{{- $secret := include "marble.secretName" $ -}}
- name: ENV
  value: {{ $.Values.common.env | quote }}
- name: LOGGING_FORMAT
  value: {{ $.Values.common.loggingFormat | quote }}
{{- if $.Values.common.requestLoggingLevel }}
- name: REQUEST_LOGGING_LEVEL
  value: {{ $.Values.common.requestLoggingLevel | quote }}
{{- end }}
# --- Analytics export (optional) ---
{{- if $.Values.analytics.bucketUrl }}
- name: ANALYTICS_BUCKET_URL
  value: {{ $.Values.analytics.bucketUrl | quote }}
{{- end }}
# --- Postgres (external) ---
{{- if $.Values.postgres.connectionString }}
- name: PG_CONNECTION_STRING
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: PG_CONNECTION_STRING
{{- else }}
- name: PG_HOSTNAME
  value: {{ $.Values.postgres.host | quote }}
- name: PG_PORT
  value: {{ $.Values.postgres.port | quote }}
- name: PG_USER
  value: {{ $.Values.postgres.user | quote }}
- name: PG_DATABASE
  value: {{ $.Values.postgres.database | quote }}
- name: PG_SSL_MODE
  value: {{ $.Values.postgres.sslMode | quote }}
{{- if $.Values.postgres.maxPoolSize }}
- name: PG_MAX_POOL_SIZE
  value: {{ $.Values.postgres.maxPoolSize | quote }}
{{- end }}
{{- if $.Values.postgres.impersonateRole }}
- name: PG_IMPERSONATE_ROLE
  value: {{ $.Values.postgres.impersonateRole | quote }}
{{- end }}
- name: PG_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: PG_PASSWORD
{{- end }}
# --- Auth (Firebase) ---
- name: AUTH_PROVIDER
  value: {{ $.Values.auth.provider | quote }}
{{- if $.Values.auth.firebase.projectId }}
- name: FIREBASE_PROJECT_ID
  value: {{ $.Values.auth.firebase.projectId | quote }}
{{- end }}
{{- if $.Values.auth.firebase.authDomain }}
- name: FIREBASE_AUTH_DOMAIN
  value: {{ $.Values.auth.firebase.authDomain | quote }}
{{- end }}
{{- if $.Values.auth.firebase.googleCloudProject }}
- name: GOOGLE_CLOUD_PROJECT
  value: {{ $.Values.auth.firebase.googleCloudProject | quote }}
{{- end }}
{{- if include "marble.gcpServiceAccountFile" (dict "ctx" $) }}
- name: GOOGLE_APPLICATION_CREDENTIALS
  value: {{ $.Values.auth.firebase.serviceAccount.mountPath | quote }}
{{- end }}
# --- Blob storage (S3) ---
{{- if $.Values.storage.ingestionBucketUrl }}
- name: INGESTION_BUCKET_URL
  value: {{ $.Values.storage.ingestionBucketUrl | quote }}
{{- end }}
{{- if $.Values.storage.caseManagerBucketUrl }}
- name: CASE_MANAGER_BUCKET_URL
  value: {{ $.Values.storage.caseManagerBucketUrl | quote }}
{{- end }}
{{- if $.Values.storage.aws.region }}
- name: AWS_REGION
  value: {{ $.Values.storage.aws.region | quote }}
- name: AWS_DEFAULT_REGION
  value: {{ $.Values.storage.aws.region | quote }}
{{- end }}
{{- if and (not $.Values.storage.aws.useIrsa) $.Values.storage.aws.accessKeyId }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: AWS_SECRET_ACCESS_KEY
{{- end }}
# --- Screening: OpenSanctions SaaS (v1.12.0 SCREENING_-prefixed names) ---
- name: SCREENING_OPENSANCTIONS_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: SCREENING_OPENSANCTIONS_API_KEY
{{- if $.Values.screening.opensanctions.apiHost }}
- name: SCREENING_OPENSANCTIONS_API_HOST
  value: {{ $.Values.screening.opensanctions.apiHost | quote }}
{{- end }}
{{- if $.Values.screening.opensanctions.authMethod }}
- name: SCREENING_OPENSANCTIONS_AUTH_METHOD
  value: {{ $.Values.screening.opensanctions.authMethod | quote }}
{{- end }}
# --- URLs ---
- name: MARBLE_API_URL
  value: {{ include "marble.apiUrl" $ | quote }}
{{- if $.Values.urls.apiInternalUrl }}
- name: MARBLE_API_INTERNAL_URL
  value: {{ $.Values.urls.apiInternalUrl | quote }}
{{- end }}
# --- License (optional; empty = free license, not fatal) ---
{{- if $.Values.license.key }}
- name: LICENSE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: LICENSE_KEY
{{- end }}
# --- Data offloading (optional) ---
{{- if $.Values.offloading.enabled }}
- name: OFFLOADING_ENABLED
  value: "true"
- name: OFFLOADING_BUCKET_URL
  value: {{ $.Values.offloading.bucketUrl | quote }}
{{- end }}
# --- Observability (optional) ---
{{- if $.Values.observability.sentry.dsn }}
- name: SENTRY_DSN
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: SENTRY_DSN
{{- end }}
{{- if $.Values.observability.prometheus.enabled }}
- name: ENABLE_PROMETHEUS
  value: "true"
{{- end }}
{{- if eq $component "server" }}
# --- api-server only ---
- name: PORT
  value: {{ $.Values.common.port | quote }}
{{- if $.Values.urls.appUrl }}
- name: MARBLE_APP_URL
  value: {{ $.Values.urls.appUrl | quote }}
{{- end }}
- name: FIREBASE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: FIREBASE_API_KEY
{{- if include "marble.jwtSigningKeyFile" (dict "ctx" $) }}
- name: AUTHENTICATION_JWT_SIGNING_KEY_FILE
  value: {{ $.Values.apiServer.jwtSigningKey.mountPath | quote }}
{{- end }}
{{- if $.Values.bootstrap.orgName }}
- name: CREATE_ORG_NAME
  value: {{ $.Values.bootstrap.orgName | quote }}
{{- end }}
{{- if $.Values.bootstrap.orgAdminEmail }}
- name: CREATE_ORG_ADMIN_EMAIL
  value: {{ $.Values.bootstrap.orgAdminEmail | quote }}
{{- end }}
{{- if $.Values.bootstrap.globalAdminEmail }}
- name: CREATE_GLOBAL_ADMIN_EMAIL
  value: {{ $.Values.bootstrap.globalAdminEmail | quote }}
{{- end }}
{{- end }}
{{- if eq $component "worker" }}
# --- api-worker only ---
{{- if $.Values.worker.probePort }}
- name: CLOUD_RUN_PROBE_PORT
  value: {{ $.Values.worker.probePort | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Whether the GCP service-account key file is actually available to mount.
True only when SA is enabled AND the key is supplied somewhere — either inline `json`
(chart-managed Secret) or via `secrets.existingSecret`. Gating the volume/mount/env on
this (not on `enabled` alone) avoids a CreateContainerConfigError when `enabled: true`
but no key is provided, since the Secret would not carry GCP_SERVICE_ACCOUNT_JSON.
Emits a non-empty string when true. Call with (dict "ctx" $).
*/}}
{{- define "marble.gcpServiceAccountFile" -}}
{{- $ := .ctx -}}
{{- if and $.Values.auth.firebase.serviceAccount.enabled (or $.Values.auth.firebase.serviceAccount.json $.Values.secrets.existingSecret) -}}
true
{{- end -}}
{{- end -}}

{{/*
Whether the JWT signing-key PEM file is actually available to mount (api-server only).
Same rationale as marble.gcpServiceAccountFile: gate on the key being supplied (inline `pem`
or `secrets.existingSecret`), not on `enabled` alone, so `enabled: true` with no key does
not strand the api-server pod on a missing Secret key. Emits a non-empty string when true.
*/}}
{{- define "marble.jwtSigningKeyFile" -}}
{{- $ := .ctx -}}
{{- if and $.Values.apiServer.jwtSigningKey.enabled (or $.Values.apiServer.jwtSigningKey.pem $.Values.secrets.existingSecret) -}}
true
{{- end -}}
{{- end -}}

{{/*
Secret-file volumes (GCP service-account JSON for Firebase; RSA JWT signing key PEM).
Mounted on api-server (both) and worker (GCP SA only). Call with (dict "ctx" $ "component" "server"|"worker").
*/}}
{{- define "marble.secretVolumes" -}}
{{- $ := .ctx -}}
{{- $secret := include "marble.secretName" $ -}}
{{- if include "marble.gcpServiceAccountFile" (dict "ctx" $) }}
- name: gcp-service-account
  secret:
    secretName: {{ $secret }}
    items:
      - key: GCP_SERVICE_ACCOUNT_JSON
        path: {{ base $.Values.auth.firebase.serviceAccount.mountPath }}
{{- end }}
{{- if and (eq .component "server") (include "marble.jwtSigningKeyFile" (dict "ctx" $)) }}
- name: jwt-signing-key
  secret:
    secretName: {{ $secret }}
    items:
      - key: AUTHENTICATION_JWT_SIGNING_KEY
        path: {{ base $.Values.apiServer.jwtSigningKey.mountPath }}
{{- end }}
{{- end -}}

{{- define "marble.secretVolumeMounts" -}}
{{- $ := .ctx -}}
{{- if include "marble.gcpServiceAccountFile" (dict "ctx" $) }}
- name: gcp-service-account
  mountPath: {{ dir $.Values.auth.firebase.serviceAccount.mountPath }}
  readOnly: true
{{- end }}
{{- if and (eq .component "server") (include "marble.jwtSigningKeyFile" (dict "ctx" $)) }}
- name: jwt-signing-key
  mountPath: {{ dir $.Values.apiServer.jwtSigningKey.mountPath }}
  readOnly: true
{{- end }}
{{- end -}}
