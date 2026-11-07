// Commun à tous les écrans : rendu, barre du haut, barre d'action, cartes,
// attente, état du réseau.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

function qcard(tag, html, cls = '', foot = ''){
  return `<div class="qcard ${cls}${dealPending ? ' deal' : ''}"><span class="qtag">${tag}</span>
    <p class="qtext">${html}</p>${foot}</div>`;
}

// Champs dont la saisie survit à un rafraîchissement : leur valeur vient d'un
// brouillon gardé en mémoire, le curseur est remis à sa place.
const CHAMPS_SUIVIS = /^(pun-\d|w-clue|w-theme|dico-def|dil-start|dil-but|c-name|j-name|j-code|pj-code|cat-q|pj-new|[ae]-(text|left|right|act))$/;
function render(){
  // un re-rendu pendant un glissement arracherait la carte sous le doigt
  if (dragging || flying) { pendingRender = true; return }
  document.body.classList.toggle('is-home', !session && !adminOpen);
  hauteurAccueil();
  // Couleur d'accent du jeu en cours (voir body[data-game] dans la feuille de style)
  const jeu = !adminOpen && session && state ? state.room.mode : '';
  if (jeu) document.body.dataset.game = jeu; else delete document.body.dataset.game;
  let html;
  if (adminOpen) html = adminView();
  else if (!session) html = home();
  else if (!state) html = '<p class="center"><span class="spin"></span>Connexion à la partie…</p>';
  else html = topbar() + { lobby, question_select: qselect, answering, judging, ranking, clue, guessing,
    naming: bacNaming, writing: bacWrite, voting: bacVote,
    white_clue:whiteClue, white_vote:whiteVote, white_guess:whiteGuess,
    white_elimination:whiteElimination, mime_play:mimePlay, dico_pick:dicoPick, dico_write:dicoWrite, dico_vote:dicoVote,
    dilemme_pick:dilemmePick, dilemme_write:dilemmeWrite, dilemme_vote:dilemmeVote, reveal, finished }[state.room.status]();
  // Réécrire un DOM identique fait clignoter les boutons et perdre le focus :
  // la plupart des rafraîchissements ne changent rien à l'écran.
  // Sans barre d'action fixe, la réserve du bas laisserait un grand vide.
  document.body.classList.toggle('no-dock', !html.includes('class="dock"'));
  if (html !== lastHtml) {
    lastHtml = html;
    // la saisie en cours (punition, indice, pseudo, carte de l'admin…) survit au rafraîchissement
    const ae = document.activeElement, focId = CHAMPS_SUIVIS.test(ae?.id || '') ? ae.id : null, foc = focId ? ae.selectionStart : null;
    app.innerHTML = html;
    if (holding) app.querySelectorAll('[data-hold]').forEach(el => el.classList.add('show'));
    if (focId) { const c = document.getElementById(focId); if (c) { c.focus(); try { c.setSelectionRange(foc, foc) } catch {} } }
    // Fondu/glissé seulement quand on change d'écran, pas à chaque petit
    // rafraîchissement (sinon toute la page tremble sous les yeux).
    const key = adminOpen ? 'admin' : !session ? 'home' : !state ? 'load' : state.room.status + (pun?.phase ? '-pun' : '') + (isWhite() ? '-' + (state.white?.cycle || 0) : '');
    const newScreen = key !== renderedKey;
    if (newScreen) {
      renderedKey = key;
      app.classList.remove('enter'); void app.offsetWidth; app.classList.add('enter');
      // Les mises en scène (podium, cible, carte retournée, +N) ne se jouent
      // qu'à l'arrivée sur l'écran ; un rafraîchissement ensuite les montre finies.
      app.classList.add('fresh'); clearTimeout(render.fresh);
      render.fresh = setTimeout(() => app.classList.remove('fresh'), 2800);
      countUp();
    } else app.classList.remove('fresh');
    if (adminOpen) adminApresRendu();
    // les confettis à l'arrivée sur l'écran de fin, pas à chaque mise à jour
    else if (session && state && state.room.status === 'finished') { if (newScreen) confetti() }
    else if (session && state && state.room.status === 'writing') fillBac();
    fitDock();
    if (!session && !adminOpen) fitGames();
  }
  updateCountdown();
  dealPending = false;
}

// La barre d'action est fixe : elle recouvre la fin du contenu si la page ne
// réserve pas sa hauteur. Un écran à deux boutons est bien plus haut qu'un
// écran à un seul, et la police réglée par le système change encore la donne :
// on mesure au lieu de deviner.
function fitDock(){
  const dock = app.querySelector('.dock');
  document.documentElement.style.setProperty('--dock-h', (dock ? dock.offsetHeight : 0) + 'px');
}
// La rotation et la barre d'URL de Safari changent la hauteur du bouton
// (retour à la ligne du libellé) : la réserve doit suivre.
addEventListener('resize', fitDock);

// La zone grandit avec son contenu plutôt que de faire défiler le texte vers la
// droite. offsetHeight - clientHeight rend les bordures, que scrollHeight ne
// compte pas alors que box-sizing:border-box les inclut dans la hauteur.
function autoGrow(el){
  if (!el) return;
  el.style.height = 'auto';
  el.style.height = (el.scrollHeight + el.offsetHeight - el.clientHeight) + 'px';
}

// Le point devant le code dit l'état du réseau : vert en direct, doré quand
// le temps réel est coupé (relecture toutes les 4 s), rose hors connexion.
// En partie, la barre du haut montre le jeu (vignette + nom) plutôt que le
// code, inutile une fois la partie lancée. Le point de connexion se pose sur
// la vignette ; le code reste lu par les lecteurs d'écran.
function netBadge(code){
  const [cls, msg] = !navigator.onLine ? [' down', 'Hors connexion'] : rtOk || !rtSeen ? ['', 'Connecté'] : [' slow', 'Connexion lente, reconnexion…'];
  const g = GAMES[state.room.mode] || GAMES.phrases;
  return `<span class="gchip${cls}" title="${msg}" role="status" aria-label="${g.name}, partie ${esc(code)} · ${msg}">
      <img src="games/${gameImg(state.room.mode)}" width="720" height="720" alt=""></span>`;
}
addEventListener('offline', () => { toast('Connexion perdue. On reprend dès qu’elle revient.'); render() });
addEventListener('online', () => { render(); if (session) refresh(true) });

function topbar(){
  const r = state.room;
  // Salon : la vignette du jeu à gauche, le code au milieu, la croix à droite.
  if (r.status === 'lobby') return `<div class="top lobbytop">
      <img class="gamelogo" src="games/${gameImg(r.mode)}" width="720" height="720" alt="${(GAMES[r.mode] || GAMES.phrases).name}">
      <div class="codeblock"><p class="eyebrow">Code de la partie</p>
        <div class="bigcode">${[...r.code].map(c => `<span class="ch">${esc(c)}</span>`).join('')}</div>
        <button type="button" class="share" data-act="share"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15V3M7 8l5-5 5 5"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/></svg>Inviter</button></div>
      <button class="xbtn" data-act="leave" aria-label="Quitter la partie" title="Quitter"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
    </div>`;
  return `<div class="top">
      <div class="top-l">${netBadge(r.code)}<span class="gmeta"><b>${(GAMES[r.mode] || GAMES.phrases).name}</b>${r.round ? `<span class="round">Manche ${r.round}${isCounted() ? ' / ' + (r.round + roundsLeft()) : ''}</span>` : ''}</span></div>
      <div class="top-r">
        <span class="cdring" id="cd" hidden aria-hidden="true"><svg viewBox="0 0 36 36"><circle class="trk" cx="18" cy="18" r="16"></circle><circle class="arc" cx="18" cy="18" r="16" pathLength="100" stroke-dasharray="100" stroke-dashoffset="0"></circle></svg><b class="cdn"></b></span>
        <button class="xbtn" data-act="leave" aria-label="Quitter la partie" title="Quitter"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      </div>
    </div>`;
}

function waitScreen(title, sub, stack = 1){
  const backs = stack > 1
    ? `<div class="cardstack"><span class="cardback b2"></span><span class="cardback b3"></span><span class="cardback"></span></div>`
    : '<span class="cardback"></span>';
  return `<div class="waitScreen">${backs}
    <h2 class="bigstate">${title}</h2>
    <p class="muted"><span class="pulse"></span>${sub}</p>${scoreStrip()}</div>`;
}
