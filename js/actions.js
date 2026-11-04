// Actions : clics, saisie, clavier, démarrage de l'appli.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Actions ---------- */
async function enter(call, name){
  if (busy) return;
  busy = true;
  try {
    const d = await call();
    try { localStorage.setItem('pdcat-name', name) } catch {}
    save({ code:d.code, token:d.token });
    history.replaceState(null,'',location.pathname + '?code=' + d.code);
    busy = false; startSession();
  } catch (e) { busy = false; toast(e.message) }
}

document.addEventListener('click', async e => {
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  // un balayage se termine par un clic fantôme : on l'ignore
  if (el.classList.contains('acard') && Date.now() - lastSwipeEnd < 400) return;
  // certains navigateurs n'accordent le verrou d'écran qu'après un geste
  if (session && !wakeLock) keepAwake();
  if (el.dataset.act === 'share') return shareInvite();
  // Le Dico : le livre s'ouvre et se feuillette sur le téléphone du meneur
  if (el.dataset.act === 'dico-open') return dicoOuvrir(false);
  if (el.dataset.act === 'dico-flip') return dicoOuvrir(true);
  if (el.dataset.act === 'dico-entry') { dicoSel = +el.dataset.i; return render() }
  if (el.dataset.act === 'dico-choose') {
    const e = dicoPage?.mots?.[dicoSel]; if (!e) return;
    pressedEl = el;
    return act('dico_pick', { p_word:e[0], p_nature:e[1], p_def:e[2] });
  }
  if (el.dataset.act === 'dico-send') {
    const t = (document.getElementById('dico-def')?.value || '').trim();
    if (t.length < 3) return toast('Écris une définition.');
    pressedEl = el;
    return act('dico_write', { p_text:t });
  }
  if (el.dataset.act === 'dico-vote') { pressedEl = el; return act('dico_vote', { p_def:el.dataset.id }) }
  if (el.dataset.act === 'game-pick') { gamePick = !gamePick; return render() }
  if (el.dataset.act === 'rules') { rulesOpen = !rulesOpen; return render() }
  if (el.dataset.act === 'pun-toggle') {
    optDraft = { ...optDraft, pun: optValue('pun') > 0 ? 0 : PUN_NB };
    clearTimeout(optTimer); optTimer = setTimeout(() => { optTimer = null; sendOpts() }, 600);
    return render();
  }
  if (el.dataset.act === 'step') {
    const k = el.dataset.k, [lo, hi] = OPT_BORNES[k];
    const v = Math.min(hi, Math.max(lo, optValue(k) + +el.dataset.d));
    optDraft = { ...optDraft, [k]: v };
    clearTimeout(optTimer); optTimer = setTimeout(() => { optTimer = null; sendOpts() }, 600);
    return render();
  }
  pressedEl = el;
  const a = el.dataset.act, id = el.dataset.id;
  if (a === 'target' || a === 'turns' || a === 'mode') {
    const box = document.getElementById('c-' + a);
    if (box) box.value = el.dataset.v;
    el.parentElement.querySelectorAll('.seg-b').forEach(b => {
      const on = b === el; b.classList.toggle('on', on); b.setAttribute('aria-pressed', on);
    });
    // l'accroche suit la vignette choisie, sans re-rendre (la saisie du pseudo reste)
    if (a === 'mode') { const p = document.getElementById('c-pitch'); if (p) p.innerHTML = pitch(el.dataset.v) }
    return;
  }
  if (a === 'tab') {
    const want = el.dataset.tab;
    // les deux volets restent dans le DOM : on ne re-rend pas, sinon on perd la saisie
    document.querySelectorAll('.tab').forEach(t => {
      const on = t === el; t.classList.toggle('on', on); t.setAttribute('aria-selected', on);
    });
    const from = document.getElementById(want === 'join' ? 'c-name' : 'j-name');
    const to = document.getElementById(want === 'join' ? 'j-name' : 'c-name');
    if (from && to && from.value.trim()) to.value = from.value;   // le pseudo suit l'onglet
    document.getElementById('pane-create').hidden = want !== 'create';
    document.getElementById('pane-join').hidden = want !== 'join';
    return;
  }
  if (a === 'admin') { adminOpen = true; adminTab = 'a'; adminLast = {}; catalog = { kind:'a', total:0, items:[], q:'' }; return render() }
  if (a === 'admin-close') {
    adminOpen = false; adminPwd = ''; adminLevel = ''; adminTab = 'a'; adminLast = {};
    catalog = { kind:'a', total:0, items:[], q:'' };
    return render();
  }
  // Revenir sur un jeu rouvre le catalogue qu'on y avait laissé.
  if (a === 'admin-game') {
    const g = el.dataset.game, cur = jeuDe(adminTab);
    if (!CATALOGUES[g] || g === cur) return;
    adminLast[cur] = adminTab;
    return adminSwitch(adminLast[g] || CATALOGUES[g][0][0]);
  }
  if (a === 'admin-tab') return adminSwitch(el.dataset.tab);
  if (a === 'admin-login') {
    const pwd = val('a-pwd');
    if (!pwd) return toast('Entre le code admin.');
    if (busy) return;
    busy = true; el.disabled = true;
    try {
      // le serveur seul décide du niveau : 'plus' ouvre la consultation et la suppression
      const level = await rpc('admin_level', { p_password: pwd });
      if (level === 'none') { toast('Code incorrect.'); el.disabled = false }
      else {
        adminPwd = pwd; adminLevel = level; render();
        if (level === 'plus') loadCatalog(0);
      }
    } catch (e) { toast(e.message); el.disabled = false }
    busy = false;
    return;
  }
  if (a === 'hole-add') {
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
    majTrous();
    autoGrow(champ);
    return;
  }
  if (a === 'admin-add') {
    const k = adminTab, mot = MOT[k], w = k === 'w' || k === 'm';
    const text = val('a-text'), gauche = val('a-left'), droite = val('a-right');
    if (w ? !gauche || !droite : !text) return toast(w ? (k === 'm' ? 'Remplis les deux mots.' : 'Remplis les deux extrêmes.') : `Écris une ${mot}.`);
    if (busy) return;
    busy = true; el.disabled = true;
    try {
      const d = k === 'm'
        ? await rpc('admin_add_white_word', { p_password:adminPwd, p_civil:gauche, p_undercover:droite })
        : w ? await rpc('admin_add_wave_card', { p_password: adminPwd, p_left: gauche, p_right: droite })
        : await rpc('admin_add_card', { p_password: adminPwd, p_kind: k, p_text: text });
      toast(k === 'm' ? 'Paire de mots ajoutée.' : `Ajoutée. ${d.total} ${mot}s au catalogue.`);
      // le rendu identique n'écrit plus le DOM : on vide les champs à la main
      const saisie = document.activeElement?.id;
      for (const id of ['a-text', 'a-left', 'a-right']) { const c = document.getElementById(id); if (c) c.value = '' }
      // validé au clavier : on repart de la gauche pour enchaîner les cartes
      if (saisie === 'a-right') document.getElementById('a-left')?.focus();
      majTrous();
      autoGrow(document.getElementById('a-text'));
      el.disabled = false;
      if (adminLevel === 'plus') loadCatalog(0);
    } catch (e) {
      toast(/existe déjà/i.test(e.message) ? mot.charAt(0).toUpperCase() + mot.slice(1) + ' déjà existante' : e.message);
      if (/Mot de passe/i.test(e.message)) { adminPwd = ''; adminLevel = ''; render() } else el.disabled = false;
    }
    busy = false;
    return;
  }
  if (a === 'admin-form') {
    // Le classement automatique se trompe sur les noms propres qui finissent
    // comme un infinitif (« Vladimir Poutine ») : on corrige d'une touche.
    const next = el.dataset.form === 'v' ? 'n' : 'v';
    el.disabled = true;
    try {
      await rpc('admin_set_card_form', { p_password: adminPwd, p_id: +id, p_form: next });
      const item = catalog.items.find(c => String(c.id) === String(id));
      if (item) item.form = next;
      paintCatalog();
    } catch (e) { toast(e.message); el.disabled = false }
    return;
  }
  if (a === 'admin-more') { el.disabled = true; return loadCatalog(catalog.items.length) }
  if (a === 'admin-del') {
    const item = catalog.items.find(c => String(c.id) === String(id));
    const mot = MOT[catalog.kind];
    if (!confirm(`Supprimer « ${item ? item.text : `cette ${mot}`} » du catalogue ?`)) return;
    el.disabled = true;
    try {
      if (catalog.kind === 'm') await rpc('admin_delete_white_word', { p_password:adminPwd, p_id:+id });
      else await rpc('admin_delete_card', { p_password: adminPwd, p_kind: catalog.kind, p_id: +id });
      catalog.items = catalog.items.filter(c => String(c.id) !== String(id));
      catalog.total = Math.max(0, catalog.total - 1);
      paintCatalog();
      toast(mot.charAt(0).toUpperCase() + mot.slice(1) + ' supprimée.');
    } catch (e) { toast(e.message); el.disabled = false }
    return;
  }
  if (a === 'create') {
    const n = val('c-name'); if (!n) return toast('Choisis un pseudo.');
    return enter(() => rpc('create_room',{ p_name:n, p_target:+val('c-target'), p_mode:val('c-mode') || 'phrases', p_turns:+val('c-turns') || 2 }), n);
  }
  if (a === 'join') {
    const c = val('j-code').replace(/\D/g,''), n = val('j-name');
    if (c.length !== 4) return toast('Le code fait 4 chiffres.');
    if (!n) return toast('Choisis un pseudo.');
    return enter(() => rpc('join_room',{ p_code:c, p_name:n }), n);
  }
  if (a === 'bot') return act('add_bot');
  if (a === 'ready') return act('set_ready',{ p_ready: !state.me.ready });
  // avec punitions, le lancement passe d'abord par l'écran de saisie
  if (a === 'start') return act(pun?.on ? 'punish_start' : 'start_game');
  // le choix reste local : les autres joueurs n'ont leur écran qu'à la validation
  if (a === 'question') { qpick = +id; return render() }
  if (a === 'question-back') { qpick = null; return render() }
  if (a === 'question-go') {
    if (!qpick) return;
    const q = qpick;
    if (await act('select_question',{ p_question_id:q })) qpick = null;
    return;
  }
  if (a === 'select') {
    const n = state?.blanks || 1, carte = +id, rang = picks.indexOf(carte);
    if (rang >= 0) picks.splice(rang, 1);          // re-toucher retire la carte
    else if (n === 1) picks = [carte];             // un seul trou : une seule carte
    else if (picks.length < n) picks.push(carte);  // sinon on remplit dans l'ordre
    else { picks.shift(); picks.push(carte) }      // main pleine : la plus ancienne saute
    return render();
  }
  if (a === 'send') {
    if (picks.length < (state?.blanks || 1)) return;
    const [c1, c2] = picks;
    if (await act('submit_answer', { p_answer_id: c1, p_answer_id2: c2 ?? null })) picks = [];
    return;
  }
  if (a === 'drop') {
    if (picks.length !== 1 || !state?.me?.can_discard) return;
    const c = picks[0];
    if (await act('discard_card', { p_answer_id: c })) { picks = []; render() }
    return;
  }
  // Priorités : chaque touche pose la carte sur la première marche libre ;
  // toucher une carte posée la retire et libère sa marche. Le glisser-déposer
  // (plus haut) peut laisser des marches vides entre deux cartes.
  if (a === 'rank') {
    const c = +id, n = (state?.rank_cards || []).length;
    if (picks.includes(c)) return;
    const libre = Array.from({ length:n }, (_, i) => i).find(i => !picks[i]);
    if (libre !== undefined) picks[libre] = c;
    return render();
  }
  if (a === 'unrank') { const i = picks.indexOf(+id); if (i >= 0) picks[i] = undefined; return render() }
  if (a === 'send-rank') {
    const n = (state?.rank_cards || []).length;
    if (picks.slice(0, n).filter(Boolean).length < n) return;
    return act('submit_ranking', { p_cards: picks.slice(0, n) });
  }
  if (a === 'readnext') { readIndex++; return render() }
  if (a === 'pick') { picked = id; return render() }
  if (a === 'rankview') { rankView = id; return render() }
  if (a === 'confirm' && picked) return act('pick_winner',{ p_submission_id:picked });
  if (a === 'clue') {
    const t = (document.getElementById('w-clue')?.value || '').trim();
    if (!t) return toast(isInverse() ? 'Écris ta réponse.' : 'Écris un indice.');
    return act('submit_clue', { p_clue: t });
  }
  if (a === 'guess') return act('submit_guess', { p_value: dialVal });
  if (a === 'wave-variant') return act('set_wave_variant', { p_variant: el.dataset.v });
  if (a === 'set-game') {
    const m = el.dataset.v, r = state.room;
    if (!GAMES[m] || m === r.mode) { gamePick = false; return render() }
    // le brouillon des réglages visait l'ancien jeu
    clearTimeout(optTimer); optTimer = null; optDraft = {};
    if (!(await act('set_room_options', { p_mode:m, p_target:Math.min(20, Math.max(1, +r.target || 5)), p_turns:Math.min(5, Math.max(1, +r.turns || 2)) }))) return;
    gamePick = false;
    // même temps par défaut qu'à la création : sans minuteur pour Petit bac, Mr White et Mimes
    const t = ['bac','white','mimes'].includes(m) ? 'unlimited' : 'medium';
    if (state.room.time_mode !== t) await act('set_time_mode', { p_mode:t });
    toast(`Jeu changé : ${GAMES[m].name}.`);
    return render();
  }
  if (a === 'time-mode') return act('set_time_mode', { p_mode: el.dataset.v });
  if (a === 'theme') {
    const t = (document.getElementById('w-theme')?.value || '').trim();
    if (!t) return toast('Écris un thème.');
    if (await act('submit_theme', { p_theme: t })) themeDraft = '';
    return;
  }
  if (a === 'mime-progress') return act('mime_progress', { p_action:'next' });
  if (a === 'mime-note') { mimeNotes[id] = +el.dataset.v; return render() }
  if (a === 'mime-rate') {
    const ids = mimeIds();
    if (ids.some(x => !mimeNotes[x])) return toast('Note chaque joueur.');
    return act('mime_rate', { p_players: ids, p_notes: ids.map(x => mimeNotes[x]) });
  }
  if (a === 'bac-cat') {
    const t = (document.getElementById('bac-cat')?.value || '').trim();
    if (!t) return toast('Écris une catégorie.');
    if (await act('bac_category', { p_name: t })) catDraft = '';
    return render();
  }
  if (a === 'bac-done') { clearTimeout(bacTimer); return act('bac_save', { p_answers: bacDraft, p_done: true }) }
  if (a === 'bac-vote') {
    // le choix reste allumé pendant qu'on attend le vote de l'autre
    bacMyVote = { k: state.room.round + ':' + (state.bac?.step || 0), v: +el.dataset.v };
    if (!(await act('bac_vote', { p_vote: +el.dataset.v }))) { bacMyVote = null; render() }
    return;
  }
  if (a === 'white-open-vote') return act('white_open_vote');
  if (a === 'white-resume') return act('white_resume');
  if (a === 'white-vote') return act('white_vote', { p_target:id });
  if (a === 'white-oral-verdict') return act('white_oral_verdict', { p_correct:el.dataset.correct==='1' });
  if (a === 'punish-submit') {
    const t = [...document.querySelectorAll('.punfield input')].map(c => c.value.trim());
    if (await act('punish_submit', { p_texts: t })) punDrafts = [];
    return;
  }
  if (a === 'punish-spin') return act('punish_spin');
  if (a === 'continue') return act('continue_game');
  if (a === 'bac-next') return act('next_round');
  if (a === 'kick') return act('kick_player',{ p_player_id:id });
  // En pleine partie, un tap par erreur sur la croix sortait le joueur (et
  // pouvait renvoyer tout le monde au salon) : on demande confirmation.
  if (a === 'leave' && state && state.room.status !== 'lobby'
      && !confirm('Quitter la partie en cours ? Tu ne pourras pas la reprendre.')) return;
  if (a === 'leave') { try { await rpc('leave_room',{ p_code:session.code, p_token:session.token }); ping() } catch {} return leaveLocal() }
});
document.addEventListener('input', e => {
  if (e.target.id === 'w-clue') clueDraft = e.target.value;
  if (e.target.id === 'w-theme') themeDraft = e.target.value;
  if (e.target.id === 'dico-def') { dicoDraft = e.target.value; autoGrow(e.target) }
  if (e.target.id === 'bac-cat') catDraft = e.target.value;
  if (/^pun-\d$/.test(e.target.id)) punDrafts[+e.target.dataset.i] = e.target.value;
  if (e.target.matches('.bacfield input')) {
    bacDraft[+e.target.dataset.i] = e.target.value;
    clearTimeout(bacTimer); bacTimer = setTimeout(saveBac, 700);
  }
  if (e.target.id === 'j-code') e.target.value = e.target.value.replace(/\D/g,'');
  if (e.target.id === 'a-text') { majTrous(); autoGrow(e.target) }
  if (e.target.id === 'cat-q') {
    catalog.q = e.target.value;
    clearTimeout(catTimer);
    catTimer = setTimeout(() => loadCatalog(0), 300);   // seule la liste est repeinte
  }
});
document.addEventListener('keydown', e => {
  if (e.key === 'Enter' && e.target.matches('#c-name')) document.querySelector('[data-act=create]')?.click();
  if (e.key === 'Enter' && e.target.matches('#j-name, #j-code')) document.querySelector('[data-act=join]')?.click();
  if (e.key === 'Enter' && e.target.matches('#w-clue')) document.querySelector('[data-act=clue]')?.click();
  if (e.key === 'Enter' && e.target.matches('#w-theme')) document.querySelector('[data-act=theme]')?.click();
  if (e.key === 'Enter' && e.target.matches('#bac-cat')) document.querySelector('[data-act=bac-cat]')?.click();
  // Punitions : Entrée passe au champ suivant, puis ferme le clavier
  if (e.key === 'Enter' && e.target.matches('.punfield input')) {
    e.preventDefault();
    const suivant = document.getElementById('pun-' + (+e.target.dataset.i + 1));
    suivant ? suivant.focus() : e.target.blur();
  }
  // Petit bac : Entrée passe à la catégorie suivante, et ferme le clavier à la dernière.
  if (e.key === 'Enter' && e.target.matches('.bacfield input')) {
    e.preventDefault();
    const suivant = document.getElementById('bac-' + (+e.target.dataset.i + 1));
    suivant ? suivant.focus() : e.target.blur();
  }
  if (e.key === 'Enter' && e.target.matches('#a-pwd')) document.querySelector('[data-act=admin-login]')?.click();
  // Extrêmes : Entrée passe de la gauche à la droite, puis valide la carte.
  if (e.key === 'Enter' && e.target.matches('#a-left')) { e.preventDefault(); document.getElementById('a-right')?.focus() }
  if (e.key === 'Enter' && e.target.matches('#a-right')) { e.preventDefault(); document.querySelector('[data-act=admin-add]')?.click() }
  // Une phrase tient sur une ligne logique : Entrée valide au lieu d'ajouter un
  // saut de ligne, que _clean_card écraserait de toute façon.
  if (e.key === 'Enter' && e.target.matches('#a-text')) {
    e.preventDefault();
    document.querySelector('[data-act=admin-add]')?.click();
  }
});
// En quittant l'appli en pleine saisie, la grille part tout de suite.
document.addEventListener('visibilitychange', () => { if (!document.hidden) { refresh(true); keepAwake() } else if (state?.room.status === 'writing') saveBac() });

const urlCode = (new URLSearchParams(location.search).get('code') || '').replace(/\D/g,'');
if (session && urlCode && urlCode !== session.code) save(null);
session ? startSession() : render();

// Le service worker retélécharge la page à chaque lancement : sans lui, l'app
// installée sur l'écran d'accueil reste figée sur la version de son installation.
if ('serviceWorker' in navigator) {
  addEventListener('load', () => navigator.serviceWorker.register('./sw.js').catch(() => {}));
}
