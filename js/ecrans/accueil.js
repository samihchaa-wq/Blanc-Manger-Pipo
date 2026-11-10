// Accueil : onglets Créer / Rejoindre, pseudo, les vignettes des jeux pour
// choisir celui de la partie, puis « Créer la partie ». Le jeu se change
// ensuite dans le salon. Cinq appuis rapides sur le logo ouvrent l'admin :
// plus de bouton visible par tout le monde.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.

// Une ligne pour le jeu choisi : nom, nombre de joueurs, principe.
function pitch(k){
  const g = GAMES[k] || GAMES.phrases;
  return `<b>${g.name}</b> · ${joueurs(k)}<br><span>${g.pitch}</span>`;
}
// Brouillons : un rafraîchissement de l'écran ne vide pas les champs.
let homeName = null, homeCode = null;
function home(){
  const code = (new URLSearchParams(location.search).get('code') || '').replace(/\D/g,'').slice(0,8);
  if (homeName === null) { try { homeName = localStorage.getItem('pdcat-name') || '' } catch { homeName = '' } }
  if (homeCode === null) homeCode = code;
  const join = !!code;            // arrivé par un lien d'invitation : on ouvre le bon onglet
  const jeu = dernierJeu();       // la vignette du dernier jeu choisi sur ce téléphone
  let hasOfficialQuizSession=false;
  try { hasOfficialQuizSession=!!localStorage.getItem('asgq-2026-participant') } catch {}
  const resumeQuiz=hasOfficialQuizSession
    ? '<button type="button" class="asgq-resume-link" data-act="asgq-resume">REPRENDRE LE GRAND QUIZ</button>'
    : '';
  return `
    <div class="home">
      <h1><button type="button" class="logo" data-act="logo" aria-label="Le Soulièteur"><img src="design-studio/logo-officiel.webp" width="800" height="637" alt="Le Soulièteur" decoding="async" fetchpriority="high"></button><span class="shift" aria-hidden="true"></span></h1>

      <div class="tabs" role="tablist">
        <button class="tab ${join ? '' : 'on'}" data-act="tab" data-tab="create" role="tab" aria-selected="${!join}">Créer</button>
        <button class="tab ${join ? 'on' : ''}" data-act="tab" data-tab="join" role="tab" aria-selected="${join}">Rejoindre</button>
      </div>

      <section class="panel pane" id="pane-create" ${join ? 'hidden' : ''}>
        <label class="inline"><span>Pseudo :</span><input id="c-name" maxlength="20" autocomplete="nickname" placeholder="Ton prénom ou surnom" value="${esc(homeName)}"></label>
        <div class="field">
          <div class="gamesbox" style="--rows:${Math.ceil(Object.keys(GAMES).length / 3)}"><div class="gamesfit"><div class="seg s2 games" role="group" aria-label="Jeu">
            ${Object.entries(GAMES).map(([k, g]) => `<button type="button" class="seg-b ${k === jeu ? 'on' : ''}" data-act="mode" data-v="${k}" aria-pressed="${k === jeu}"><img src="games/${tileImg(k)}" width="720" height="720" alt="${g.name}" decoding="async"></button>`).join('')}
          </div></div></div>
          <input type="hidden" id="c-mode" value="${jeu}">
          <p class="pitch" id="c-pitch" aria-live="polite">${pitch(jeu)}</p>
        </div>
        <!-- le réglage propre à chaque jeu se fait dans le salon : l'accueil tient sur un écran -->
        <button class="btn" data-act="create">Créer la partie</button>
        ${hasOfficialQuizSession ? `<div id="asgq-resume-create" ${jeu==='qcm'?'':'hidden'}>${resumeQuiz}</div>` : ''}
        <div id="asgq-host-recovery-create" ${jeu==='qcm'?'':'hidden'}>
          <button type="button" class="asgq-admin-recovery-link" data-act="asgq-host-recovery">
            REPRENDRE L’ÉMISSION OFFICIELLE (ADMIN+)
          </button>
        </div>
      </section>

      <section class="panel pane" id="pane-join" ${join ? '' : 'hidden'}>
        <label class="inline"><span>Pseudo :</span><input id="j-name" maxlength="20" autocomplete="nickname" placeholder="Ton prénom ou surnom" value="${esc(homeName)}"></label>
        <label><span>Code de la partie</span><input id="j-code" type="text" inputmode="numeric" pattern="[0-9]*" maxlength="8" autocomplete="one-time-code" spellcheck="false" placeholder="•••• ••••" value="${esc(homeCode)}"></label>
        <button class="btn" data-act="join">Rejoindre la partie</button>
        ${hasOfficialQuizSession ? resumeQuiz : ''}
      </section>
    </div>`;
}

// Accueil : la taille des vignettes se règle en CSS (largeur de l'app et
// hauteur stable 100svh, voir .gamesbox). Seuls les navigateurs sans 100svh
// passent par ici : les vignettes prennent toute la largeur et rétrécissent de ce qui dépasse de
// l'écran. Sur 3 colonnes, la grille gagne « rangées / 3 » px de hauteur par px
// de largeur : on réduit d'autant, en remesurant.
const tailleEnCss = !!window.CSS?.supports?.('height', '100svh');
function fitGames(){
  const g = app.querySelector('.home .seg.games');
  if (!g || tailleEnCss) return;
  g.style.width = ''; g.style.margin = '';
  const rangees = Math.max(1, Math.ceil(g.children.length / 3));
  for (let i = 0; i < 4; i++) {
    const over = document.documentElement.scrollHeight - innerHeight;
    if (over <= 1) break;
    g.style.width = Math.max(200, g.offsetWidth - Math.ceil(over * 3 / rangees) - 2) + 'px';
    g.style.margin = '0 auto';   // réduite, la grille reste centrée
  }
}
addEventListener('resize', fitGames);

// Accueil : la hauteur du bloc = la hauteur réelle de l'écran moins les marges
// de main (encoche et barre du bas comprises). Sur iPhone, 100dvh donnait
// moins que l'écran : vide sous le bouton, vignettes petites. On ne garde que
// la plus grande hauteur vue pour une même largeur, pour que le clavier (qui
// réduit la fenêtre sur Android) ne fasse pas rétrécir les vignettes.
let hauteurVue = { w: 0, h: 0 };
function hauteurAccueil(){
  const m = document.querySelector('main');
  if (!m || !document.body.classList.contains('is-home')) return;
  if (innerWidth !== hauteurVue.w) hauteurVue = { w: innerWidth, h: 0 };
  hauteurVue.h = Math.max(hauteurVue.h, innerHeight);
  const st = getComputedStyle(m);
  const h = hauteurVue.h - parseFloat(st.paddingTop) - parseFloat(st.paddingBottom);
  if (h > 300) document.documentElement.style.setProperty('--home-h', Math.floor(h) + 'px');
}
addEventListener('resize', hauteurAccueil);
addEventListener('orientationchange', () => setTimeout(hauteurAccueil, 300));
document.fonts?.ready.then(() => fitGames());

async function enter(call, name){
  if (busy) return;
  busy = true;
  try {
    const d = await call();
    // Les refus de connexion sont des réponses JSON (et non des exceptions SQL)
    // afin que le serveur puisse conserver les compteurs d'essais échoués.
    if (d && typeof d.error === 'string') throw Error(d.error);
    if (!d?.code || !d?.token) throw Error('Réponse du serveur invalide. Réessaie.');
    try { localStorage.setItem('pdcat-name', name) } catch {}
    save({ code:d.code, token:d.token });
    homeCode = null;
    history.replaceState(null,'',location.pathname + '?code=' + d.code);
    busy = false; startSession();
  } catch (e) { busy = false; toast(e.message) }
}

// Le QCM n'est plus un salon du Soulieteur : c'est l'événement AS Grinta unique.
function ouvrirGrintaQuiz(remplacer = false, onglet = null){
  // Comme les autres jeux : la vignette ne lance rien. Seul « Créer la partie » ouvre le QCM.
  const url = new URL('./grinta-quiz/', location.href);
  // Une partie QCM de test ne consomme jamais la partie unique de la soirée.
  if (onglet === 'create') url.searchParams.set('repetition','1');
  if (onglet) url.searchParams.set('action', onglet === 'join' ? 'join' : 'create');
  if (remplacer) location.replace(url.href);
  else location.assign(url.href);
}

/* ---------- Actions ---------- */
let logoTaps = [];
surAction('logo', () => {
  const t = Date.now();
  logoTaps = logoTaps.filter(x => t - x < 3000).concat(t);
  if (logoTaps.length >= 5) { logoTaps = []; ouvrirAdmin() }
}, { marque:false });
// Les deux volets restent dans la page : on ne redessine pas (le logo
// rejouerait son allumage), on bascule seulement ce qui est visible.
surAction('tab', el => {
  const want = el.dataset.tab;
  document.querySelectorAll('.home .tab').forEach(t => {
    const on = t === el; t.classList.toggle('on', on); t.setAttribute('aria-selected', on);
  });
  document.getElementById('pane-create').hidden = want !== 'create';
  document.getElementById('pane-join').hidden = want !== 'join';
  // le pseudo suit l'onglet
  for (const id of ['c-name', 'j-name']) { const c = document.getElementById(id); if (c) c.value = homeName || '' }
}, { marque:false });
// Une vignette touchée s'allume et l'accroche suit, sans redessiner (la saisie du pseudo reste).
surAction('mode', el => {
  const box = document.getElementById('c-mode');
  if (box) box.value = el.dataset.v;
  el.parentElement.querySelectorAll('.seg-b').forEach(b => {
    const on = b === el; b.classList.toggle('on', on); b.setAttribute('aria-pressed', on);
  });
  const p = document.getElementById('c-pitch'); if (p) p.innerHTML = pitch(el.dataset.v);
  const resume=document.getElementById('asgq-resume-create');
  if(resume) resume.hidden=el.dataset.v!=='qcm';
  const recovery=document.getElementById('asgq-host-recovery-create');
  if(recovery) recovery.hidden=el.dataset.v!=='qcm';
}, { marque:false });
surAction('create', () => {
  const n = val('c-name'); if (!n) return toast('Choisis un pseudo.');
  const jeu = GAMES[val('c-mode')] ? val('c-mode') : dernierJeu();
  if (jeu === 'qcm') {
    try { localStorage.setItem('pdcat-name', n) } catch {}
    retenirJeu(jeu);
    return ouvrirGrintaQuiz(false, 'create');
  }
  retenirJeu(jeu);
  return enter(() => rpc('create_room', { p_name:n, p_target:5, p_mode:jeu, p_turns:2 }), n);
});
// This resumes an existing authenticated session. It never creates a new quiz.
surAction('asgq-resume',()=>{
  let stored=false;
  try {stored=!!localStorage.getItem('asgq-2026-participant')} catch {}
  if(!stored) return toast('Aucune session du Grand Quiz sur cet appareil.');
  location.assign(new URL('./grinta-quiz/',location.href).href);
});
// Admin+-authenticated recovery is available even on a brand new device
// with no local token. This must never open a rehearsal or create an event.
surAction('asgq-host-recovery',()=>{
  const url=new URL('./grinta-quiz/',location.href);
  url.searchParams.set('action','resume');
  location.assign(url.href);
});
// A lost official quiz session requires an ephemeral code issued by the host.
// Only expose this exceptional route AFTER a failed official-room join.
function montrerRecuperationAsgq(){
  const pane=document.getElementById('pane-join');
  if(!pane || document.getElementById('asgq-recovery-panel')) return;
  const section=document.createElement('div');
  section.id='asgq-recovery-panel';
  section.className='asgq-recovery-panel';
  section.innerHTML=`<p>Tu étais déjà dans le Grand Quiz ? Demande un code de récupération à l'animateur pour retrouver ton score.</p>
    <label><span>Code temporaire de récupération</span>
      <input id="asgq-recovery-code" type="text" inputmode="numeric" maxlength="8"
        autocomplete="one-time-code" spellcheck="false" placeholder="8 chiffres"></label>
    <button class="btn" data-act="asgq-recover">Récupérer ma place</button>`;
  pane.append(section);
}
// The main Soulieteur join screen is the ONLY entry for invited Quiz players.
// Look up the type of the 8-digit room before creating any participant.
// Regular Soulieteur rooms continue using their original RPC untouched.
surAction('join', async () => {
  const c = val('j-code').replace(/\D/g,''), n = val('j-name');
  if (c.length !== 4 && c.length !== 8) return toast('Le code fait 8 chiffres (ou 4 pour les anciens salons).');
  if (!n) return toast('Choisis un pseudo.');
  if (busy) return;
  if (c.length === 8) {
    busy = true;
    let quizMode=null;
    try {
      quizMode = await rpc('asgq_room_mode', {p_code:c});
      if (quizMode === 'official' || quizMode === 'rehearsal') {
        const name=quizMode === 'rehearsal' ? 'asgq_rehearsal_join_room' : 'asgq_join_room';
        const joined=await rpc(name,{p_code:c,p_name:n});
        if(joined?.error) throw Error(joined.error);
        if(!joined?.token) throw Error('Session du Grand Quiz introuvable.');
        try {
          localStorage.setItem(quizMode === 'rehearsal'
            ? 'asgq-2026-rehearsal-participant' : 'asgq-2026-participant',joined.token);
          localStorage.setItem('pdcat-name',n);
        } catch {}
        const url=new URL('./grinta-quiz/',location.href);
        if(quizMode === 'rehearsal') url.searchParams.set('repetition','1');
        location.assign(url.href);
        return;
      }
    } catch(e) {
      if(quizMode === 'official' && /Nom déjà utilisé|prénom est déjà pris|déjà inscrit|commenc|inscriptions|inscription|vestiaire est complet/i.test(e.message || '')) {
        montrerRecuperationAsgq();
      }
      toast(e.message || 'Impossible de rejoindre le Grand Quiz.');
      return;
    } finally {busy = false}
  }
  return enter(() => rpc('join_room',{ p_code:c, p_name:n }), n);
});
surAction('asgq-recover', async () => {
  if(busy) return;
  const c=val('j-code').replace(/\D/g,''), n=val('j-name');
  const rescue=val('asgq-recovery-code').replace(/\D/g,'');
  if(c.length!==8 || !n || rescue.length!==8) {
    return toast('Renseigne le code de la partie, ton pseudo et les 8 chiffres fournis par l’animateur.');
  }
  busy=true;
  try {
    const joined=await rpc('asgq_claim_player_handoff',{
      p_room_code:c,p_player_name:n,p_handoff_code:rescue
    });
    if(joined?.error) throw Error(joined.error);
    if(!joined?.token) throw Error('Impossible de retrouver ton accès au Grand Quiz.');
    try {
      localStorage.setItem('asgq-2026-participant',joined.token);
      localStorage.setItem('pdcat-name',joined.name || n);
    } catch {}
    location.assign(new URL('./grinta-quiz/',location.href).href);
  } catch(e) {
    toast(e.message || 'Récupération impossible.');
  } finally {busy=false}
});
document.addEventListener('input', e => {
  if (e.target.id === 'c-name' || e.target.id === 'j-name') homeName = e.target.value;
  if (e.target.id === 'j-code') homeCode = e.target.value = e.target.value.replace(/\D/g,'');
  if (e.target.id === 'asgq-recovery-code') e.target.value=e.target.value.replace(/\D/g,'');
});
document.addEventListener('keydown', e => {
  if (e.key === 'Enter' && e.target.matches('#c-name')) document.querySelector('[data-act=create]')?.click();
  if (e.key === 'Enter' && e.target.matches('#j-name, #j-code')) document.querySelector('[data-act=join]')?.click();
});
