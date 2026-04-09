#!/usr/bin/env bash
# setup-ngc-secret.sh <namespace>
# Creates a Kubernetes imagePullSecret for nvcr.io in the given namespace.
# Uses the NGC API key from ~/Downloads/ngcapikey (standard demo location).
#
# Usage:
#   bash scripts/setup-ngc-secret.sh dynamo-demo
#   bash scripts/setup-ngc-secret.sh dynamo-system

set -euo pipefail

NAMESPACE="${1:-dynamo-demo}"
SECRET_NAME="ngc-registry"
NGC_KEY_FILE="${NGC_KEY_FILE:-${HOME}/Downloads/ngcapikey}"
REGISTRY="nvcr.io"

if [ ! -f "${NGC_KEY_FILE}" ]; then
  echo "ERROR: NGC API key file not found at ${NGC_KEY_FILE}"
  echo "  Set NGC_KEY_FILE env var or place key at ${NGC_KEY_FILE}"
  exit 1
fi

NGC_KEY=$(cat "${NGC_KEY_FILE}")

# Idempotent: delete and recreate if already exists
kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null

kubectl create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${REGISTRY}" \
  --docker-username='$oauthtoken' \
  --docker-password="${NGC_KEY}" \
  --namespace="${NAMESPACE}"

echo "✓ imagePullSecret '${SECRET_NAME}' created in namespace '${NAMESPACE}'"
