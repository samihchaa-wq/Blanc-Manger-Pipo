// Phrases à trou : accord des réponses dans la phrase, choix de la question,
// main du joueur, lecture et vote du lecteur, et les actions de ces écrans.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.
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
/* ---------- Écrans ---------- */
function qselect(){
  const r = state.room;
  const reader = P(r.reader_id);
  if (!isMe(reader?.id)) return waitScreen(`${nameOf(reader?.id)} est le lecteur`, 'Il choisit une carte parmi 5…');
  const chosen = state.question_choices.find(q => q.id === qpick);
  // Phrase choisie : elle passe seule en grand, le lecteur la lit à la table.
  if (chosen) return `
    <p class="role"><b>Lis la phrase à voix haute</b>, puis valide.</p>
    ${qcard(ic('voice') + 'À lire à voix haute', blank(chosen.text), 'aloud')}
    <div class="dock">
      <button class="btn" data-act="question-go" ${dis()}>J'ai lu la phrase</button>
      <button class="btn ghost" data-act="question-back" ${dis()}>Choisir une autre carte</button>
    </div>`;
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
    ${waiting(left)}${scoreStrip('l')}`;

  const cartes = state.my_cards || [];
  if (cartes.length) return `
    <p class="role"><b>${cartes.length > 1 ? 'Cartes envoyées.' : 'Carte envoyée.'}</b></p>
    ${qcard(cartes.length > 1 ? 'Tes réponses' : 'Ta réponse', fill(q, cartes))}
    <p class="meta" style="margin-top:18px">${done}/${others.length} ont joué</p>${bar}
    ${waiting(left)}${scoreStrip('l')}`;

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
    ${qcard(`${ic('voice')}Réponse ${readIndex + 1} / ${subs.length}`, fill(q, subs[readIndex].cards), 'aloud')}
    <div class="steps" aria-hidden="true">${subs.map((s,i) => `<i class="${i <= readIndex ? 'on' : ''}"></i>`).join('')}</div>
    <div class="dock"><button class="btn" data-act="readnext">${readIndex + 1 === subs.length ? 'Voir toutes les réponses' : 'Réponse suivante'}</button></div>`;
  return `
    <p class="role"><b>Tu es le lecteur.</b></p>
    <ul class="subs">
      ${subs.map(s => `<li><button class="scard ${s.id === picked ? 'sel' : ''}" data-act="pick" data-id="${s.id}" aria-pressed="${s.id === picked}">${fill(q, s.cards)}</button></li>`).join('')}
    </ul>
    <div class="dock"><button class="btn" data-act="confirm" ${dis(!picked)}>${picked ? 'Donner le point' : 'Touche ta réponse préférée'}</button></div>`;
}

/* ---------- Actions ---------- */
// le choix reste local : les autres joueurs n'ont leur écran qu'à la validation
surAction('question', (el, id) => { qpick = +id; render() });
surAction('question-back', () => { qpick = null; render() });
surAction('question-go', async () => {
  if (!qpick) return;
  const q = qpick;
  if (await act('select_question',{ p_question_id:q })) qpick = null;
});
surAction('select', (el, id) => {
  const n = state?.blanks || 1, carte = +id, rang = picks.indexOf(carte);
  if (rang >= 0) picks.splice(rang, 1);          // re-toucher retire la carte
  else if (n === 1) picks = [carte];             // un seul trou : une seule carte
  else if (picks.length < n) picks.push(carte);  // sinon on remplit dans l'ordre
  else { picks.shift(); picks.push(carte) }      // main pleine : la plus ancienne saute
  render();
});
surAction('send', async () => {
  if (picks.length < (state?.blanks || 1)) return;
  const [c1, c2] = picks;
  if (await act('submit_answer', { p_answer_id: c1, p_answer_id2: c2 ?? null })) picks = [];
});
surAction('drop', async () => {
  if (picks.length !== 1 || !state?.me?.can_discard) return;
  const c = picks[0];
  if (await act('discard_card', { p_answer_id: c })) { picks = []; render() }
});
surAction('readnext', () => { readIndex++; render() });
surAction('pick', (el, id) => { picked = id; render() });
surAction('confirm', () => picked && act('pick_winner',{ p_submission_id:picked }));
