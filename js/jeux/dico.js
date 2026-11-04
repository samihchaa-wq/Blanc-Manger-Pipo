// Le Dico : le meneur ouvre un dictionnaire à une page au hasard et y choisit
// son mot ; les autres en inventent la définition.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Le Dico ---------- */
// Le livre est un ensemble de fichiers statiques (dico/index.json, dico/p000.json…)
// générés depuis le Wiktionnaire : des pages de 8 mots dans l'ordre alphabétique.
// Chaque entrée est [mot, nature abrégée, définition].
let dicoIdx = null, dicoPage = null, dicoSel = null, dicoAnim = '';
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
