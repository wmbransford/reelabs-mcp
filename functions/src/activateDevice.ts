import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";
import { generateApiToken, sha256 } from "./codes";

interface ActivateRequest {
  userCode: string;
}

interface ActivateResponse {
  status: "ok";
}

export const activateDevice = onCall<ActivateRequest, Promise<ActivateResponse>>(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "sign_in_required");
    }
    const uid = request.auth.uid;
    const userCode = (request.data?.userCode ?? "").toUpperCase().trim();
    if (!userCode) {
      throw new HttpsError("invalid-argument", "missing_user_code");
    }

    const db = getFirestore();
    const now = Timestamp.now();

    const snap = await db
      .collection("deviceCodes")
      .where("userCode", "==", userCode)
      .limit(1)
      .get();

    if (snap.empty) {
      throw new HttpsError("not-found", "code_not_found");
    }
    const doc = snap.docs[0];
    const data = doc.data();

    if (data.status !== "pending") {
      throw new HttpsError("failed-precondition", "code_already_used");
    }
    if (data.expiresAt.toMillis() < now.toMillis()) {
      throw new HttpsError("deadline-exceeded", "code_expired");
    }

    const apiToken = generateApiToken();
    const apiTokenHash = sha256(apiToken);

    await db.runTransaction(async (tx) => {
      // Upsert user profile.
      const userRef = db.collection("users").doc(uid);
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) {
        tx.set(userRef, {
          email: request.auth!.token.email ?? null,
          displayName: request.auth!.token.name ?? null,
          photoURL: request.auth!.token.picture ?? null,
          createdAt: now,
          subscriptionTier: "free",
          quotaMinutesUsed: 0,
          quotaPeriodStart: now,
        });
      }

      // Store API token (hashed).
      tx.set(db.collection("apiTokens").doc(apiTokenHash), {
        uid,
        createdAt: now,
        lastUsedAt: now,
      });

      // Mark device code activated. Plaintext apiToken lives here until the
      // binary polls and retrieves it, at which point it's deleted.
      tx.update(doc.ref, {
        status: "activated",
        uid,
        apiToken,
        activatedAt: FieldValue.serverTimestamp(),
      });
    });

    return { status: "ok" };
  },
);
