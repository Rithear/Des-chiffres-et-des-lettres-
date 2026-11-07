// @ts-nocheck
// ============================================================================
// Des chiffres et des lettres : fonction Supabase « push » (notifications)
// © 2026 Rithear – Tous droits réservés
//
// À coller en entier dans Supabase > Edge Functions > (fonction « push ») puis Deploy.
// La base l'appelle toute seule chaque minute avec les notifications à envoyer
// (voir supabase-notifications.sql). Elle chiffre chaque message et l'envoie au
// téléphone du joueur (Web Push). Aucune donnée n'est gardée ici.
//
// Le secret VAPID_PRIVATE doit être enregistré dans Edge Functions > Secrets.
// Ne mets jamais ce secret dans un fichier sur GitHub.
// ============================================================================

const VAPID_PUBLIC = "BKpXlUkaaqXwMR3SVnQ_t6SfYgTfbzjRigGSTubqkjxmDHcsrsEtICnv_lrA99lJ_me8j2CYLMb2OfzcSmHQWCU";
const SUBJECT = "mailto:dcedl.jeu@gmail.com";
const SB_URL = "https://destghbdqigegolliggd.supabase.co";
const SB_KEY = "sb_publishable_arAUj7PGF7TMzS1IcHYnVw_1MroacPZ";
// seuls les services de notification des navigateurs sont acceptés
const HOSTS = [/(^|\.)googleapis\.com$/, /(^|\.)push\.services\.mozilla\.com$/, /(^|\.)push\.apple\.com$/, /(^|\.)notify\.windows\.com$/];

const enc = new TextEncoder();
const b64d = (s) => {
  s = String(s).replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
};
const b64e = (u) => {
  let s = "";
  for (const x of u) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const cat = (...a) => {
  const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0));
  let i = 0;
  for (const x of a) { o.set(x, i); i += x.length; }
  return o;
};

// ----- signature VAPID (prouve que le message vient bien du jeu) -----
let signKey = null;
async function getSignKey() {
  if (signKey) return signKey;
  const pub = b64d(VAPID_PUBLIC);
  const d = (Deno.env.get("VAPID_PRIVATE") || "").trim();
  if (!d) throw new Error("VAPID_PRIVATE manquant");
  signKey = await crypto.subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", x: b64e(pub.slice(1, 33)), y: b64e(pub.slice(33, 65)), d, ext: true },
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return signKey;
}
const jwts = new Map();
async function vapid(aud) {
  const now = Math.floor(Date.now() / 1000), c = jwts.get(aud);
  if (c && c.exp - now > 3600) return c.t;
  const exp = now + 12 * 3600;
  const h = b64e(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const p = b64e(enc.encode(JSON.stringify({ aud, exp, sub: SUBJECT })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await getSignKey(), enc.encode(h + "." + p)));
  const t = h + "." + p + "." + b64e(sig);
  jwts.set(aud, { t, exp });
  return t;
}

// ----- chiffrement du message (RFC 8291, aes128gcm) -----
async function hkdf(salt, ikm, info, len) {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, len * 8));
}
async function encrypt(p256dh, auth, text) {
  const ua = b64d(p256dh), sec = b64d(auth);
  const kp = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const as = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", ua, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, kp.privateKey, 256));
  const ikm = await hkdf(sec, shared, cat(enc.encode("WebPush: info\0"), ua, as), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, cat(enc.encode(text), new Uint8Array([2]))));
  return cat(salt, new Uint8Array([0, 0, 16, 0]), new Uint8Array([as.length]), as, ct);
}

// ----- envoi d'un message -----
async function send(m) {
  const u = new URL(m.e);
  if (u.protocol !== "https:" || !HOSTS.some((r) => r.test(u.hostname))) return "bad";
  const body = await encrypt(m.k, m.a, m.p);
  const r = await fetch(m.e, {
    method: "POST",
    headers: {
      Authorization: "vapid t=" + (await vapid(u.origin)) + ", k=" + VAPID_PUBLIC,
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "86400",
      Urgency: "normal",
    },
    body,
  });
  try { await r.arrayBuffer(); } catch (_) { /* rien */ }
  return r.status;
}

Deno.serve(async (req) => {
  const json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  // ouverture dans un navigateur : petit contrôle de l'installation
  if (req.method !== "POST") return json({ ok: true, cle_vapid: !!(Deno.env.get("VAPID_PRIVATE") || "").trim() });
  let msgs = [];
  try { const j = await req.json(); if (Array.isArray(j.msgs)) msgs = j.msgs.slice(0, 500); } catch (_) { /* rien */ }
  const gone = [], res = { envoyes: 0, erreurs: 0, codes: {} };
  await Promise.all(msgs.map(async (m) => {
    try {
      const s = await send(m);
      res.codes[s] = (res.codes[s] || 0) + 1;
      if (s === 404 || s === 410 || s === "bad") gone.push(m.e);
      else if (s >= 200 && s < 300) res.envoyes++;
      else res.erreurs++;
    } catch (e) {
      res.erreurs++;
      res.codes[String(e && e.message || e)] = 1;
    }
  }));
  // abonnements qui n'existent plus (application désinstallée, notifications coupées…)
  if (gone.length) {
    try {
      await fetch(SB_URL + "/rest/v1/rpc/push_gone", {
        method: "POST",
        headers: { apikey: SB_KEY, "Content-Type": "application/json" },
        body: JSON.stringify({ p_ends: [...new Set(gone)] }),
      });
    } catch (_) { /* rien */ }
  }
  return json({ ...res, supprimes: gone.length });
});
