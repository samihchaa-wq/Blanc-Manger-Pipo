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
let entryMode = codeFromLink.length === 8 ? 'join' : 'create';

try { token = localStorage.getItem(storeKey); } catch (_) {}
const safe = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const firstLetter = name => safe((name || 'G').trim().slice(0,1).toUpperCase());
const topText = n => n === 1 ? '1RE MI-TEMPS' : '2E MI-TEMPS';
const halfNum = s => s.position - (s.half === 2 ? s.first_half_count : 0);
const totalHalf = s => s.half === 2 ? s.second_half_count : s.first_half_count;

function toast(message) {
  notice.textContent = message;
  notice.classList.add('visible');
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => notice.classList.remove('visible'), 3500);
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
function shell(html, key) {
  const practiceTag=isRehearsal ? '<div class="rehearsal-banner">RÉPÉTITION AVEC BOTS · SCORES DE TEST</div>' : '';
  app.innerHTML = `<section class="scene" data-screen="${key}">${practiceTag}${html}</section>`;
}
function renderJoin() {
  signature = 'join-' + entryMode;
  let savedName = '';
  try { savedName = localStorage.getItem('pdcat-name') || '' } catch (_) {}
  const isCreate = entryMode === 'create';
  shell(`
    ${stage('<h1 class="entry-title">LE GRAND <span class="gold">QUIZ</span></h1>',isCreate?'excited':'thinking','welcome')}
    <div class="entry-tabs" role="tablist" aria-label="Accès au quiz">
      <button type="button" data-entry-mode="create" role="tab" aria-selected="${isCreate}" class="${isCreate?'on':''}">Créer</button>
      <button type="button" data-entry-mode="join" role="tab" aria-selected="${!isCreate}" class="${!isCreate?'on':''}">Rejoindre</button>
    </div>
    <form class="panel join-panel" id="join-form" autocomplete="off">
      <label class="field"><span>TON PRÉNOM</span><input id="player-name" maxlength="22" minlength="2" required placeholder="Ton prénom" autocomplete="nickname" value="${safe(savedName)}"></label>
      ${isCreate
        ? '<label class="field"><span>MOT DE PASSE ADMIN+</span><input class="code" id="admin-password" type="password" required autocomplete="off" placeholder="••••••••" aria-label="Mot de passe Admin+"></label>'
        : `<label class="field"><span>CODE DE LA PARTIE</span><input class="code" id="room-code" type="text" inputmode="numeric" pattern="[0-9]{8}" maxlength="8" required autocomplete="one-time-code" placeholder="8 chiffres" value="${safe(codeFromLink)}" aria-label="Code de la partie à 8 chiffres"></label>`}
      <button type="submit" class="primary" id="join-button">${isCreate?'CRÉER LA PARTIE':'REJOINDRE'}</button>
      ${isCreate ? '<p class="entry-hint">Admin+ : création uniquement</p>' : ''}
    </form>
    ${!isRehearsal ? '<a class="quiet-link" href="./?repetition=1">TESTER AVEC DES BOTS</a>' : ''}
  `, 'join');
}
function hostControl(s, label) {
  return s.is_host ? `<button type="button" class="primary host-next" data-next-phase>${label}</button>` : '';
}
function renderLobby(s) {
  const count=s.players.length;
  const players=s.players.map(p => `<li class="${p.id === s.me.id ? 'me' : ''}"><span>${safe(p.name)}</span>${isRehearsal && s.is_host && p.is_bot ? `<button type="button" class="remove-bot" data-remove-bot="${safe(p.id)}" aria-label="Retirer ${safe(p.name)}" title="Retirer ${safe(p.name)}">×</button>` : ''}</li>`).join('');
  shell(`
    ${stage('<h2>VESTIAIRE</h2>','confident','lobby')}
    <div class="panel lobby-panel">
      <div class="room-invite"><div><span class="eyebrow">CODE DE LA PARTIE</span><div class="room-code">${safe(s.room_code || '--------')}</div></div>
        <button type="button" class="invite-button" data-share-room ${s.room_code?'':'disabled'}>Inviter</button></div>
      <div class="section-title"><span class="eyebrow">JOUEURS (${count-1})</span></div>
      <ul class="roster">${players}</ul>
      ${s.is_host
        ? `${isRehearsal ? `<button type="button" class="add-bot" data-add-bot ${count >= (s.max_players || 30) || s.players.filter(p=>p.is_bot).length >= 20 ? 'disabled' : ''}>+ AJOUTER UN BOT</button>` : ''}
           <button type="button" class="primary start-quiz" data-start-quiz ${count < 2 || !s.ready ? 'disabled' : ''}>LANCER LA PARTIE</button>`
        : '<p class="muted center">En attente du maître du jeu…</p>'}
    </div>

  `, 'lobby');
}
function renderIntro(s) {
  shell(`${stage('<h2>1RE MI-TEMPS</h2>','cheer','intro')}
    ${hostControl(s,'AFFICHER LA QUESTION')}`, 'intro');
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
  const playerCount=s.players.filter(p=>!p.is_host).length;
  shell(`<div class="question-topline">${presenter('question')}<div class="kicker"><span class="round-chip">${topText(s.half)}</span><span class="pos">QUESTION <b>${halfNum(s)}</b><small> / ${totalHalf(s)}</small></span></div></div>
    <div class="question-card" role="group" aria-label="Question ${halfNum(s)}">
      <div class="question-card-top" aria-hidden="true"><span>AS GRINTA</span><span class="question-card-index">Q${String(halfNum(s)).padStart(2,'0')}</span></div>
      <h2>${safe(q.text)}</h2>
      <div class="question-card-bottom" aria-hidden="true"><span></span><span></span><span></span></div>
    </div>
    <div class="choices" role="group" aria-label="Choix de réponse">${choices}</div>
    ${s.is_host ? `<p class="response-note" id="answer-counter">${q.answered_count || 0} / ${playerCount} réponses</p>${hostControl(s,'RÉVÉLER LA RÉPONSE')}`
      : `<p class="response-note" aria-live="polite">${choice === null || choice === undefined ? '' : 'Réponse enregistrée'}</p>`}`, 'question');
}
function rankingRows(s, count = 5) {
  return (s.standings || []).slice(0,count).map((p,i)=>`<li class="${p.id===s.me.id?'you':''}"><span class="rank-no">${String(i+1).padStart(2,'0')}</span><span class="rank-name">${safe(p.name)}${p.id===s.me.id?' · toi':''}</span><b>${p.score}</b></li>`).join('');
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
function renderReveal(s) {
  const q=s.question || {};
  const success=q.my_choice === q.correct && !s.is_host;
  const answered=q.my_choice !== null && q.my_choice !== undefined;
  const verdict=s.is_host ? 'RÉPONSE RÉVÉLÉE' : success ? 'BIEN JOUÉ !' : answered ? 'DOMMAGE !' : 'PAS DE RÉPONSE';
  const resultPose = presenterPoseForReveal(s, success, answered);
  shell(`<div class="kicker result-kicker"><span class="round-chip">LE VERDICT</span><span class="pos">QUESTION <b>${halfNum(s)}</b><small> / ${totalHalf(s)}</small></span></div>
    ${stage(`<div class="result-status ${success?'good':s.is_host?'':'bad'}">${verdict}</div>`,resultPose,'reveal')}
    <div class="answer-reveal">
      <div class="answer-reveal-label"><span class="answer-reveal-tick" aria-hidden="true">✓</span><span>BONNE RÉPONSE</span></div>
      <strong>${safe(q.choices?.[q.correct] || '')}</strong>
      ${s.is_host?'':`<b class="answer-reveal-points">+${q.earned ?? 0} PT${q.earned === 1?'':'S'}</b>`}
    </div>
    <div class="section-title"><span class="eyebrow">CLASSEMENT</span></div>
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s)}</ol></div>
    ${hostControl(s,'QUESTION SUIVANTE')}`, 'reveal');
}
function renderHalftime(s) {
  shell(`${stage('<h2>MI-TEMPS</h2>','thinking','halftime')}
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s,30)}</ol></div>
    ${hostControl(s,'REPRENDRE LE QUIZ')}`, 'halftime');
}
function renderFinished(s) {
  const top=(s.standings||[]).slice(0,3);
  const order=top.length >= 3 ? [top[1],top[0],top[2]] : top.length===2?[top[1],top[0]]:top;
  const podium=order.map(p=> {
    const position=top.indexOf(p)+1;
    const tier=position===1?'first':position===3?'third':'';
    return `<div class="pod ${tier}"><span class="circle">${firstLetter(p.name)}</span><span class="name">${safe(p.name)}</span><span class="points">${p.score} PTS</span><div class="step">${position}</div></div>`;
  }).join('');
  shell(`${stage('<h2>PODIUM</h2>','victory','podium')}
    <h2 class="champion-name">${safe(top[0]?.name || 'AS Grinta')}</h2>
    <div class="podium">${podium}</div>
    <div class="section-title"><span class="eyebrow">CLASSEMENT FINAL</span></div>
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s,30)}</ol></div>
    ${isRehearsal ? '<button type="button" class="primary practice-again" data-repeat-rehearsal>NOUVELLE PARTIE</button>' : ''}
`, 'finished');
}
function renderState(force=false) {
  if (!state) return;
  const {now: serverNow, ...stable} = state;
  // Other players' answer counts should not restart the whole screen animation.
  if (stable.phase==='question' && stable.question) {
    stable.question={...stable.question,answered_count:null};
  }
  const next=JSON.stringify(stable);
  if (!force && next===signature) {
    const counter=document.getElementById('answer-counter');
    if(counter) counter.textContent=`${state.question?.answered_count || 0} / ${state.players.filter(p=>!p.is_host).length} réponses`;
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
    renderState();
  } catch(error) {
    const message=fmtError(error);
    if (/Session expirée|Session introuvable|Session inconnue/i.test(message)) {
      token=null; state=null; try{localStorage.removeItem(storeKey)}catch(_){}
      renderJoin(); toast('Ta session a expiré. Rejoins de nouveau la partie.');
    } else if(!lastConnectionError) {
      lastConnectionError=true;
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
  const creating=entryMode==='create';
  const password=creating ? form.querySelector('#admin-password').value : '';
  const roomCode=creating ? '' : form.querySelector('#room-code').value.replace(/[^0-9]/g,'');
  if(name.length<2 || (creating && !password) || (!creating && roomCode.length!==8)) {
    return toast(creating ? 'Entre ton prénom et le code Admin+.' : 'Entre ton prénom et le code de partie à 8 chiffres.');
  }
  button.disabled=true;
  button.textContent=creating ? 'CRÉATION EN COURS…' : 'ENTRÉE EN COURS…';
  try {
    const rpcName=creating ? (isRehearsal ? 'asgq_rehearsal_create' : 'asgq_create') : (isRehearsal ? 'asgq_rehearsal_join_room' : 'asgq_join_room');
    const args=creating ? {...(isRehearsal?{p_bots:0}:{}),p_password:password,p_name:name} : {p_code:roomCode,p_name:name};
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
    if(button.isConnected) {button.disabled=false;button.textContent=creating?'CRÉER LA PARTIE':'REJOINDRE LA PARTIE'}
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

async function shareRoom() {
  const code=state?.room_code;
  if(!code) return;
  const url=new URL(location.href);
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

app.addEventListener('submit',e=>{if(e.target.id==='join-form') void join(e)});
app.addEventListener('click',e=>{
  if(isRehearsal && e.target.closest('[data-repeat-rehearsal]')) {
    token=null;state=null;signature='';entryMode='create';
    try{localStorage.removeItem(storeKey)}catch(_){}
    renderJoin();
    return;
  }
  const mode=e.target.closest('[data-entry-mode]');
  if(mode) {
    const name=document.getElementById('player-name')?.value.trim();
    if(name) try { localStorage.setItem('pdcat-name',name) } catch(_){}
    entryMode=mode.dataset.entryMode==='join'?'join':'create';
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
app.addEventListener('input',e=>{
  if(e.target.id==='room-code') e.target.value=e.target.value.replace(/[^0-9]/g,'').slice(0,8);
});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)void fetchState()});
setInterval(()=>{if(token && !requesting)void fetchState()},1800);
if(token) void fetchState(); else renderJoin();