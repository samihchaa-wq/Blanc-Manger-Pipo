// Cartes et accord des phrases, rendu, accueil, admin, barre du haut, salon et punitions, écrans de Phrases à trou.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Cartes ---------- */
// replaceAll, pas replace : une phrase à deux trous n'en montrait qu'un, le
// second restant affiché en quatre tirets bas bruts.
function blank(q){ return esc(q).replaceAll('____','<span class="blank"></span>') }
// Mots qui s'élident devant une voyelle. Sans ça « on a arrêté de ____ » suivi
// de « aller chez le kiné » donne « arrêté de aller ». Le h est traité comme
// aspiré (« de Hitler ») : le catalogue n'a aucune réponse à h muet en tête.
const ELIDE = /\b(de|ce|je|le|la|me|ne|se|te|que|jusque|lorsque|puisque|quoique)\s+$/i;
const VOYELLE = /^[aeiouyàâäéèêëîïôöùûü]/i;
// Un groupe nominal qui s'ouvre sur un déterminant n'est jamais un nom propre :
// son initiale peut redescendre en milieu de phrase. Un infinitif non plus,
// mais ça le serveur seul le sait, d'où le champ « form ».
const DET = /^(un|une|des|le|la|les|du|de|mon|ma|mes|ton|ta|tes|son|sa|ses|notre|nos|votre|vos|leur|leurs|ce|cet|cette|ces|deux|trois|quatre)\b/i;
// Articles contractés. « pour en arriver à » + « les années 39-45 » ne donne pas
// « à les années » mais « aux années ». La préposition et l'article fusionnent
// en un seul mot, qui part donc avec la réponse et non avec la question.
// « de » + « des » : la règle stricte réduit à « de » (« à cause de capotes
// XXL »), mais ça se lit comme un mot manquant. On absorbe le « de » de la
// question à la place, en lisant le « des » de la carte comme « de les ».
// Laisser les deux donnerait « à cause de des capotes XXL ».
// Le \b d'usage ne marche pas devant « à », que JavaScript ne compte pas comme
// une lettre : on capture l'espace qui précède pour retrouver où couper.
const CONTRACT = [
  [/(^|\s)à\s+$/i,  /^les\b\s*/i, 'aux '],
  [/(^|\s)à\s+$/i,  /^le\b\s*/i,  'au '],
  [/(^|\s)de\s+$/i, /^les\b\s*/i, 'des '],
  [/(^|\s)de\s+$/i, /^le\b\s*/i,  'du '],
  [/(^|\s)de\s+$/i, /^des\b\s*/i, 'des '],
];

// `cartes` est la liste des réponses, une par trou. Une case vide reste un trou,
// ce qui donne l'aperçu au fur et à mesure que le joueur choisit.
function fill(q, cartes){
  const liste = Array.isArray(cartes) ? cartes : [cartes];
  const morceaux = String(q).split('____');
  if (morceaux.length < 2) return esc(q) + ' <span class="fill">' + esc(liste[0]?.text ?? '') + '</span>';

  let html = '', avant = morceaux[0];
  for (let k = 0; k < morceaux.length - 1; k++) {
    const c = liste[k] || {};
    if (!c.text) { html += esc(avant) + '<span class="blank"></span>'; avant = morceaux[k + 1]; continue }

    // La réponse est stockée telle que son autrice l'a tapée. Le trou en tête de
    // phrase impose la majuscule ; ailleurs on l'abaisse, mais seulement quand la
    // réponse ne peut pas être un nom propre : « Jean-Michel » et « Hitler »
    // gardent la leur, « Un Ricard tiède » la perd.
    let x = (k === 0 && avant === '') ? c.text.charAt(0).toUpperCase() + c.text.slice(1)
          : (c.form === 'v' || DET.test(c.text)) ? c.text.charAt(0).toLowerCase() + c.text.slice(1)
          : c.text;

    let fondu = false;
    for (const [prep, art, sortie] of CONTRACT) {
      const mp = avant.match(prep);
      if (mp && art.test(x)) {
        avant = avant.slice(0, mp.index + mp[1].length);
        x = sortie + x.replace(art, '');
        fondu = true;
        break;
      }
    }
    // Une contraction a déjà absorbé la préposition : plus rien à élider.
    const el = fondu ? null : avant.match(ELIDE);
    // « de » → « d' », « que » → « qu' », « la » → « l' » : on retire la voyelle finale.
    if (el && VOYELLE.test(x)) avant = avant.slice(0, el.index) + el[1].slice(0,-1) + '’';

    html += esc(avant) + '<span class="fill">' + esc(x) + '</span>';
    avant = morceaux[k + 1];
  }
  return html + esc(avant);
}
function qcard(tag, html, cls = '', foot = ''){
  return `<div class="qcard ${cls}${dealPending ? ' deal' : ''}"><span class="qtag">${tag}</span>
    <p class="qtext">${html}</p>${foot}</div>`;
}

/* ---------- Vues ---------- */
function render(){
  // un re-rendu pendant un glissement arracherait la carte sous le doigt
  if (dragging || flying) { pendingRender = true; return }
  document.body.classList.toggle('is-home', !session && !adminOpen);
  let html;
  if (adminOpen) html = adminView();
  else if (!session) html = home();
  else if (!state) html = '<p class="center"><span class="spin"></span>Connexion à la partie…</p>';
  else html = topbar() + { lobby, question_select: qselect, answering, judging, ranking, clue, guessing,
    naming: bacNaming, writing: bacWrite, voting: bacVote,
    white_clue:whiteClue, white_vote:whiteVote, white_guess:whiteGuess,
    white_elimination:whiteElimination, mime_play:mimePlay, reveal, finished }[state.room.status]();
  // Réécrire un DOM identique fait clignoter les boutons et perdre le focus :
  // la plupart des rafraîchissements ne changent rien à l'écran.
  // Sans barre d'action fixe, la réserve du bas laisserait un grand vide.
  document.body.classList.toggle('no-dock', !html.includes('class="dock"'));
  if (html !== lastHtml) {
    lastHtml = html;
    // la saisie d'une punition survit au rafraîchissement du salon
    const ae = document.activeElement, focId = /^(pun-\d|w-clue|w-theme)$/.test(ae?.id || '') ? ae.id : null, foc = focId ? ae.selectionStart : null;
    app.innerHTML = html;
    if (focId) { const c = document.getElementById(focId); if (c) { c.focus(); c.setSelectionRange(foc, foc) } }
    // Fondu/glissé seulement quand on change d'écran, pas à chaque petit
    // rafraîchissement (sinon toute la page tremble sous les yeux).
    const key = adminOpen ? 'admin' : !session ? 'home' : !state ? 'load' : state.room.status + (pun?.phase ? '-pun' : '') + (isWhite() ? '-' + (state.white?.cycle || 0) : '');
    const newScreen = key !== renderedKey;
    if (newScreen) {
      renderedKey = key;
      app.classList.remove('enter'); void app.offsetWidth; app.classList.add('enter');
    }
    if (adminOpen) { paintCatalog(); majTrous(); autoGrow(document.getElementById('a-text')) }
    // les confettis à l'arrivée sur l'écran de fin, pas à chaque mise à jour
    else if (session && state && state.room.status === 'finished') { if (newScreen) confetti() }
    else if (session && state && state.room.status === 'writing') fillBac();
    fitDock();
  }
  updateCountdown();
  dealPending = false;
}

// La barre d'action est fixe : elle recouvre la fin du contenu si la page ne
// réserve pas sa hauteur. Un écran à deux boutons est bien plus haut qu'un
// écran à un seul, et la police réglée par le système change encore la donne :
// on mesure au lieu de deviner.
function fitDock(){
  const dock = app.querySelector('.dock');
  document.documentElement.style.setProperty('--dock-h', (dock ? dock.offsetHeight : 0) + 'px');
}
// La rotation et la barre d'URL de Safari changent la hauteur du bouton
// (retour à la ligne du libellé) : la réserve doit suivre.
addEventListener('resize', fitDock);

function home(){
  const code = (new URLSearchParams(location.search).get('code') || '').replace(/\D/g,'').slice(0,4);
  let nm = ''; try { nm = localStorage.getItem('pdcat-name') || '' } catch {}
  const join = !!code;            // arrivé par un lien d'invitation : on ouvre le bon onglet
  return `
    <div class="home">
      <div class="home-top">
        <button class="iconbtn solo" data-act="admin" aria-label="Admin" title="Admin">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l7 3v5c0 4.2-2.8 7.6-7 9-4.2-1.4-7-4.8-7-9V6z"/><path d="M9.5 12l1.8 1.8 3.5-3.6"/></svg>
        </button>
      </div>

      <h1><img src="logo.svg" width="801" height="303" alt="Le Soulièteur" decoding="async" fetchpriority="high"><span class="shift" aria-hidden="true"></span></h1>

      <div class="tabs" role="tablist">
        <button class="tab ${join ? '' : 'on'}" data-act="tab" data-tab="create" role="tab" aria-selected="${!join}">Créer</button>
        <button class="tab ${join ? 'on' : ''}" data-act="tab" data-tab="join" role="tab" aria-selected="${join}">Rejoindre</button>
      </div>

      <section class="panel pane" id="pane-create" ${join ? 'hidden' : ''}>
        <label class="inline"><span>Pseudo :</span><input id="c-name" maxlength="20" autocomplete="nickname" value="${esc(nm)}"></label>
        <div class="field">
          <div class="seg s2 games" role="group" aria-label="Jeu">
            ${Object.entries(GAMES).map(([k,g]) => `<button type="button" class="seg-b ${k === 'phrases' ? 'on' : ''}" data-act="mode" data-v="${k}" aria-pressed="${k === 'phrases'}"><img src="games/${k === 'white' ? 'white-home.jpg' : k === 'mimes' ? 'mimes.jpg' : k + '.webp'}" width="720" height="720" alt="${g.name}" decoding="async"></button>`).join('')}
          </div>
          <input type="hidden" id="c-mode" value="phrases">
        </div>
        <!-- le réglage propre à chaque jeu se fait dans le salon : l'accueil tient sur un écran -->
        <input type="hidden" id="c-turns" value="2">
        <input type="hidden" id="c-target" value="5">
        <button class="btn" data-act="create">Créer la partie</button>
      </section>

      <section class="panel pane" id="pane-join" ${join ? '' : 'hidden'}>
        <label class="inline"><span>Pseudo :</span><input id="j-name" maxlength="20" autocomplete="nickname" value="${esc(nm)}"></label>
        <label><span>Code de la partie</span><input id="j-code" type="text" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="one-time-code" spellcheck="false" placeholder="••••" value="${esc(code)}"></label>
        <button class="btn" data-act="join">Rejoindre la partie</button>
      </section>
    </div>`;
}

// Une barre pour le jeu, puis les catalogues de ce jeu.
function adminView(){
  const plus = adminLevel === 'plus';
  const k = adminTab, q = k === 'q', w = k === 'w' || k === 'm', jeu = jeuDe(k), sous = CATALOGUES[jeu];
  const body = adminLevel
    ? `<div class="tabs jeux" role="tablist" aria-label="Jeu">
         ${Object.keys(CATALOGUES).map(g =>
           `<button class="tab ${jeu === g ? 'on' : ''}" data-act="admin-game" data-game="${g}" role="tab" aria-selected="${jeu === g}">${GAMES[g].name}</button>`).join('')}
       </div>
       <div class="soustabs" role="tablist" aria-label="Catalogue">
         ${sous.map(([x,t]) =>
           `<button type="button" class="soustab ${k === x ? 'on' : ''}" data-act="admin-tab" data-tab="${x}" role="tab" aria-selected="${k === x}">${t}</button>`).join('')}
       </div>
       <section class="panel">
         ${w
           ? `              <label><span>${k === 'm' ? 'Mot des Civils' : 'Extrême gauche'}</span><input id="a-left" maxlength="60" autocomplete="off" enterkeyhint="next"></label>
              <label><span>${k === 'm' ? 'Mot Undercover' : 'Extrême droite'}</span><input id="a-right" maxlength="60" autocomplete="off" enterkeyhint="done"></label>`
           : `<label><textarea id="a-text" rows="1" maxlength="${q ? 150 : 80}" aria-label="Texte de la ${MOT[k]}"></textarea></label>`}
         ${q ? `<div class="holebar">
           <button class="btn ghost small" data-act="hole-add">+ Ajouter un trou</button>
           <span class="meta" id="hole-count">0 trou sur 2</span>
         </div>` : ''}
         <button class="btn" data-act="admin-add">Ajouter au catalogue</button>
       </section>
       ${plus ? `
         <h3 class="sec" id="cat-count">Catalogue</h3>
         <input class="searchfield" id="cat-q" placeholder="Rechercher ${k === 'm' ? 'une paire de mots' : w ? 'un extrême' : `une ${MOT[k]}`}" autocomplete="off" value="${esc(catalog.q)}">
         <ul class="catlist" id="cat-list"></ul>
         <div id="cat-more"></div>` : ''}`
    : `<section class="panel">
         <p class="eyebrow">Accès réservé</p>
         <label><span>Code</span><input id="a-pwd" type="password" autocomplete="off" placeholder="••••••••"></label>
         <button class="btn" data-act="admin-login">Entrer</button>
       </section>`;
  return `
    <div class="top">
      <div class="top-l"><span class="round">${plus ? 'Admin +' : 'Admin'}</span></div>
      <button class="link" data-act="admin-close">Retour</button>
    </div>
    ${body}`;
}

// La zone grandit avec son contenu plutôt que de faire défiler le texte vers la
// droite. offsetHeight - clientHeight rend les bordures, que scrollHeight ne
// compte pas alors que box-sizing:border-box les inclut dans la hauteur.
function autoGrow(el){
  if (!el) return;
  el.style.height = 'auto';
  el.style.height = (el.scrollHeight + el.offsetHeight - el.clientHeight) + 'px';
}

// On compte les suites de deux tirets bas et plus : c'est ce que le serveur
// normalise ensuite en « ____ ».
const compteTrous = t => (String(t || '').match(/_{2,}/g) || []).length;

function majTrous(){
  const champ = document.getElementById('a-text'), etiq = document.getElementById('hole-count');
  if (!champ || !etiq) return;
  const n = compteTrous(champ.value);
  etiq.textContent = `${n} trou${n > 1 ? 's' : ''} sur 2`;
  const b = document.querySelector('[data-act="hole-add"]');
  if (b) b.disabled = n >= 2;
}

function paintCatalog(){
  const list = document.getElementById('cat-list');
  if (!list) return;
  const q = catalog.kind === 'q';
  const mot = MOT[catalog.kind];
  const count = document.getElementById('cat-count');
  if (count) count.textContent = `Catalogue · ${catalog.total} ${mot}${catalog.total > 1 ? 's' : ''}`;
  list.innerHTML = catalog.items.length
    ? catalog.items.map(c => `<li>
        ${q ? (c.blanks > 1 ? '<span class="form two" aria-label="Deux trous">2 trous</span>' : '')
            : catalog.kind === 'p' ? `<span class="form theme">${esc(c.theme)}</span>`
            : catalog.kind === 'w' || catalog.kind === 'm' ? ''
            : `<button class="form ${c.form === 'v' ? 'v' : 'n'}" data-act="admin-form" data-id="${c.id}" data-form="${esc(c.form)}"
          aria-label="${c.form === 'v' ? 'Verbe à l’infinitif' : 'Groupe nominal'}">${c.form === 'v' ? 'V' : 'N'}</button>`}
        <span class="ct">${catalog.kind === 'w' || catalog.kind === 'm'
          ? `${esc(c.left)} <span class="sep" aria-hidden="true">↔</span> ${esc(c.right)}`
          : esc(c.text)}</span>
        <button class="del" data-act="admin-del" data-id="${c.id}" aria-label="Supprimer">✕</button>
      </li>`).join('')
    : `<li class="empty">Aucune ${mot}.</li>`;
  const more = document.getElementById('cat-more');
  if (more) more.innerHTML = catalog.items.length < catalog.total
    ? `<button class="btn ghost" data-act="admin-more">Afficher plus (${catalog.total - catalog.items.length})</button>`
    : '';
}

function adminSwitch(k){
  if (!k || k === adminTab) return;
  adminTab = k;
  catalog = { kind:k, total:0, items:[], q:'' };
  render();
  if (adminLevel === 'plus') loadCatalog(0);
}

async function loadCatalog(offset = 0){
  if (adminLevel !== 'plus') return;
  try {
    const d = catalog.kind === 'm'
      ? await rpc('admin_list_white_words', { p_password:adminPwd, p_search:catalog.q, p_offset:offset })
      : await rpc('admin_list_cards', { p_password:adminPwd, p_kind:catalog.kind, p_search:catalog.q, p_offset:offset });
    catalog.total = d.total;
    catalog.items = offset ? catalog.items.concat(d.items) : d.items;
    paintCatalog();
  } catch (e) { toast(e.message) }
}

// Le point devant le code dit l'état du réseau : vert en direct, doré quand
// le temps réel est coupé (relecture toutes les 4 s), rose hors connexion.
function netBadge(code){
  const [cls, msg] = !navigator.onLine ? [' down', 'Hors connexion'] : rtOk || !rtSeen ? ['', 'Connecté'] : [' slow', 'Connexion lente, reconnexion…'];
  return `<span class="code${cls}" title="${msg}" role="status" aria-label="Partie ${esc(code)} · ${msg}">${esc(code)}</span>`;
}
addEventListener('offline', () => { toast('Connexion perdue. On reprend dès qu’elle revient.'); render() });
addEventListener('online', () => { render(); if (session) refresh(true) });

function topbar(){
  const r = state.room;
  // Salon : la vignette du jeu à gauche, le code au milieu, la croix à droite.
  if (r.status === 'lobby') return `<div class="top lobbytop">
      <img class="gamelogo" src="games/${gameImg(r.mode)}" width="720" height="720" alt="${(GAMES[r.mode] || GAMES.phrases).name}">
      <div class="codeblock"><p class="eyebrow">Code de la partie</p>
        <div class="bigcode">${[...r.code].map(c => `<span class="ch">${esc(c)}</span>`).join('')}</div>
        <button type="button" class="share" data-act="share"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15V3M7 8l5-5 5 5"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/></svg>Inviter</button></div>
      <button class="xbtn" data-act="leave" aria-label="Quitter la partie" title="Quitter"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
    </div>`;
  return `<div class="top">
      <div class="top-l">${netBadge(r.code)}${r.round ? `<span class="round">Manche ${r.round}${isCounted() ? ' / ' + (r.round + roundsLeft()) : ''}</span>` : ''}</div>
      <div class="top-r">
        <span class="cdring" id="cd" hidden aria-hidden="true"><svg viewBox="0 0 36 36"><circle class="trk" cx="18" cy="18" r="16"></circle><circle class="arc" cx="18" cy="18" r="16" pathLength="100" stroke-dasharray="100" stroke-dashoffset="0"></circle></svg><b class="cdn"></b></span>
        <button class="xbtn" data-act="leave" aria-label="Quitter la partie" title="Quitter"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      </div>
    </div>`;
}

function lobby(){
  const r = state.room, host = isMe(r.host_id), n = state.players.length, min = minPlayers(r.mode), max = maxPlayers(r.mode);
  const all = state.players.every(p => p.ready), missing = Math.max(0, min - n);
  // partie lancée avec punitions : chacun propose les siennes avant le jeu
  if (pun?.phase) return punWrite();
  return `
    ${gameBox(host)}
    <h2 class="sec">Joueurs · ${n}/${max}</h2>
    <ul class="plist">
      ${[...state.players].sort((a, b) => (b.id === r.host_id) - (a.id === r.host_id)).map(p => `<li class="${p.ready ? 'is-ready' : ''}">
        ${p.ready ? '<span class="ok" aria-hidden="true">✓</span>' : ''}<span class="nm">${esc(p.name)}</span>${
        p.id === r.host_id ? '<span class="tag host">hôte</span>' : p.is_bot ? '<span class="tag">bot</span>' : ''}${
        isMe(p.id) ? '<span class="tag">toi</span>' : ''}<span class="sr">${p.ready ? ', prêt' : ', pas encore prêt'}</span>${
        host && !isMe(p.id) ? `<button class="kick" data-act="kick" data-id="${p.id}" aria-label="Retirer ${esc(p.name)}">✕</button>` : ''}
      </li>`).join('')}
    </ul>
    ${host && n < max ? `<button class="btn ghost small" data-act="bot" ${dis()}>+ Ajouter un bot</button>` : ''}
    <div class="dock">
      ${host ? '' : `<p class="dockhint">${lobbyHint()}</p>`}
      <button class="btn ${state.me.ready ? 'on' : 'alt'}" data-act="ready">${state.me.ready ? 'Je suis prêt ✓' : 'Je suis prêt'}</button>
      ${host ? `<button class="btn" data-act="start" ${dis(n < min || !all)}>${n < min ? `Il manque ${missing} joueur${missing > 1 ? 's' : ''}` : !all ? 'En attente des joueurs' : 'Lancer la partie'}</button>` : ''}
    </div>`;
}

// Les invités n'ont pas le bouton de lancement : on leur dit ce qui se passe.
function lobbyHint(){
  const r = state.room, n = state.players.length, min = minPlayers(r.mode), hote = nameOf(r.host_id);
  if (n < min) { const k = min - n; return `Il manque ${k} joueur${k > 1 ? 's' : ''} pour jouer.` }
  if (!state.me.ready) return `Indique que tu es prêt, <b>${hote}</b> lancera la partie.`;
  const attente = state.players.filter(p => !p.ready).length;
  return attente ? `On attend ${attente} joueur${attente > 1 ? 's' : ''}, puis <b>${hote}</b> lancera la partie.`
    : `Tout le monde est prêt, <b>${hote}</b> va lancer la partie.`;
}

// Réglages du salon : − et + changent la valeur à l'écran tout de suite,
// l'envoi au serveur part quand l'hôte arrête de taper.
const optKey = () => ['priorites','ondes','mimes'].includes(state.room.mode) ? 'turns' : 'target';
const OPT_BORNES = { ...BORNES, pun:[0, 5] };
let optDraft = {}, optTimer = null;
function optValue(k){
  if (k in optDraft) return optDraft[k];
  if (k === 'pun') return pun?.on ? +pun.count : 0;
  return k === 'target' && state.room.mode === 'bac' ? bacRounds() : +state.room[k];
}
const PUN_NB = 2;
function punCheck(){
  const v = optValue('pun') > 0;
  const parts = Array.from({ length: 8 }, (_, i) =>
    `${SEAT_COLORS[i % SEAT_COLORS.length]} ${i * 45}deg ${(i + 1) * 45}deg`).join(',');
  return `<div class="field"><button type="button" class="punsw${v ? ' on' : ''}" data-act="pun-toggle"
      role="switch" aria-checked="${v}" aria-label="Punitions"><span class="mini" style="background:conic-gradient(${parts})"></span></button></div>`;
}
function stepper(k, label){
  const [lo, hi] = OPT_BORNES[k], v = optValue(k);
  return `<div class="field"><span>${label}</span><div class="step" role="group" aria-label="${label}">
      <button type="button" data-act="step" data-k="${k}" data-d="-1" aria-label="Moins" ${v <= lo ? 'disabled' : ''}>−</button>
      <b aria-live="polite">${v}</b>
      <button type="button" data-act="step" data-k="${k}" data-d="1" aria-label="Plus" ${v >= hi ? 'disabled' : ''}>+</button>
    </div></div>`;
}
async function sendOpts(){
  if (busy) { optTimer = setTimeout(() => { optTimer = null; sendOpts() }, 300); return }
  const d = optDraft, k = optKey();
  const serveur = c => { const keep = optDraft; optDraft = {}; const v = optValue(c); optDraft = keep; return v };
  if ('pun' in d && d.pun !== serveur('pun'))
    await act('punish_options', d.pun ? { p_on: true, p_count: d.pun } : { p_on: false, p_count: null });
  if (k in d && d[k] !== serveur(k)) {
    const r = state.room, o = { target:+r.target, turns:+r.turns, [k]:d[k] };
    await act('set_room_options', { p_mode:r.mode, p_target:o.target, p_turns:o.turns });
  }
  // un tapotement pendant l'envoi a remplacé le brouillon : on le garde pour le prochain envoi
  if (d === optDraft) { optDraft = {}; render() }
}

// Le jeu est choisi à la création : le salon affiche le jeu, sa règle repliée
// derrière le « i », et l'hôte n'y règle que la durée de la partie.
let rulesOpen = false, gamePick = false, rulesMode = '';
// La règle s'ouvre d'elle-même la première fois qu'on voit un jeu sur ce téléphone.
function rulesFirstTime(mode){
  if (mode === rulesMode) return;
  rulesMode = mode;
  let vus = [];
  try { vus = JSON.parse(localStorage.getItem('pdcat-rules') || '[]') } catch {}
  rulesOpen = !vus.includes(mode);
  if (rulesOpen) try { localStorage.setItem('pdcat-rules', JSON.stringify([...vus, mode])) } catch {}
}
const TIME_MODES = [
  ['unlimited','Illimité','Aucun compte à rebours.'],
  ['slow','Lent','Pour prendre le temps de réfléchir.'],
  ['medium','Moyen','Un rythme équilibré.'],
  ['fast','Rapide','Des décisions plus instinctives.']
];
function timeField(host){
  const cur = state.room.time_mode || (['bac','white','mimes'].includes(state.room.mode) ? 'unlimited' : 'medium');
  const selected = TIME_MODES.find(x => x[0] === cur) || TIME_MODES[2];
  const buttons = host
    ? '<div class="seg time-modes" role="group" aria-label="Temps">'
      + TIME_MODES.map(([key,label]) => '<button type="button" class="seg-b '
        + (key === cur ? 'on' : '') + '" data-act="time-mode" data-v="' + key
        + '" aria-pressed="' + (key === cur) + '" ' + dis() + '>' + label + '</button>').join('')
      + '</div>'
    : '<p class="gdesc">Mode choisi : <b>' + selected[1] + '</b></p>';
  return '<div class="timefield"><div class="timehead">Temps</div>'
    + buttons + '<p class="gdesc">' + selected[2]
    + ' La durée s’adapte au mini-jeu.</p></div>';
}
function gameBox(host){
  const r = state.room, g = GAMES[r.mode] || GAMES.phrases;
  rulesFirstTime(r.mode);
  // Le nombre se règle avec − et + : manches à gagner, à jouer, ou tours par joueur.
  const k = optKey(), label = (r.mode === 'bac' || r.mode === 'white') ? 'Manches à jouer'
    : k === 'turns' ? `Tours de ${r.mode === 'ondes' ? 'médium' : 'juge'}` : 'Manches à gagner';
  const opts = host ? stepper(k, label) : '';
  // Punitions : une roue à activer, toujours 2 par joueur quand elles sont activées
  const on = !!pun?.on, nb = +(pun?.count || PUN_NB);
  const punOpt = !pun ? ''
    : host ? punCheck()
    : on ? `<p class="gdesc">🎡 Punitions : ${nb} par joueur, à proposer au lancement. Le dernier en tire une à la roue.</p>` : '';
  return `<section class="panel gamebox">
      <div class="gtitle"><h3 class="gname">${g.name}</h3><button type="button" class="info${rulesOpen ? ' on' : ''}" data-act="rules"
        aria-expanded="${rulesOpen}" aria-label="Règles du jeu">i</button>${host ? `<button type="button" class="chg" data-act="game-pick"
        aria-expanded="${gamePick}">${gamePick ? 'Fermer' : 'Changer de jeu'}</button>` : ''}</div>
      ${host && gamePick ? gamePicker() : ''}
      ${rulesOpen ? `<p class="gdesc">${g.desc}</p>${r.mode === 'ondes' ? `<p class="gdesc">${WAVE_INVERSE_DESC}</p>` : ''}` : ''}
      ${r.mode === 'ondes' ? waveVariant(host) : ''}
      ${host ? `<div class="opts${pun ? ' pun' : ' solo'}">${opts}${punOpt}</div>` : opts + punOpt}
      ${timeField(host)}
    </section>`;
}

// L'hôte change de jeu depuis le salon : le groupe reste dans la même salle.
// Un jeu trop petit pour le salon (Petit bac : 2 joueurs) est grisé.
function gamePicker(){
  const n = state.players.filter(p => p.active !== false).length, cur = state.room.mode;
  return `<div class="seg games pick" role="group" aria-label="Choisir le jeu">${Object.entries(GAMES).map(([k, g]) => {
    const trop = n > maxPlayers(k);
    return `<button type="button" class="seg-b ${k === cur ? 'on' : ''}" data-act="set-game" data-v="${k}" aria-pressed="${k === cur}"
      ${trop || busy ? 'disabled' : ''} title="${trop ? `${g.name} : ${maxPlayers(k)} joueurs maximum` : g.name}">
      <img src="games/${tileImg(k)}" width="720" height="720" alt="${g.name}${trop ? ` (${maxPlayers(k)} joueurs maximum)` : ''}" decoding="async">${trop ? `<small class="max" aria-hidden="true">${maxPlayers(k)} joueurs max</small>` : ''}</button>`;
  }).join('')}</div>`;
}

// Baromètre : Normal ou Inversé, au choix de l'hôte.
function waveVariant(host){
  const v = state.room.wave_variant === 'inverse' ? 'inverse' : 'normal';
  if (!host) return `<p class="gdesc">Mode : <b>${v === 'inverse' ? 'Inversé' : 'Normal'}</b></p>`;
  return `<div class="seg s2 variant" role="group" aria-label="Mode du Baromètre">${[['normal','Normal'],['inverse','Inversé']].map(([k, l]) =>
    `<button type="button" class="seg-b ${v === k ? 'on' : ''}" data-act="wave-variant" data-v="${k}" aria-pressed="${v === k}" ${dis()}>${l}</button>`).join('')}</div>`;
}

// Écran d'après « Lancer la partie » : chacun propose ses punitions, secrètes
// jusqu'à la fin. Le jeu démarre tout seul quand tout le monde a validé.
// Proposer est facultatif : valider sans rien écrire compte comme « validé ».
function punWrite(){
  const mine = pun?.mine || [], nb = +(pun?.count || 1), sent = pun?.sent || [];
  const attente = state.players.filter(p => !p.is_bot && !sent.includes(p.id));
  if (sent.some(isMe)) return `
    <h2 class="bigstate">C’est envoyé.</h2>
    <p class="role">Le jeu démarre dès que tout le monde a validé.</p>
    ${mine.length ? `<h3 class="sec">Tes punitions</h3>
    <ul class="punlist">${mine.map(x => `<li><span>${esc(x.text)}</span></li>`).join('')}</ul>` : ''}
    ${waiting(attente, 'C’est parti…')}`;
  return `
    <h2 class="bigstate">${nb > 1 ? `Propose jusqu’à ${nb} punitions` : 'Propose une punition'}</h2>
    <p class="role">Personne ne les voit avant la fin. Le dernier tourne la roue et en tire une.</p>
    ${Array.from({ length: nb }, (_, i) => `<label class="punfield"><span>Punition ${i + 1} (facultative)</span>
      <input id="pun-${i}" data-i="${i}" maxlength="100" autocomplete="off" autocapitalize="sentences"
        enterkeyhint="${i < nb - 1 ? 'next' : 'done'}" value="${esc(punDrafts[i] || '')}"></label>`).join('')}
    <div class="dock"><button class="btn" data-act="punish-submit" ${dis()}>Valider</button></div>`;
}

// Fin de partie : la roue des punitions, lancée par le dernier du classement.
function punSection(){
  const items = pun?.items || [];
  if (!pun?.on || !items.length) return '';
  const loser = P(pun.loser_id), pick = pun.pick;
  // un bot ou un absent ne peut pas tourner : n'importe qui le fait à sa place
  const peut = !pick && (isMe(pun.loser_id) || !loser || loser.is_bot);
  const n = items.length, a = 360 / n, k = pick ? Math.max(0, items.findIndex(x => x.id === pick.id)) : 0;
  const parts = items.map((_, i) => `${SEAT_COLORS[i % SEAT_COLORS.length]} ${(i * a).toFixed(1)}deg ${((i + 1) * a).toFixed(1)}deg`).join(',');
  const ecoule = punAnimAt ? Date.now() - punAnimAt : Infinity, anim = !!pick && ecoule < PUN_MS;
  const spin = pick ? 1440 + 360 - (k + .5) * a : 0;
  // re-rendue en pleine rotation, la roue reprend là où elle en était
  const disque = `<div class="roue pun ${anim ? '' : 'still'}" style="--spin:${spin.toFixed(1)}deg;${anim ? `animation-delay:-${ecoule}ms;` : ''}background:conic-gradient(${parts})" aria-hidden="true">${
    items.map((_, i) => `<span class="lab" style="--a:${((i + .5) * a).toFixed(1)}deg"><i>${pick && !anim && i === k ? '★' : '?'}</i></span>`).join('')}</div>`;
  const qui = loser ? (isMe(loser.id) ? 'Toi' : esc(loser.name)) : '?';
  const autres = pick ? items.filter(x => x.id !== pick.id) : [];
  return `<section class="punbox">
      <h3 class="sec">Punition</h3>
      <p class="role">${pick ? '' : isMe(pun.loser_id) ? '<b>Tu finis dernier·e.</b> À toi de tourner la roue !' : `<b>${qui}</b> finit dernier·e et doit tourner la roue.`}</p>
      <div class="roueBox"><span class="pointer" aria-hidden="true"></span>${disque}</div>
      ${peut ? `<button class="btn" data-act="punish-spin" ${dis()}>Tourner la roue</button>` : ''}
      ${pick ? `<div class="${anim || !punAnimAt ? 'punres' : ''}" style="animation-delay:${anim ? PUN_MS - ecoule : 0}ms">
          ${qcard(`Punition pour ${qui}`, esc(pick.text), 'win', `<span class="by">proposée par ${esc(pick.author)}</span>`)}
          ${autres.length ? `<h3 class="sec">Les autres punitions</h3><ul class="punlist">${autres.map(x => `<li><span>${esc(x.text)}</span></li>`).join('')}</ul>` : ''}
        </div>` : ''}
    </section>`;
}

function waitScreen(title, sub, stack = 1){
  const backs = stack > 1
    ? `<div class="cardstack"><span class="cardback b2"></span><span class="cardback b3"></span><span class="cardback"></span></div>`
    : '<span class="cardback"></span>';
  return `<div class="waitScreen">${backs}
    <h2 class="bigstate">${title}</h2>
    <p class="muted"><span class="pulse"></span>${sub}</p></div>`;
}

// 12 teintes distinctes, une par siège : au-delà de 6 joueurs, deux aiguilles
// reprenaient la même couleur et la légende devenait ambiguë.
const SEAT_COLORS = ['#FFC23D','#FF6B98','#3FDC9C','#A88CFF','#FF9440','#4CC3F5',
                     '#C5DD45','#E784DA','#7FD858','#8AA2FF','#FF7C64','#2FD0C0'];

function qselect(){
  const r = state.room;
  const reader = P(r.reader_id);
  if (!isMe(reader?.id)) return waitScreen(`${nameOf(reader?.id)} est le lecteur`, 'Il choisit une carte parmi 5…');
  const chosen = state.question_choices.find(q => q.id === qpick);
  return `
    <p class="role"><b>Tu es le lecteur.</b></p>
    <ul class="qchoices">
      ${state.question_choices.map(q => {
        const off = chosen && q.id !== qpick;
        return `<li><button class="qchoice ${chosen ? (off ? 'off' : 'on') : ''}" data-act="question" data-id="${q.id}" ${off ? 'disabled' : ''}>${blank(q.text)}</button></li>`;
      }).join('')}
    </ul>
    ${chosen ? `<div class="dock">
      <button class="btn" data-act="question-go" ${dis()}>J'ai lu la phrase</button>
      <button class="btn ghost" data-act="question-back" ${dis()}>Choisir une autre carte</button>
    </div>` : ''}`;
}

function answering(){
  const r = state.room, q = state.question || '';
  const others = state.players.filter(p => p.id !== r.reader_id);
  const left = others.filter(p => !p.submitted), done = others.length - left.length;
  const bar = `<div class="bar"><i style="width:${others.length ? Math.round(done / others.length * 100) : 0}%"></i></div>`;

  if (isMe(r.reader_id)) return `
    <p class="role"><b>Tu es le lecteur.</b></p>
    ${qcard('Question', blank(q))}
    <p class="meta" style="margin-top:18px">${done}/${others.length} ont joué</p>${bar}
    ${waiting(left)}`;

  const cartes = state.my_cards || [];
  if (cartes.length) return `
    <p class="role"><b>${cartes.length > 1 ? 'Cartes envoyées.' : 'Carte envoyée.'}</b></p>
    ${qcard(cartes.length > 1 ? 'Tes réponses' : 'Ta réponse', fill(q, cartes))}
    <p class="meta" style="margin-top:18px">${done}/${others.length} ont joué</p>${bar}
    ${waiting(left)}`;

  const n = state.blanks || 1;
  const choisies = picks.map(id => state.hand.find(c => c.id === id)).filter(Boolean);
  const canDrop = !!state.me.can_discard;
  const reste = n - choisies.length;
  return `
    <p class="role"><b>${nameOf(r.reader_id)}</b> est le lecteur.</p>
    ${qcard('Question', fill(q, choisies), 'sticky')}
    <p class="swipehint">${n > 1
      ? `Touche <b>${n}</b> cartes dans l'ordre des trous${canDrop ? ', glisse <b>←</b> pour jeter' : ''}`
      : `Touche ou glisse <b>→</b> pour jouer${canDrop ? ', <b>←</b> pour jeter' : ''}`}</p>
    <ul class="hand${dealPending ? ' deal-in' : ''}">
      ${state.hand.map((c,i) => {
        const rang = picks.indexOf(c.id) + 1;
        return `<li style="--i:${i}"><div class="swipe">
        ${n > 1 ? '' : '<span class="cue play" aria-hidden="true"><span>Jouer</span></span>'}
        ${canDrop ? '<span class="cue drop" aria-hidden="true"><span>Jeter</span></span>' : ''}
        <button class="acard ${rang ? 'sel' : ''}" data-act="select" data-id="${c.id}" aria-pressed="${!!rang}">${
          rang && n > 1 ? `<i class="rang">${rang}</i>` : ''}${esc(c.text)}</button>
      </div></li>`;
      }).join('')}
    </ul>
    ${n > 1 ? `<div class="dock">
      <button class="btn" data-act="send" ${dis(reste > 0)}>${reste > 0
        ? `Choisis ${reste} carte${reste > 1 ? 's' : ''}`
        : 'Envoyer mes deux cartes'}</button>
      ${canDrop && choisies.length === 1 ? `<button class="btn ghost" data-act="drop" ${dis()}>Jeter cette carte</button>` : ''}
    </div>`
    // Un seul trou : le balayage reste un raccourci, mais toucher une carte
    // suffit pour la jouer ou la jeter (clavier, lecteur d'écran, débutants).
    : choisies.length ? `<div class="dock">
      <button class="btn" data-act="send" ${dis()}>Jouer cette carte</button>
      ${canDrop ? `<button class="btn ghost" data-act="drop" ${dis()}>Jeter cette carte</button>` : ''}
    </div>` : ''}`;
}

function judging(){
  const r = state.room, q = state.question || '', subs = state.submissions;
  if (!isMe(r.reader_id)) return waitScreen('Le lecteur découvre les réponses',
    `${nameOf(r.reader_id)} les lit une par une…`, subs.length);
  if (readIndex < subs.length) return `
    <p class="role"><b>Tu es le lecteur.</b></p>
    ${qcard(`Réponse ${readIndex + 1} / ${subs.length}`, fill(q, subs[readIndex].cards))}
    <div class="steps" aria-hidden="true">${subs.map((s,i) => `<i class="${i <= readIndex ? 'on' : ''}"></i>`).join('')}</div>
    <div class="dock"><button class="btn" data-act="readnext">${readIndex + 1 === subs.length ? 'Voir toutes les réponses' : 'Réponse suivante'}</button></div>`;
  return `
    <p class="role"><b>Tu es le lecteur.</b></p>
    <ul class="subs">
      ${subs.map(s => `<li><button class="scard ${s.id === picked ? 'sel' : ''}" data-act="pick" data-id="${s.id}" aria-pressed="${s.id === picked}">${fill(q, s.cards)}</button></li>`).join('')}
    </ul>
    <div class="dock"><button class="btn" data-act="confirm" ${dis(!picked)}>${picked ? 'Donner le point' : 'Touche ta réponse préférée'}</button></div>`;
}

