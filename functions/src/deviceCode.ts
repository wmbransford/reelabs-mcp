import { onRequest } from "firebase-functions/v2/https";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import {
  ACTIVATION_URL_BASE,
  DEVICE_CODE_POLL_INTERVAL_SECONDS,
  DEVICE_CODE_TTL_SECONDS,
} from "./config";
import { generateDeviceCode, generateUserCode, sha256 } from "./codes";

export const deviceCode = onRequest(
  { cors: false, region: "us-central1" },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }

    const db = getFirestore();
    const deviceCode = generateDeviceCode();
    const userCode = await allocateUniqueUserCode(db);

    const now = Timestamp.now();
    const expiresAt = Timestamp.fromMillis(
      now.toMillis() + DEVICE_CODE_TTL_SECONDS * 1000,
    );

    await db.collection("deviceCodes").doc(sha256(deviceCode)).set({
      userCode,
      status: "pending",
      createdAt: now,
      expiresAt,
    });

    const verificationUri = ACTIVATION_URL_BASE;
    const verificationUriComplete = `${ACTIVATION_URL_BASE}?code=${encodeURIComponent(userCode)}`;

    res.status(200).json({
      deviceCode,
      userCode,
      verificationUri,
      verificationUriComplete,
      expiresInSeconds: DEVICE_CODE_TTL_SECONDS,
      intervalSeconds: DEVICE_CODE_POLL_INTERVAL_SECONDS,
    });
  },
);

async function allocateUniqueUserCode(
  db: FirebaseFirestore.Firestore,
): Promise<string> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const candidate = generateUserCode();
    const existing = await db
      .collection("deviceCodes")
      .where("userCode", "==", candidate)
      .limit(1)
      .get();
    if (existing.empty) return candidate;
  }
  throw new Error("failed_to_allocate_user_code");
}
