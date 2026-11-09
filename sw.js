// Sans ce fichier, une app ajoutée à l'écran d'accueil garde sa propre copie de
// la page, que rien ne va chercher à rafraîchir : la seule façon d'obtenir une
// mise à jour était de supprimer l'icône et de la recréer.
//
// Stratégie « réseau d'abord » : à chaque lancement la page est retéléchargée
// (en contournant le cache HTTP, sinon les 10 minutes de cache de GitHub Pages
// s'appliqueraient encore), et la copie locale ne sert que hors connexion.
const CACHE = 'soulieteur-grinta-2026-v2';
// After updating, clear only obsolete copies owned by this application's SW.
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(name => name === 'soulieteur' || name.startsWith('soulieteur-grinta-2026-'))
      .filter(name => name !== CACHE).map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener('install', () => self.skipWaiting());
// Versioned cache cleanup and client claiming run in the activate handler above.

self.addEventListener('fetch', e => {
  const req = e.request;
  // Seules les ressources du site passent par ici : les appels à Supabase et
  // les polices Google gardent leur comportement normal.
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;

  e.respondWith((async () => {
    try {
      const fresh = await fetch(req, { cache: 'no-store' });
      if (fresh.ok) (await caches.open(CACHE)).put(req, fresh.clone());
      return fresh;
    } catch (err) {
      const cached = await caches.match(req);
      if (cached) return cached;
      // Une navigation hors connexion retombe sur la dernière page gardée.
      if (req.mode === 'navigate') {
        const home = await caches.match('./index.html') || await caches.match('./');
        if (home) return home;
      }
      throw err;
    }
  })());
});
