import type { Request } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { sha256 } from "./codes";

export interface AuthedUser {
  uid: string;
  tokenHash: string;
}

export async function authenticate(req: Request): Promise<AuthedUser | null> {
  const header = req.header("authorization") ?? req.header("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) return null;

  const apiToken = match[1].trim();
  const tokenHash = sha256(apiToken);

  const db = getFirestore();
  const ref = db.collection("apiTokens").doc(tokenHash);
  const snap = await ref.get();
  if (!snap.exists) return null;

  const data = snap.data()!;
  if (data.revokedAt) return null;

  // Best-effort lastUsedAt update. Don't await.
  ref.update({ lastUsedAt: FieldValue.serverTimestamp() }).catch(() => {});

  return { uid: data.uid as string, tokenHash };
}
