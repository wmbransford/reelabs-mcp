# Deployment

Cloud infrastructure for the transcription proxy, device-code auth flow, and install landing page. Deployed to Firebase (project `orbit-ai-d1f41`).

End users installing ReeLabs MCP via Homebrew or the curl installer do **not** need anything in this folder. It's only relevant when deploying or updating the backend.

## Layout

| Path | Purpose |
|------|---------|
| `functions/` | Cloud Functions: transcription proxy, device-code auth, user activation |
| `web/public/` | Firebase Hosting site (landing page, `install.sh`, device-activation page) |
| `firestore.rules` | Firestore security rules |
| `firestore.indexes.json` | Firestore composite indexes |
| `firebase.json` | Firebase CLI config (functions, hosting, firestore) |
| `.firebaserc` | Default Firebase project (`orbit-ai-d1f41`) |
| `setup-gcp.sh` | One-time GCP setup: enables APIs, creates service account, grants roles |

## First-time setup

```bash
cd deployment
./setup-gcp.sh           # enable APIs, create service account
firebase login           # if not already logged in
firebase deploy          # deploy everything
```

## Routine deploys

All `firebase` commands must be run from this directory.

```bash
cd deployment

firebase deploy --only functions     # backend changes
firebase deploy --only hosting       # landing page / install.sh changes
firebase deploy --only firestore     # rules / index changes
firebase deploy                      # everything
```

## Local development

```bash
cd deployment/functions
npm install
npm run build        # compile TypeScript
npm run serve        # emulate functions locally
```
