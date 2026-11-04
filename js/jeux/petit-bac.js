// Petit bac : catégories, roue des lettres, grille, votes.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Petit bac ---------- */
// Le brouillon suit la manche : il est relu sur le serveur en arrivant sur la
// saisie, pour qu'un rechargement de la page ne fasse rien perdre.
function bacSync(prev, s){
  const r = s.room, b = s.bac || {};
  if (r.status !== 'writing') bacRound = 0;
  else if (bacRound !== r.round) {
    bacRound = r.round;
    bacDraft = Array.from({ length:6 }, (_, i) => b.mine?.[i] || '');
    bacSent = JSON.stringify(bacDraft);
    // Horloge locale, pour qu'un téléphone mal réglé ne bloque pas la roue :
    // elle ne tourne que si la saisie vient de s'ouvrir (phase_at est posé
    // 5 s après le tirage de la lettre).
    roueAt = stamp(r.phase_at) - Date.now() > -10000 ? Date.now() : 0;
  }
  // L'adversaire a rendu sa grille : un message, sans redessiner la saisie
  // (un nouveau DOM fermerait le clavier sous les doigts).
  if (prev?.room.status === 'writing' && r.status === 'writing' && !b.done)
    s.players.filter(p => !isMe(p.id) && p.bac_done && !prev.players.find(q => q.id === p.id)?.bac_done)
      .forEach(p => toast(`${p.name} a fini !`));
}

// Les champs sont remplis après coup : la saisie n'entre pas dans le HTML
// comparé par render(), qui ne réécrit donc pas la grille à chaque frappe.
function fillBac(){
  app.querySelectorAll('.bacfield input').forEach(el => { el.value = bacDraft[+el.dataset.i] || '' });
}

// Enregistrement au fil de la frappe. Les envois passent l'un après l'autre :
// une version ancienne n'arrive jamais après la nouvelle.
function saveBac(){
  clearTimeout(bacTimer);
  return bacChain = bacChain.then(async () => {
    if (!session || state?.room.status !== 'writing' || state.bac?.done) return;
    const j = JSON.stringify(bacDraft);
    if (j === bacSent) return;
    try { await rpc('bac_save', { p_code:session.code, p_token:session.token, p_answers:bacDraft, p_done:false }); bacSent = j }
    catch {}
  });
}

// La roue des lettres s'arrête sur la lettre tirée par le serveur.
function roue(lettre){
  const n = BAC_LETTRES.length, a = 360 / n, k = Math.max(0, BAC_LETTRES.indexOf(lettre));
  const parts = [...BAC_LETTRES].map((_, i) =>
    `${SEAT_COLORS[i % SEAT_COLORS.length]} ${(i * a).toFixed(1)}deg ${((i + 1) * a).toFixed(1)}deg`).join(',');
  // le dégradé conique part de midi : après rotation, la part k est sous la flèche
  const spin = 1440 + 360 - (k + .5) * a;
  return `<div class="roueWrap">
      <h2 class="bigstate">Quelle lettre ?</h2>
      <div class="roueBox">
        <span class="pointer" aria-hidden="true"></span>
        <div class="roue" style="--spin:${spin.toFixed(1)}deg;background:conic-gradient(${parts})" aria-hidden="true">${
          [...BAC_LETTRES].map((l, i) => `<span class="lab" style="--a:${((i + .5) * a).toFixed(1)}deg"><i>${l}</i></span>`).join('')}</div>
        <b class="rouel">${esc(lettre)}</b>
      </div>
    </div>`;
}

// Début de partie : chacun propose une catégorie à son tour, jusqu'à six.
// Elles servent pour toutes les manches et disparaissent avec la partie.
function bacNaming(){
  const r = state.room, cats = state.bac?.categories || [], moi = isMe(r.reader_id);
  return `
    <p class="role">${moi ? '<b>À toi de proposer une catégorie.</b>' : `<b>${nameOf(r.reader_id)}</b> propose une catégorie.`}</p>
    <ol class="bacslots">${Array.from({ length:6 }, (_, i) => `<li class="${i < cats.length ? 'full' : ''}${i === cats.length - 1 ? ' new' : ''}">
      <span class="num">${i + 1}</span>${i < cats.length ? `<span class="cat">${esc(cats[i])}</span>` : '<span class="slot"></span>'}</li>`).join('')}</ol>
    ${moi ? `<label style="margin-top:22px"><span>Ta catégorie</span><input id="bac-cat" maxlength="40" autocomplete="off" autocapitalize="sentences"
        enterkeyhint="done" value="${esc(catDraft)}"></label>
      <div class="dock"><button class="btn" data-act="bac-cat" ${dis()}>Proposer</button></div>` : ''}`;
}

function bacWrite(){
  const b = state.bac || {}, cats = b.categories || [], L = esc(b.letter || '');
  if (roueEnCours()) return roue(b.letter || '');
  if (b.done) return `
    <p class="role"><b>Grille envoyée.</b></p>
    ${bacTable(cats, [{ player_id: state.me.id, answers: b.mine || [] }], cats.length)}
    ${waiting(state.players.filter(p => !p.bac_done), 'Tout le monde a fini.')}`;
  return `
    <div class="bachead"><span class="bacl">${L}</span>
      <span class="bacnote">Un mot en <b>${L}</b> pour chaque catégorie</span></div>
    ${cats.map((c, i) => `<label class="bacfield"><span>${esc(c)}</span><input id="bac-${i}" data-i="${i}" maxlength="120"
      autocomplete="off" autocorrect="off" autocapitalize="sentences" spellcheck="false"
      enterkeyhint="${i < cats.length - 1 ? 'next' : 'done'}" placeholder="${L}…" ></label>`).join('')}
    <div class="dock"><button class="btn" data-act="bac-done" ${dis()}>J’ai fini</button></div>`;
}

// Une case par catégorie, une ligne par joueur, avec le vote reçu s'il est connu.
function bacTable(cats, rows, upto){
  return `<ol class="bactab">${cats.slice(0, upto).map((c, i) => `<li><span class="cat">${esc(c)}</span>${rows.map(x => `
      <span class="ans"><span class="qui">${isMe(x.player_id) ? 'Toi' : nameOf(x.player_id)}</span>
        <span class="mot">${x.answers?.[i] ? esc(x.answers[i]) : '—'}</span><span class="pt">${voteIcon(x.points?.[i])}</span></span>`).join('')}</li>`).join('')}</ol>`;
}
// toi d'abord, l'adversaire ensuite
const bacRows = () => [...(state.bac?.rows || [])].sort((x, y) => isMe(y.player_id) - isMe(x.player_id));

// Catégorie par catégorie : chacun juge la réponse de l'autre. Le vote reçu
// reste caché tant que les deux n'ont pas voté (le serveur ne l'envoie pas).
function bacVote(){
  const b = state.bac || {}, cats = b.categories || [], i = b.step || 0, rows = bacRows();
  const mine = rows.find(x => isMe(x.player_id)), theirs = rows.find(x => !isMe(x.player_id));
  if (!theirs) return '';
  const nom = nameOf(theirs.player_id), leur = theirs.answers?.[i] || '', moi = mine?.answers?.[i] || '';
  const cle = state.room.round + ':' + i, choix = bacMyVote?.k === cle ? bacMyVote.v : null;
  const aMoi = !!leur && theirs.pending && choix == null;
  const mot = t => t ? esc(t) : '<span class="vide">Rien écrit</span>';
  const boutons = actif => `<div class="votes" role="group" aria-label="Ta note pour ${nom}">${VOTES.map(([v, e, t]) =>
    `<button class="vote ${choix === v ? 'on' : ''}" data-act="bac-vote" data-v="${v}" aria-pressed="${choix === v}" ${actif ? dis() : 'disabled'}>${ic(e, 'v' + v)}<small>${t}</small></button>`).join('')}</div>`;
  return `
    <p class="role">${aMoi ? '<b>À toi de juger.</b>' : mine?.pending && moi ? `<b>${nom}</b> juge ta réponse.` : ''}</p>
    ${qcard(`Catégorie ${i + 1} / ${cats.length} · lettre ${esc(b.letter)}`, esc(cats[i]), 'clue')}
    <div class="duel">
      <div class="rep them"><small>${nom}</small>${mot(leur)}</div>
      <div class="rep mine"><small>Toi</small>${mot(moi)}</div>
    </div>
    ${leur ? '' : `<p class="waiting">Rien écrit : 0 point pour ${nom}.</p>`}
    ${i ? `<h3 class="sec">Déjà jugé</h3>${bacTable(cats, rows, i)}` : ''}
    ${leur ? `<div class="dock">${boutons(aMoi)}</div>` : ''}`;
}

function bacReveal(){
  const b = state.bac || {}, rows = bacRows();
  const tot = x => (x.points || []).reduce((s, v) => s + (v || 0), 0);
  return `
    <p class="role"><b>Fin de la manche ${state.room.round}.</b></p>
    <ol class="rank">${[...rows].sort((x, y) => tot(y) - tot(x)).map(x => `<li>
      <span class="nm"><span class="who">${isMe(x.player_id) ? 'Toi' : nameOf(x.player_id)}</span></span>
      <b class="plus" data-n="${tot(x)}">+${tot(x)}</b></li>`).join('')}</ol>
    <h3 class="sec">Classement</h3>${rank()}
    <h3 class="sec">Lettre ${esc(b.letter)}</h3>${bacTable(b.categories || [], rows, 6)}
    ${ackWaiting()}
    <div class="dock"><button class="btn" data-act="bac-next" ${dis(state.me.next_ack === state.room.round)}>${state.me.next_ack === state.room.round ? 'En attente de l’autre joueur…' : state.room.round >= bacRounds() ? 'Voir le résultat' : 'Manche suivante'}</button></div>`;
}

