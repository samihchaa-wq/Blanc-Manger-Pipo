// Le Dico : le meneur ouvre un dictionnaire à une page au hasard et y choisit
// son mot ; les autres en inventent la définition.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Le Dico ---------- */
// Le livre est un ensemble de fichiers statiques (dico/index.json, dico/p000.json…)
// générés depuis le Wiktionnaire : des pages de 8 mots dans l'ordre alphabétique.
// Chaque entrée est [mot, nature abrégée, définition].
let dicoIdx = null, dicoPage = null, dicoSel = null, dicoAnim = '', dicoDraft = '';
const dicoVues = new Set();   // pages déjà ouvertes sur ce téléphone
const pause = ms => new Promise(r => setTimeout(r, ms));

async function dicoIndex(){
  if (!dicoIdx) dicoIdx = await (await fetch('dico/index.json')).json();
  return dicoIdx;
}
// Une page au hasard, jamais deux fois la même sur ce téléphone tant qu'il en reste.
async function dicoPageAuHasard(){
  const ix = await dicoIndex();
  let n;
  do n = Math.floor(Math.random() * ix.pages); while (dicoVues.has(n) && dicoVues.size < ix.pages);
  dicoVues.add(n);
  const f = Math.floor(n / ix.parFichier);
  const pages = await (await fetch(`dico/p${String(f).padStart(3, '0')}.json`)).json();
  return { n: n + 1, mots: pages[n % ix.parFichier] };
}

// Ouvrir le livre fermé, ou tourner vers une autre page : l'animation et le
// chargement partent ensemble, la page s'affiche quand les deux sont finis.
async function dicoOuvrir(tourner){
  if (dicoAnim) return;
  dicoAnim = tourner ? 'flipping' : 'opening'; render();
  try {
    const [p] = await Promise.all([dicoPageAuHasard(), pause(tourner ? 480 : 950)]);
    dicoPage = p; dicoSel = null;
  } catch { toast('Le dictionnaire ne s’ouvre pas. Vérifie ta connexion.') }
  dicoAnim = ''; render();
}

// Le livre fermé (ou entrouvert pour les joueurs qui attendent).
function dicoLivre(cls){
  return `<div class="dbook ${cls}" aria-hidden="true">
    <div class="dpages"></div>
    <div class="dcover"><span class="dtitle">Dictionnaire</span><span class="dsub">du Soulièteur</span></div>
  </div>`;
}

function dicoPick(){
  const r = state.room;
  if (!isMe(r.reader_id)) return `<div class="waitScreen">${dicoLivre('idle')}
    <h2 class="bigstate">${nameOf(r.reader_id)} ouvre le dictionnaire</h2>
    <p class="muted"><span class="pulse"></span>Recherche d’un mot…</p>${scoreStrip()}</div>`;
  if (!dicoPage) return `
    <p class="role"><b>Tu es le Dico.</b> Ouvre le dictionnaire au hasard, puis choisis un mot sur la page.</p>
    <div class="bookwrap">${dicoLivre(dicoAnim === 'opening' ? 'opening' : 'closed')}</div>
    <div class="dock"><button class="btn" data-act="dico-open" ${dicoAnim ? 'disabled' : ''}>${dicoAnim ? 'Ouverture…' : 'Ouvrir le dictionnaire'}</button></div>`;
  const mots = dicoPage.mots, sel = mots[dicoSel];
  return `
    <p class="role"><b>Choisis un mot</b> sur la page, puis lis-le à voix haute.</p>
    <article class="dpage ${dicoAnim === 'flipping' ? 'flipping' : 'opened'}" aria-label="Page ${dicoPage.n} du dictionnaire">
      <header><span>${esc(mots[0][0])}</span><span>${esc(mots.at(-1)[0])}</span></header>
      <ol>${mots.map(([m, n, d], i) => `<li><button type="button" class="dent${i === dicoSel ? ' on' : ''}" data-act="dico-entry" data-i="${i}" aria-pressed="${i === dicoSel}">
        <b>${esc(m)}</b> <i>${esc(n)}</i> ${esc(d)}</button></li>`).join('')}</ol>
      <footer>${dicoPage.n}</footer>
    </article>
    <p class="dcredit">Définitions : Wiktionnaire, CC BY-SA 4.0</p>
    <div class="dock">
      <button class="btn" data-act="dico-choose" ${dis(!sel || dicoAnim)}>${sel ? `Choisir « ${esc(sel[0])} »` : 'Touche un mot'}</button>
      <button class="btn ghost" data-act="dico-flip" ${dicoAnim ? 'disabled' : ''}>Ouvrir à une autre page</button>
    </div>`;
}

// Le mot du tour, seul (sans sa nature grammaticale).
function dicoMot(cls = ''){
  const d = state.dico || {};
  return qcard(cls.includes('aloud') ? ic('voice') + 'Le mot à lire' : 'Le mot du Dico',
    `<span class="dmot">${esc(d.word || '')}</span>`, cls);
}
// Qui a fini d'écrire ou de voter, comme dans les autres jeux.
function dicoSuivi(faits, mot){
  const r = state.room, autres = state.players.filter(p => p.id !== r.reader_id && p.active !== false);
  const reste = autres.filter(p => !faits.includes(p.id)), n = autres.length - reste.length;
  return `<p class="meta" style="margin-top:18px">${n}/${autres.length} ${mot}</p>
    <div class="bar"><i style="width:${autres.length ? Math.round(n / autres.length * 100) : 0}%"></i></div>
    ${waiting(reste, 'Tout le monde a fini.')}`;
}

// Rédaction : le meneur lit le mot (il voit la vraie définition), les autres en inventent une.
function dicoWrite(){
  const r = state.room, d = state.dico || {}, suivi = dicoSuivi(d.written || [], 'ont écrit');
  if (isMe(r.reader_id)) return `
    <p class="role"><b>Lis le mot à voix haute.</b> Les autres en écrivent une définition.</p>
    ${dicoMot('aloud short')}
    <section class="dbox dtrue"><p class="eyebrow">La vraie définition, toi seul la vois</p><p>${esc(d.definition || '')}</p></section>
    ${suivi}`;
  if (d.mine) return `
    <p class="role"><b>Définition envoyée.</b> Elle sera mélangée avec la vraie.</p>
    ${dicoMot('short')}
    <section class="dbox"><p class="eyebrow">Ta définition</p><p>${esc(d.mine)}</p></section>
    ${suivi}`;
  return `
    <p class="role"><b>${nameOf(r.reader_id)}</b> a choisi un mot. Invente sa définition, façon dictionnaire.</p>
    ${dicoMot('short')}
    <label class="dwrite"><span>Ta définition</span><textarea id="dico-def" rows="3" maxlength="300" autocapitalize="sentences">${esc(dicoDraft)}</textarea></label>
    <div class="dock"><button class="btn" data-act="dico-send" ${dis()}>Envoyer ma définition</button></div>`;
}

// Vote : toutes les définitions, mélangées. Le meneur les lit à voix haute ;
// les autres touchent celle qu'ils croient vraie (pas la leur), et peuvent
// changer d'avis tant que tout le monde n'a pas voté.
function dicoVote(){
  const r = state.room, d = state.dico || {}, moi = isMe(r.reader_id), defs = d.defs || [];
  const items = defs.map((x, i) => moi
    ? `<li><div class="ddef big"><span class="dnum">${i + 1}</span><span class="dtx">${esc(x.text)}</span></div></li>`
    : `<li><button type="button" class="ddef${x.id === d.my_vote ? ' on' : ''}${x.mine ? ' own' : ''}" data-act="dico-vote" data-id="${x.id}"
        aria-pressed="${x.id === d.my_vote}" ${x.mine ? 'disabled' : dis()}><span class="dnum">${i + 1}</span><span class="dtx">${esc(x.text)}${
        x.mine ? '<small>Ta définition</small>' : ''}</span></button></li>`).join('');
  return `
    <p class="role">${moi ? '<b>Lis toutes les définitions à voix haute</b>, dans cet ordre.'
      : d.my_vote ? '<b>Vote enregistré.</b> Tu peux encore changer d’avis.' : '<b>Laquelle est la vraie ?</b> Écoute, puis touche ta réponse.'}</p>
    ${dicoMot('short')}
    <ol class="ddefs">${items}</ol>
    ${dicoSuivi(d.voted || [], 'ont voté')}`;
}

// Révélation : la vraie définition et qui l'a trouvée, puis chaque fausse avec
// son auteur et les joueurs qu'elle a dupés.
function dicoReveal(){
  const r = state.room, d = state.dico || {}, defs = d.defs || [];
  const vraie = defs.find(x => x.is_true), fausses = defs.filter(x => !x.is_true && P(x.author_id));
  const qui = ids => `<div class="found">${(ids || []).length
    ? ids.map(id => `<span class="chip">${nameOf(id)}</span>`).join('') : 'Personne'}</div>`;
  const pts = (d.points || []).filter(x => P(x.player_id)).sort((a, b) => b.points - a.points);
  return `
    <p class="role">La vraie définition de <b>${esc(d.word || '')}</b></p>
    ${qcard(esc(d.word || ''), esc(d.definition || vraie?.text || ''), 'win dtruecard',
      `<span class="by">Trouvée par</span>${qui(vraie?.voters)}`)}
    ${fausses.length ? `<h3 class="sec">Les fausses définitions</h3>
    <ol class="dfakes">${fausses.map(x => { const n = (x.voters || []).length; return `<li class="dbox">
      <p>${esc(x.text)}</p>
      <p class="dby"><span><b>${isMe(x.author_id) ? 'Toi' : nameOf(x.author_id)}</b> · ${n ? `${n} joueur${n > 1 ? 's' : ''} dupé${n > 1 ? 's' : ''}` : 'personne n’y a cru'}</span></p>
      ${n ? qui(x.voters) : ''}</li>` }).join('')}</ol>` : ''}
    <h3 class="sec">Points de la manche</h3>
    <ol class="rank">${pts.map(x => `<li><span class="nm"><span class="who">${nameOf(x.player_id)}</span>${
      x.player_id === r.reader_id ? '<span class="tag host">meneur</span>' : ''}</span><b class="plus" data-n="${x.points}">+${x.points}</b></li>`).join('')}</ol>
    <h3 class="sec">Classement</h3>${rank()}`;
}

/* ---------- Actions ---------- */
// Le livre s'ouvre et se feuillette sur le téléphone du meneur
surAction('dico-open', () => dicoOuvrir(false), { marque:false });
surAction('dico-flip', () => dicoOuvrir(true), { marque:false });
surAction('dico-entry', el => { dicoSel = +el.dataset.i; render() }, { marque:false });
surAction('dico-choose', () => {
  const e = dicoPage?.mots?.[dicoSel]; if (!e) return;
  return act('dico_pick', { p_word:e[0], p_nature:e[1], p_def:e[2] });
});
surAction('dico-send', () => {
  const t = (document.getElementById('dico-def')?.value || '').trim();
  if (t.length < 3) return toast('Écris une définition.');
  return act('dico_write', { p_text:t });
});
surAction('dico-vote', el => act('dico_vote', { p_def:el.dataset.id }));
document.addEventListener('input', e => {
  if (e.target.id === 'dico-def') { dicoDraft = e.target.value; autoGrow(e.target) }
});
