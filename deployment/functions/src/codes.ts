import { randomBytes, createHash } from "node:crypto";

const USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ23456789";

export function generateDeviceCode(): string {
  return randomBytes(32).toString("base64url");
}

export function generateUserCode(): string {
  const pick = () => {
    const buf = randomBytes(4);
    let out = "";
    for (let i = 0; i < 4; i++) {
      out += USER_CODE_ALPHABET[buf[i] % USER_CODE_ALPHABET.length];
    }
    return out;
  };
  return `${pick()}-${pick()}`;
}

export function generateApiToken(): string {
  return "rl_" + randomBytes(32).toString("base64url");
}

export function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
