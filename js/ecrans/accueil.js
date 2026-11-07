// Accueil : un pseudo, puis « Créer une partie » ou un code pour rejoindre.
// Le jeu se choisit ensuite dans le salon (la nouvelle partie reprend le
// dernier jeu choisi sur ce téléphone). Cinq appuis rapides sur le logo
// ouvrent l'admin : plus de bouton visible par tout le monde.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

// Brouillons : un rafraîchissement de l'écran ne vide pas les champs.
let homeName = null, homeCode = null;
function home(){
  const lien = (new URLSearchParams(location.search).get('code') || '').replace(/\D/g,'').slice(0,4);
  if (homeName === null) { try { homeName = localStorage.getItem('pdcat-name') || '' } catch { homeName = '' } }
  if (homeCode === null) homeCode = lien;
  const pseudo = `<label class="field"><span>Ton pseudo</span>
      <input id="h-name" maxlength="20" autocomplete="nickname" enterkeyhint="go" placeholder="Ton prénom ou surnom" value="${esc(homeName)}"></label>`;
  // Arrivé par un lien d'invitation : rejoindre passe en premier.
  const corps = lien ? `
      <p class="invite">Invitation à la partie <b>${esc(lien)}</b></p>
      ${pseudo}
      <button class="btn" data-act="join">Rejoindre la partie</button>
      <button class="btn ghost" data-act="create">Créer une autre partie</button>` : `
      ${pseudo}
      <button class="btn" data-act="create">Créer une partie</button>
      <p class="ou"><span>ou rejoindre une partie</span></p>
      <div class="joinrow">
        <input id="h-code" type="text" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="one-time-code" spellcheck="false"
          enterkeyhint="go" placeholder="Code" aria-label="Code de la partie, 4 chiffres" value="${esc(homeCode)}">
        <button class="btn ghost" data-act="join">Rejoindre</button>
      </div>`;
  return `
    <div class="home">
      <h1><button type="button" class="logo" data-act="logo" aria-label="Le Soulièteur"><img src="logo.svg" width="801" height="303" alt="Le Soulièteur" decoding="async" fetchpriority="high"></button><span class="shift" aria-hidden="true"></span></h1>
      <p class="tagline">Le jeu qui gâche les repas de famille.</p>
      <section class="panel homebox">${corps}
      </section>
    </div>`;
}

async function enter(call, name){
  if (busy) return;
  busy = true;
  try {
    const d = await call();
    try { localStorage.setItem('pdcat-name', name) } catch {}
    save({ code:d.code, token:d.token });
    homeCode = null;
    history.replaceState(null,'',location.pathname + '?code=' + d.code);
    busy = false; startSession();
  } catch (e) { busy = false; toast(e.message) }
}

/* ---------- Actions ---------- */
let logoTaps = [];
surAction('logo', () => {
  const t = Date.now();
  logoTaps = logoTaps.filter(x => t - x < 3000).concat(t);
  if (logoTaps.length >= 5) { logoTaps = []; ouvrirAdmin() }
}, { marque:false });
surAction('create', () => {
  const n = val('h-name'); if (!n) return toast('Choisis un pseudo.');
  return enter(() => rpc('create_room', { p_name:n, p_target:5, p_mode:dernierJeu(), p_turns:2 }), n);
});
surAction('join', () => {
  const c = String(homeCode || '').replace(/\D/g,''), n = val('h-name');
  if (!n) return toast('Choisis un pseudo.');
  if (c.length !== 4) return toast('Le code fait 4 chiffres.');
  return enter(() => rpc('join_room',{ p_code:c, p_name:n }), n);
});
document.addEventListener('input', e => {
  if (e.target.id === 'h-name') homeName = e.target.value;
  if (e.target.id === 'h-code') homeCode = e.target.value = e.target.value.replace(/\D/g,'');
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Enter') return;
  // Entrée dans le pseudo : rejoindre si un code est là, sinon créer.
  if (e.target.matches('#h-name')) document.querySelector(String(homeCode || '').length === 4 ? '[data-act=join]' : '[data-act=create]')?.click();
  if (e.target.matches('#h-code')) document.querySelector('[data-act=join]')?.click();
});
