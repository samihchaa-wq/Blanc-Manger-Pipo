// Configuration, état partagé, outils, réseau (Supabase, temps réel, relecture), bots, minuteurs, écran allumé, invitation.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
const sb = supabase.createClient('https://yqfewxadpyulgxehhpcu.supabase.co','sb_publishable_Qdso-n_uVYAH1_YzjSLYlQ_rOWg93tg');
const app = document.getElementById('app');
let session = load(), state = null, busy = false, picks = [], picked = null, readIndex = 0, rankView = null;
let last = '', channel = null, poll = null, deb = null, dealPending = false, rtOk = false, lastSync = 0;
let holding = false;   // doigt posé sur la carte secrète de Mr White
let rtSeen = false;   // le temps réel a déjà répondu au moins une fois
let reapTimer = null, tickTimer = null, renderedKey = '', botTimer = null;
let swipe = null, dragging = false, flying = false, pendingRender = false, lastSwipeEnd = 0;
let qpick = null;   // carte retenue par le lecteur, pas encore envoyée aux autres
let dialVal = 50, dialDrag = null, clueDraft = '', themeDraft = '';
let mimeNotes = {};   // Mimes : notes du juge, gardées en local jusqu'à la validation   // Baromètre : aiguille et indice en cours
// Petit bac : la grille en cours de saisie, ce qui en est déjà enregistré, et
// l'instant local où la roue des lettres a démarré.
let bacDraft = [], bacSent = '', bacRound = 0, bacTimer = null, bacChain = Promise.resolve();
let roueAt = 0, roueTimer = null, bacMyVote = null, catDraft = '';
let pressedEl = null, lastHtml = '';
// Punitions : état lu au salon et en fin de partie, saisie en cours, et
// l'instant local où l'on a vu la roue partir (pour l'animer une seule fois).
let pun = null, punDrafts = [], punAnimAt = 0, punTimer = null;
const PUN_MS = 3400;
// le code admin ne vit qu'en mémoire : jamais dans le fichier, jamais stocké
let adminOpen = false, adminPwd = '', adminLevel = '';
let adminTab = 'a';   // l'admin s'ouvre toujours sur les réponses de Phrases à trou
let adminLast = {};   // dernier catalogue ouvert dans chaque jeu
// Les catalogues de l'admin, rangés par jeu. Une carte Baromètre porte
// deux textes : l'extrême de gauche et celui de droite.
const CATALOGUES = { phrases:[['q','Questions'],['a','Réponses']], priorites:[['p','Réponses']], ondes:[['w','Extrêmes']], white:[['m','Paires de mots']] };
const jeuDe = k => Object.keys(CATALOGUES).find(g => CATALOGUES[g].some(([x]) => x === k));
const MOT = { q:'question', a:'réponse', p:'réponse', w:'carte', m:'paire' };
let catalog = { kind:'a', total:0, items:[], q:'' }, catTimer = null;

// Les jeux hébergés par l'appli. Le salon en montre la règle courte.
const GAMES = {
  phrases:   { name:'Phrases à trou',  desc:'Le lecteur pose une phrase à trou, chacun la complète avec sa carte la plus drôle.' },
  priorites: { name:'Priorités',       desc:'Un juge classe 5 cartes par importance, les autres devinent son classement.' },
  ondes:     { name:'Baromètre', desc:'Le médium donne un indice pour situer une cible cachée, les autres placent leur aiguille au plus près.' },
  bac:       { name:'Petit bac', desc:'Vous inventez les catégories, la roue tire la lettre. Trouvez des mots qui commencent par elle, puis jugez ceux de votre adversaire.' },
  white:     { name:'Mr White', desc:'Ensemble dans la même pièce : découvrez votre mot en secret, donnez des indices à voix haute puis votez. Dans une partie sur cinq en moyenne, un imposteur devient Mr White et ne reçoit aucun mot.' },
  mimes:     { name:'Mimes', desc:'Le juge lit une action à voix haute. Chacun reçoit en secret une intensité de 1 à 10 et la mime à son tour. Le juge devine l’intensité de chacun : 3 pts si c’est exact, 2 pts à 1 près, 1 pt à 2 près.' },
  dilemme:   { name:'Dilemme parfait', desc:'Le meneur pose le début d’un dilemme (« Tu gagnes un million d’euros… »), chacun écrit la suite après « mais… ». Puis tout le monde répond Oui ou Non aux dilemmes des autres. Le but : couper la table en deux. 3 pts pour un 50/50 parfait, 0 si tout le monde répond pareil.' },
  dico:      { name:'Le Dico', desc:'Le meneur ouvre le dictionnaire au hasard, choisit un mot et le lit à voix haute. Chacun en invente une définition ; elles sont mélangées avec la vraie, le meneur les lit toutes et chacun vote pour celle qu’il croit juste. +2 pts si tu trouves la vraie, +1 pt par joueur que ta définition a dupé, +2 pts au meneur si personne ne trouve.' },
};
// Baromètre inversé : un joueur écrit un thème, le médium y répond selon la cible.
const WAVE_INVERSE_DESC = 'Mode inversé : un joueur écrit un thème (« un salaire que j’aimerais toucher »), le médium voit la cible et répond (« 100 000 € »), les autres placent l’aiguille d’après sa réponse.';
// Vignettes du choix du jeu (accueil et salon) : Mr White a la sienne.
const tileImg = k => k === 'white' ? 'white-home.jpg' : k === 'mimes' ? 'mimes.jpg' : k + '.webp';
const gameImg = k => k === 'white' ? 'white.svg' : k === 'mimes' ? 'mimes.jpg' : (GAMES[k] ? k : 'phrases') + '.webp';
const isPrio = () => state?.room.mode === 'priorites';
const isWave = () => state?.room.mode === 'ondes';
const isBac = () => state?.room.mode === 'bac';
const isWhite = () => state?.room.mode === 'white';
const isMime = () => state?.room.mode === 'mimes';
const isDico = () => state?.room.mode === 'dico';
const isDilemme = () => state?.room.mode === 'dilemme';
const isInverse = () => isWave() && state?.room.wave_variant === 'inverse';
// Priorités, Baromètre et Petit bac se jouent en manches comptées, pas au score cible.
const isCounted = () => isPrio() || isWave() || isBac() || isWhite() || isMime() || isDico() || isDilemme();
// Un juge (ou un médium) et un devineur suffisent ; Phrases à trou demande au
// moins deux réponses à départager. Le Petit bac se joue à deux exactement.
// Le serveur applique les mêmes règles.
const minPlayers = mode => mode === 'priorites' || mode === 'ondes' || mode === 'bac' || mode === 'mimes' ? 2 : 3;
const maxPlayers = mode => mode === 'bac' ? 2 : 12;
// Réglages du salon, à − et + (le serveur applique les mêmes bornes) :
// manches de 1 à 20 (Phrases à trou, Petit bac), tours de 1 à 5 (Priorités, Baromètre).
const BORNES = { target:[1, 20], turns:[1, 5] };
// Manches du Petit bac, stockées dans room.target
const bacRounds = () => Math.min(20, Math.max(1, +state.room.target || 5));
// K, Q, W, X, Y et Z ne sortent pas : trop peu de mots pour six catégories.
const BAC_LETTRES = 'ABCDEFGHIJLMNOPRSTUV';
// 3,4 s de rotation, puis la lettre reste affichée un instant avant la grille.
const ROUE_MS = 4600;
const roueEnCours = () => Date.now() - roueAt < ROUE_MS;
// Icônes au trait, à la place des emojis (pouces, égal, fête, roue) et des
// caractères croix, coche, étoile, dont le rendu changeait d'un téléphone à
// l'autre (le signe égal sortait en barres grises).
const ICONS = {
  x:'<path d="M6 6l12 12M18 6L6 18"/>',
  check:'<path d="M5 12.5l4.5 4.5L19 7"/>',
  up:'<path d="M7 11v9H4v-9z"/><path d="M7 11l4-7.5c1.6 0 2.6 1.3 2.3 2.9L12.7 10h5.8a2 2 0 0 1 2 2.3l-1.1 6a2 2 0 0 1-2 1.7H7"/>',
  equal:'<path d="M5 9.5h14M5 14.5h14"/>',
  star:'<path d="M12 3.6l2.5 5.2 5.7.8-4.1 4 1 5.7L12 16.6l-5.1 2.7 1-5.7-4.1-4 5.7-.8z"/>',
  eye:'<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  prev:'<path d="M14.5 6l-6 6 6 6"/>',
  next:'<path d="M9.5 6l6 6-6 6"/>',
  voice:'<path d="M4 9.5v5h3.5l4.5 4v-13l-4.5 4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/>',
};
ICONS.down = '<g transform="rotate(180 12 12)">' + ICONS.up + '</g>';
const ic = (n, cls = '') => `<svg class="ic${cls ? ' ' + cls : ''}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[n] || ''}</svg>`;
const VOTES = [[2,'up','2 pts'],[1,'equal','Égalité'],[0,'down','0 pt']];
const voteIcon = v => { const x = VOTES.find(([p]) => p === v); return x ? ic(x[1], 'v' + v) : '' };

/* ---------- Mise à jour ---------- */
// Après une mise en ligne, un téléphone resté ouvert garde l'ancien code en
// mémoire (il affichait une partie du Dico sous le nom « Phrases à trou »).
// On compare de temps en temps le code en ligne à celui qui tourne ici, et on
// recharge dès que c'est sans risque. La comparaison porte sur le contenu des
// fichiers, pas sur leur date : GitHub Pages publie souvent deux fois le même
// code à quelques secondes d'écart, et ça ne doit pas recharger deux fois.
let majEnAttente = false, derniereVerif = 0;
const codeCharge = new Map();   // adresse -> { etag, texte } du code qui tourne ici
// La page, ses scripts et ses styles (le client Supabase, fourni tel quel, à part).
function fichiersDuCode(){
  const urls = [new URL(location.pathname, location.href).href];
  document.querySelectorAll('script[src], link[rel="stylesheet"][href]').forEach(el => {
    const u = new URL(el.getAttribute('src') || el.getAttribute('href'), location.href);
    if (u.origin === location.origin && !u.pathname.includes('/vendor/')) urls.push(u.href);
  });
  return urls;
}
// La mise en ligne ajoute ?v=… aux adresses des scripts : on n'en tient pas compte.
const sansVersion = t => t.replace(/\?v=[\w.-]+/g, '');
// Un fichier tel qu'il est en ligne, ou null s'il n'a pas changé depuis etag.
async function lireEnLigne(url, etag){
  const r = await fetch(url, { cache: 'no-store', headers: etag ? { 'If-None-Match': etag } : {} });
  if (r.status === 304) return null;
  if (!r.ok) throw new Error(r.status);
  return { etag: r.headers.get('etag'), texte: sansVersion(await r.text()) };
}
// Le code qui tourne ici : la copie gardée par le service worker au chargement,
// sinon celle du réseau.
async function lireCharge(url){
  const c = await globalThis.caches?.match(url, { ignoreSearch: true }).catch(() => null);
  return c?.ok ? { etag: c.headers.get('etag'), texte: sansVersion(await c.text()) } : lireEnLigne(url);
}
async function verifierVersion(){
  if (majEnAttente || Date.now() - derniereVerif < 30000) return;
  derniereVerif = Date.now();
  try {
    for (const url of fichiersDuCode()) {
      const connu = codeCharge.get(url);
      if (!connu) { codeCharge.set(url, await lireCharge(url)); continue }
      const enLigne = await lireEnLigne(url, connu.etag);
      if (!enLigne) continue;
      if (enLigne.texte !== connu.texte) { majEnAttente = true; return rechargerSiPossible() }
      codeCharge.set(url, enLigne);   // même code republié : seule l'empreinte change
    }
  } catch {}
}
// Jamais en pleine saisie : seulement à l'accueil, au salon, aux résultats, en fin
// de partie, ou tout de suite si ce code ne connaît pas le jeu de la partie.
function rechargerSiPossible(){
  if (!majEnAttente || adminOpen) return;
  const st = state?.room?.status, saisie = document.activeElement?.matches?.('input, textarea');
  const calme = !session || !state || (['lobby', 'reveal', 'finished'].includes(st) && !pun?.phase);
  if (state && !GAMES[state.room.mode]) return recharger();
  if (calme && !saisie) recharger();
}
// Garde-fou : jamais deux rechargements en moins de 2 minutes (le temps que la
// mise en ligne se propage partout).
function recharger(){
  try {
    if (Date.now() - (+sessionStorage.getItem('pdcat-maj') || 0) < 120000) return;
    sessionStorage.setItem('pdcat-maj', String(Date.now()));
  } catch {}
  location.reload();
}
setTimeout(verifierVersion, 4000);
setInterval(verifierVersion, 5 * 60 * 1000);

/* ---------- Outils ---------- */
function load(){ try { return JSON.parse(localStorage.getItem('pdcat')) } catch { return null } }
function save(v){ session = v; try { v ? localStorage.setItem('pdcat', JSON.stringify(v)) : localStorage.removeItem('pdcat') } catch {} }
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const val = id => (document.getElementById(id)?.value || '').trim();
const P = id => state?.players.find(p => p.id === id), isMe = id => id === state?.me.id, nameOf = id => esc(P(id)?.name || '?');
const dis = cond => (cond || busy) ? 'disabled' : '';

// 12 teintes distinctes, une par siège : au-delà de 6 joueurs, deux aiguilles
// reprenaient la même couleur et la légende devenait ambiguë.
const SEAT_COLORS = ['#FFC23D','#FF6B98','#3FDC9C','#A88CFF','#FF9440','#4CC3F5',
                     '#C5DD45','#E784DA','#7FD858','#8AA2FF','#FF7C64','#2FD0C0'];
const seatColor = id => SEAT_COLORS[Math.max(0, state.players.findIndex(p => p.id === id)) % SEAT_COLORS.length];
const chips = list => list.map(p => `<span class="chip">${esc(p.name)}</span>`).join('');
function waiting(list, done = 'Tout le monde a joué.'){
  return list.length
    ? `<div class="waiting">On attend ${chips(list)}</div>`
    : `<p class="waiting">${done}</p>`;
}
function toast(m){
  const t = document.getElementById('toast');
  t.textContent = m; t.classList.add('on');
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove('on'), 3000);
}

/* ---------- Réseau ---------- */
async function rpc(fn, args){ const { data, error } = await sb.rpc(fn, args); if (error) throw Error(error.message); return data }
async function act(fn, extra = {}){
  if (busy) return false;
  busy = true;
  // On marque le bouton touché plutôt que de reconstruire tout l'écran : le
  // retour est immédiat, et le reste de la page ne bouge pas sous le doigt.
  const el = pressedEl; pressedEl = null;
  if (el && el.isConnected) { el.disabled = true; el.classList.add('pending') }
  try { await rpc(fn, { p_code: session.code, p_token: session.token, ...extra }); ping(); await refresh(true); return true }
  catch (e) { toast(e.message); return false }
  finally { busy = false; render() }
}

// Une seule requête par relecture : get_full_state enchaîne côté serveur
// get_state, white_state et punish_state (migrations 20261104175320 et 20261104175401). Tant
// que la base ne la connaît pas, on retombe sur les trois appels d'avant.
let fullState = true;
async function readState(){
  const args = { p_code: session.code, p_token: session.token };
  if (fullState) {
    try {
      const d = await rpc('get_full_state', args);
      const s = d.state, pu = d.pun || null;
      if (d.white) s.white = d.white;
      // Le serveur a déjà relu l'état après punish_state : la saisie des
      // punitions vient de se fermer, salon = annulée, sinon la partie démarre.
      let annulee = false;
      if (pun?.phase && pu && !pu.phase && s.room.status === 'lobby') annulee = true;
      else if (pun?.phase && s.room.status !== 'lobby') ping();   // on prévient les autres
      return { s, pu, annulee };
    } catch (e) {
      // fonction absente (PGRST202 / « Could not find the function ») : ancien chemin
      if (!/get_full_state|PGRST202|Could not find the function/i.test(e.message)) throw e;
      fullState = false;
    }
  }
  return readStateLegacy(args);
}
async function readStateLegacy(args){
  let s = await rpc('get_state', args);
  if (s.room.mode === 'white' && s.room.status !== 'lobby')
    s.white = await rpc('white_state', { p_code:session.code, p_token:session.token });
  // les punitions ne servent qu'au salon et à l'écran de fin
  let pu = null;
  if (s.room.status === 'lobby' || s.room.status === 'finished')
    try { pu = await rpc('punish_state', args) } catch {}
  // La saisie des punitions s'est fermée entre les deux lectures (punish_state
  // lance la partie quand le dernier attendu est parti) : on relit l'état pour
  // savoir si la partie a démarré ou si elle est annulée.
  let annulee = false;
  if (pun?.phase && pu && !pu.phase && s.room.status === 'lobby') {
    s = await rpc('get_state', args);
    if (s.room.status === 'lobby') annulee = true;
    else { pu = null; ping() }   // c'est cette lecture qui a lancé la partie : on prévient les autres
  }
  return { s, pu, annulee };
}

async function refresh(force = false){
  if (!session) return;
  lastSync = Date.now();
  try {
    const lu = await readState(), annulee = lu.annulee;
    let s = lu.s, pu = lu.pu;
    const j = JSON.stringify([s, pu]);
    if (!force && j === last) return;
    // la roue vient d'être lancée : on l'anime ici ; arrivé après coup, on voit le résultat
    if (pu?.pick && pun && !pun.pick && s.room.status === 'finished') {
      punAnimAt = Date.now();
      clearTimeout(punTimer); punTimer = setTimeout(render, PUN_MS + 600);
    } else if (!pu?.pick) punAnimAt = 0;
    // saisie des punitions annulée faute de joueurs
    if (annulee)
      toast(`Un joueur est parti : il faut au moins ${minPlayers(s.room.mode)} joueurs, retour au salon.`);
    if (pu?.phase && !pun?.phase) punDrafts = [];
    pun = pu;
    const changed = !state || state.room.round !== s.room.round || state.room.status !== s.room.status;
    const prev = state, prevStatus = state?.room.status;
    // Retour brutal au salon en pleine partie = on est tombé sous le minimum du jeu.
    if (prevStatus && prevStatus !== 'lobby' && s.room.status === 'lobby')
      toast(`Un joueur est parti : il faut au moins ${minPlayers(s.room.mode)} joueurs, la partie est arrêtée.`);
    state = s; last = j;
    if (changed) {
      picks = []; picked = null; readIndex = 0; rankView = null; qpick = null; dialVal = 50; clueDraft = ''; mimeNotes = {}; dicoPage = null; dicoSel = null; dicoDraft = ''; dilChoix = null; dilStartDraft = ''; dilButDraft = ''; dilVotes = {}; dealPending = s.room.status === 'answering' || s.room.status === 'ranking';
    }
    if (s.room.mode === 'bac') bacSync(prev, s);
    // un jeu que ce code ne connaît pas : une version plus récente est en ligne
    if (!GAMES[s.room.mode]) verifierVersion();
    render(); scheduleAuto();
    rechargerSiPossible();
  } catch (e) {
    if (/Session expirée/.test(e.message)) { toast('Tu ne fais plus partie de cette partie.'); leaveLocal() }
  }
}
function connect(){
  disconnect();
  rtSeen = false;
  channel = sb.channel('room-' + session.code, { config:{ broadcast:{ self:false } } });
  channel.on('broadcast', { event:'bump' }, () => { clearTimeout(deb); deb = setTimeout(refresh,250) })
    .subscribe(st => {
      const ok = st === 'SUBSCRIBED';
      // (re)connecté : on prévient les autres (un joueur qui arrive au salon)
      // et on rattrape ce qui a pu se passer pendant la coupure
      const was = rtOk || !rtSeen; rtSeen = true;
      if (ok && !rtOk) { rtOk = true; ping(); if (Date.now() - lastSync > 2000) refresh() }
      rtOk = ok;
      if (ok !== was) render();   // le point de connexion change de couleur
    });
  // Chaque action envoie un « bump » aux autres : la relecture régulière n'est
  // qu'un filet de sécurité. Temps réel en place : toutes les 30 s ; coupé :
  // toutes les 4 s, pour que l'attente ne paraisse pas figée. Chaque relecture
  // est une requête journalisée qui renvoie tout l'état : à 4 s en continu,
  // le quota gratuit de Supabase (journaux, données sortantes) explosait.
  poll = setInterval(() => {
    if (!document.hidden && Date.now() - lastSync >= (rtOk ? 30000 : 4000) - 100) refresh();
  }, 4000);
  clearInterval(tickTimer); tickTimer = setInterval(updateCountdown,500);
}
function disconnect(){
  if (channel) sb.removeChannel(channel);
  channel = null; rtOk = false; clearInterval(poll); clearInterval(tickTimer);
  clearTimeout(reapTimer); clearTimeout(botTimer); clearTimeout(roueTimer); clearTimeout(bacTimer);
}
function ping(){ if (channel?.state === 'joined') channel.send({ type:'broadcast', event:'bump', payload:{} }) }
function startSession(){ state = null; last = ''; render(); connect(); refresh(true); keepAwake() }
function leaveLocal(){ disconnect(); save(null); state = null; history.replaceState(null,'',location.pathname); keepAwake(); render() }

// L'écran reste allumé tant qu'on est dans une partie : pendant les attentes
// (lecteur, mimes, Mr White) le téléphone se verrouillait, et les bots, pilotés
// par le téléphone de l'hôte, se figeaient avec lui. Le verrou tombe tout seul
// quand l'appli passe en arrière-plan : on le reprend au retour.
let wakeLock = null, wakeAsk = null;
async function keepAwake(){
  try {
    if (session && !document.hidden) {
      if (wakeLock || wakeAsk || !navigator.wakeLock) return;
      wakeAsk = navigator.wakeLock.request('screen');
      const l = await wakeAsk;
      l.addEventListener('release', () => { if (wakeLock === l) wakeLock = null });
      wakeLock = l;
      if (!session) { wakeLock = null; l.release() }   // parti pendant la demande
    } else if (wakeLock) { const l = wakeLock; wakeLock = null; await l.release() }
  } catch {}
  finally { wakeAsk = null }
}

// Le lien d'invitation ouvre directement l'onglet « Rejoindre » avec le code.
async function shareInvite(){
  const code = state?.room.code; if (!code) return;
  const url = location.origin + location.pathname + '?code=' + code;
  const game = (GAMES[state.room.mode] || GAMES.phrases).name;
  const text = `Rejoins ma partie de ${game} sur Le Soulièteur, code ${code}`;
  if (navigator.share) {
    try { await navigator.share({ title:'Le Soulièteur', text, url }); return }
    catch (e) { if (e?.name === 'AbortError') return }
  }
  try { await navigator.clipboard.writeText(url); toast('Lien copié : envoie-le aux autres joueurs.') }
  catch { prompt('Copie ce lien et envoie-le :', url) }
}
function scheduleAuto(){
  clearTimeout(roueTimer);
  // la roue des lettres finie, la grille prend sa place
  if (state?.room.status === 'writing' && roueEnCours()) roueTimer = setTimeout(render, roueAt + ROUE_MS - Date.now() + 30);
  scheduleReap();
  scheduleBots();
}

// Les bots sont pilotés par le client de l'hôte : dès qu'un bot a quelque chose
// à faire dans la phase courante, on appelle bot_step après un court délai
// (effet « il réfléchit »). Le serveur n'agit que sur les bots.
function scheduleBots(){
  clearTimeout(botTimer);
  if (!state || !session || !isMe(state.room.host_id)) return;
  const r = state.room, bots = state.players.filter(p => p.is_bot && p.active);
  if (!bots.length) return;
  let todo = false;
  if (r.status === 'question_select') todo = bots.some(b => b.id === r.reader_id);
  else if (r.status === 'answering')  todo = bots.some(b => b.id !== r.reader_id && !b.submitted);
  else if (r.status === 'judging')    todo = bots.some(b => b.id === r.reader_id);
  else if (r.status === 'ranking')    todo = bots.some(b => !b.ranked);
  else if (r.status === 'clue' && isInverse()) todo = state.wave?.theme == null ? bots.some(b => b.id === state.wave?.asker_id) : bots.some(b => b.id === r.reader_id);
  else if (r.status === 'clue')       todo = bots.some(b => b.id === r.reader_id);
  else if (r.status === 'mime_play')  todo = bots.some(b => b.id === r.reader_id);
  // Le Dico : meneur bot, bots qui n'ont pas écrit ou pas voté
  else if (r.status === 'dico_pick')  todo = bots.some(b => b.id === r.reader_id);
  else if (r.status === 'dico_write') todo = bots.some(b => b.id !== r.reader_id && !(state.dico?.written || []).includes(b.id));
  else if (r.status === 'dico_vote')  todo = bots.some(b => b.id !== r.reader_id && !(state.dico?.voted || []).includes(b.id));
  // Dilemme parfait : meneur bot, bots qui n'ont pas écrit ou pas répondu
  else if (r.status === 'dilemme_pick')  todo = bots.some(b => b.id === r.reader_id);
  else if (r.status === 'dilemme_write') todo = bots.some(b => !(state.dilemme?.written || []).includes(b.id));
  else if (r.status === 'dilemme_vote')  todo = bots.some(b => !(state.dilemme?.voted || []).includes(b.id));
  else if (r.status === 'guessing')   todo = bots.some(b => b.id !== r.reader_id && !b.guessed);
  else if (r.status === 'naming')     todo = bots.some(b => b.id === r.reader_id);
  else if (r.status === 'writing')    todo = bots.some(b => !b.bac_done);
  // une grille en attente de vote dont le juge est un bot
  else if (r.status === 'voting')     todo = (state.bac?.rows || []).some(x => x.pending && bots.some(b => b.id !== x.player_id));
  else if (r.status === 'white_clue') todo = !!state.white?.bot_pending;
  else if (r.status === 'white_vote') todo = (state.white?.roles || []).some(x => !x.out && !x.voted && bots.some(b => b.id === x.player_id));
  else if (r.status === 'white_guess') todo = !!state.white?.bot_pending;
  else if (r.status === 'reveal') todo = bots.some(b => b.next_ack !== r.round);
  else if (r.status === 'finished')   todo = bots.some(b => !b.continue_requested);
  if (!todo) return;
  botTimer = setTimeout(async () => {
    const fn = r.mode === 'white' && r.status.startsWith('white_') ? 'white_bot_step'
      : r.status === 'mime_play' ? 'mime_bot_step'
      : r.status === 'clue' && isInverse() ? 'wave_bot_step' : 'bot_step';
    try {
      // Le serveur n'a pas le dictionnaire : le téléphone de l'hôte lui en envoie une page
      if (r.mode === 'dico' && r.status.startsWith('dico_')) {
        const p = await dicoPageAuHasard();
        await rpc('dico_bot_step', { p_code:session.code, p_token:session.token,
          p_words:p.mots.map(e => e[0]), p_natures:p.mots.map(e => e[1]), p_defs:p.mots.map(e => e[2]) });
      } else if (r.mode === 'dilemme' && r.status.startsWith('dilemme_')) {
        await rpc('dilemme_bot_step', { p_code:session.code, p_token:session.token, ...dilemmeBotArgs() });
      } else await rpc(fn, { p_code:session.code, p_token:session.token });
      ping(); refresh(true);
    }
    catch {}
  }, 900);
}

// Durées et échéances reçues du serveur Supabase.
const stamp = t => Date.parse(String(t || '').replace(' ','T')) || 0;
const phaseLength = () => Math.max(0, Number(state?.room?.phase_seconds) || 0) * 1000;
const phaseDeadline = () => stamp(state?.room?.phase_deadline);
const advisoryPhase = () => state?.room?.status === 'white_clue' || state?.room?.status === 'mime_play';
function scheduleReap(){
  clearTimeout(reapTimer);
  const dl = phaseDeadline();
  if (!dl || !session || advisoryPhase()) return;
  reapTimer = setTimeout(async () => {
    if (!session || !state) return;
    try { await rpc('reap_idle', { p_code:session.code, p_token:session.token }); ping(); await refresh(true) }
    catch {}
  }, Math.max(0, dl - Date.now()) + 500);
}
function updateCountdown(){
  const el = document.getElementById('cd');
  if (!el) return;
  const dl = phaseDeadline(), len = phaseLength();
  if (!dl || !len) { el.hidden = true; return }
  el.hidden = false;
  const ms = Math.max(0, dl - Date.now());
  el.querySelector('.arc').style.strokeDashoffset = (100 * (1 - Math.min(ms, len) / len)).toFixed(2);
  el.classList.toggle('low', ms > 0 && ms <= 15000);
  const sec = Math.ceil(ms / 1000);
  el.classList.toggle('long', sec >= 60);
  el.querySelector('.cdn').textContent = sec >= 60
    ? Math.floor(sec / 60) + ':' + String(sec % 60).padStart(2,'0')
    : String(sec);
}

