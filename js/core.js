// Configuration, état partagé, outils, réseau (Supabase, temps réel, relecture), bots, minuteurs, écran allumé, invitation.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
const sb = supabase.createClient('https://yqfewxadpyulgxehhpcu.supabase.co','sb_publishable_Qdso-n_uVYAH1_YzjSLYlQ_rOWg93tg');
const app = document.getElementById('app');
let session = load(), state = null, busy = false, picks = [], picked = null, readIndex = 0, rankView = null;
let last = '', channel = null, poll = null, deb = null, dealPending = false, rtOk = false, lastSync = 0;
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
const isInverse = () => isWave() && state?.room.wave_variant === 'inverse';
// Priorités, Baromètre et Petit bac se jouent en manches comptées, pas au score cible.
const isCounted = () => isPrio() || isWave() || isBac() || isWhite() || isMime();
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
const VOTES = [[2,'👍','2 pts'],[1,'🟰','Égalité'],[0,'👎','0 pt']];
const emoji = v => (VOTES.find(([p]) => p === v) || [])[1] || '';

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
// Pastille d'un joueur : sa couleur de siège et son initiale (décorative, le
// nom est toujours écrit à côté).
function avatar(id, size = ''){
  const n = String(P(id)?.name || '?').trim();
  const ini = esc((Array.from(n)[0] || '?').toLocaleUpperCase('fr'));
  return `<span class="av${size ? ' ' + size : ''}" style="--c:${seatColor(id)}" aria-hidden="true">${ini}</span>`;
}
const chips = list => list.map(p => `<span class="chip">${avatar(p.id, 'sm')}${esc(p.name)}</span>`).join('');
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
// get_state, white_state et punish_state (migration 20261107120000). Tant
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
      picks = []; picked = null; readIndex = 0; rankView = null; qpick = null; dialVal = 50; clueDraft = ''; mimeNotes = {}; dealPending = s.room.status === 'answering' || s.room.status === 'ranking';
    }
    if (s.room.mode === 'bac') bacSync(prev, s);
    render(); scheduleAuto();
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
    try { await rpc(fn, { p_code:session.code, p_token:session.token }); ping(); refresh(true) }
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
  el.querySelector('.cdn').textContent = sec >= 60
    ? Math.floor(sec / 60) + ':' + String(sec % 60).padStart(2,'0')
    : String(sec);
}

