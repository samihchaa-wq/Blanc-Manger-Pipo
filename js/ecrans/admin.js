// Admin : un seul écran, piloté par la description des catalogues ci-dessous.
// Code simple : ajouter des cartes. Code admin + : aussi consulter, chercher,
// modifier, supprimer, et choisir le code Private Joke du groupe.
// S'ouvre par cinq appuis rapides sur le logo de l'accueil.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

// Les catalogues, rangés par jeu. Chaque catalogue décrit ses champs (texte
// principal, puis un ou deux champs courts) : le formulaire d'ajout, la liste
// et la modification en place en découlent. Le paquet Normal de Phrases à trou
// s'écrit dans les migrations : seules les Private jokes s'ajoutent ici.
const CATALOGUES = {
  phrases:  [{ k:'q', titre:'Questions', mot:'question', trous:true,
               champs:[{ id:'text', label:'Nouvelle question', max:150, ph:'Mon pire cauchemar : ____.' }] },
             { k:'j', titre:'Private jokes', mot:'réponse', forme:true,
               champs:[{ id:'text', label:'Nouvelle réponse Private Joke', max:80, ph:'Le katana d’Alain' }] }],
  priorites:[{ k:'p', titre:'Cartes', mot:'carte',
               champs:[{ id:'text', label:'Nouvelle carte', max:80, ph:'Un apéro au soleil' }] }],
  ondes:    [{ k:'w', titre:'Extrêmes', mot:'carte',
               champs:[{ id:'left', label:'Extrême gauche', max:40, ph:'Glacial' }, { id:'right', label:'Extrême droite', max:40, ph:'Brûlant' }] }],
  white:    [{ k:'m', titre:'Paires de mots', mot:'paire',
               champs:[{ id:'left', label:'Mot des Civils', max:60, ph:'Plage' }, { id:'right', label:'Mot de l’imposteur', max:60, ph:'Piscine' }] }],
  mimes:    [{ k:'x', titre:'Actions', mot:'action',
               champs:[{ id:'text', label:'Action à mimer', max:80, ph:'Mange un citron' },
                       { id:'left', label:'Intensité 1', max:60, ph:'c’est sucré' }, { id:'right', label:'Intensité 10', max:60, ph:'c’est atrocement acide' }] }],
};
const catDe = k => Object.values(CATALOGUES).flat().find(c => c.k === k);
const jeuDe = k => Object.keys(CATALOGUES).find(g => CATALOGUES[g].some(c => c.k === k));
const Mot = m => m.charAt(0).toUpperCase() + m.slice(1);

// Le code admin ne vit qu'en mémoire : jamais dans le fichier, jamais stocké.
let adminOpen = false, adminPwd = '', adminLevel = '';
let adminTab = 'j', adminLast = {};   // catalogue ouvert, et le dernier ouvert dans chaque jeu
let catalog = { kind:'j', total:0, items:[], q:'' }, catTimer = null;
let adminDraft = {};    // formulaire d'ajout en cours, par champ
let adminEdit = null;   // carte en cours de modification : { id, text, left, right }
let pjNew = '';         // nouveau code Private Joke (admin +)

function ouvrirAdmin(){
  adminOpen = true; adminTab = 'j'; adminLast = {}; adminDraft = {}; adminEdit = null;
  catalog = { kind:'j', total:0, items:[], q:'' };
  render();
}
function fermerAdmin(){
  adminOpen = false; adminPwd = ''; adminLevel = ''; adminTab = 'j'; adminLast = {}; adminDraft = {}; adminEdit = null; pjNew = '';
  catalog = { kind:'j', total:0, items:[], q:'' };
  render();
}

// Un champ du formulaire : la question est une zone qui grandit, le reste une ligne.
function champ(c, f, prefixe, valeur, i, n){
  const id = `${prefixe}-${f.id}`, dernier = i === n - 1;
  // En modification, « Nouvelle question » devient « Question ».
  const label = prefixe === 'e' ? Mot(f.label.replace(/^Nouvel(le)? /, '')) : f.label;
  const attrs = `id="${id}" data-ordre="${i}" maxlength="${f.max}" autocomplete="off" placeholder="Ex. : ${esc(f.ph)}" enterkeyhint="${dernier ? 'done' : 'next'}"`;
  const saisie = c.trous && f.id === 'text'
    ? `<textarea ${attrs} rows="1">${esc(valeur)}</textarea>`
    : `<input ${attrs} value="${esc(valeur)}">`;
  return `<label class="field"><span>${label}</span>${saisie}</label>`;
}

function adminView(){
  const plus = adminLevel === 'plus', k = adminTab, c = catDe(k), jeu = jeuDe(k), sous = CATALOGUES[jeu];
  const haut = `<div class="top">
      <div class="top-l"><span class="round">${plus ? 'Admin +' : 'Admin'}</span></div>
      <button class="link" data-act="admin-close">Retour</button>
    </div>`;
  if (!adminLevel) return haut + `<section class="panel">
      <p class="eyebrow">Accès réservé</p>
      <label class="field"><span>Code admin</span><input id="a-code" type="password" autocomplete="off" enterkeyhint="go" placeholder="••••••••"></label>
      <button class="btn" data-act="admin-login">Entrer</button>
    </section>`;
  const form = c.champs.map((f, i) => champ(c, f, 'a', adminDraft[f.id] || '', i, c.champs.length)).join('');
  return haut + `
    <div class="tabs jeux" role="tablist" aria-label="Jeu">
      ${Object.keys(CATALOGUES).map(g =>
        `<button class="tab ${jeu === g ? 'on' : ''}" data-act="admin-game" data-game="${g}" role="tab" aria-selected="${jeu === g}">${GAMES[g].name}</button>`).join('')}
    </div>
    ${sous.length > 1 ? `<div class="soustabs" role="tablist" aria-label="Catalogue">
      ${sous.map(x => `<button type="button" class="soustab ${k === x.k ? 'on' : ''}" data-act="admin-tab" data-tab="${x.k}" role="tab" aria-selected="${k === x.k}">${x.titre}</button>`).join('')}
    </div>` : ''}
    <section class="panel adminform" data-form="a">
      ${form}
      ${c.trous ? `<div class="holebar">
        <button class="btn ghost small" data-act="hole-add">+ Ajouter un trou</button>
        <span class="meta" id="hole-count">0 trou sur 2</span>
      </div>` : ''}
      <button class="btn" data-act="admin-add">Ajouter</button>
    </section>
    ${plus ? catalogueView(c) : `<p class="hint">Avec le code admin +, tu peux aussi consulter, modifier et supprimer les cartes.</p>`}
    ${plus && k === 'j' ? `<section class="panel pjset">
      <h3 class="sec">Code Private Joke</h3>
      <p class="hint">À donner à ton groupe : il débloque le mode Private Joke dans le salon. Ton code admin le débloque toujours.</p>
      <label class="field"><span>Nouveau code (4 caractères au moins)</span><input id="pj-new" type="text" autocomplete="off" maxlength="40" value="${esc(pjNew)}"></label>
      <button class="btn alt" data-act="admin-pj">Enregistrer le code</button>
    </section>` : ''}`;
}

// La liste du catalogue (admin +) : recherche, cartes, modification en place.
function catalogueView(c){
  const mot = c.mot, n = catalog.total;
  const lignes = catalog.items.length ? catalog.items.map(x => adminEdit?.id === x.id ? ligneEdition(c, x) : ligne(c, x)).join('')
    : `<li class="empty">Aucune ${mot}.</li>`;
  return `
    <h3 class="sec">Catalogue · ${n} ${mot}${n > 1 ? 's' : ''}</h3>
    ${c.forme ? `<p class="hint">Nom ou Verbe : sert à accorder la réponse dans la phrase. Touche l’étiquette pour la corriger.</p>` : ''}
    <input class="searchfield" id="cat-q" placeholder="Rechercher" autocomplete="off" value="${esc(catalog.q)}">
    <ul class="catlist">${lignes}</ul>
    ${catalog.items.length < n ? `<button class="btn ghost" data-act="admin-more">Afficher plus (${n - catalog.items.length})</button>` : ''}`;
}
function ligne(c, x){
  const badge = c.k === 'q' ? (x.blanks > 1 ? '<span class="form two">2 trous</span>' : '')
    : c.k === 'p' ? `<span class="form theme">${esc(x.theme)}</span>`
    : c.forme ? `<button class="form ${x.form === 'v' ? 'v' : 'n'}" data-act="admin-form" data-id="${x.id}"
        aria-label="${x.form === 'v' ? 'Verbe : toucher pour passer en Nom' : 'Nom : toucher pour passer en Verbe'}">${x.form === 'v' ? 'Verbe' : 'Nom'}</button>` : '';
  const texte = c.k === 'x' ? `${esc(x.text)}<small class="sous">1 : ${esc(x.left)} · 10 : ${esc(x.right)}</small>`
    : x.text == null ? `${esc(x.left)} <span class="sep" aria-hidden="true">↔</span> ${esc(x.right)}`
    : esc(x.text);
  return `<li>${badge}<span class="ct">${texte}</span>
      <button class="edit" data-act="admin-edit" data-id="${x.id}" aria-label="Modifier">${ic('pen')}</button>
      <button class="del" data-act="admin-del" data-id="${x.id}" aria-label="Supprimer">${ic('x')}</button></li>`;
}
function ligneEdition(c, x){
  return `<li class="editing" data-form="e">
      <div class="efields">${c.champs.map((f, i) => champ(c, f, 'e', adminEdit[f.id] ?? '', i, c.champs.length)).join('')}</div>
      <div class="eacts">
        <button class="btn small" data-act="admin-save" data-id="${x.id}">Enregistrer</button>
        <button class="btn ghost small" data-act="admin-edit-cancel">Annuler</button>
      </div></li>`;
}

// On compte les suites de deux tirets bas et plus : c'est ce que le serveur
// normalise ensuite en « ____ ».
const compteTrous = t => (String(t || '').match(/_{2,}/g) || []).length;
function majTrous(){
  const champ = document.getElementById('a-text'), etiq = document.getElementById('hole-count');
  if (!champ || !etiq) return;
  const n = compteTrous(champ.value);
  etiq.textContent = `${n} trou${n > 1 ? 's' : ''} sur 2`;
  const b = document.querySelector('[data-act="hole-add"]');
  if (b) b.disabled = n >= 2;
}
function adminApresRendu(){
  majTrous();
  document.querySelectorAll('.adminform textarea, .editing textarea').forEach(autoGrow);
}

function adminSwitch(k){
  if (!k || k === adminTab) return;
  adminTab = k; adminDraft = {}; adminEdit = null;
  catalog = { kind:k, total:0, items:[], q:'' };
  render();
  if (adminLevel === 'plus') loadCatalog(0);
}
async function loadCatalog(offset = 0){
  if (adminLevel !== 'plus') return;
  const kind = catalog.kind;
  try {
    const d = await rpc('admin_cards_list', { p_password:adminPwd, p_kind:kind, p_search:catalog.q, p_offset:offset });
    if (catalog.kind !== kind) return;   // on a changé de catalogue entre-temps
    catalog.total = d.total;
    catalog.items = offset ? catalog.items.concat(d.items) : d.items;
    render();
  } catch (e) { erreurAdmin(e) }
}
// Code refusé en cours de route (changé entre-temps) : retour à l'écran du code.
function erreurAdmin(e){
  toast(/existe déjà/i.test(e.message) ? Mot(catDe(adminTab).mot) + ' déjà existante.' : e.message);
  if (/Mot de passe/i.test(e.message)) { adminPwd = ''; adminLevel = ''; render() }
}
const valeurs = (c, prefixe) => Object.fromEntries(c.champs.map(f => [f.id, (document.getElementById(`${prefixe}-${f.id}`)?.value || '').trim()]));

/* ---------- Actions ---------- */
surAction('admin-close', fermerAdmin, { marque:false });
// Revenir sur un jeu rouvre le catalogue qu'on y avait laissé.
surAction('admin-game', el => {
  const g = el.dataset.game, cur = jeuDe(adminTab);
  if (!CATALOGUES[g] || g === cur) return;
  adminLast[cur] = adminTab;
  adminSwitch(adminLast[g] || CATALOGUES[g][0].k);
}, { marque:false });
surAction('admin-tab', el => adminSwitch(el.dataset.tab), { marque:false });
surAction('admin-login', async el => {
  const pwd = val('a-code');
  if (!pwd) return toast('Entre le code admin.');
  if (busy) return;
  busy = true; el.disabled = true;
  try {
    // le serveur seul décide du niveau : 'plus' ouvre la consultation et la modification
    const level = await rpc('admin_level', { p_password: pwd });
    if (level === 'none') { toast('Code incorrect.'); el.disabled = false }
    else {
      adminPwd = pwd; adminLevel = level; render();
      if (level === 'plus') loadCatalog(0);
    }
  } catch (e) { toast(e.message); el.disabled = false }
  busy = false;
});
surAction('hole-add', () => {
  const champ = document.getElementById('a-text');
  if (!champ) return;
  if (compteTrous(champ.value) >= 2) return toast('Deux trous au maximum.');
  const d = champ.selectionStart ?? champ.value.length, f = champ.selectionEnd ?? d;
  // Sans l'espace, cliquer après « de » donnerait « de____ ». Pas d'espace
  // après en revanche : la suite est souvent une virgule.
  const bout = (champ.value.slice(0, d) && !/\s$/.test(champ.value.slice(0, d)) ? ' ' : '') + '____';
  // maxlength ne retient que la frappe, pas une insertion par script.
  if (champ.value.length - (f - d) + bout.length > 150) return toast('La phrase dépasse 150 caractères.');
  champ.focus();
  champ.setRangeText(bout, d, f, 'end');
  adminDraft.text = champ.value;
  majTrous();
  autoGrow(champ);
}, { marque:false });
surAction('admin-add', async el => {
  const c = catDe(adminTab), v = valeurs(c, 'a');
  const vide = c.champs.find(f => !v[f.id]);
  if (vide) { toast(`Remplis « ${vide.label} ».`); return document.getElementById('a-' + vide.id)?.focus() }
  if (busy) return;
  busy = true; el.disabled = true;
  try {
    const d = await rpc('admin_card_add', { p_password:adminPwd, p_kind:c.k, p_text:v.text || null, p_left:v.left || null, p_right:v.right || null });
    toast(`Ajoutée. ${d.total} ${c.mot}s ${c.k === 'j' ? 'en Private jokes' : 'au catalogue'}.`);
    adminDraft = {};
    busy = false; render();
    // validé au clavier : on repart du premier champ pour enchaîner les cartes
    document.getElementById('a-' + c.champs[0].id)?.focus();
    if (adminLevel === 'plus') loadCatalog(0);
  } catch (e) { busy = false; el.disabled = false; erreurAdmin(e) }
});
surAction('admin-form', async (el, id) => {
  // Le classement automatique se trompe sur les noms propres qui finissent
  // comme un infinitif (« Vladimir Poutine ») : on corrige d'une touche.
  const item = catalog.items.find(x => String(x.id) === String(id));
  if (!item) return;
  const next = item.form === 'v' ? 'n' : 'v';
  el.disabled = true;
  try {
    await rpc('admin_card_update', { p_password:adminPwd, p_kind:adminTab, p_id:+id, p_form:next });
    item.form = next; render();
  } catch (e) { el.disabled = false; erreurAdmin(e) }
});
surAction('admin-edit', (el, id) => {
  const item = catalog.items.find(x => String(x.id) === String(id));
  if (!item) return;
  adminEdit = { id:item.id, text:item.text, left:item.left, right:item.right };
  render();
  document.querySelector('.editing input, .editing textarea')?.focus();
}, { marque:false });
surAction('admin-edit-cancel', () => { adminEdit = null; render() }, { marque:false });
surAction('admin-save', async (el, id) => {
  const c = catDe(adminTab), v = valeurs(c, 'e');
  const vide = c.champs.find(f => !v[f.id]);
  if (vide) return toast(`Remplis « ${vide.label} ».`);
  el.disabled = true;
  try {
    const d = await rpc('admin_card_update', { p_password:adminPwd, p_kind:c.k, p_id:+id, p_text:v.text || null, p_left:v.left || null, p_right:v.right || null });
    // le serveur renvoie les textes nettoyés (espaces, point final)
    const item = catalog.items.find(x => String(x.id) === String(id));
    if (item) for (const f of c.champs) if (d[f.id] != null) item[f.id] = d[f.id];
    if (item && c.k === 'q') item.blanks = compteTrous(item.text) > 1 ? 2 : 1;
    adminEdit = null; render();
    toast('Modifiée.');
  } catch (e) { el.disabled = false; erreurAdmin(e) }
});
surAction('admin-more', el => { el.disabled = true; return loadCatalog(catalog.items.length) }, { marque:false });
surAction('admin-del', async (el, id) => {
  const c = catDe(catalog.kind), item = catalog.items.find(x => String(x.id) === String(id));
  const nom = !item ? `cette ${c.mot}` : item.text ?? `${item.left} ↔ ${item.right}`;
  if (!confirm(`Supprimer « ${nom} » du catalogue ?`)) return;
  el.disabled = true;
  try {
    await rpc('admin_card_delete', { p_password:adminPwd, p_kind:catalog.kind, p_id:+id });
    catalog.items = catalog.items.filter(x => String(x.id) !== String(id));
    catalog.total = Math.max(0, catalog.total - 1);
    if (adminEdit?.id === +id) adminEdit = null;
    render();
    toast(Mot(c.mot) + ' supprimée.');
  } catch (e) { el.disabled = false; erreurAdmin(e) }
});
surAction('admin-pj', async el => {
  const code = (document.getElementById('pj-new')?.value || '').trim();
  if (code.length < 4) return toast('Le code fait 4 caractères au moins.');
  el.disabled = true;
  try {
    await rpc('admin_set_private_code', { p_password:adminPwd, p_secret:code });
    retenirPJ(code); pjNew = ''; render();
    toast('Code Private Joke enregistré.');
  } catch (e) { el.disabled = false; erreurAdmin(e) }
});
document.addEventListener('input', e => {
  const t = e.target;
  if (t.id === 'cat-q') {
    catalog.q = t.value;
    clearTimeout(catTimer);
    catTimer = setTimeout(() => loadCatalog(0), 300);
    return;
  }
  if (t.id === 'pj-new') { pjNew = t.value; return }
  const m = /^([ae])-(text|left|right)$/.exec(t.id);
  if (!m) return;
  if (m[1] === 'a') adminDraft[m[2]] = t.value; else if (adminEdit) adminEdit[m[2]] = t.value;
  if (t.id === 'a-text') majTrous();
  if (t.tagName === 'TEXTAREA') autoGrow(t);
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Enter') return;
  if (e.target.matches('#a-code')) return document.querySelector('[data-act=admin-login]')?.click();
  if (e.target.matches('#pj-new')) return document.querySelector('[data-act=admin-pj]')?.click();
  // Formulaire d'ajout ou de modification : Entrée passe au champ suivant, puis
  // valide. Une phrase tient sur une ligne : pas de saut de ligne dans la question.
  const box = e.target.closest('[data-form]');
  if (!box || !e.target.matches('[data-ordre]')) return;
  e.preventDefault();
  const suivant = box.querySelector(`[data-ordre="${+e.target.dataset.ordre + 1}"]`);
  if (suivant) return suivant.focus();
  box.querySelector(box.dataset.form === 'a' ? '[data-act=admin-add]' : '[data-act=admin-save]')?.click();
});
