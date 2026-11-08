# Marble Helm chart

A first-party Helm chart to deploy [Marble](https://github.com/checkmarble/marble) on Kubernetes,
tailored to this deployment profile:

- **External PostgreSQL** (managed, e.g. AWS RDS) — no in-chart database
- **External OpenSanctions SaaS** — no Elasticsearch / yente / motiva
- **Firebase** authentication + **AWS S3** blob storage, on **EKS**
- Routed via a **Traefik `IngressRoute`** (`traefik.io/v1alpha1`)

It is designed to be deployed by Terraform `helm_release` exactly like the other apps in
`reasy-infra-apps` (see [`examples/helm_marble.tf`](examples/helm_marble.tf) and
[`examples/marble-values.yaml`](examples/marble-values.yaml)).

## Architecture

Marble ships a single backend binary (`/app`) run in three modes, plus the frontend:

| Workload | Kind | Command | Exposed | Notes |
|---|---|---|---|---|
| `marble-api` | Deployment | `--server` | internal ClusterIP `:8080` | dashboard + SSR target + public API |
| `marble-worker` | Deployment | `--worker` | none | background jobs, ingestion, screening, webhooks |
| `marble-frontend` | Deployment | (image CMD) | via IngressRoute `:8080` | TanStack Start SSR UI |
| `marble-migrations` | Job (Helm hook) | `--migrations` | n/a | runs `pre-install,pre-upgrade` before the above |

Only the **frontend** is exposed externally. The browser never talks to the API directly — the
frontend SSR calls it over internal cluster DNS (`MARBLE_API_URL`). Optionally a second IngressRoute
route can expose Marble's programmatic public API (`/v1`, `/v1beta`).

## Prerequisites

- A reachable **PostgreSQL 16+** with a database named `marble` (`search_path marble,public`).
- A **Firebase** project (Web API key + a service-account JSON for the Admin SDK).
- **S3** bucket(s) for ingestion (and case files); IRSA role recommended on EKS.
- An **OpenSanctions SaaS** API key.
- **Traefik** in the cluster with `web`/`websecure` entrypoints and a cert resolver (`le`).

## Install

### With Terraform (recommended; matches reasy-infra-apps)

1. Package & push the chart to your OCI registry (or reference it by local path):
   ```bash
   helm package installation/helm
   helm push marble-reasy-0.2.0.tgz oci://<ACCOUNT>.dkr.ecr.eu-west-1.amazonaws.com/charts
   ```
2. Copy [`examples/helm_marble.tf`](examples/helm_marble.tf) to the `reasy-infra-apps` repo root and
   [`examples/marble-values.yaml`](examples/marble-values.yaml) to `marble_config/marble-values.yaml`.
3. Wire the `TF_VAR_marble_*` secrets in the GitHub Actions workflow (same pattern as the other apps).
4. `terraform apply`.

### With Helm directly (for testing)

```bash
helm upgrade --install marble installation/helm -n marble --create-namespace \
  --set postgres.host=<rds-endpoint> --set postgres.user=marble --set postgres.password=<pw> \
  --set auth.firebase.apiKey=<fb-web-api-key> \
  --set-file auth.firebase.serviceAccount.json=<path/to/sa.json> \
  --set-file apiServer.jwtSigningKey.pem=<path/to/jwt.pem> \
  --set screening.opensanctions.apiKey=<os-key> \
  --set storage.ingestionBucketUrl=s3://marble-ingestion-prod --set storage.aws.region=eu-west-1 \
  --set frontend.session.secret="$(openssl rand -base64 48)" \
  --set urls.appUrl=https://marble.reasy.fr \
  --set storage.aws.accessKeyId=<AWS_ACCESS_KEY_ID> --set storage.aws.secretAccessKey=<AWS_SECRET_ACCESS_KEY>
```

> `--set-file` is the clean way to pass the multi-line GCP SA JSON and the RSA PEM. With Terraform,
> pass them via `set` variables, or create the Secret out-of-band and use `secrets.existingSecret`.

## Secrets

By default the chart **creates a Secret** from the `(secret)` values you provide (injected by Terraform
`set`), matching the repo convention (no external-secrets / sealed-secrets). To use a pre-existing
Secret instead, set `secrets.existingSecret=<name>`; it must contain the keys it references:

`PG_PASSWORD` · `FIREBASE_API_KEY` · `GCP_SERVICE_ACCOUNT_JSON` · `SCREENING_OPENSANCTIONS_API_KEY` ·
`SESSION_SECRET` · `AUTHENTICATION_JWT_SIGNING_KEY` · `AWS_ACCESS_KEY_ID` · `AWS_SECRET_ACCESS_KEY` ·
(optional) `LICENSE_KEY`, `SENTRY_DSN`, `PG_CONNECTION_STRING`.

## Telemetry

Telemetry follows Marble's own defaults: Segment usage events and worker usage metrics (to
`api.checkmarble.com`) are on; Sentry, Prometheus, and the analytics export are off unless configured.

## Important gotchas (baked into the chart)

- **`SESSION_SECRET` must be ≥ 32 characters** (iron-webcrypto) or the frontend throws on the first
  request — *not* at boot. Generate with `openssl rand -base64 48`.
- The frontend image hardcodes `NODE_ENV=development`; the chart **overrides it to `production`**
  (`frontend.nodeEnv`) so end users never see raw error stacks.
- OpenSanctions env vars are **`SCREENING_`-prefixed** in v1.12.0. The unprefixed `OPENSANCTIONS_*`
  names in upstream `.env.example`/compose are dead — this chart emits the correct ones.
- The **worker fatals at boot without `INGESTION_BUCKET_URL`** (`storage.ingestionBucketUrl`).
- Provide a **stable JWT signing key** (`apiServer.jwtSigningKey.pem`), else a new key is generated on
  every restart — logging everyone out and breaking `apiServer.replicas > 1`.
- `KILL_IF_READ_LICENSE_ERROR` is intentionally never set; a license-server hiccup will not crash pods.
- Migrations run as a **pre-install/pre-upgrade hook** before the api/worker (which fatal without the
  migration-seeded `deployment_id` row). They are idempotent.

## Things to validate in your environment

- **AWS credentials**: static keys are injected by default (`storage.aws.useIrsa=false`,
  `accessKeyId`/`secretAccessKey` -> Secret). To use an IRSA role instead, set `useIrsa=true`, omit the
  keys, and annotate the ServiceAccount via `serviceAccount.annotations` with `eks.amazonaws.com/role-arn`.
- **Pod security**: the backend (distroless/cc) and frontend (oven/bun) images were not confirmed to run
  as non-root, so `podSecurityContext.runAsNonRoot` is **not** forced. Set it if your policy requires it
  after confirming the images tolerate it.
- **First-boot bootstrap**: set `bootstrap.orgName`/`orgAdminEmail` once for the initial org/admin
  (the admin email must also exist in Firebase), then blank them.

## Values reference

See [`values.yaml`](values.yaml) — every key is documented inline. The most important ones:

| Path | Required | Purpose |
|---|---|---|
| `postgres.host` / `.user` / `.password` | ✅ | external Postgres connection |
| `auth.firebase.apiKey` | ✅ | Firebase Web API key (api-server fatals without it) |
| `auth.firebase.projectId` | ✅ (off-GCP) | Firebase project id |
| `auth.firebase.serviceAccount.json` | ✅ (off-GCP) | Firebase Admin SA key (mounted file) |
| `screening.opensanctions.apiKey` | ✅ | OpenSanctions SaaS key |
| `storage.ingestionBucketUrl` | ✅ | S3 ingestion bucket (worker fatals without it) |
| `storage.aws.region` | ✅ | AWS region for S3 |
| `storage.aws.accessKeyId` / `.secretAccessKey` | ✅ | static S3 credentials (`useIrsa=false`) |
| `frontend.session.secret` | ✅ | session seal secret (≥ 32 chars) |
| `urls.appUrl` | ✅ | public frontend URL (`MARBLE_APP_URL`) |
| `apiServer.jwtSigningKey.pem` | recommended | stable RSA token-signing key |
| `serviceAccount.annotations` | optional | EKS IRSA role (only if `storage.aws.useIrsa=true`) |
| `ingressRoute.enabled` / `.host` | optional | render the Traefik IngressRoute in-chart |
