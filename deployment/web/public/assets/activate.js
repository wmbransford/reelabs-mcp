import {
  auth,
  googleProvider,
  signInWithPopup,
  onAuthStateChanged,
  functions,
  httpsCallable,
} from "./firebase-init.js";

const codeInput = document.getElementById("code-input");
const signInBtn = document.getElementById("sign-in-btn");
const activateBtn = document.getElementById("activate-btn");
const userInfo = document.getElementById("user-info");
const userEmail = document.getElementById("user-email");
const statusEl = document.getElementById("status");
const successEl = document.getElementById("success");
const formEl = document.getElementById("form");

// Pre-fill code from query string.
const urlCode = new URL(window.location.href).searchParams.get("code");
if (urlCode) {
  codeInput.value = urlCode.toUpperCase();
}

function setStatus(text, type) {
  statusEl.textContent = text;
  statusEl.className = "status" + (type ? " " + type : "");
}

onAuthStateChanged(auth, (user) => {
  if (user) {
    signInBtn.style.display = "none";
    userInfo.style.display = "flex";
    userEmail.textContent = user.email ?? user.displayName ?? "signed in";
    activateBtn.disabled = !codeInput.value.trim();
  } else {
    signInBtn.style.display = "inline-flex";
    userInfo.style.display = "none";
    activateBtn.disabled = true;
  }
});

codeInput.addEventListener("input", () => {
  if (auth.currentUser) {
    activateBtn.disabled = !codeInput.value.trim();
  }
});

signInBtn.addEventListener("click", async () => {
  setStatus("");
  try {
    await signInWithPopup(auth, googleProvider);
  } catch (err) {
    setStatus(`Sign-in failed: ${err?.message ?? err}`, "error");
  }
});

activateBtn.addEventListener("click", async () => {
  const code = codeInput.value.trim().toUpperCase();
  if (!code) return;

  activateBtn.disabled = true;
  setStatus("Activating…");

  try {
    const activateDevice = httpsCallable(functions, "activateDevice");
    await activateDevice({ userCode: code });
    formEl.style.display = "none";
    successEl.style.display = "block";
    setStatus("");
  } catch (err) {
    const code = err?.code ?? "unknown";
    const msg = err?.message ?? String(err);
    setStatus(`${code}: ${msg}`, "error");
    activateBtn.disabled = false;
  }
});
