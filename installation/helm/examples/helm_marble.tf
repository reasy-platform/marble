# helm_marble.tf — drop this into reasy-infra-apps (repo root), alongside helm_n8n.tf etc.
#
# Follows the existing convention: one helm_release + one Traefik IngressRoute
# (kubernetes_manifest), static config in marble_config/marble-values.yaml, and
# dynamic/secret values injected via `set`. Helm provider hashicorp/helm ~> 3.1.0.
#
# Secrets flow (as in the rest of the repo): GitHub Actions secret -> TF_VAR_* ->
# sensitive variable -> helm_release `set`. The chart renders the k8s Secret from these.

locals {
  marble_domain_name = var.stage == "nonprod" ? "nonprod-marble.reasy.fr" : "marble.reasy.fr"
}

# --- Sensitive inputs (wire these in .github/workflows as TF_VAR_marble_* like the others) ---
variable "marble_firebase_api_key" {
  type      = string
  sensitive = true
}
variable "marble_opensanctions_api_key" {
  type      = string
  sensitive = true
}
variable "marble_session_secret" {
  # MUST be >= 32 chars. Generate once: openssl rand -base64 48
  type      = string
  sensitive = true
}
# Multi-line secrets are passed BASE64-encoded so their quotes/newlines need no escaping
# through GitHub Actions -> TF_VAR -> Terraform. They are base64decode()'d below.
variable "marble_gcp_service_account_json_b64" {
  # Firebase Admin service-account key JSON, base64-encoded.
  #   openssl base64 -A -in service_account_key.json | gh secret set MARBLE_GCP_SA_JSON_B64 --repo <owner>/<repo>
  type      = string
  sensitive = true
}
variable "marble_jwt_signing_key_b64" {
  # Stable RSA private key PEM, base64-encoded. Generate once: openssl genrsa 4096
  #   openssl base64 -A -in jwt_signing_key.pem | gh secret set MARBLE_JWT_SIGNING_KEY_B64 --repo <owner>/<repo>
  type      = string
  sensitive = true
}
variable "marble_aws_access_key_id" {
  # AWS access key for the S3 buckets (injected static credentials, no IRSA).
  type      = string
  sensitive = true
}
variable "marble_aws_secret_access_key" {
  type      = string
  sensitive = true
}

resource "helm_release" "marble" {
  name             = "marble"
  create_namespace = true
  namespace        = "marble"

  # First-party chart. Package + push to your OCI registry, e.g.:
  #   helm package marble/installation/helm && helm push marble-reasy-0.2.0.tgz oci://<ECR>/charts
  repository = "oci://496782470059.dkr.ecr.eu-west-1.amazonaws.com/reasy-helm/marble-reasy"
  chart      = "marble-reasy"
  version    = "0.2.0"
  # Alternatively, reference a local path instead of repository/version:
  #   chart = "${path.module}/charts/marble"

  values = ["${file("marble_config/marble-values.yaml")}"]

  set = [
    # --- External Postgres (RDS) ---
    { name = "postgres.host", value = data.aws_db_instance.rds.address },
    { name = "postgres.user", value = "marble" },
    { name = "postgres.password", value = var.rds_db_password },

    # --- URLs (stage-dependent) ---
    { name = "urls.appUrl", value = "https://${local.marble_domain_name}" },

    # --- S3 buckets (stage-dependent) ---
    { name = "storage.ingestionBucketUrl", value = "s3://reasy-marble-ingestion-${var.stage}" },
    { name = "storage.caseManagerBucketUrl", value = "s3://reasy-marble-case-manager-${var.stage}" },

    # --- S3 static credentials (no IRSA) ---
    { name = "storage.aws.accessKeyId", value = var.marble_aws_access_key_id },
    { name = "storage.aws.secretAccessKey", value = var.marble_aws_secret_access_key },

    # --- Secrets (rendered by the chart into the marble Secret) ---
    { name = "auth.firebase.apiKey", value = var.marble_firebase_api_key },
    { name = "screening.opensanctions.apiKey", value = var.marble_opensanctions_api_key },
    { name = "frontend.session.secret", value = var.marble_session_secret },
    # Decoded here -> the JSON/PEM reach Terraform escaping-free; the chart's `| quote` does final escaping.
    { name = "auth.firebase.serviceAccount.json", value = base64decode(var.marble_gcp_service_account_json_b64) },
    { name = "apiServer.jwtSigningKey.pem", value = base64decode(var.marble_jwt_signing_key_b64) },
  ]
}

# Traefik IngressRoute — only the frontend is exposed; api-server/worker stay internal.
resource "kubernetes_manifest" "marble_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "marble-server"
      namespace = "marble"
      annotations = {
        "kubernetes.io/ingress.class"             = "traefik-public"
        "external-dns.alpha.kubernetes.io/target" = data.aws_lb.public_nlb.dns_name
      }
    }
    spec = {
      entryPoints = ["websecure", "web"]
      routes = [
        {
          match    = "Host(`${local.marble_domain_name}`)"
          kind     = "Rule"
          services = [{ name = "marble-frontend", port = 8080 }]
        },
        # Uncomment to also expose Marble's programmatic public API to external clients:
        {
          match    = "Host(`${local.marble_domain_name}`) && (PathPrefix(`/v1`) || PathPrefix(`/v1beta`))"
          kind     = "Rule"
          services = [{ name = "marble-api", port = 8080 }]
        },
      ]
      tls = { certResolver = "le" }
    }
  }
  depends_on = [helm_release.marble]
}
