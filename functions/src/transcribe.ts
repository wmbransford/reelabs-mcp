import { onRequest } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { GoogleAuth } from "google-auth-library";
import {
  CHIRP_LOCATION,
  CHIRP_MODEL,
  CHIRP_PROJECT_ID,
  CHIRP_PROXY_SA,
  FREE_TIER_MINUTES_PER_MONTH,
} from "./config";
import { authenticate } from "./auth";

const auth = new GoogleAuth({
  scopes: "https://www.googleapis.com/auth/cloud-platform",
});

export const transcribe = onRequest(
  {
    cors: false,
    region: "us-central1",
    serviceAccount: CHIRP_PROXY_SA,
    memory: "512MiB",
    timeoutSeconds: 120,
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }

    const user = await authenticate(req);
    if (!user) {
      res.status(401).json({ error: "unauthenticated" });
      return;
    }

    const language = (req.query.language as string) || "en-US";
    const durationSeconds = parseFloat(
      (req.query.durationSeconds as string) || "0",
    );
    if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
      res.status(400).json({ error: "missing_duration" });
      return;
    }

    const db = getFirestore();
    const userRef = db.collection("users").doc(user.uid);

    // Quota check — free tier: FREE_TIER_MINUTES_PER_MONTH per period.
    const userSnap = await userRef.get();
    const userData = userSnap.exists ? userSnap.data()! : {};
    const tier = (userData.subscriptionTier as string) ?? "free";
    const minutesUsed = (userData.quotaMinutesUsed as number) ?? 0;
    const chargeMinutes = durationSeconds / 60;

    if (tier === "free" && minutesUsed + chargeMinutes > FREE_TIER_MINUTES_PER_MONTH) {
      res.status(402).json({
        error: "quota_exceeded",
        tier,
        minutesUsed,
        limit: FREE_TIER_MINUTES_PER_MONTH,
      });
      return;
    }

    // Expect raw audio bytes in body (application/octet-stream or audio/flac).
    const audioBytes: Buffer = req.rawBody;
    if (!audioBytes || audioBytes.length === 0) {
      res.status(400).json({ error: "missing_audio" });
      return;
    }

    let chirpResponse: unknown;
    try {
      chirpResponse = await callChirp(audioBytes, language);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      res.status(502).json({ error: "chirp_failed", detail: msg });
      return;
    }

    // Charge usage after successful call.
    await userRef.set(
      {
        quotaMinutesUsed: FieldValue.increment(chargeMinutes),
        lastTranscribeAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    res.status(200).json(chirpResponse);
  },
);

async function callChirp(audio: Buffer, language: string): Promise<unknown> {
  const client = await auth.getClient();
  const tokenResp = await client.getAccessToken();
  const token = tokenResp.token;
  if (!token) throw new Error("no_access_token");

  const recognizer = `projects/${CHIRP_PROJECT_ID}/locations/${CHIRP_LOCATION}/recognizers/_`;
  const url = `https://${CHIRP_LOCATION}-speech.googleapis.com/v2/${recognizer}:recognize`;

  const body = {
    config: {
      languageCodes: [language],
      model: CHIRP_MODEL,
      features: {
        enableWordTimeOffsets: true,
        enableAutomaticPunctuation: true,
      },
      autoDecodingConfig: {},
    },
    content: audio.toString("base64"),
  };

  const resp = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`chirp_${resp.status}: ${text}`);
  }
  return await resp.json();
}
