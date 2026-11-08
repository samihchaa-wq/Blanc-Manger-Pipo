// Mimes : action, intensités, notes du juge.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Mimes ---------- */
// Le juge voit l'action ; chaque mime voit en plus son intensité secrète.
// Ordre de passage : les sièges à partir du juge (le serveur les range ainsi).
const mimeIds = () => (state.mime?.parts || []).map(x => x.player_id).filter(id => id !== state.room.reader_id && P(id));
function mimeCard(cls = ''){
  const m = state.mime || {};
  return qcard(cls ? ic('voice') + 'Action à lire à voix haute' : 'Action', esc(m.action || ''), cls, `<span class="by">1 : ${esc(m.low || '')} · 10 : ${esc(m.high || '')}</span>`);
}
function mimeOrder(){
  return `<h3 class="sec">Ordre de passage</h3><ol class="mime-order">${mimeIds().map(id =>
    `<li>${nameOf(id)}${isMe(id) ? ' <span class="tag">toi</span>' : ''}</li>`).join('')}</ol>`;
}
let mimeCustomEditing = false, mimeActionDraft = '', mimeLowDraft = '', mimeHighDraft = '';
function mimePlay(){
  const r = state.room, m = state.mime || {}, judge = isMe(r.reader_id);
  if (m.ready === false) {
    if (!judge) return `
      <p class="role"><b>${nameOf(r.reader_id)}</b> prépare le défi Mimes.</p>
      <p class="waiting"><span class="pulse"></span>Le juge choisit une action ou invente son défi…</p>
      ${scoreStrip('l')}`;
    if (mimeCustomEditing) return `
      <p class="role"><b>Invente ton mime.</b> Les intensités secrètes des joueurs sont déjà tirées.</p>
      <section class="panel customchallenge">
        <label class="field"><span>Action à mimer</span><input id="custom-mime-action" maxlength="80"
          autocomplete="off" value="${esc(mimeActionDraft)}" placeholder="Manger un citron"></label>
        <label class="field"><span>Intensité 1</span><input id="custom-mime-low" maxlength="60"
          autocomplete="off" value="${esc(mimeLowDraft)}" placeholder="C'est délicieux"></label>
        <label class="field"><span>Intensité 10</span><input id="custom-mime-high" maxlength="60"
          autocomplete="off" value="${esc(mimeHighDraft)}" placeholder="C'est atrocement acide"></label>
      </section>
      <div class="dock">
        <button class="btn" data-act="custom-mime-send" ${dis()}>Lancer mon mime</button>
        <button class="btn ghost" data-act="custom-mime-cancel">Annuler</button>
      </div>`;
    return `
      <p class="role"><b>Tu es le juge.</b> Pour cette manche, choisis le défi classique ou invente le tien.</p>
      ${mimeCard('aloud short')}
      <button class="btn ghost small custom-choice" data-act="custom-mime-open">Inventer mon mime</button>
      <div class="dock"><button class="btn" data-act="custom-mime-default" ${dis()}>Jouer le mime proposé</button></div>`;
  }
  const order = mimeIds(), step = Math.max(0, Math.min(order.length, Number(r.mime_index) || 0));
  const current = step ? order[step - 1] : null;
  const stage = r.time_mode === 'unlimited' ? '' : '<section class="mime-stage">'
    + (step === 0 ? 'Le juge lance les prestations une par une.'
       : '<b>' + nameOf(current) + '</b> mime actuellement.')
    + (judge && step < order.length
       ? '<button class="btn ghost small" data-act="mime-progress">'
         + (step ? 'Mime suivant' : 'Démarrer le premier mime') + '</button>'
       : '') + '</section>';
  if (!judge) return `
    <p class="role"><b>${nameOf(r.reader_id)}</b> est le juge.</p>
    ${mimeCard()}
    <section class="white-secret"><p class="eyebrow">Ton intensité :</p><strong>${m.mine ?? '?'} / 10</strong></section>
    ${mimeOrder()}${stage}
    <p class="muted" style="text-align:center"><span class="pulse"></span>Mimez chacun votre tour, ${nameOf(r.reader_id)} note ensuite.</p>`;
  const ids = mimeIds(), done = ids.every(id => mimeNotes[id]);
  return `
    <p class="role"><b>Tu es le juge.</b> Lis l’action à voix haute. Chacun la mime à son tour, devine son intensité.</p>
    ${mimeCard('aloud short')}${stage}
    <h3 class="sec">Tes notes</h3>
    <ul class="mime-rates">${ids.map(id => `<li><span class="nm">${nameOf(id)}</span>
      <div class="mime-notes" role="group" aria-label="Note de ${nameOf(id)}">${Array.from({ length:10 }, (_, i) => i + 1).map(v =>
        `<button type="button" class="${mimeNotes[id] === v ? 'on' : ''}" data-act="mime-note" data-id="${id}" data-v="${v}" aria-pressed="${mimeNotes[id] === v}">${v}</button>`).join('')}</div></li>`).join('')}</ul>
    <div class="dock"><button class="btn" data-act="mime-rate" ${dis(!done)}>${done ? 'Valider les notes' : 'Note chaque joueur'}</button></div>`;
}
function mimeReveal(){
  const r = state.room, parts = state.mime?.parts || [];
  const judge = parts.find(x => x.player_id === r.reader_id);
  return `
    <p class="role">${isMe(r.reader_id) ? '<b>Tes notes</b>' : `Les notes de <b>${nameOf(r.reader_id)}</b>`}</p>
    ${mimeCard()}
    <h3 class="sec">Points de la manche</h3>
    <ol class="rank">${parts.filter(x => x.player_id !== r.reader_id && P(x.player_id)).map(x => `<li>
      <span class="nm"><span class="who">${nameOf(x.player_id)}</span><span class="tag">joué ${x.intensity ?? '?'} · noté ${x.guess ?? '?'}</span></span>
      <b class="plus" data-n="${x.points ?? 0}">+${x.points ?? 0}</b></li>`).join('')}
      ${judge ? `<li><span class="nm"><span class="who">${nameOf(judge.player_id)}</span><span class="tag host">juge</span></span><b class="plus" data-n="${judge.points ?? 0}">+${judge.points ?? 0}</b></li>` : ''}</ol>
    <h3 class="sec">Classement</h3>${rank()}
    ${ackWaiting()}
    <div class="dock"><button class="btn" data-act="bac-next" ${dis(state.me.next_ack === r.round)}>${state.me.next_ack === r.round ? 'En attente des autres…' : roundsLeft() ? 'Manche suivante' : 'Voir le résultat'}</button></div>`;
}

/* ---------- Actions ---------- */
surAction('custom-mime-open', () => { mimeCustomEditing = true; render() }, { marque:false });
surAction('custom-mime-cancel', () => { mimeCustomEditing = false; render() }, { marque:false });
surAction('custom-mime-default', () => act('choose_mime_challenge', {
  p_custom:false,p_action:null,p_low:null,p_high:null
}));
surAction('custom-mime-send', async () => {
  const a = (document.getElementById('custom-mime-action')?.value || '').trim();
  const l = (document.getElementById('custom-mime-low')?.value || '').trim();
  const h = (document.getElementById('custom-mime-high')?.value || '').trim();
  if (a.length < 3 || l.length < 2 || h.length < 2)
    return toast('Renseigne l’action et ses deux intensités.');
  if (await act('choose_mime_challenge', {p_custom:true,p_action:a,p_low:l,p_high:h})) {
    mimeCustomEditing = false; mimeActionDraft = ''; mimeLowDraft = ''; mimeHighDraft = '';
  }
});
document.addEventListener('input', e => {
  if (e.target.id === 'custom-mime-action') mimeActionDraft = e.target.value;
  if (e.target.id === 'custom-mime-low') mimeLowDraft = e.target.value;
  if (e.target.id === 'custom-mime-high') mimeHighDraft = e.target.value;
});
surAction('mime-progress', () => act('mime_progress', { p_action:'next' }));
surAction('mime-note', (el, id) => { mimeNotes[id] = +el.dataset.v; render() });
surAction('mime-rate', () => {
  const ids = mimeIds();
  if (ids.some(x => !mimeNotes[x])) return toast('Note chaque joueur.');
  return act('mime_rate', { p_players: ids, p_notes: ids.map(x => mimeNotes[x]) });
});
