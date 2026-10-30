#!/usr/bin/env bash
# Generate cosign key pair for Stage 3 image signing.
# Private key goes to keys/cosign.key (git-ignored).
# Public key goes to keys/cosign.pub (committed, used in pipeline verify step).
#
# Lab key has empty passphrase (COSIGN_PASSWORD="").
# Production: use a KMS-backed key; store passphrase in Jenkins credential vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/../keys"
mkdir -p "${KEYS_DIR}"

if [[ -f "${KEYS_DIR}/cosign.key" ]]; then
  echo "keys/cosign.key already exists. Delete it first to regenerate."
  exit 1
fi

echo "Generating cosign key pair (empty passphrase for lab)..."

docker run --rm \
  -v "${KEYS_DIR}:/keys" \
  -e COSIGN_PASSWORD="" \
  -w /keys \
  gcr.io/projectsigstore/cosign:v2.5.0 \
  generate-key-pair --output-key-prefix cosign

chmod 600 "${KEYS_DIR}/cosign.key"

echo ""
echo "Key pair generated:"
echo "  Private: keys/cosign.key  (git-ignored — NEVER commit)"
echo "  Public:  keys/cosign.pub  (safe to commit)"
echo ""
echo "Next steps:"
echo "  1. git add keys/cosign.pub && git commit -m 'add cosign public key'"
echo "  2. Load cosign.key into Jenkins as a Secret File credential (id: cosign-private-key-file)"
echo "  3. Run the Stage 3 pipeline — it signs by digest and verifies before finishing"
