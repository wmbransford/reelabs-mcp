import { onRequest } from "firebase-functions/v2/https";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { sha256 } from "./codes";

export const deviceToken = onRequest(
  { cors: false, region: "us-central1" },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }

    const deviceCode = (req.body?.deviceCode ?? "").toString();
    if (!deviceCode) {
      res.status(400).json({ error: "missing_device_code" });
      return;
    }

    const db = getFirestore();
    const ref = db.collection("deviceCodes").doc(sha256(deviceCode));
    const snap = await ref.get();

    if (!snap.exists) {
      res.status(404).json({ error: "invalid_device_code" });
      return;
    }

    const data = snap.data()!;
    const now = Timestamp.now();

    if (data.expiresAt.toMillis() < now.toMillis()) {
      await ref.delete();
      res.status(410).json({ error: "expired" });
      return;
    }

    if (data.status === "pending") {
      res.status(202).json({ status: "pending" });
      return;
    }

    if (data.status === "activated" && data.apiToken) {
      // Consume the token: return it once, then delete the device code doc.
      const apiToken = data.apiToken as string;
      await ref.delete();
      res.status(200).json({
        status: "activated",
        apiToken,
        uid: data.uid,
      });
      return;
    }

    res.status(500).json({ error: "invalid_state" });
  },
);
