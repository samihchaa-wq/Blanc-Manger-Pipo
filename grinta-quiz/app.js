/* Grand Quiz AS Grinta 2026 — mobile-only, single event.
 * Adapted from the Soulieteur QCM's synchronized answering / scoring model.
 * The server owns scores and secret answers. Only the authenticated host advances phases.
 */
'use strict';

const SUPABASE_URL = 'https://yqfewxadpyulgxehhpcu.supabase.co';
// Publishable client key, NOT a service-role secret.
const SUPABASE_KEY = 'sb_publishable_Qdso-n_uVYAH1_YzjSLYlQ_rOWg93tg';
const api = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const isRehearsal = new URLSearchParams(location.search).get('repetition') === '1';
const storeKey = isRehearsal ? 'asgq-2026-rehearsal-participant' : 'asgq-2026-participant';
const app = document.getElementById('app');
const notice = document.getElementById('notice');
const networkStatus = document.getElementById('network-status');
const letters = ['A','B','C','D'];
let token = null;
let state = null;
let signature = '';
let requesting = false;
let sendingAnswer = false;
let chosenOptimistically = null;
let noticeTimer = null;
let lastConnectionError = false;
let lobbyActionBusy = false;
let advanceBusy = false;
const codeFromLink = (new URLSearchParams(location.search).get('code') || '').replace(/[^0-9]/g,'').slice(0,8);
// All joining happens through the main Soulieteur entry screen, including invitations.

try { token = localStorage.getItem(storeKey); } catch (_) {}
const safe = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const firstLetter = name => safe((name || 'G').trim().slice(0,1).toUpperCase());
const topText = n => n === 1 ? '1RE MI-TEMPS' : '2E MI-TEMPS';
const halfNum = s => s.position - (s.half === 2 ? s.first_half_count : 0);
const totalHalf = s => s.half === 2 ? s.second_half_count : s.first_half_count;
const allQuestions = s => Number(s.first_half_count || 10) + Number(s.second_half_count || 10);
const showEmblem = '<span class="show-emblem" aria-hidden="true"><span class="laurel">❧</span><span class="ball">⚽</span><span class="laurel">❧</span></span>';
const showProgress = s => `<div class="show-progress" role="img" aria-label="Question ${Number(s.position)||1} sur ${allQuestions(s)}">${Array.from({length:Math.min(40,allQuestions(s))},(_,i)=>`<span class="show-progress-dot ${i<Number(s.position||1)?'passed':''}" aria-hidden="true"></span>`).join('')}</div>`;

function toast(message) {
  notice.textContent = message;
  notice.classList.add('visible');
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => notice.classList.remove('visible'), 3500);
}
function showNetworkProblem(offline) {
  if(networkStatus) networkStatus.hidden = !offline;
}
function fmtError(error) {
  const message=String(error?.message || '');
  if (/Mot de passe Admin\+ incorrect|Une répétition est en cours|Maximum 20 bots|Le salon est complet|Seul le créateur|Ajoute au moins un bot|La partie a déjà commencé|Le code de la partie|Nom déjà utilisé/i.test(message)) return message;
  if (/DELETE requires a WHERE clause|SQL|PostgREST|PGRST\d|syntax error|permission denied|relation .* does not exist|violates .* constraint/i.test(message)) return 'Impossible de terminer cette action. Réessaie.';
  return message.length>120 || !message ? 'Connexion impossible. Réessaie.' : message;
}
// Club photographs, original 1024x1536 cutouts: no compressed sprite or face recreation.
// Semantic pose names keep each expression appropriate to the current quiz moment.
const PRESENTER_FILES = Object.freeze({
  welcome:'laughter', thinking:'thinking', excited:'thumbs', amazed:'amazed', surprised:'surprised',
  confident:'arms', puzzled:'confused', doubt:'skeptical', facepalm:'facepalm',
  victory:'trophy', question:'pointing', cheer:'cheer'
});
const presenter = pose => {
  const file = PRESENTER_FILES[pose] || PRESENTER_FILES.confident;
  return `<div class="presenter-shot presenter-${safe(pose)}"><img class="presenter-photo" src="./presenters/${file}.png" width="1024" height="1536" decoding="async" alt="Animateur AS Grinta" draggable="false"></div>`;
};
const stage = (title,pose,kind='') =>
  `<div class="stage-head stage-${safe(kind)}">${presenter(pose)}<div class="stage-copy">${title}</div></div>`;

function headerText(overline, title, sub) {
  return `<div class="hero"><div class="eyebrow">${overline}</div><h2>${title}</h2>${sub ? `<p>${sub}</p>` : ''}</div>`;
}
// Optional host-only access recovery. Never shown to invited players or bots.
function hostAccessPanel(s) {
  if(isRehearsal || !s?.is_host) return '';
  const players=(s.players||[]).filter(p=>!p.is_host);
  if(!players.length) return '';
  return `<details class="host-access">
    <summary>RÉTABLIR L'ACCÈS D'UN JOUEUR</summary>
    <p>Si un joueur a perdu sa session, choisis son prénom et donne-lui le code temporaire. Son score sera conservé.</p>
    <div class="host-access-players">${players.map(p=>`<button type="button" data-issue-player-code="${safe(p.id)}">${safe(p.name)}</button>`).join('')}</div>
    <div class="host-access-result" id="host-access-result" role="status" aria-live="polite"></div>
  </details>`;
}
function shell(html, key) {
  const practiceTag=isRehearsal && key!=='finished' ? '<div class="rehearsal-banner">RÉPÉTITION AVEC BOTS · SCORES DE TEST</div>' : '';
  const access=['join','recover-host','expired'].includes(key) ? '' : hostAccessPanel(state);
  app.innerHTML = `<section class="scene" data-screen="${key}">${practiceTag}${html}${access}</section>`;
}
function renderLostSession() {
  signature='session-expired';
  shell(`${stage('<h2>SESSION EXPIRÉE</h2>','puzzled','expired')}
    <div class="panel lost-session"><p>Cette session ne peut plus être utilisée. Retourne dans Le Soulieteur pour accéder à une partie encore ouverte.</p>
    <a class="primary recovery-link" href="../">RETOUR AU SOULIETEUR</a>
      ${!isRehearsal?'<button type="button" class="quiet-link host-recovery-link" data-host-recovery>REPRENDRE L’ÉMISSION (ADMIN+)</button>':''}</div>`, 'expired');
}
function renderJoin() {
  signature = 'join-create';
  let savedName = '';
  try { savedName = localStorage.getItem('pdcat-name') || '' } catch (_) {}
  shell(`
    ${stage('<h1 class="entry-title">PRÊT POUR<br>LE GRAND<br>QUIZ ?</h1>','excited','welcome')}
    <form class="panel join-panel" id="join-form" autocomplete="off">
      <label class="field"><span>TON PRÉNOM</span><input id="player-name" maxlength="22" minlength="2" required placeholder="Ton prénom" autocomplete="nickname" value="${safe(savedName)}"></label>
      <label class="field"><span>MOT DE PASSE ADMIN+</span><input class="code" id="admin-password" type="password" required autocomplete="off" placeholder="••••••••" aria-label="Mot de passe Admin+"></label>
      <button type="submit" class="primary" id="join-button">CRÉER LA PARTIE</button>
      <p class="entry-hint">Admin+ : création uniquement</p>
    </form>
    ${!isRehearsal ? '<button type="button" class="quiet-link host-recovery-link" data-host-recovery>REPRENDRE L’ÉMISSION (ADMIN+)</button><a class="quiet-link" href="./?repetition=1">TESTER AVEC DES BOTS</a>' : ''}
  `, 'join');
}
function renderHostRecovery() {
  shell(`
    ${stage('<h2>REPRENDRE L’ÉMISSION</h2>','confident','welcome')}
    <form class="panel join-panel" id="recover-host-form" autocomplete="off">
      <p class="host-recovery-description">Tu peux récupérer ton rôle d’animateur depuis un nouvel appareil. L’ancien accès sera déconnecté.</p>
      <label class="field"><span>MOT DE PASSE ADMIN+</span><input class="code" id="recovery-admin-password" type="password" required autocomplete="off" placeholder="••••••••"></label>
      <button type="submit" class="primary">REPRENDRE L’ANIMATION</button>
    </form>
    <button type="button" class="quiet-link" data-back-to-creation>RETOUR À L’ACCUEIL</button>
  `, 'recover-host');
}
function hostControl(s, label) {
  return s.is_host ? `<button type="button" class="primary host-next" data-next-phase>${label}</button>` : '';
}
function renderLobby(s) {
  const count=s.players.length;
  const participantCount=s.players.filter(p => !p.is_host).length;
  const manyPlayers=participantCount > 12;
  const players=s.players.map(p => `<li class="${p.id === s.me.id ? 'me' : ''}"><span>${safe(p.name)}</span>${isRehearsal && s.is_host && p.is_bot ? `<button type="button" class="remove-bot" data-remove-bot="${safe(p.id)}" aria-label="Retirer ${safe(p.name)}" title="Retirer ${safe(p.name)}">×</button>` : ''}</li>`).join('');
  const rosterSection=`<div class="section-title"><span class="eyebrow">JOUEURS (${participantCount})</span><small class="host-count">+ 1 animateur</small></div>
    <ul class="roster">${players}</ul>
    ${s.is_host && isRehearsal ? `<button type="button" class="add-bot" data-add-bot ${count >= (s.max_players || 30) || s.players.filter(p=>p.is_bot).length >= 20 ? 'disabled' : ''}>+ AJOUTER UN BOT</button>` : ''}`;
  const whyDisabled=participantCount<1 ? 'Il faut au moins un joueur pour lancer.' : !s.ready ? 'La partie n’est pas encore prête à démarrer.' : '';
  shell(`
    ${stage('<h2>VESTIAIRE</h2>','confident','lobby')}
    <div class="panel lobby-panel">
      <div class="room-invite"><div>${showEmblem}<span class="eyebrow">CODE DE LA PARTIE</span><div class="room-code">${safe(s.room_code || '--------')}</div></div>
        <button type="button" class="invite-button" data-share-room ${s.room_code?'':'disabled'}>INVITER</button></div>
      ${manyPlayers?'':rosterSection}
    </div>
    ${manyPlayers ? `<div class="panel lobby-roster-panel">${rosterSection}</div>` : ''}
    ${s.is_host
      ? `<button type="button" class="primary start-quiz" data-start-quiz ${count < 2 || !s.ready ? 'disabled' : ''}>LANCER LA PARTIE</button>${whyDisabled ? `<p class="launch-hint" role="status">${whyDisabled}</p>` : ''}`
      : '<p class="muted center">En attente du maître du jeu…</p>'}
  `, 'lobby');
}
function renderIntro(s) {
  shell(`${stage('<h2>1RE MI-TEMPS</h2>','cheer','intro')}
    ${hostControl(s,'AFFICHER LA QUESTION')}`, 'intro');
}
// On the host's question screen, display only participants that have not answered.
// This comes from the authenticated server, never inferred from the total count.
function waitingPlayersHtml(s) {
  const waiting=s.question?.waiting_players;
  if (!Array.isArray(waiting)) return '<span class="waiting-title">On attend les réponses…</span>';
  if (!waiting.length) return '<span class="waiting-complete">Tout le monde a répondu !</span>';
  return `<span class="waiting-title">On attend :</span><span class="waiting-names">${waiting.map(p=>`<span class="waiting-name">${safe(p.name)}</span>`).join('')}</span>`;
}
function renderQuestion(s) {
  const q=s.question || {};
  const choice=chosenOptimistically !== null ? chosenOptimistically : q.my_choice;
  const choices=(q.choices || []).map((answer,i)=>{
    const content=`<span class="letter" aria-hidden="true">${letters[i]}</span><span class="choice-text">${safe(answer)}</span><span class="choice-indicator" aria-hidden="true"></span>`;
    return s.is_host
      ? `<div class="choice readonly">${content}</div>`
      : `<button class="choice ${choice === i ? 'selected' : ''}" data-answer="${i}" aria-pressed="${choice === i}" type="button" ${sendingAnswer ? 'disabled' : ''}>${content}</button>`;
  }).join('');
  shell(`<div class="question-topline">${presenter('question')}<div class="kicker"><span class="round-chip">QUESTION</span><span class="pos"><b>${s.position}</b><small> / ${allQuestions(s)}</small></span></div></div>
    ${showProgress(s)}
    <div class="question-card" role="group" aria-label="Question ${halfNum(s)}">
      <div class="question-card-top" aria-hidden="true"><span>${showEmblem}</span><span class="question-card-index">Q${String(halfNum(s)).padStart(2,'0')}</span></div>
      <h2>${safe(q.text)}</h2>
      <div class="question-card-bottom" aria-hidden="true"><span></span><span></span><span></span></div>
    </div>
    <div class="choices" role="group" aria-label="Choix de réponse">${choices}</div>
    ${s.is_host ? `<p class="response-note" id="answer-counter" role="status" aria-live="polite">${waitingPlayersHtml(s)}</p>${hostControl(s,'RÉVÉLER LA RÉPONSE')}`
      : `<p class="response-note answer-feedback" role="status" aria-live="polite">${sendingAnswer ? 'Enregistrement…' : choice === null || choice === undefined ? '' : 'Réponse enregistrée · Tu peux changer ton choix.'}</p>`}`, 'question');
}
// Equal scores share a rank: 1, 1, 3, 4 (not the order in which they joined).
function competitionRank(standings,index) {
  const score=Number(standings[index]?.score ?? 0);
  const first=standings.findIndex(player=>Number(player.score)===score);
  return first>=0 ? first+1 : index+1;
}
function rankingRows(s, count = 5) {
  const standings=s.standings || [];
  const makeRow=(p,i,extra='')=>`<li class="${p.id===s.me.id?'you':''} ${extra}"><span class="rank-no">${String(competitionRank(standings,i)).padStart(2,'0')}</span><span class="rank-name">${safe(p.name)}${p.id===s.me.id?' · toi':''}</span><b>${p.score}</b></li>`;
  const top=standings.slice(0,count).map((p,i)=>makeRow(p,i)).join('');
  const ownIndex=s.is_host ? -1 : standings.findIndex(p=>p.id===s.me.id);
  return top+(ownIndex>=count ? `<li class="rank-divider" aria-hidden="true">···</li>${makeRow(standings[ownIndex],ownIndex,'personal-rank')}` : '');
}
// Correct -> congratulatory; incorrect -> skeptical/facepalm;
// unanswered -> genuinely surprised or questioning. The host does not answer
// questions and remains neutral, and poses stay stable during state polling.
function presenterPoseForReveal(s, success, answered) {
  if (s.is_host) return 'confident';
  const position = Math.max(1, Number(s.position) || 1);
  if (success) return ['amazed','excited','welcome'][(position - 1) % 3];
  if (answered) return position % 2 === 0 ? 'doubt' : 'facepalm';
  return position % 2 === 0 ? 'puzzled' : 'surprised';
}
function renderResponseBreakdown(s) {
  // Only the server-supplied reveal list is authoritative. Never guess from scores.
  const responses=s.question?.responses;
  if (!Array.isArray(responses)) return '';
  const categories=[
    {status:'correct',label:'ONT BIEN RÉPONDU',symbol:'✓'},
    {status:'incorrect',label:'SE SONT TROMPÉS',symbol:'×'},
    {status:'unanswered',label:"N'ONT PAS RÉPONDU",symbol:'—'}
  ];
  const groups=categories.map(category=>{
    const players=responses.filter(p=>p.status===category.status);
    const names=players.length
      ? players.map(p=>`<span class="response-person">${safe(p.name)}</span>`).join('')
      : '<span class="response-empty">Personne</span>';
    return `<div class="response-group response-group--${category.status}">
      <div class="response-group-header">
        <span class="response-symbol" aria-hidden="true">${category.symbol}</span>
        <span class="response-group-name">${category.label}</span>
        <strong class="response-group-count">${players.length}</strong>
      </div>
      <div class="response-names">${names}</div>
    </div>`;
  }).join('');
  return `<section class="response-breakdown" aria-label="Bilan des réponses des joueurs">
    <div class="section-title"><span class="eyebrow">RÉPONSES DES JOUEURS</span></div>
    <div class="response-groups">${groups}</div>
  </section>`;
}
function renderReveal(s) {
  const q=s.question || {};
  const success=q.my_choice === q.correct && !s.is_host;
  const answered=q.my_choice !== null && q.my_choice !== undefined;
  const verdict=s.is_host ? 'RÉPONSE RÉVÉLÉE' : success ? 'BIEN JOUÉ !' : answered ? 'DOMMAGE !' : 'PAS DE RÉPONSE';
  const resultPose = presenterPoseForReveal(s, success, answered);
  shell(`<div class="kicker result-kicker"><span class="round-chip">LE VERDICT</span><span class="pos">QUESTION <b>${s.position}</b><small> / ${allQuestions(s)}</small></span></div>
    ${stage(`<div class="result-status ${success?'good':s.is_host?'':'bad'}">${verdict}</div>`,resultPose,'reveal')}
    <div class="reveal-question"><span>LA QUESTION</span><p>${safe(q.text || '')}</p></div>
    <div class="answer-reveal">
      <div class="answer-reveal-label"><span class="answer-reveal-tick" aria-hidden="true">✓</span><span>BONNE RÉPONSE</span></div>
      <strong>${safe(q.choices?.[q.correct] ?? '')}</strong>
      ${s.is_host?'':`<b class="answer-reveal-points">+${q.earned ?? 0} PT${q.earned === 1?'':'S'}</b>`}
    </div>
    ${!s.is_host && answered && !success ? `<p class="personal-answer">Tu avais répondu : <strong>${safe(q.choices?.[q.my_choice] ?? '')}</strong></p>` : ''}
    ${q.explanation ? `<div class="reveal-explanation"><span>POURQUOI ?</span><p>${safe(q.explanation)}</p></div>` : ''}
    ${renderResponseBreakdown(s)}
    <div class="section-title"><span class="eyebrow">CLASSEMENT</span></div>
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s)}</ol></div>
    ${hostControl(s,'QUESTION SUIVANTE')}`, 'reveal');
}
function renderHalftime(s) {
  const top=s.standings?.[0];
  const count=Number(s.first_half_count || 10);
  shell(`${stage('<h2>MI-TEMPS</h2><p>On souffle… mais le match continue.</p>','thinking','halftime')}
    <div class="halftime-board">
      <div class="halftime-board-title">APRÈS ${count} QUESTIONS</div>
      <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s,5)}</ol></div>
    </div>
    <div class="halftime-stat">
      <div class="halftime-stat-title">LE CHIFFRE DE LA PREMIÈRE MI-TEMPS</div>
      <span class="stat-target" aria-hidden="true">◎</span>
      <strong>${Number(top?.score || 0)}<small> / ${count}</small></strong>
      <span class="stat-caption">points pour le leader</span>
    </div>
    ${hostControl(s,'LANCER LA 2E MI-TEMPS')}`, 'halftime');
}
function renderFinished(s) {
  const standings=s.standings||[];
  const top=standings.slice(0,3);
  const winnerScore=top[0]?.score;
  const winners=winnerScore===undefined ? [] : standings.filter(p=>Number(p.score)===Number(winnerScore));
  const tied=winners.length>1;
  const order=top.length >= 3 ? [top[1],top[0],top[2]] : top.length===2?[top[1],top[0]]:top;
  const podium=order.map(p=> {
    const position=competitionRank(standings,standings.indexOf(p));
    const tier=position===1?'first':position===2?'second':'third';
    return `<div class="pod ${tier}"><span class="pod-crown" aria-hidden="true">♛</span><span class="name">${safe(p.name)}</span><span class="points">${p.score} pts</span><div class="step">${position}</div></div>`;
  }).join('');
  const others=standings.slice(3).map((p,i)=>`<li class="${p.id===s.me.id?'you':''}"><span class="rank-no">${competitionRank(standings,i+3)}e</span><span class="rank-name">${safe(p.name)}${p.id===s.me.id?' · toi':''}</span><b>${p.score} pts</b></li>`).join('');
  const championNames=winners.length ? winners.map(p=>safe(p.name)).join(' · ') : 'AS Grinta';
  shell(`${stage(`<h2>${tied?'CHAMPIONS DU QUIZ':'CHAMPION DU QUIZ'}</h2><p>Fin de l’émission · Merci à tous</p>`,'victory','podium')}
    <h3 class="champion-name">${championNames}</h3>
    ${tied? `<p class="joint-champions">${winners.length} CHAMPIONS EX ÆQUO</p>` : ''}
    <div class="podium">${podium}</div>
    ${others ? `<div class="section-title"><span class="eyebrow">CLASSEMENT FINAL</span></div>
    <div class="panel ranking-panel"><ol class="small-list">${others}</ol></div>` : ''}
    ${isRehearsal && s.is_host ? '<button type="button" class="primary practice-again" data-repeat-rehearsal>REJOUER</button>' : ''}
`, 'finished');
}
function renderState(force=false) {
  if (!state) return;
  const {now: serverNow, ...stable} = state;
  // Other players' answer counts should not restart the whole screen animation.
  if (stable.phase==='question' && stable.question) {
    stable.question={...stable.question,answered_count:null,waiting_players:null};
  }
  const next=JSON.stringify(stable);
  if (!force && next===signature) {
    const counter=document.getElementById('answer-counter');
    if(counter) counter.innerHTML=waitingPlayersHtml(state);
    return;
  }
  signature=next;
  switch(state.phase) {
    case 'lobby': renderLobby(state);break;
    case 'intro': renderIntro(state);break;
    case 'question': renderQuestion(state);break;
    case 'reveal': renderReveal(state);break;
    case 'halftime': renderHalftime(state);break;
    case 'finished': renderFinished(state);break;
    default: app.innerHTML='<p class="muted center">Phase de jeu inconnue.</p>';
  }
}
async function fetchState() {
  if (!token || requesting) return;
  requesting=true;
  try {
    const {data,error}=await api.rpc(isRehearsal ? 'asgq_rehearsal_state' : 'asgq_state',{p_token:token});
    if (error) throw error;
    if (!data || !data.me) throw new Error('Réponse du serveur invalide.');
    state=data;
    lastConnectionError=false;
    showNetworkProblem(false);
    renderState();
  } catch(error) {
    const message=fmtError(error);
    if (/Session expirée|Session introuvable|Session inconnue/i.test(message)) {
      token=null; state=null; try{localStorage.removeItem(storeKey)}catch(_){}
      showNetworkProblem(false);
      renderLostSession(); toast('Session expirée.');
    } else if(!lastConnectionError) {
      lastConnectionError=true;
      showNetworkProblem(true);
      toast('Connexion momentanément indisponible. Nouvelle tentative automatique.');
    }
  } finally {requesting=false}
}

async function join(event) {
  event.preventDefault();
  const form=event.currentTarget;
  const button=form.querySelector('button[type=submit]');
  if(button.disabled) return;
  const name=form.querySelector('#player-name').value.trim();
  const password=form.querySelector('#admin-password').value;
  if(name.length<2 || !password) return toast('Entre ton prénom et le code Admin+.');
  button.disabled=true;
  button.textContent='CRÉATION EN COURS…';
  try {
    const rpcName=isRehearsal ? 'asgq_rehearsal_create' : 'asgq_create';
    const args={...(isRehearsal?{p_bots:0}:{}),p_password:password,p_name:name};
    const {data,error}=await api.rpc(rpcName,args);
    if(error) throw error;
    if(data?.error) throw new Error(data.error);
    token=data?.token;
    if(!token) throw new Error('Session manquante.');
    try {
      localStorage.setItem(storeKey,token);
      localStorage.setItem('pdcat-name',name);
    } catch(_){}
    signature='';
    await fetchState();
  } catch(error) {
    toast(fmtError(error));
  } finally {
    if(button.isConnected) {button.disabled=false;button.textContent='CRÉER LA PARTIE'}
  }
}
async function recoverHost(event) {
  event.preventDefault();
  if(isRehearsal) return;
  const form=event.currentTarget;
  const button=form.querySelector('button[type=submit]');
  if(button.disabled) return;
  const password=form.querySelector('#recovery-admin-password').value;
  if(!password) return toast('Entre le mot de passe Admin+.');
  button.disabled=true;
  button.textContent='RÉCUPÉRATION…';
  try {
    const {data,error}=await api.rpc('asgq_recover_host',{p_password:password});
    if(error) throw error;
    if(data?.error) throw new Error(data.error);
    if(!data?.token) throw new Error('Impossible de retrouver la session animateur.');
    token=data.token;
    state=null;
    signature='';
    try {
      localStorage.setItem(storeKey,token);
      if(data.name) localStorage.setItem('pdcat-name',data.name);
    } catch(_){}
    await fetchState();
  } catch(error) {
    toast(fmtError(error));
  } finally {
    if(button.isConnected) {
      button.disabled=false;
      button.textContent='REPRENDRE L’ANIMATION';
    }
  }
}
async function lobbyCommand(rpcName, botId=null) {
  if (!state?.is_host || state.phase!=='lobby' || lobbyActionBusy) return;
  if (!isRehearsal && rpcName!=='asgq_start') return;
  lobbyActionBusy=true;
  const selector=rpcName.endsWith('_add_bot')?'[data-add-bot]':rpcName.endsWith('_start')?'[data-start-quiz]':null;
  const button=selector?document.querySelector(selector):Array.from(document.querySelectorAll('[data-remove-bot]')).find(el=>el.dataset.removeBot===botId);
  if (button) button.disabled=true;
  try {
    const args={p_token:token,...(botId?{p_bot_id:botId}:{})};
    const {data,error}=await api.rpc(rpcName,args);
    if (error) throw error;
    if (data?.error) throw new Error(data.error);
    signature='';
    await fetchState();
  } catch(error) {
    toast(fmtError(error));
    if (button?.isConnected) button.disabled=false;
  } finally { lobbyActionBusy=false; }
}
async function advancePhase() {
  if (!state?.is_host || !['intro','question','reveal','halftime'].includes(state.phase) || advanceBusy) return;
  advanceBusy=true;
  const button=document.querySelector('[data-next-phase]');
  if (button) button.disabled=true;
  try {
    const {error}=await api.rpc(isRehearsal ? 'asgq_rehearsal_advance' : 'asgq_advance',{
      p_token:token,p_expected_phase:state.phase,p_expected_position:state.position
    });
    if (error) throw error;
    signature='';
    await fetchState();
  } catch(error) {
    toast(fmtError(error));
    if(button?.isConnected) button.disabled=false;
  } finally { advanceBusy=false; }
}

async function issuePlayerHandoff(playerId,button) {
  if(isRehearsal || !state?.is_host || !(state.players||[]).some(p=>p.id===playerId && !p.is_host)) return;
  if(button) button.disabled=true;
  try {
    const {data,error}=await api.rpc('asgq_issue_player_handoff',{
      p_host_token:token,p_player_id:playerId
    });
    if(error) throw error;
    if(data?.error) throw new Error(data.error);
    if(!data?.code) throw new Error('Impossible de générer un code de récupération.');
    const output=document.getElementById('host-access-result');
    if(output) {
      output.innerHTML=`<strong>${safe(data.name)}</strong>
        <span>CODE TEMPORAIRE</span>
        <b class="handoff-code">${safe(data.code)}</b>
        <small>Valable 10 minutes et une seule fois. Communique ce code uniquement au joueur concerné.</small>
        <button type="button" data-copy-player-code="${safe(data.code)}">COPIER LE CODE</button>`;
    }
  } catch(error) {
    toast(fmtError(error));
  } finally {
    if(button?.isConnected) button.disabled=false;
  }
}
async function shareRoom() {
  const code=state?.room_code;
  if(!code) return;
  const url=new URL('../',location.href);
  url.searchParams.set('code',code);
  const message='Rejoins le Grand Quiz AS Grinta 2026 ! Code : '+code;
  try {
    if(navigator.share) {
      await navigator.share({title:'Grand Quiz AS Grinta',text:message,url:url.href});
    } else if(navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(message+' '+url.href);
      toast('Invitation copiée.');
    } else {
      toast('Code à partager : '+code);
    }
  } catch(error) {
    if(error?.name!=='AbortError') toast('Code à partager : '+code);
  }
}
async function answer(index) {
  if(!state || state.phase!=='question' || state.is_host || sendingAnswer) return;
  const previous=state.question.my_choice;
  chosenOptimistically=index;
  sendingAnswer=true;
  renderState(true);
  try {
    const {error}=await api.rpc(isRehearsal ? 'asgq_rehearsal_answer' : 'asgq_answer',{p_token:token,p_choice:index});
    if(error) throw error;
    // Update immediately; a subsequent state refresh updates the shared answer count.
    if(state?.phase==='question') state.question.my_choice=index;
  } catch(error) {
    chosenOptimistically=null;
    if(state?.phase==='question') state.question.my_choice=previous;
    toast(fmtError(error));
  } finally {
    chosenOptimistically=null;
    sendingAnswer=false;
    signature='';
    renderState(true);
    void fetchState();
  }
}

app.addEventListener('submit',e=>{
  if(e.target.id==='join-form') void join(e);
  else if(e.target.id==='recover-host-form') void recoverHost(e);
});
app.addEventListener('click',e=>{
  if(e.target.closest('[data-host-recovery]')) {renderHostRecovery();return}
  if(e.target.closest('[data-back-to-creation]')) {renderJoin();return}
  const issue=e.target.closest('[data-issue-player-code]');
  if(issue) {void issuePlayerHandoff(issue.dataset.issuePlayerCode,issue);return}
  const copy=e.target.closest('[data-copy-player-code]');
  if(copy) {
    if(navigator.clipboard?.writeText) {
      void navigator.clipboard.writeText(copy.dataset.copyPlayerCode).then(()=>toast('Code temporaire copié.'),()=>toast('Sélectionne le code affiché pour le copier.'));
    } else toast('Sélectionne le code affiché pour le copier.');
    return;
  }
  if(isRehearsal && e.target.closest('[data-repeat-rehearsal]')) {
    token=null;state=null;signature='';
    try{localStorage.removeItem(storeKey)}catch(_){}
    renderJoin();
    return;
  }
  const removeBot=e.target.closest('[data-remove-bot]');
  if(removeBot) {void lobbyCommand('asgq_rehearsal_remove_bot',removeBot.dataset.removeBot);return}
  if(e.target.closest('[data-add-bot]')) {void lobbyCommand('asgq_rehearsal_add_bot');return}
  if(e.target.closest('[data-start-quiz]')) {void lobbyCommand(isRehearsal?'asgq_rehearsal_start':'asgq_start');return}
  if(e.target.closest('[data-next-phase]')) {void advancePhase();return}
  if(e.target.closest('[data-share-room]')) {void shareRoom();return}
  const button=e.target.closest('[data-answer]');
  if(button) void answer(Number(button.dataset.answer));
});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)void fetchState()});
window.addEventListener('online',()=>{if(token)void fetchState()});
window.addEventListener('offline',()=>{if(token)showNetworkProblem(true)});
setInterval(()=>{if(token && !requesting)void fetchState()},1800);
if(token) void fetchState();
else if(codeFromLink.length===8) {
  // Old quiz invitation links also return to the single Soulieteur join screen.
  const url=new URL('../',location.href);
  url.searchParams.set('code',codeFromLink);
  location.replace(url.href);
} else renderJoin();