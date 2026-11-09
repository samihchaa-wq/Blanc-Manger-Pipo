/* Grand Quiz AS Grinta 2026 — mobile-only, single event.
 * Adapted from the Soulieteur QCM's synchronized answering / scoring model.
 * The server owns time, scoring, transitions and secret answers. No host or regie.
 */
'use strict';

const SUPABASE_URL = 'https://yqfewxadpyulgxehhpcu.supabase.co';
// Publishable client key, NOT a service-role secret.
const SUPABASE_KEY = 'sb_publishable_Qdso-n_uVYAH1_YzjSLYlQ_rOWg93tg';
const api = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const storeKey = 'asgq-2026-participant';
const app = document.getElementById('app');
const notice = document.getElementById('notice');
const letters = ['A','B','C','D'];
let token = null;
let state = null;
let serverDelta = 0;
let signature = '';
let requesting = false;
let sendingAnswer = false;
let chosenOptimistically = null;
let noticeTimer = null;
let lastConnectionError = false;
const codeFromLink = (new URLSearchParams(location.search).get('code') || '').replace(/[^0-9]/g,'').slice(0,8);
let entryMode = codeFromLink.length === 8 ? 'join' : 'create';

try { token = localStorage.getItem(storeKey); } catch (_) {}
const safe = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const firstLetter = name => safe((name || 'G').trim().slice(0,1).toUpperCase());
const date = value => value ? Date.parse(value) : null;
const now = () => Date.now() + serverDelta;
const deadline = () => date(state?.phase === 'lobby' ? state.starts_at : state?.phase_until);
const timeRemaining = () => Math.max(0,(deadline() ?? now()) - now());
const sec = ms => Math.ceil(ms / 1000);
const waitText = seconds => seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2,'0')}`;
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
  const e = error?.message || 'Connexion impossible.';
  return e.replace(/^JSON object requested, multiple \(or no\) rows returned.*/,'Session introuvable.');
}
function headerText(overline, title, sub) {
  return `<div class="hero"><div class="eyebrow">${overline}</div><h2>${title}</h2>${sub ? `<p>${sub}</p>` : ''}</div>`;
}
function timerLine(label) {
  return `<div class="timer-line"><div class="eyebrow">${label}</div><div class="big-timer" id="clock">--</div></div><div class="bar"><i id="time-progress"></i></div>`;
}
function shell(html, key) {
  app.innerHTML = `<section class="scene" data-screen="${key}">${html}</section>`;
  updateClocks();
}
function renderJoin() {
  signature = 'join-' + entryMode;
  let savedName = '';
  try { savedName = localStorage.getItem('pdcat-name') || '' } catch (_) {}
  const isCreate = entryMode === 'create';
  shell(`
    <div class="hero"><div class="eyebrow">LA GRANDE SOIRÉE 2026</div>
      <h1>LE GRAND<br><span class="gold">QUIZ.</span></h1>
      <p>Deux mi-temps. Une seule équipe. Un seul champion.</p></div>
    <div class="entry-tabs" role="tablist" aria-label="Accès au quiz">
      <button type="button" data-entry-mode="create" role="tab" aria-selected="${isCreate}" class="${isCreate?'on':''}">Créer</button>
      <button type="button" data-entry-mode="join" role="tab" aria-selected="${!isCreate}" class="${!isCreate?'on':''}">Rejoindre</button>
    </div>
    <form class="panel" id="join-form" autocomplete="off">
      <div class="eyebrow" style="margin-bottom:22px">${isCreate?'CRÉER LA PARTIE':'REJOINDRE LE VESTIAIRE'}</div>
      <label class="field"><span>TON PRÉNOM</span><input id="player-name" maxlength="22" minlength="2" required placeholder="Ex. : Alban" autocomplete="nickname" value="${safe(savedName)}"></label>
      ${isCreate
        ? '<label class="field"><span>MOT DE PASSE ADMIN+ (CRÉATION UNIQUEMENT)</span><input class="code" id="admin-password" type="password" required autocomplete="off" placeholder="••••••••" aria-label="Mot de passe Admin+"></label>'
        : `<label class="field"><span>CODE DE LA PARTIE</span><input class="code" id="room-code" type="text" inputmode="numeric" pattern="[0-9]{8}" maxlength="8" required autocomplete="one-time-code" placeholder="•••• ••••" value="${safe(codeFromLink)}" aria-label="Code de la partie à 8 chiffres"></label>`}
      <button type="submit" class="primary" id="join-button">${isCreate?'CRÉER LA PARTIE':'REJOINDRE LA PARTIE'}</button>
      <p class="muted center" style="margin:20px 0 0">${isCreate
        ? 'Admin+ sert uniquement à créer la partie. Les autres joueurs utilisent le code à 8 chiffres.'
        : 'Demande le code de salon au créateur. Aucun mot de passe Admin+ nécessaire.'}</p>
    </form>`, 'join');
}
function renderLobby(s) {
  const count = s.players.length;
  const players = s.players.map(p => `<li class="${p.id === s.me.id ? 'me' : ''}"><span class="avatar">${firstLetter(p.name)}</span><span>${safe(p.name)}</span></li>`).join('');
  shell(`
    ${headerText('AVANT-MATCH', 'LE <span class="gold">VESTIAIRE</span>', 'Les joueurs prennent place. Le coup d’envoi sera automatique.')}
    <div class="panel">
      <div class="room-invite"><div><span class="eyebrow">CODE DE LA PARTIE</span><div class="room-code">${safe(s.room_code || '--------')}</div></div>
        <button type="button" class="invite-button" data-share-room ${s.room_code?'':'disabled'}>Inviter</button></div>
      <div class="timer-line"><span class="chip">${count} JOUEUR${count>1?'S':''} CONNECTÉ${count>1?'S':''}</span><span class="eyebrow">AS GRINTA</span></div>
      ${s.starts_at ? `${timerLine('COUP D’ENVOI DANS')}<p class="muted center">Tout commence automatiquement à zéro.</p>` : `<p class="muted center">${!s.ready ? 'Le quiz est en préparation. Le coup d’envoi sera activé lorsque les deux mi-temps seront prêtes.' : 'Le compte à rebours débutera dès que deux joueurs auront rejoint le vestiaire.'}</p>`}
      <div class="section-title"><span class="eyebrow">DANS LE VESTIAIRE</span></div>
      <ul class="roster">${players}</ul>
    </div>`, 'lobby');
}
function renderIntro(s) {
  shell(`${headerText('ÇA COMMENCE', 'PREMIÈRE <span class="gold">MI-TEMPS</span>', 'AS Grinta. Prépare ton meilleur niveau.')}
    <div class="panel center"><div class="metric"><span>COUP D’ENVOI DANS</span><div class="number" id="clock">--</div><span>La première question arrive automatiquement.</span></div><div class="bar"><i id="time-progress"></i></div></div>`, 'intro');
}
function renderQuestion(s) {
  const q = s.question || {};
  const choice = chosenOptimistically !== null ? chosenOptimistically : q.my_choice;
  const choices = (q.choices || []).map((answer,i)=> `<button class="choice ${choice === i ? 'selected' : ''}" data-answer="${i}" aria-pressed="${choice === i}" type="button" ${sendingAnswer ? 'disabled' : ''}><span class="letter">${letters[i]}</span><span>${safe(answer)}</span></button>`).join('');
  shell(`<div class="kicker"><span>${topText(s.half)}</span><span class="pos">QUESTION ${halfNum(s)} / ${totalHalf(s)}</span></div>
    ${timerLine('TEMPS RESTANT')}
    <div class="question-card" style="margin-top:22px"><div class="number">${q.points || 1} POINT${q.points > 1?'S':''} EN JEU</div><h2>${safe(q.text)}</h2></div>
    <div class="choices">${choices}</div>
    <div class="response-note">${choice === null || choice === undefined ? 'Choisis ta réponse avant la fin du chrono.' : 'Réponse enregistrée. Tu peux encore changer d’avis.'}</div>
    <div class="center muted" style="margin-top:auto"><span id="answer-counter">${q.answered_count || 0}</span> / ${s.players.length} réponses reçues</div>`, 'question');
}
function rankingRows(s, count = 5) {
  return (s.standings || []).slice(0,count).map((p,i)=>`<li class="${p.id===s.me.id?'you':''}"><span class="rank-no">${i+1}</span><span class="avatar">${firstLetter(p.name)}</span><span class="rank-name">${safe(p.name)}${p.id===s.me.id?' · toi':''}</span><b>${p.score}</b></li>`).join('');
}
function renderReveal(s) {
  const q = s.question || {};
  const success = q.my_choice === q.correct;
  const answered = q.my_choice !== null && q.my_choice !== undefined;
  const choices = (q.choices || []).map((answer,i)=> {
    const correct = i === q.correct;
    const mineWrong = q.my_choice === i && !correct;
    const cls = correct?'correct':mineWrong?'wrong':'dim';
    return `<div class="choice ${cls}" role="listitem"><span class="letter">${letters[i]}</span><span>${safe(answer)}</span></div>`;
  }).join('');
  const verdict = success ? 'BIEN JOUÉ !' : answered ? 'DOMMAGE !' : 'TEMPS ÉCOULÉ';
  const outcome = `<div class="result-status ${success?'good':'bad'}">${verdict}</div>
    <div class="score-gain">+${q.earned ?? 0} POINT${q.earned === 1?'':'S'}</div>`;
  shell(`<div class="kicker"><span>RÉSULTAT · ${topText(s.half)}</span><span class="pos">QUESTION ${halfNum(s)} / ${totalHalf(s)}</span></div>
    <div class="panel center" style="margin-bottom:16px">${outcome}<p class="muted">${safe(q.text)}</p></div>
    <div class="choices" role="list" style="margin-top:0">${choices}</div>
    ${q.explanation ? `<p class="muted">${safe(q.explanation)}</p>` : ''}
    <div class="section-title"><span class="eyebrow">CLASSEMENT PROVISOIRE</span></div>
    <div class="panel" style="padding:8px 18px"><ol class="small-list">${rankingRows(s)}</ol></div>
    ${timerLine('QUESTION SUIVANTE DANS')}`, 'reveal');
}
function renderHalftime(s) {
  shell(`${headerText('45 MINUTES · MI-TEMPS', 'PAUSE <span class="gold">VESTIAIRE</span>', 'Place au classement de la première partie.')}
    <div class="panel"><span class="eyebrow">LE CLASSEMENT À LA PAUSE</span><ol class="small-list" style="margin-top:16px">${rankingRows(s,30)}</ol>
    ${timerLine('REPRISE DANS')}</div>
    <p class="muted center">La deuxième mi-temps portera sur le football en général.</p>`, 'halftime');
}
function renderFinished(s) {
  const top = (s.standings||[]).slice(0,3);
  const order = top.length >= 3 ? [top[1],top[0],top[2]] : top.length===2?[top[1],top[0]]:top;
  const podium = order.map(p=> {
    const position=top.indexOf(p)+1;
    const tier=position===1?'first':position===3?'third':'';
    return `<div class="pod ${tier}"><span class="circle">${firstLetter(p.name)}</span><span class="name">${safe(p.name)}</span><span class="points">${p.score} PTS</span><div class="step">${position}</div></div>`;
  }).join('');
  shell(`${headerText('COUP DE SIFFLET FINAL', 'LE GRAND <span class="gold">VAINQUEUR</span>', 'Le quiz est terminé. Voici le verdict du vestiaire.')}
    <div class="panel center"><div class="eyebrow">CHAMPION DU GRAND QUIZ 2026</div>
      <h2 class="display" style="font-size:clamp(42px,12vw,69px);color:var(--gold);margin:13px 0">${safe(top[0]?.name || 'AS Grinta')}</h2>
      <div class="podium">${podium}</div>
    </div>
    <div class="section-title"><span class="eyebrow">CLASSEMENT FINAL</span></div>
    <div class="panel" style="padding:8px 18px"><ol class="small-list">${rankingRows(s,30)}</ol></div>
    <p class="muted center">Merci à tous les joueurs de l'AS Grinta.</p>`, 'finished');
}
function updateClocks() {
  if (!state) return;
  const t = deadline();
  if (!t) return;
  const remaining = Math.max(0,t-now());
  const clock = document.getElementById('clock');
  if (clock) {
    clock.textContent = waitText(sec(remaining));
    clock.classList.toggle('urgent',remaining <= 5000 && remaining > 0);
  }
  const start = date(state.phase_started_at);
  const total = t - (start || now());
  const pct = total>0 ? Math.max(0,Math.min(100,remaining/total*100)) : 0;
  const progress = document.getElementById('time-progress');
  if (progress) progress.style.width = `${pct}%`;
  // The normal 1.8 s polling interval advances expired phases without RPC storms.
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
    const {data,error}=await api.rpc('asgq_state',{p_token:token});
    if (error) throw error;
    if (!data || !data.me) throw new Error('Réponse du serveur invalide.');
    const atReceive=Date.now();
    serverDelta=date(data.now)-atReceive;
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
    const rpcName=creating ? 'asgq_create' : 'asgq_join_room';
    const args=creating ? {p_password:password,p_name:name} : {p_code:roomCode,p_name:name};
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
  if(!state || state.phase!=='question' || sendingAnswer || timeRemaining()<=0) return;
  const previous=state.question.my_choice;
  chosenOptimistically=index;
  sendingAnswer=true;
  renderState(true);
  try {
    const {error}=await api.rpc('asgq_answer',{p_token:token,p_choice:index});
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
  const mode=e.target.closest('[data-entry-mode]');
  if(mode) {
    const name=document.getElementById('player-name')?.value.trim();
    if(name) try { localStorage.setItem('pdcat-name',name) } catch(_){}
    entryMode=mode.dataset.entryMode==='join'?'join':'create';
    renderJoin();
    return;
  }
  if(e.target.closest('[data-share-room]')) {void shareRoom();return}
  const button=e.target.closest('[data-answer]');
  if(button) void answer(Number(button.dataset.answer));
});
app.addEventListener('input',e=>{
  if(e.target.id==='room-code') e.target.value=e.target.value.replace(/[^0-9]/g,'').slice(0,8);
});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)void fetchState()});
setInterval(updateClocks,200);
setInterval(()=>{if(token && !requesting)void fetchState()},1800);
if(token) void fetchState(); else renderJoin();