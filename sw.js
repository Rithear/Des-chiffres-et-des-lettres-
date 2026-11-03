// Des chiffres et des lettres — fonctionnement hors connexion (depuis la v16)
// © 2026 Rithear – Tous droits réservés
//
// Ce fichier se dépose une seule fois, à côté de index.html.
// Il n'a PAS besoin d'être modifié à chaque mise à jour du jeu :
// la liste des fichiers à garder sur le téléphone se trouve dans index.html (constante OFFL).
//
// Fonctionnement :
// - la page du jeu : internet d'abord (dernière version), copie du téléphone si pas de réseau
//   ou si le réseau ne répond pas en 3,5 secondes ;
// - les sons, la vidéo et les dictionnaires : copie du téléphone, renouvelée quand index.html
//   annonce une nouvelle empreinte pour le fichier ;
// - la bibliothèque Supabase et les grandes listes de mots (jsdelivr) : gardées pour le hors connexion ;
// - Supabase (comptes, scores) et le Wiktionnaire ne passent jamais par ici.

const SCOPE = self.registration.scope;
const CACHE = "dcl1|" + SCOPE;           // un cache par dépôt (les dépôts de test ne se mélangent pas)
const MANIF = SCOPE + "__hors-connexion.json";
const WAIT = 3500;
const CDN = "https://cdn.jsdelivr.net/";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil((async () => {
  for (const k of await caches.keys())
    if (k.startsWith("dcl") && k.endsWith("|" + SCOPE) && k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

const sleep = ms => new Promise(r => setTimeout(r, ms));
const isPage = u => u.origin === location.origin && (u.href.split(/[?#]/)[0] === SCOPE || u.href.split(/[?#]/)[0] === SCOPE + "index.html");

self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET") return;
  const u = new URL(r.url);
  if (r.mode === "navigate" && isPage(u)) return e.respondWith(page(e));
  if (u.origin === location.origin && u.href.startsWith(SCOPE + "assets/")) return e.respondWith(asset(e));
  if (u.href.startsWith(CDN)) return e.respondWith(cdn(e));
});

// page du jeu : réseau d'abord, copie du téléphone en secours
async function page(e) {
  const c = await caches.open(CACHE);
  const net = fetch(e.request).then(res => {
    if (res.ok && res.type === "basic" && !res.redirected) c.put(SCOPE, res.clone());
    return res;
  });
  e.waitUntil(net.catch(() => {}));
  const old = await c.match(SCOPE);
  if (!old) return net.catch(() => new Response("<meta charset=utf-8><p style='font:18px system-ui;text-align:center;margin-top:40vh'>Pas de connexion internet.</p>", { headers: { "Content-Type": "text/html; charset=utf-8" } }));
  return Promise.race([
    net.then(res => res.ok ? res : old, () => old),
    sleep(WAIT).then(() => old)
  ]);
}

// sons, vidéo, dictionnaires : copie du téléphone d'abord
async function asset(e) {
  const r = e.request, key = r.url.split(/[?#]/)[0];
  const c = await caches.open(CACHE);
  const hit = await c.match(key);
  if (hit) return ranged(r, hit);
  try {
    const res = await fetch(r);
    if (res.status === 200 && !r.headers.has("range")) c.put(key, res.clone());
    return res;
  } catch (err) {
    return new Response("", { status: 504 });
  }
}

// jsdelivr : supabase-js (renouvelé en arrière-plan) et grandes listes de mots (fixes)
async function cdn(e) {
  const r = e.request, c = await caches.open(CACHE);
  const get = () => fetch(r.url, { mode: "cors", credentials: "omit" }).then(res => {
    if (res.ok) c.put(r.url, res.clone());
    return res;
  });
  const hit = await c.match(r.url);
  if (hit) {
    if (r.url.includes("supabase-js")) e.waitUntil(get().catch(() => {}));
    return hit;
  }
  // pas de copie : réseau, mais on n'attend pas indéfiniment (le jeu a ses listes de secours)
  return Promise.race([get(), sleep(8000).then(() => Response.error())]);
}

// lecture d'un morceau de fichier (les lecteurs audio/vidéo demandent souvent des morceaux)
async function ranged(r, res) {
  const h = r.headers.get("range");
  if (!h) return res;
  const m = /bytes=(\d*)-(\d*)/.exec(h);
  if (!m) return res;
  const b = await res.blob(), n = b.size;
  let s, end;
  if (m[1] === "") { s = Math.max(0, n - (+m[2] || 0)); end = n - 1; }
  else { s = +m[1]; end = m[2] === "" ? n - 1 : Math.min(+m[2], n - 1); }
  if (s >= n || s > end) return new Response(null, { status: 416, headers: { "Content-Range": "bytes */" + n } });
  return new Response(b.slice(s, end + 1), {
    status: 206,
    headers: {
      "Content-Type": res.headers.get("Content-Type") || "application/octet-stream",
      "Content-Range": "bytes " + s + "-" + end + "/" + n,
      "Content-Length": String(end - s + 1),
      "Accept-Ranges": "bytes"
    }
  });
}

// préparation du hors connexion : demandée par index.html avec la liste des fichiers
// si une liste plus récente arrive pendant une préparation, elle est traitée juste après
let loop = null, next = null;
self.addEventListener("message", e => {
  const d = e.data || {};
  if (d.t !== "pre" || !Array.isArray(d.f)) return;
  next = d;
  if (!loop) loop = (async () => {
    while (next) {
      const x = next; next = null;
      try { await prepare(x.f, x.x || []); } catch (err) { await tell({ t: "fail" }); }
    }
    loop = null;
  })();
  e.waitUntil(loop);
});

async function tell(m) {
  for (const cl of await self.clients.matchAll({ includeUncontrolled: true })) cl.postMessage(m);
}

async function prepare(files, extra) {
  const c = await caches.open(CACHE);
  let man = {};
  try { const r = await c.match(MANIF); if (r) man = await r.json(); } catch (err) {}
  const todo = [];
  for (const [p, h, size] of files) {
    const url = new URL(p, SCOPE).href;
    if (man[url] === h && await c.match(url)) continue;
    todo.push({ url, h, size: size || 1 });
  }
  if (!(await c.match(SCOPE))) todo.unshift({ url: SCOPE, h: "", size: 600000, page: 1 });
  for (const url of extra) if (!(await c.match(url))) todo.push({ url, h: "", size: 200000, cdn: 1 });
  const total = todo.reduce((a, x) => a + x.size, 0);
  let done = 0, fail = 0;
  if (todo.length) await tell({ t: "prog", p: 0 });
  for (const x of todo) {
    try {
      const res = x.cdn ? await fetch(x.url, { mode: "cors", credentials: "omit" }) : await fetch(x.url, { cache: "reload" });
      if (!res.ok || (x.page && res.redirected)) throw new Error(res.status);
      await c.put(x.url, res);
      if (x.h) { man[x.url] = x.h; await c.put(MANIF, new Response(JSON.stringify(man), { headers: { "Content-Type": "application/json" } })); }
    } catch (err) { fail++; }
    done += x.size;
    await tell({ t: "prog", p: Math.round(done / total * 100) });
  }
  // ménage : les anciens fichiers de assets/ qui ne sont plus dans la liste
  const keep = new Set(files.map(([p]) => new URL(p, SCOPE).href));
  for (const req of await c.keys()) {
    if (req.url.startsWith(SCOPE + "assets/") && !keep.has(req.url)) { await c.delete(req); delete man[req.url]; }
  }
  await c.put(MANIF, new Response(JSON.stringify(man), { headers: { "Content-Type": "application/json" } }));
  await tell({ t: fail ? "fail" : "ready" });
}
