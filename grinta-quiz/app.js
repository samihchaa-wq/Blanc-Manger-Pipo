/* Grand Quiz AS Grinta 2026 — mobile-only, single event.
 * Adapted from the Soulieteur QCM's synchronized answering / scoring model.
 * The server protects scoring and secret answers; the master of the game controls every transition.
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
  if (/Mot de passe Admin\+ incorrect|Une répétition est en cours|Maximum 20 bots|Le salon est complet|Seul le créateur|Seul le maître du jeu|Ajoute au moins un bot|La partie a déjà commencé|Le code de la partie|Nom déjà utilisé|Les deux mi-temps ne sont pas prêtes/i.test(message)) return message;
  if (/DELETE requires a WHERE clause|SQL|PostgREST|PGRST\d|syntax error|permission denied|relation .* does not exist|violates .* constraint/i.test(message)) return 'Impossible de terminer cette action. Réessaie.';
  return message.length>120 || !message ? 'Connexion impossible. Réessaie.' : message;
}
// Les huit portraits sont fournis par le club : aucun visage n'est généré dans le jeu.
const presenter = pose =>
  `<div class="presenter-shot presenter-${safe(pose)}"><div class="presenter-photo" role="img" aria-label="Maître du jeu AS Grinta"></div></div>`;
const stage = (title,pose,kind='') =>
  `<div class="stage-head stage-${safe(kind)}"><div class="stage-copy">${title}</div>${presenter(pose)}</div>`;

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
    ${stage('<h1 class="entry-title">LE GRAND <span class="gold">QUIZ</span></h1>', 'welcome', 'welcome')}
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
function hostAction(s, label, action='next') {
  return s.is_host ? `<button type="button" class="primary start-quiz" data-host-action="${action}">${label}</button>`
    : '<p class="muted center">En attente du maître du jeu…</p>';
}
function renderLobby(s) {
  const count=s.players.length;
  const players=s.players.map(p => `<li class="${p.id === s.me.id ? 'me' : ''}"><span class="avatar">${firstLetter(p.name)}</span><span>${safe(p.name)}${p.id === s.me.id && s.is_host ? ' · MAÎTRE DU JEU' : ''}${p.is_bot ? ' <span class="bot-label">BOT</span>' : ''}</span>${isRehearsal && s.is_host && p.is_bot ? `<button type="button" class="remove-bot" data-remove-bot="${safe(p.id)}" aria-label="Retirer ${safe(p.name)}" title="Retirer ${safe(p.name)}">×</button>` : ''}</li>`).join('');
  const canStart=count >= 2 && s.ready;
  shell(`
    ${stage('<h2>VESTIAIRE</h2>', 'confident', 'lobby')}
    <div class="panel lobby-panel">
      <div class="room-invite"><div><span class="eyebrow">CODE DE LA PARTIE</span><div class="room-code">${safe(s.room_code || '--------')}</div></div>
        <button type="button" class="invite-button" data-share-room ${s.room_code?'':'disabled'}>Inviter</button></div>
      <div class="section-title"><span class="eyebrow">JOUEURS (${count})</span></div>
      <ul class="roster">${players}</ul>
      ${isRehearsal && s.is_host ? `<button type="button" class="add-bot" data-add-bot ${count >= (s.max_players || 30) || s.players.filter(p=>p.is_bot).length >= 20 ? 'disabled' : ''}>+ AJOUTER UN BOT</button>` : ''}
      ${s.is_host ? `<button type="button" class="primary start-quiz" data-host-action="start" ${canStart?'':'disabled'}>${!s.ready?'QUIZ NON PRÊT':count<2?'EN ATTENTE DE JOUEURS':'LANCER LA PARTIE'}</button>`
          : '<p class="muted center">En attente du maître du jeu…</p>'}
    </div>
    <a class="quiet-link" href="../">RETOUR AUX JEUX</a>
  `, 'lobby');
}
function renderIntro(s) {
  shell(`${stage('<h2>1RE MI-TEMPS</h2>', 'cheer', 'intro')}
    <div class="panel center">${hostAction(s,'COMMENCER LES QUESTIONS')}</div>`, 'intro');
}
function renderQuestion(s) {
  const q=s.question || {};
  const choice=chosenOptimistically !== null ? chosenOptimistically : q.my_choice;
  const choices=(q.choices || []).map((answer,i) => s.is_host
    ? `<div class="choice host-choice"><span class="letter">${letters[i]}</span><span>${safe(answer)}</span></div>`
    : `<button class="choice ${choice === i ? 'selected' : ''}" data-answer="${i}" aria-pressed="${choice === i}" type="button" ${sendingAnswer?'disabled':''}><span class="letter">${letters[i]}</span><span>${safe(answer)}</span></button>`).join('');
  shell(`<div class="question-topline"><div class="kicker"><span>${topText(s.half)}</span><span class="pos">QUESTION ${halfNum(s)} / ${totalHalf(s)}</span></div>${presenter('question')}</div>
    <div class="question-card"><h2>${safe(q.text)}</h2></div>
    <div class="choices">${choices}</div>
    ${s.is_host ? hostAction(s,'RÉVÉLER LA RÉPONSE') : `<p class="response-note" aria-live="polite">${choice === null || choice === undefined ? '' : 'Réponse enregistrée'}</p>`}`, 'question');
}
function rankingRows(s, count = 5) {
  return (s.standings || []).slice(0,count).map((p,i)=>`<li class="${p.id===s.me.id?'you':''}"><span class="rank-no">${i+1}</span><span class="avatar">${firstLetter(p.name)}</span><span class="rank-name">${safe(p.name)}${p.id===s.me.id?' · toi':''}</span><b>${p.score}</b></li>`).join('');
}
function renderReveal(s) {
  const q=s.question || {};
  const success=q.my_choice === q.correct;
  const answered=q.my_choice !== null && q.my_choice !== undefined;
  const verdict=s.is_host ? 'RÉPONSE RÉVÉLÉE' : success ? 'BIEN JOUÉ !' : answered ? 'DOMMAGE !' : 'SANS RÉPONSE';
  const lastQuestion=s.position===s.first_half_count+s.second_half_count;
  const lastOfFirst=s.half===1 && s.position===s.first_half_count;
  const nextLabel=lastQuestion?'VOIR LE PODIUM':lastOfFirst?'MI-TEMPS':'QUESTION SUIVANTE';
  shell(`<div class="kicker"><span>RÉSULTAT</span><span class="pos">QUESTION ${halfNum(s)} / ${totalHalf(s)}</span></div>
    ${stage(`<div class="result-status ${success?'good':'bad'}">${verdict}</div>`,s.is_host?'confident':success?'excited':answered?'facepalm':'surprised','reveal')}
    <div class="answer-reveal"><span>BONNE RÉPONSE</span><strong>${safe(q.choices?.[q.correct] || '')}</strong>${s.is_host?'':`<b>+${q.earned ?? 0} PT${q.earned === 1?'':'S'}</b>`}</div>
    <div class="section-title"><span class="eyebrow">CLASSEMENT</span></div>
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s)}</ol></div>
    ${hostAction(s,nextLabel)}`, 'reveal');
}
function renderHalftime(s) {
  shell(`${stage('<h2>MI-TEMPS</h2>', 'puzzled', 'halftime')}
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s,30)}</ol></div>
    ${hostAction(s,'LANCER LA 2E MI-TEMPS')}`, 'halftime');
}
function renderFinished(s) {
  const top=(s.standings||[]).slice(0,3);
  const order=top.length >= 3 ? [top[1],top[0],top[2]] : top.length===2?[top[1],top[0]]:top;
  const podium=order.map(p=> {
    const position=top.indexOf(p)+1;
    const tier=position===1?'first':position===3?'third':'';
    return `<div class="pod ${tier}"><span class="circle">${firstLetter(p.name)}</span><span class="name">${safe(p.name)}</span><span class="points">${p.score} PTS</span><div class="step">${position}</div></div>`;
  }).join('');
  shell(`${stage('<h2>PODIUM</h2>', 'victory', 'podium')}
    <h2 class="champion-name">${safe(top[0]?.name || 'AS Grinta')}</h2>
    <div class="podium">${podium}</div>
    <div class="section-title"><span class="eyebrow">CLASSEMENT FINAL</span></div>
    <div class="panel ranking-panel"><ol class="small-list">${rankingRows(s,30)}</ol></div>
    ${isRehearsal ? '<button type="button" class="primary practice-again" data-repeat-rehearsal>NOUVELLE PARTIE</button>' : ''}
    <a class="quiet-link" href="../">RETOUR AUX JEUX</a>`, 'finished');
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
    if(counter) counter.textContent=String(state.question?.answered_count || 0);
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
  if (!isRehearsal || !state?.is_host || state.phase!=='lobby' || lobbyActionBusy) return;
  lobbyActionBusy=true;
  const selector=rpcName==='asgq_rehearsal_add_bot'?'[data-add-bot]':null;
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

let hostActionBusy = false;
async function masterCommand(action) {
  if (!state?.is_host || hostActionBusy) return;
  if (action==='start' && state.phase!=='lobby') return;
  if (action==='next' && !['intro','question','reveal','halftime'].includes(state.phase)) return;
  hostActionBusy=true;
  const button=document.querySelector('[data-host-action]');
  if(button) button.disabled=true;
  try {
    const rpcName=isRehearsal ? (action==='start'?'asgq_rehearsal_start':'asgq_rehearsal_advance')
      : (action==='start'?'asgq_start':'asgq_advance');
    const args=action==='start' ? {p_token:token}
      : {p_token:token,p_expected_phase:state.phase,p_expected_position:state.position};
    const {error}=await api.rpc(rpcName,args);
    if(error) throw error;
    signature='';
    await fetchState();
  } catch(error) {
    toast(fmtError(error));
    if(button?.isConnected)button.disabled=false;
  } finally {
    hostActionBusy=false;
  }
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
  if(!state || state.is_host || state.phase!=='question' || sendingAnswer) return;
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
  const master=e.target.closest('[data-host-action]');
  if(master) {void masterCommand(master.dataset.hostAction);return}
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