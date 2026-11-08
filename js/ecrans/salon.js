// Salon : le jeu choisi (accroche, règle, mode, réglages repliés), les joueurs
// et le lancement. Plus d'étape « Je suis prêt » : l'hôte lance quand il veut,
// le serveur ne vérifie que le nombre de joueurs.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

const joueurs = k => minPlayers(k) === maxPlayers(k) ? `${minPlayers(k)} joueurs` : `${minPlayers(k)} à ${maxPlayers(k)} joueurs`;

function lobby(){
  const r = state.room, host = isMe(r.host_id), n = state.players.length, min = minPlayers(r.mode), max = maxPlayers(r.mode);
  const manque = Math.max(0, min - n);
  // partie lancée avec punitions : chacun propose les siennes avant le jeu
  if (pun?.phase) return punWrite();
  return `
    ${gameBox(host)}
    <h2 class="sec">Joueurs · ${n}/${max}</h2>
    <ul class="plist">
      ${[...state.players].sort((a, b) => (b.id === r.host_id) - (a.id === r.host_id)).map(p => `<li>
        <span class="nm">${esc(p.name)}</span>${p.id === r.host_id ? '<span class="tag">hôte</span>' : p.is_bot ? '<span class="tag">bot</span>' : ''}${
        host && !isMe(p.id) ? `<button class="kick" data-act="kick" data-id="${p.id}" aria-label="Retirer ${esc(p.name)}">${ic('x')}</button>` : ''}
      </li>`).join('')}
    </ul>
    ${host && n < max ? `<button class="btn ghost small" data-act="bot" ${dis()}>+ Ajouter un bot</button>` : ''}
    <div class="dock">
      ${host
        ? `<button class="btn" data-act="start" ${dis(manque > 0)}>${manque ? `Il manque ${manque} joueur${manque > 1 ? 's' : ''}` : 'Lancer la partie'}</button>`
        : `<p class="dockhint">${lobbyHint()}</p>`}
    </div>`;
}

// Les invités n'ont pas le bouton de lancement : on leur dit ce qui se passe.
function lobbyHint(){
  const r = state.room, n = state.players.length, min = minPlayers(r.mode);
  if (n < min) { const k = min - n; return `Il manque ${k} joueur${k > 1 ? 's' : ''} pour jouer.` }
  return `<b>${nameOf(r.host_id)}</b> va lancer la partie.`;
}

/* ---------- Le jeu ---------- */
let rulesOpen = false, gamePick = false, reglagesOuverts = false;
// Le panneau du jeu : son nom, la règle seulement si on la demande, puis les
// réglages (repliés pour l'hôte, résumés en une ligne pour les autres).
function gameBox(host){
  const r = state.room, g = GAMES[r.mode] || GAMES.phrases;
  const modeDesc = { ondes: WAVE_INVERSE_DESC, dilemme: DILEMME_VARIANT_DESC, phrases: PHRASES_VARIANT_DESC }[r.mode];
  return `<section class="panel gamebox">
      <div class="gtitle">
        <div class="gtext"><h3 class="gname">${g.name}</h3><p class="gsub">${joueurs(r.mode)}</p></div>
        ${host ? `<button type="button" class="chg" data-act="game-pick" aria-expanded="${gamePick}">${gamePick ? 'Fermer' : 'Changer de jeu'}</button>` : ''}
      </div>
      ${host && gamePick ? gamePicker() : ''}
      ${rulesOpen ? `<ul class="gdesc grules">${g.desc.map(step => `<li>${esc(step)}</li>`).join("")}</ul>${modeDesc ? `<p class="gdesc">${esc(modeDesc)}</p>` : ''}` : ''}
      <button type="button" class="rulesbtn" data-act="rules" aria-expanded="${rulesOpen}">${rulesOpen ? 'Masquer la règle' : 'Lire la règle'}</button>
      ${reglages(host)}
    </section>`;
}

// Changer de jeu : la liste complète, rangée par famille, avec pour chaque jeu
// le nombre de joueurs et son accroche. Un jeu trop petit pour le salon
// (Petit bac : 2 joueurs) est grisé.
function gamePicker(){
  const n = state.players.filter(p => p.active !== false).length, cur = state.room.mode;
  return `<div class="gpick" role="group" aria-label="Choisir le jeu">${CATEGORIES.map(([c, titre]) => `
      <h4 class="gcat">${titre}</h4>
      ${Object.entries(GAMES).filter(([, g]) => g.cat === c).map(([k, g]) => {
        const trop = n > maxPlayers(k);
        return `<button type="button" class="gitem${k === cur ? ' on' : ''}" data-act="set-game" data-v="${k}" data-game="${k}" aria-pressed="${k === cur}" ${trop || busy ? 'disabled' : ''}>
          <img src="games/${tileImg(k)}" width="720" height="720" alt="" decoding="async">
          <span class="gi"><b>${g.name}</b><small>${trop ? `${maxPlayers(k)} joueurs maximum` : joueurs(k)}</small><span>${g.pitch}</span></span>
        </button>`;
      }).join('')}`).join('')}</div>`;
}

/* ---------- Modes propres à un jeu ---------- */
// Baromètre (Normal / Inversé), Dilemme (50/50 / Aléatoire) et Phrases à trou
// (Normal / Private Joke) : le mode se choisit dans les réglages.
const MODES = {
  ondes:   { cle:'wave_variant',    act:'wave-variant',    defaut:'normal',    liste:[['normal','Normal'],['inverse','Inversé']] },
  dilemme: { cle:'dilemme_variant', act:'dilemme-variant', defaut:'aleatoire', liste:[['moitie','50/50'],['aleatoire','Aléatoire']] },
  phrases: { cle:'phrases_variant', act:'phrases-variant', defaut:'normal',    liste:[['normal','Normal'],['private','Private Joke']] },
};
function modeCourant(){
  const m = MODES[state.room.mode];
  if (!m) return null;
  const v = m.liste.some(([k]) => k === state.room[m.cle]) ? state.room[m.cle] : m.defaut;
  return { ...m, v, label: m.liste.find(([k]) => k === v)[1] };
}
function modeChoix(){
  const m = modeCourant();
  if (!m) return '';
  return `<div class="seg s2 variant" role="group" aria-label="Mode de ${(GAMES[state.room.mode] || GAMES.phrases).name}">${m.liste.map(([k, l]) =>
    `<button type="button" class="seg-b ${m.v === k ? 'on' : ''}" data-act="${m.act}" data-v="${k}" aria-pressed="${m.v === k}" ${dis()}>${l}</button>`).join('')}</div>
    ${state.room.mode === 'phrases' && pjDemande && m.v === 'normal' ? `<div class="pjcode">
      <label class="field"><span>Code Private Joke</span>
        <input id="pj-code" type="password" autocomplete="off" enterkeyhint="go" placeholder="Le code de votre groupe" value="${esc(pjDraft)}"></label>
      <button type="button" class="btn alt small" data-act="pj-ok" ${dis()}>Débloquer</button>
      <p class="hint">Le code admin marche aussi.</p>
    </div>` : ''}`;
}

// Phrases à trou, Private Joke : il faut le code du groupe (le code admin marche
// aussi) ; une fois accepté, ce téléphone le retient et ne le redemande plus.
let pjDemande = false, pjDraft = '';
const codePJ = () => { try { return localStorage.getItem('pdcat-pj') || '' } catch { return '' } };
const retenirPJ = c => { try { c ? localStorage.setItem('pdcat-pj', c) : localStorage.removeItem('pdcat-pj') } catch {} };
// Envoie le code : refusé, ce téléphone l'oublie et redemande.
async function choisirPJ(code, el){
  if (busy) return;
  busy = true;
  if (el && el.isConnected) { el.disabled = true; el.classList.add('pending') }
  try {
    try { await rpc('set_phrases_variant', { p_code:session.code, p_token:session.token, p_variant:'private', p_secret:code }) }
    catch (e) {
      // serveur pas encore à jour (pas de version avec code) : l'ancienne suffit
      if (!/PGRST202|Could not find the function/i.test(e.message)) throw e;
      await rpc('set_phrases_variant', { p_code:session.code, p_token:session.token, p_variant:'private' });
    }
    retenirPJ(code); pjDemande = false; pjDraft = '';
    ping(); await refresh(true);
  } catch (e) {
    if (/code/i.test(e.message)) { retenirPJ(''); pjDemande = true }
    toast(e.message);
  } finally { busy = false; render() }
}

/* ---------- Réglages ---------- */
// − et + changent la valeur à l'écran tout de suite, l'envoi au serveur part
// quand l'hôte arrête de taper.
const optKey = () => ['priorites','ondes','mimes','dico','dilemme'].includes(state.room.mode) ? 'turns' : 'target';
const OPT_BORNES = { ...BORNES, pun:[0, 5] };
let optDraft = {}, optTimer = null;
function optValue(k){
  if (k in optDraft) return optDraft[k];
  if (k === 'pun') return pun?.on ? +pun.count : 0;
  return k === 'target' && state.room.mode === 'bac' ? bacRounds() : +state.room[k];
}
function stepper(k, label, full = label){
  const [lo, hi] = OPT_BORNES[k], v = optValue(k);
  return `<div class="step" role="group" aria-label="${full}">
      <button type="button" data-act="step" data-k="${k}" data-d="-1" aria-label="Moins" ${v <= lo ? 'disabled' : ''}>−</button>
      <b aria-live="polite">${v}</b>
      <button type="button" data-act="step" data-k="${k}" data-d="1" aria-label="Plus" ${v >= hi ? 'disabled' : ''}>+</button>
    </div>`;
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
const TIME_MODES = [
  ['unlimited','Illimité','Aucun compte à rebours.'],
  ['slow','Lent','Pour prendre le temps de réfléchir.'],
  ['medium','Moyen','Un rythme équilibré.'],
  ['fast','Rapide','Des décisions plus instinctives.']
];
const timeMode = () => {
  const cur = state.room.time_mode || (['bac','white','mimes'].includes(state.room.mode) ? 'unlimited' : 'medium');
  return TIME_MODES.find(x => x[0] === cur) || TIME_MODES[2];
};
// Temps : les quatre rythmes côte à côte, celui choisi allumé.
function timeField(host){
  const [cur, label] = timeMode();
  if (!host) return label;
  return `<div class="seg s4 tseg" role="group" aria-label="Temps">${TIME_MODES.map(([k, l, d]) =>
    `<button type="button" class="seg-b ${k === cur ? 'on' : ''}" data-act="time-mode" data-v="${k}" aria-pressed="${k === cur}" title="${d}" ${dis()}>${l}</button>`).join('')}</div>`;
}
// Le libellé du nombre réglable : manches à gagner, à jouer, ou tours par joueur.
function optLabel(){
  const r = state.room, k = optKey();
  return (r.mode === 'bac' || r.mode === 'white') ? 'Manches à jouer'
    : k === 'turns' ? `Tours de ${r.mode === 'ondes' ? 'médium' : ['dico','dilemme'].includes(r.mode) ? 'meneur' : 'juge'}` : 'Manches à gagner';
}
// Une ligne qui dit tout : « Mode Normal · 5 manches à gagner · Temps moyen · Punitions ».
function resumeReglages(){
  const k = optKey(), v = optValue(k), [, temps] = timeMode();
  const nb = `${v} ${optLabel().toLowerCase().replace('manches', v > 1 ? 'manches' : 'manche').replace('tours', v > 1 ? 'tours' : 'tour')}`;
  const p = pun ? (optValue('pun') > 0 ? ' · Punitions' : ' · Sans punitions') : '';
  const m = modeCourant();
  return `${m ? `Mode ${m.label} · ` : ''}${nb} · Temps ${temps.toLowerCase()}${p}`;
}
function reglages(host){
  if (!host) return `<p class="gdesc resume">${resumeReglages()}</p>`;
  return `<div class="reglages${reglagesOuverts ? ' open' : ''}">
      <button type="button" class="regtog" data-act="reglages" aria-expanded="${reglagesOuverts}">
        <span><b>Réglages</b><small>${resumeReglages()}</small></span>${ic('next', 'chev')}</button>
      ${reglagesOuverts ? `<div class="regbody">
        ${modeCourant() ? `<div class="rrow col"><span>Mode</span>${modeChoix()}</div>` : ''}
        <div class="rrow"><span>${optLabel()}</span>${stepper(optKey(), optKey() === 'turns' ? 'Tours' : 'Manches', optLabel())}</div>
        <div class="rrow col"><span>Temps</span>${timeField(true)}</div>
        ${pun ? `<div class="rrow"><span>Punitions <small>${PUN_NB} par joueur, tirées au sort à la fin</small></span>${punCheck()}</div>` : ''}
      </div>` : ''}
    </div>`;
}

/* ---------- Actions ---------- */
surAction('game-pick', () => { gamePick = !gamePick; render() }, { marque:false });
surAction('rules', () => { rulesOpen = !rulesOpen; render() }, { marque:false });
surAction('reglages', () => { reglagesOuverts = !reglagesOuverts; render() }, { marque:false });
surAction('step', el => {
  const k = el.dataset.k, [lo, hi] = OPT_BORNES[k];
  const v = Math.min(hi, Math.max(lo, optValue(k) + +el.dataset.d));
  optDraft = { ...optDraft, [k]: v };
  clearTimeout(optTimer); optTimer = setTimeout(() => { optTimer = null; sendOpts() }, 600);
  render();
}, { marque:false });
surAction('bot', () => act('add_bot'));
// avec punitions, le serveur ouvre d'abord l'écran de saisie
surAction('start', () => act('lancer_partie'));
surAction('kick', (el, id) => act('kick_player',{ p_player_id:id }));
surAction('set-game', async el => {
  const m = el.dataset.v, r = state.room;
  if (!GAMES[m] || m === r.mode) { gamePick = false; return render() }
  // le brouillon des réglages visait l'ancien jeu
  clearTimeout(optTimer); optTimer = null; optDraft = {};
  if (!(await act('set_room_options', { p_mode:m, p_target:Math.min(20, Math.max(1, +r.target || 5)), p_turns:Math.min(5, Math.max(1, +r.turns || 2)) }))) return;
  gamePick = false; pjDemande = false; rulesOpen = false;
  retenirJeu(m);
  // même temps par défaut qu'à la création : sans minuteur pour Petit bac, Mr White et Mimes
  const t = ['bac','white','mimes'].includes(m) ? 'unlimited' : 'medium';
  if (state.room.time_mode !== t) await act('set_time_mode', { p_mode:t });
  toast(`Jeu changé : ${GAMES[m].name}.`);
  render();
});
surAction('time-mode', el => act('set_time_mode', { p_mode: el.dataset.v }));
surAction('wave-variant', el => act('set_wave_variant', { p_variant: el.dataset.v }));
surAction('dilemme-variant', el => act('set_dilemme_variant', { p_variant: el.dataset.v }));
surAction('phrases-variant', el => {
  if (el.dataset.v !== 'private') { pjDemande = false; return act('set_phrases_variant', { p_variant:'normal' }) }
  if (state.room.phrases_variant === 'private') return;
  const code = codePJ();
  if (code) return choisirPJ(code, el);
  pjDemande = true; render();
  document.getElementById('pj-code')?.focus();
});
surAction('pj-ok', el => {
  const c = (document.getElementById('pj-code')?.value || '').trim();
  if (!c) return toast('Entre le code Private Joke.');
  return choisirPJ(c, el);
});
document.addEventListener('input', e => { if (e.target.id === 'pj-code') pjDraft = e.target.value });
document.addEventListener('keydown', e => {
  if (e.key === 'Enter' && e.target.matches('#pj-code')) { e.preventDefault(); document.querySelector('[data-act=pj-ok]')?.click() }
});
