// Punitions : l'interrupteur du salon, la saisie secrète avant la partie et la
// roue de fin de partie, avec leurs actions.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

// Toujours 2 punitions par joueur quand elles sont activées.
const PUN_NB = 2;
// Salon : un vrai interrupteur Oui / Non.
function punCheck(){
  const v = optValue('pun') > 0;
  return `<button type="button" class="switch${v ? ' on' : ''}" data-act="pun-toggle" role="switch" aria-checked="${v}" aria-label="Punitions">
      <span class="knob" aria-hidden="true"></span><b>${v ? 'Oui' : 'Non'}</b></button>`;
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
    items.map((_, i) => `<span class="lab" style="--a:${((i + .5) * a).toFixed(1)}deg"><i>${pick && !anim && i === k ? ic('star', 'solid') : '?'}</i></span>`).join('')}</div>`;
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

/* ---------- Actions ---------- */
surAction('pun-toggle', () => {
  optDraft = { ...optDraft, pun: optValue('pun') > 0 ? 0 : PUN_NB };
  clearTimeout(optTimer); optTimer = setTimeout(() => { optTimer = null; sendOpts() }, 600);
  render();
}, { marque:false });
surAction('punish-submit', async () => {
  const t = [...document.querySelectorAll('.punfield input')].map(c => c.value.trim());
  if (await act('punish_submit', { p_texts: t })) punDrafts = [];
});
surAction('punish-spin', () => act('punish_spin'));
document.addEventListener('input', e => {
  if (/^pun-\d$/.test(e.target.id)) punDrafts[+e.target.dataset.i] = e.target.value;
});
document.addEventListener('keydown', e => {
  // Entrée passe au champ suivant, puis ferme le clavier
  if (e.key === 'Enter' && e.target.matches('.punfield input')) {
    e.preventDefault();
    const suivant = document.getElementById('pun-' + (+e.target.dataset.i + 1));
    suivant ? suivant.focus() : e.target.blur();
  }
});
