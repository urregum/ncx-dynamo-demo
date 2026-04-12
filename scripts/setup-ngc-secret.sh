#!/usr/bin/env bash
# setup-ngc-secret.sh <namespace>
# Creates a Kubernetes imagePullSecret for nvcr.io in the given namespace.
#
# Key resolution order:
#   1. NGC_API_KEY env var   (export NGC_API_KEY='<your-key>')
#   2. NGC_KEY_FILE env var  (path to a file containing the key)
#   3. Default file:         ~/.ngc/apikey
#
# Usage:
#   bash scripts/setup-ngc-secret.sh dynamo-demo
#   bash scripts/setup-ngc-secret.sh dynamo-system

set -euo pipefail

NAMESPACE="${1:-dynamo-demo}"
SECRET_NAME="ngc-registry"
REGISTRY="nvcr.io"

if [ -n "${NGC_API_KEY:-}" ]; then
  NGC_KEY="${NGC_API_KEY}"
else
  NGC_KEY_FILE="${NGC_KEY_FILE:-${HOME}/.ngc/apikey}"
  if [ ! -f "${NGC_KEY_FILE}" ]; then
    echo "ERROR: NGC API key not found."
    echo "  Set NGC_API_KEY env var:   export NGC_API_KEY='<your-key>'"
    echo "  Or place key at:           ${NGC_KEY_FILE}"
    echo "  Or set NGC_KEY_FILE to a custom path."
    exit 1
  fi
  NGC_KEY=$(cat "${NGC_KEY_FILE}")
fi

# Idempotent: delete and recreate if already exists
kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null

kubectl create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${REGISTRY}" \
  --docker-username='$oauthtoken' \
  --docker-password="${NGC_KEY}" \
  --namespace="${NAMESPACE}"

echo "✓ imagePullSecret '${SECRET_NAME}' created in namespace '${NAMESPACE}'"
