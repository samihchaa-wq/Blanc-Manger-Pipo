// Priorités : échelle de classement et révélation.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Priorités ---------- */
// Manches restantes après celle-ci : chaque joueur encore là doit encore juger
// (tours choisis - fois où il a déjà jugé). Le Petit bac en compte 1, 3 ou 5 (au choix de l'hôte).
function roundsLeft(){
  const r = state.room;
  if (isBac() || isWhite()) return Math.max(0, bacRounds() - r.round);
  return state.players.filter(p => p.active).reduce((n, p) => n + Math.max(0, r.turns - (p.judge_count || 0)), 0);
}
const rankCard = id => (state.rank_cards || []).find(c => c.id === id);

function ladder(ids, editable, marks){
  const n = (state.rank_cards || []).length || 5;
  return `<p class="ladder-end">Le plus important</p>
    <ol class="ladder">${Array.from({ length:n }, (_, i) => {
      const c = rankCard(ids[i]);
      const cls = !c ? '' : marks ? 'full ' + marks[i] : 'full';
      return `<li class="${cls}"><span class="num">${i + 1}</span>${!c ? '<span class="slot"></span>'
        : editable ? `<button class="acard sel" data-act="unrank" data-id="${c.id}" aria-label="Retirer ${esc(c.text)}">${esc(c.text)}</button>`
        : `<span class="acard sel">${esc(c.text)}</span>`}</li>`;
    }).join('')}</ol>
    <p class="ladder-end">Le moins important</p>`;
}

function ranking(){
  const r = state.room, cards = state.rank_cards || [], judge = isMe(r.reader_id);
  const left = state.players.filter(p => !p.ranked), done = state.players.length - left.length;
  const bar = `<div class="bar"><i style="width:${Math.round(done / state.players.length * 100)}%"></i></div>`;

  if (state.my_ranking) return `
    <p class="role"><b>Classement envoyé.</b> ${judge ? 'Les autres essaient de le deviner…' : `Verdict quand tout le monde aura classé.`}</p>
    ${ladder(state.my_ranking, false)}
    <p class="meta" style="margin-top:18px">${done}/${state.players.length} ont classé</p>${bar}
    ${waiting(left, 'Tout le monde a classé.')}`;

  const pool = cards.filter(c => !picks.includes(c.id)), reste = cards.length - picks.filter(Boolean).length;
  return `
    <p class="role">${judge ? '<b>Tu es le juge.</b>' : `<b>${nameOf(r.reader_id)}</b> est le juge.`}</p>
    ${ladder(picks, true)}
    ${pool.length
      ? `<ul class="hand${dealPending ? ' deal-in' : ''}">${pool.map((c,i) => `<li style="--i:${i}">
           <button class="acard" data-act="rank" data-id="${c.id}">${esc(c.text)}</button></li>`).join('')}</ul>`
      : ''}
    <div class="dock"><button class="btn" data-act="send-rank" ${dis(reste > 0)}>${reste > 0
      ? `Encore ${reste} carte${reste > 1 ? 's' : ''} à classer`
      : judge ? 'Valider mon classement' : 'Valider mon pronostic'}</button></div>`;
}

function rankReveal(){
  const r = state.room;
  const ks = (state.rankings || []).filter(k => P(k.player_id));
  const truth = ks.find(k => k.player_id === r.reader_id)?.cards || [];
  const guessers = ks.filter(k => k.player_id !== r.reader_id);
  const pts = [...ks].sort((a,b) => b.points - a.points);
  // Une case par joueur (dans l'ordre des sièges) : toucher un nom affiche son classement.
  const seats = state.players.map(p => ks.find(k => k.player_id === p.id)).filter(Boolean);
  const view = seats.find(k => k.player_id === rankView) || ks.find(k => k.player_id === r.reader_id);
  const cols = Math.ceil(seats.length / Math.ceil(seats.length / 4));
  return `
    <div class="seg who" role="tablist" style="grid-template-columns:repeat(${cols},1fr)">${seats.map(k => {
      const on = k === view;
      return `<button type="button" class="seg-b ${on ? 'on' : ''}" data-act="rankview" data-id="${k.player_id}" role="tab" aria-selected="${on}">
        <span>${isMe(k.player_id) ? 'Toi' : nameOf(k.player_id)}</span>${k.player_id === r.reader_id ? '<small>juge</small>' : ''}</button>`;
    }).join('')}</div>
    ${view?.player_id === r.reader_id ? `<ol class="truth">${truth.map((id, i) => {
      const hit = guessers.filter(k => k.cards[i] === id);
      return `<li><span class="num">${i + 1}</span><div class="scard">${esc(rankCard(id)?.text)}</div>
        <div class="found">${hit.length ? hit.map(k => `<span class="chip hit">✓ ${nameOf(k.player_id)}</span>`).join('') : 'Personne'}</div></li>`;
    }).join('')}</ol>`
    : view ? `<ol class="truth">${view.cards.map((id, i) => `<li><span class="num">${i + 1}</span><div class="scard">${esc(rankCard(id)?.text)}</div></li>`).join('')}</ol>` : ''}
    <h3 class="sec">Points de la manche</h3>
    <ol class="rank">${pts.map(k => `<li>
      <span class="nm"><span class="who">${nameOf(k.player_id)}</span>${k.player_id === r.reader_id ? '<span class="tag host">juge</span>' : ''}${k.points >= 12 && k.player_id !== r.reader_id ? '<span class="tag">sans-faute</span>' : ''}</span>
      <b class="plus">+${k.points ?? 0}</b></li>`).join('')}</ol>
    <h3 class="sec">Classement</h3>${rank()}`;
}

