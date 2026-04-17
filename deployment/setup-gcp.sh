#!/bin/bash
# One-time GCP setup for the ReeLabs proxy backend.
# Safe to re-run — all steps are idempotent.
#
# What this creates:
#   - Enables the APIs the proxy depends on (Speech, Firestore, Functions, etc.)
#   - Creates the `reelabs-mcp-proxy` service account (the "robot" the
#     transcribe function runs as)
#   - Grants it:
#       * roles/speech.client    — call Chirp speech-to-text
#       * roles/datastore.user   — read API tokens + write quota in Firestore
#
# After this runs, `firebase deploy --only functions` will work on a clean
# project. Without it, the transcribe function gets 500s on every request.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-orbit-ai-d1f41}"
SA_NAME="reelabs-mcp-proxy"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

REQUIRED_APIS=(
    speech.googleapis.com
    firestore.googleapis.com
    cloudfunctions.googleapis.com
    run.googleapis.com
    cloudbuild.googleapis.com
    artifactregistry.googleapis.com
    eventarc.googleapis.com
    pubsub.googleapis.com
    secretmanager.googleapis.com
)

REQUIRED_ROLES=(
    roles/speech.client
    roles/datastore.user
)

echo "=== ReeLabs GCP setup ==="
echo "Project: $PROJECT_ID"
echo "Service account: $SA_EMAIL"
echo ""

echo "Enabling APIs..."
gcloud services enable "${REQUIRED_APIS[@]}" --project="$PROJECT_ID"

echo ""
echo "Ensuring service account exists..."
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    echo "  Service account already exists."
else
    gcloud iam service-accounts create "$SA_NAME" \
        --project="$PROJECT_ID" \
        --display-name="ReeLabs MCP Proxy" \
        --description="Runs the transcribe Cloud Function. Needs Chirp + Firestore access only."
    echo "  Created."
fi

echo ""
echo "Granting roles..."
for role in "${REQUIRED_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SA_EMAIL" \
        --role="$role" \
        --condition=None \
        --quiet \
        >/dev/null
    echo "  $role"
done

echo ""
echo "✓ GCP setup complete."
echo "  Next: cd deployment && firebase deploy --only functions"
