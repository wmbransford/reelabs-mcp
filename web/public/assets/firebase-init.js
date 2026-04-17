import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.2/firebase-app.js";
import {
  getAuth,
  GoogleAuthProvider,
  signInWithPopup,
  onAuthStateChanged,
  signOut,
} from "https://www.gstatic.com/firebasejs/11.0.2/firebase-auth.js";
import {
  getFunctions,
  httpsCallable,
} from "https://www.gstatic.com/firebasejs/11.0.2/firebase-functions.js";

const firebaseConfig = {
  apiKey: "AIzaSyC4bIoLibzSS3zOW7sMuMC17ix6rR7xQN0",
  authDomain: "orbit-ai-d1f41.firebaseapp.com",
  projectId: "orbit-ai-d1f41",
  storageBucket: "orbit-ai-d1f41.firebasestorage.app",
  messagingSenderId: "509939739929",
  appId: "1:509939739929:web:366158eb9b60c166c5a988",
  measurementId: "G-WFCZGD53CF",
};

export const app = initializeApp(firebaseConfig);
export const auth = getAuth(app);
export const functions = getFunctions(app, "us-central1");

export const googleProvider = new GoogleAuthProvider();

export { signInWithPopup, onAuthStateChanged, signOut, httpsCallable };
