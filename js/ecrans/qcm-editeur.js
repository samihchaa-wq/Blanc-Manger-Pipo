// QCM : préparer son quiz (questions, 2 à 4 réponses, la bonne, points,
// commentaire montré avec la réponse), le choisir pour la partie et le
// retrouver sur ce téléphone. L'éditeur s'ouvre depuis le salon, par-dessus la
// partie (qui continue de se rafraîchir derrière) ; chaque question validée
// part tout de suite au serveur.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

/* ---------- Les quiz de ce téléphone ---------- */
// [{ id, key, title, n }], le plus récent d'abord. Le code (key) suffit à
// rouvrir un quiz : c'est lui qu'on garde, l'identifiant sert à le reconnaître.
const mesQuiz = () => {
  try { const l = JSON.parse(localStorage.getItem('pdcat-qcm') || '[]'); return Array.isArray(l) ? l.filter(x => x && x.key) : [] }
  catch { return [] }
};
function retenirQuiz(q){
  if (!q?.key) return;
  const l = mesQuiz().filter(x => x.key !== q.key && !(q.id && x.id === q.id));
  l.unshift({ id:q.id || null, key:q.key, title:q.title || 'Mon quiz', n:Array.isArray(q.questions) ? q.questions.length : +q.n || 0 });
  try { localStorage.setItem('pdcat-qcm', JSON.stringify(l.slice(0, 20))) } catch {}
}
function oublierQuiz(key){
  try { localStorage.setItem('pdcat-qcm', JSON.stringify(mesQuiz().filter(x => x.key !== key))) } catch {}
}
const nbQuestions = n => `${n} question${n > 1 ? 's' : ''}`;

/* ---------- Le quiz dans le salon ---------- */
let qcmChoix = false, qcmKeyDraft = '';
// L'encart du quiz dans le panneau du jeu : son titre pour tout le monde ;
// pour l'hôte, de quoi le choisir, le créer ou le modifier.
function qcmLobby(host){
  const q = state.qcm?.quiz;
  const anim = `<p class="hint qcm-anim">${host ? 'Tu animes : tu verras les bonnes réponses et tu ne joueras pas.'
    : `<b>${nameOf(state.room.host_id)}</b> anime le quiz.`}</p>`;
  if (!host) return `<div class="qcmbox"><p class="eyebrow">Le quiz</p>
      ${q ? `<p class="qcm-titre">${esc(q.title)}</p><p class="gsub">${nbQuestions(q.count)}</p>` : '<p class="gsub">Pas encore choisi.</p>'}${anim}</div>`;
  if (q && !qcmChoix) return `<div class="qcmbox"><p class="eyebrow">Le quiz</p>
      <p class="qcm-titre">${esc(q.title)}</p><p class="gsub">${q.count ? nbQuestions(q.count) : 'Aucune question pour l’instant'}</p>
      <div class="qcm-acts">
        <button type="button" class="btn alt small" data-act="qcm-edit" ${dis()}>${q.count ? 'Modifier les questions' : 'Écrire les questions'}</button>
        <button type="button" class="btn ghost small" data-act="qcm-change">Changer de quiz</button>
      </div>${anim}</div>`;
  const l = mesQuiz();
  return `<div class="qcmbox"><p class="eyebrow">Le quiz</p>
      ${l.length ? `<p class="gsub">Tes quiz sur ce téléphone</p>
      <ul class="qcm-mine">${l.map((x, i) => `<li><button type="button" class="qcm-pick${q?.id && x.id === q.id ? ' on' : ''}" data-act="qcm-use" data-i="${i}" ${dis()}>
        <b>${esc(x.title)}</b><small>${nbQuestions(x.n)}</small></button></li>`).join('')}</ul>`
      : '<p class="gsub">Écris ton quiz ici : il reste enregistré jusqu’à la soirée.</p>'}
      <button type="button" class="btn alt small" data-act="qcm-new" ${dis()}>Créer un nouveau quiz</button>
      <div class="qcm-code"><label class="field"><span>Code d’un quiz déjà écrit</span>
        <input id="qcm-key" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="16" placeholder="XXXX-XXXX-XXXX" value="${esc(qcmKeyDraft)}"></label>
        <button type="button" class="btn ghost small" data-act="qcm-key" ${dis()}>Ouvrir</button></div>
      ${q ? `<button type="button" class="rulesbtn" data-act="qcm-change">Garder « ${esc(q.title)} »</button>` : ''}
      ${anim}</div>`;
}

// Appel au serveur pour le salon ou l'éditeur, sans passer par act() : on a
// besoin de la réponse (le quiz, son code) et de nos propres messages.
// Renvoie { ok, data } ou { ok:false, erreur }.
async function qcmAppel(fn, args, el){
  if (busy) return { ok:false, erreur:'' };
  busy = true;
  if (el?.isConnected) { el.disabled = true; el.classList.add('pending') }
  try { return { ok:true, data:await rpc(fn, args) } }
  catch (e) { toast(e.message); return { ok:false, erreur:e.message } }
  finally { busy = false; render() }
}
// Choisit le quiz de la partie avec son code, et le retient sur ce téléphone.
async function qcmChoisir(key, el){
  if (!session) return false;
  const rep = await qcmAppel('qcm_select', { p_code:session.code, p_token:session.token, p_key:key }, el);
  if (!rep.ok) {
    // un quiz retenu ici mais disparu du serveur (supprimé, ou oublié après un an)
    if (/inconnu/i.test(rep.erreur) && mesQuiz().some(x => x.key === key)) { oublierQuiz(key); render() }
    return false;
  }
  const d = rep.data;
  retenirQuiz({ id:d.id, key, title:d.title, n:d.count });
  qcmChoix = false; qcmKeyDraft = '';
  ping(); await refresh(true);
  return true;
}

/* ---------- L'éditeur ---------- */
// { id, key, title, questions, ouvert:null|'new'|index, d:brouillon, envoi, etat }
let qcmEd = null, qcmTitreTimer = null, qcmFile = Promise.resolve();
const qcmVierge = () => ({ text:'', choices:['', '', '', ''], correct:0, points:1, note:'' });
function qcmBrouillon(i){
  const q = qcmEd.questions[i];
  return q ? { text:q.text, choices:[...q.choices, '', '', '', ''].slice(0, 4), correct:q.correct, points:q.points || 1, note:q.note || '' } : qcmVierge();
}
// La question en cours d'écriture a-t-elle changé depuis son ouverture ?
function qcmModifie(){
  const e = qcmEd;
  if (!e || e.ouvert === null || !e.d) return false;
  const base = e.ouvert === 'new' ? qcmVierge() : qcmBrouillon(e.ouvert);
  return JSON.stringify(base) !== JSON.stringify(e.d);
}
function qcmOuvrir(quiz, nouvelle = false){
  qcmEd = { id:quiz.id, key:quiz.key, title:quiz.title, questions:quiz.questions || [], ouvert:null, d:null, envoi:false, etat:'' };
  retenirQuiz(quiz);
  if (nouvelle) { qcmEd.ouvert = 'new'; qcmEd.d = qcmVierge() }
  scrollTo(0, 0);
  render();
  if (nouvelle) document.getElementById('qe-text')?.focus();
}
function qcmFermer(){
  if (qcmModifie() && !confirm('Abandonner la question en cours ?')) return;
  clearTimeout(qcmTitreTimer);
  const e = qcmEd;
  // un titre tapé juste avant de fermer part quand même
  if (e && e.titreAEnvoyer && e.title.trim()) qcmSauver(e.questions);
  qcmEd = null;
  scrollTo(0, 0);
  render();
  qcmFile.then(() => { ping(); if (session) refresh(true) });
}

function qcmEditorView(){
  const e = qcmEd, n = e.questions.length, libre = e.ouvert === null;
  const lignes = e.questions.map((q, i) => e.ouvert === i ? qcmForm(i) : qcmLigne(q, i, n)).join('');
  return `
    <div class="top"><div class="top-l"><span class="round">Ton quiz</span></div><span class="qe-etat" aria-live="polite">${esc(e.etat)}</span></div>
    <section class="panel qe-head">
      <label class="field"><span>Titre du quiz</span><input id="qe-title" maxlength="60" autocomplete="off" placeholder="Ex. : Fin de saison 2026" value="${esc(e.title)}"></label>
      <div class="qe-key"><span>Code secret</span><b>${esc(e.key)}</b>
        <button type="button" class="btn ghost small" data-act="qe-copy">${ic('copy')}Copier</button></div>
      <p class="hint">Il rouvre ce quiz sur un autre téléphone. Note-le quelque part, et ne le donne pas aux joueurs : il montre les réponses.</p>
    </section>
    <h3 class="sec">Questions · ${n}</h3>
    ${n ? `<ol class="qe-list">${lignes}</ol>` : e.ouvert === 'new' ? '' : '<p class="hint qe-vide">Aucune question pour l’instant.</p>'}
    ${e.ouvert === 'new' ? `<ol class="qe-list">${qcmForm('new')}</ol>`
      : libre && n < 100 ? '<button type="button" class="btn ghost qe-add" data-act="qe-add">+ Ajouter une question</button>' : ''}
    ${libre ? '<button type="button" class="link qe-delquiz" data-act="qe-delete">Supprimer ce quiz</button>' : ''}
    <div class="dock"><button class="btn" data-act="qe-close">Retour au salon</button></div>`;
}

function qcmLigne(q, i, n){
  const off = qcmEd.ouvert !== null ? 'disabled' : '';
  return `<li class="qe-item"><span class="qe-n">${i + 1}</span>
    <span class="qe-t">${esc(q.text)}<small>${q.choices.length} réponses · bonne : ${QCM_LETTRES[q.correct]} · ${q.points} point${q.points > 1 ? 's' : ''}${q.note ? ' · commentaire' : ''}</small></span>
    <span class="qe-acts">
      <button type="button" data-act="qe-up" data-i="${i}" aria-label="Monter la question ${i + 1}" ${i === 0 ? 'disabled' : off}>${ic('haut')}</button>
      <button type="button" data-act="qe-down" data-i="${i}" aria-label="Descendre la question ${i + 1}" ${i === n - 1 ? 'disabled' : off}>${ic('bas')}</button>
      <button type="button" data-act="qe-edit" data-i="${i}" aria-label="Modifier la question ${i + 1}" ${off}>${ic('pen')}</button>
    </span></li>`;
}

function qcmForm(i){
  const d = qcmEd.d, neuf = i === 'new', num = neuf ? qcmEd.questions.length + 1 : i + 1;
  return `<li class="qe-form customchallenge" data-qform="1">
    <label class="field"><span>Question ${num}</span>
      <textarea id="qe-text" rows="2" maxlength="200" data-qordre="0" enterkeyhint="next" placeholder="Ex. : Qui a marqué le plus de buts cette saison ?">${esc(d.text)}</textarea></label>
    <p class="qe-lab">Réponses <small>Touche la lettre de la bonne réponse.</small></p>
    <ul class="qe-choices">${[0, 1, 2, 3].map(k => `<li>
      <button type="button" class="qe-letter c${k}${d.correct === k ? ' on' : ''}" data-act="qe-correct" data-k="${k}" aria-pressed="${d.correct === k}"
        aria-label="Réponse ${QCM_LETTRES[k]}${d.correct === k ? ' : bonne réponse' : ' : en faire la bonne réponse'}">${d.correct === k ? ic('check') : QCM_LETTRES[k]}</button>
      <input id="qe-c${k}" maxlength="80" autocomplete="off" data-qordre="${k + 1}" enterkeyhint="next"
        placeholder="${k < 2 ? `Réponse ${QCM_LETTRES[k]}` : `Réponse ${QCM_LETTRES[k]} (facultative)`}" value="${esc(d.choices[k])}"></li>`).join('')}</ul>
    <button type="button" class="btn ghost small qe-vf" data-act="qe-vf">Remplir Vrai / Faux</button>
    <div class="rrow qe-pts"><span>Points pour la bonne réponse</span><div class="seg s3" role="group" aria-label="Points">${[1, 2, 3].map(p =>
      `<button type="button" class="seg-b${d.points === p ? ' on' : ''}" data-act="qe-points" data-v="${p}" aria-pressed="${d.points === p}">${p}</button>`).join('')}</div></div>
    <label class="field"><span>Commentaire après la réponse <small>facultatif</small></span>
      <input id="qe-note" maxlength="200" autocomplete="off" data-qordre="5" enterkeyhint="done" placeholder="Ex. : C’était contre Saint-Denis, 4-2 !" value="${esc(d.note)}"></label>
    <div class="qe-formacts">
      <button type="button" class="btn small" data-act="qe-save" ${qcmEd.envoi ? 'disabled' : ''}>${neuf ? 'Ajouter la question' : 'Enregistrer'}</button>
      <button type="button" class="btn ghost small" data-act="qe-cancel">${neuf ? 'Fermer' : 'Annuler'}</button>
      ${neuf ? '' : `<button type="button" class="btn ghost small qe-suppr" data-act="qe-remove" data-i="${i}">Supprimer</button>`}
    </div></li>`;
}
function qcmApresRendu(){ document.querySelectorAll('.qe-form textarea').forEach(autoGrow) }

// Vérifie la question avant l'envoi (le serveur refait les mêmes contrôles).
// Les réponses vides sont retirées : A, B et D remplies donnent trois réponses.
function qcmValide(d){
  const net = t => String(t || '').trim().replace(/\s+/g, ' ');
  const text = net(d.text);
  if (text.length < 3) return [null, 'Écris la question.'];
  const remplies = d.choices.map((c, k) => [net(c), k]).filter(([c]) => c);
  if (remplies.length < 2) return [null, 'Il faut au moins deux réponses.'];
  if (!net(d.choices[d.correct])) return [null, 'La bonne réponse est vide : touche la lettre d’une réponse remplie.'];
  const vues = new Set();
  for (const [c] of remplies) {
    if (vues.has(c.toLowerCase())) return [null, 'Deux réponses sont identiques.'];
    vues.add(c.toLowerCase());
  }
  return [{ text, choices:remplies.map(([c]) => c), correct:remplies.findIndex(([, k]) => k === d.correct),
    points:d.points, note:net(d.note) }, null];
}

// Enregistre le quiz entier, un envoi après l'autre.
function qcmSauver(questions){
  const e = qcmEd;
  if (!e) return Promise.resolve(false);
  const titre = e.title;
  e.titreAEnvoyer = false;
  const envoi = qcmFile.then(async () => {
    e.envoi = true; e.etat = 'Enregistrement…'; if (qcmEd === e) render();
    try {
      const quiz = await rpc('qcm_quiz_save', { p_key:e.key, p_title:titre, p_questions:questions });
      e.questions = quiz.questions;
      // pas de retouche du titre pendant qu'on le tape
      if (document.activeElement?.id !== 'qe-title') e.title = quiz.title;
      e.etat = 'Enregistré';
      retenirQuiz(quiz);
      return true;
    } catch (err) {
      toast(err.message); e.etat = '';
      return false;
    } finally { e.envoi = false; if (qcmEd === e) render() }
  });
  qcmFile = envoi.catch(() => false);
  return envoi;
}

/* ---------- Actions : salon ---------- */
surAction('qcm-change', () => { qcmChoix = !qcmChoix; render() }, { marque:false });
surAction('qcm-use', el => {
  const x = mesQuiz()[+el.dataset.i];
  if (x) return qcmChoisir(x.key, el);
}, { marque:false });
surAction('qcm-key', el => {
  const k = (document.getElementById('qcm-key')?.value || '').trim();
  if (k.replace(/[^A-Za-z0-9]/g, '').length !== 12) return toast('Le code d’un quiz fait 12 caractères (XXXX-XXXX-XXXX).');
  return qcmChoisir(k, el);
}, { marque:false });
surAction('qcm-new', async el => {
  const rep = await qcmAppel('qcm_quiz_create', { p_title:'Mon quiz' }, el);
  if (!rep.ok) return;
  const quiz = rep.data;
  retenirQuiz(quiz);
  if (await qcmChoisir(quiz.key)) qcmOuvrir(quiz, true);
}, { marque:false });
surAction('qcm-edit', async el => {
  const id = state.qcm?.quiz?.id, x = mesQuiz().find(q => q.id && q.id === id);
  if (!x) { qcmChoix = true; render(); return toast('Ce quiz vient d’un autre téléphone : entre son code pour le modifier ici.') }
  const rep = await qcmAppel('qcm_quiz_get', { p_key:x.key }, el);
  if (rep.ok) qcmOuvrir(rep.data);
}, { marque:false });

/* ---------- Actions : éditeur ---------- */
surAction('qe-close', () => qcmFermer(), { marque:false });
surAction('qe-copy', async () => {
  const k = qcmEd?.key; if (!k) return;
  try { await navigator.clipboard.writeText(k); toast('Code copié : garde-le précieusement.') }
  catch { prompt('Copie ce code et garde-le :', k) }
}, { marque:false });
surAction('qe-add', () => {
  qcmEd.ouvert = 'new'; qcmEd.d = qcmVierge(); render();
  document.getElementById('qe-text')?.focus();
}, { marque:false });
surAction('qe-edit', el => {
  const i = +el.dataset.i;
  qcmEd.ouvert = i; qcmEd.d = qcmBrouillon(i); render();
  document.getElementById('qe-text')?.focus();
}, { marque:false });
surAction('qe-cancel', () => { qcmEd.ouvert = null; qcmEd.d = null; render() }, { marque:false });
surAction('qe-correct', el => { qcmEd.d.correct = +el.dataset.k; render() }, { marque:false });
surAction('qe-points', el => { qcmEd.d.points = +el.dataset.v; render() }, { marque:false });
surAction('qe-vf', () => {
  qcmEd.d.choices = ['Vrai', 'Faux', '', ''];
  if (qcmEd.d.correct > 1) qcmEd.d.correct = 0;
  render();
}, { marque:false });
surAction('qe-save', async () => {
  const e = qcmEd, [q, erreur] = qcmValide(e.d);
  if (erreur) return toast(erreur);
  const liste = [...e.questions], neuf = e.ouvert === 'new';
  if (neuf) liste.push(q); else liste[e.ouvert] = q;
  if (!(await qcmSauver(liste)) || qcmEd !== e) return;
  // une question ajoutée : on enchaîne directement sur la suivante
  if (neuf && e.questions.length < 100) { e.d = qcmVierge(); toast(`Question ${e.questions.length} ajoutée.`) }
  else { e.ouvert = null; e.d = null }
  render();
  if (e.ouvert === 'new') document.getElementById('qe-text')?.focus();
}, { marque:false });
surAction('qe-remove', async el => {
  const e = qcmEd, i = +el.dataset.i;
  if (!confirm(`Supprimer la question ${i + 1} ?`)) return;
  const liste = e.questions.filter((_, k) => k !== i);
  if (await qcmSauver(liste) && qcmEd === e) { e.ouvert = null; e.d = null; render() }
}, { marque:false });
const qcmDeplacer = (i, j) => {
  const l = [...qcmEd.questions];
  if (j < 0 || j >= l.length) return;
  [l[i], l[j]] = [l[j], l[i]];
  return qcmSauver(l);
};
surAction('qe-up', el => qcmDeplacer(+el.dataset.i, +el.dataset.i - 1), { marque:false });
surAction('qe-down', el => qcmDeplacer(+el.dataset.i, +el.dataset.i + 1), { marque:false });
surAction('qe-delete', async el => {
  const e = qcmEd;
  if (!confirm(`Supprimer définitivement le quiz « ${e.title} » et toutes ses questions ?`)) return;
  if (!(await qcmAppel('qcm_quiz_delete', { p_key:e.key }, el)).ok) return;
  oublierQuiz(e.key);
  qcmEd = null; qcmChoix = false;
  toast('Quiz supprimé.');
  render();
  ping(); if (session) refresh(true);
}, { marque:false });

// Brouillons : la saisie survit aux rafraîchissements de l'écran.
document.addEventListener('input', e => {
  const t = e.target;
  if (t.id === 'qcm-key') { qcmKeyDraft = t.value; return }
  if (!qcmEd) return;
  if (t.id === 'qe-title') {
    qcmEd.title = t.value; qcmEd.titreAEnvoyer = true;
    clearTimeout(qcmTitreTimer);
    qcmTitreTimer = setTimeout(() => {
      if (qcmEd && qcmEd.title.trim()) qcmSauver(qcmEd.questions);
    }, 900);
    return;
  }
  if (!qcmEd.d) return;
  if (t.id === 'qe-text') { qcmEd.d.text = t.value; autoGrow(t) }
  else if (t.id === 'qe-note') qcmEd.d.note = t.value;
  else { const m = /^qe-c([0-3])$/.exec(t.id); if (m) qcmEd.d.choices[+m[1]] = t.value }
});
// Entrée passe au champ suivant, puis valide la question ; une question tient
// sur une ligne (pas de saut de ligne dans son texte).
document.addEventListener('keydown', e => {
  if (e.key !== 'Enter') return;
  if (e.target.matches('#qcm-key')) { e.preventDefault(); return document.querySelector('[data-act=qcm-key]')?.click() }
  const box = e.target.closest('[data-qform]');
  if (!box || !e.target.matches('[data-qordre]')) return;
  e.preventDefault();
  const suivant = box.querySelector(`[data-qordre="${+e.target.dataset.qordre + 1}"]`);
  if (suivant) return suivant.focus();
  box.querySelector('[data-act=qe-save]')?.click();
});
