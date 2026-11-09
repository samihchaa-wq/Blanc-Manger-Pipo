/* AS Grinta 2026 — purely local, disposable showcase.
 * This preview never calls Supabase, creates a room or touches final questions.
 * Not a multiplayer test: illustrative opponents have simulated scores.
 */
'use strict';
const root = document.getElementById('demo-app');
const questions = [
  {half:1, text:'Quel club est à l’honneur ce soir ?', choices:['AS Grinta','FC Démo','Le Soulieteur','Un autre club'], correct:0},
  {half:1, text:'Sur quel appareil tout le monde jouera-t-il ?', choices:['Une télévision','Un téléphone','Une console','Sur papier'], correct:1},
  {half:2, text:'Combien de joueurs une équipe aligne-t-elle au coup d’envoi ?', choices:['9','10','11','12'], correct:2},
  {half:2, text:'Quel carton signifie une expulsion ?', choices:['Vert','Jaune','Bleu','Rouge'], correct:3}
];
const duration = {lobby:4500, intro:2500, question:18000, reveal:6000, halftime:4500};
let phase = 'ready';
let index = 0;
let selected = null;
let earned = 0;
let deadline = null;
let began = null;
const playerName = (() => {
  try {return (localStorage.getItem('pdcat-name') || 'Toi').trim().slice(0,22) || 'Toi'}
  catch (_) {return 'Toi'}
})();
const players = [
  {id:'demo-me',name:playerName,score:0},
  {id:'demo-2',name:'Joueur 2',score:0},
  {id:'demo-3',name:'Joueur 3',score:0}
];
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const letter = ['A','B','C','D'];
const nameOfHalf = n => n === 1 ? '1RE MI-TEMPS' : '2E MI-TEMPS';
const numberOfHalf = () => index + 1 - (questions[index].half === 2 ? 2 : 0);
const remaining = () => Math.max(0, (deadline || Date.now())-Date.now());
const seconds = () => Math.ceil(remaining()/1000);

function hero(label,title,detail) {
  return '<div class="hero"><div class="eyebrow">'+label+'</div><h2>'+title+'</h2><p>'+detail+'</p></div>';
}
function timer(label) {
  return '<div class="timer-line"><span class="eyebrow">'+label+'</span><div class="big-timer" id="clock">--</div></div><div class="bar"><i id="time-progress"></i></div>';
}
function ranking(max=5) {
  const ordered = players.slice().sort((a,b)=>b.score-a.score);
  return ordered.slice(0,max).map((p,i)=>
    '<li class="'+(p.id==='demo-me'?'you':'')+'"><span class="rank-no">'+(i+1)+
    '</span><span class="avatar">'+esc(p.name.charAt(0).toUpperCase())+
    '</span><span class="rank-name">'+esc(p.name)+(p.id==='demo-me'?' · toi':'')+
    '</span><b>'+p.score+'</b></li>'
  ).join('');
}
function frame(html) {
  const skip = phase !== 'ready' && phase !== 'finished' ?
    '<button type="button" data-demo-next>Passer</button>' : '';
  root.innerHTML =
    '<section class="scene"><div class="demo-banner"><span>DÉMO · DONNÉES FICTIVES</span>'+
    '<div class="demo-controls">'+skip+'<a href="./">Quitter</a></div></div>'+
    html+'</section>';
  tickClock();
}
function render() {
  const q=questions[index];
  if(phase==='ready') {
    frame(hero('APERÇU INTERACTIF','LE GRAND <span class="gold">QUIZ.</span>',
      'Découvre les écrans de la soirée, sans créer de vraie partie.')+
      '<div class="panel center"><div class="eyebrow">UN MATCH EN DEUX MI-TEMPS</div>'+
      '<h2 class="demo-title">4 QUESTIONS FICTIVES</h2>'+
      '<p class="muted">Vestiaire, coup d’envoi, réponses, classement, mi-temps et podium. '+
      'Tu peux passer les étapes pour les découvrir plus vite.</p>'+
      '<button class="primary" type="button" data-demo-start>LANCER LA DÉMONSTRATION</button>'+
      '<p class="muted">Aucun mot de passe. Aucun joueur réel. Aucun score enregistré.</p></div>');
  } else if(phase==='lobby') {
    frame(hero('AVANT-MATCH','LE <span class="gold">VESTIAIRE</span>',
      'Les joueurs prennent place. Le coup d’envoi sera automatique.')+
      '<div class="panel"><div class="room-invite"><div><span class="eyebrow">CODE DE LA PARTIE</span>'+
      '<div class="room-code">DÉMO</div></div><button class="invite-button" disabled>Inviter</button></div>'+
      '<div class="timer-line"><span class="chip">3 JOUEURS CONNECTÉS</span><span class="eyebrow">AS GRINTA</span></div>'+
      timer('COUP D’ENVOI DANS')+
      '<p class="muted center">Simulation uniquement : ces joueurs ne sont pas connectés.</p>'+
      '<div class="section-title"><span class="eyebrow">DANS LE VESTIAIRE</span></div>'+
      '<ul class="roster">'+players.map(p=>
        '<li class="'+(p.id==='demo-me'?'me':'')+'"><span class="avatar">'+
        esc(p.name.charAt(0).toUpperCase())+'</span><span>'+esc(p.name)+'</span></li>'
      ).join('')+'</ul></div>');
  } else if(phase==='intro') {
    frame(hero('ÇA COMMENCE','PREMIÈRE <span class="gold">MI-TEMPS</span>',
      'AS Grinta. Prépare ton meilleur niveau.')+
      '<div class="panel center"><div class="metric"><span>COUP D’ENVOI DANS</span>'+
      '<div class="number" id="clock">--</div><span>La première question arrive automatiquement.</span>'+
      '</div><div class="bar"><i id="time-progress"></i></div></div>');
  } else if(phase==='question') {
    const answers=q.choices.map((value,i)=>
      '<button type="button" class="choice '+(selected===i?'selected':'')+
      '" data-demo-answer="'+i+'" aria-pressed="'+(selected===i)+'"><span class="letter">'+letter[i]+
      '</span><span>'+esc(value)+'</span></button>'
    ).join('');
    frame('<div class="kicker"><span>'+nameOfHalf(q.half)+'</span>'+
      '<span class="pos">QUESTION '+numberOfHalf()+' / 2</span></div>'+
      timer('TEMPS RESTANT')+
      '<div class="question-card" style="margin-top:22px"><div class="number">1 POINT EN JEU</div>'+
      '<h2>'+esc(q.text)+'</h2></div><div class="choices">'+answers+'</div>'+
      '<div class="response-note">'+(selected===null?'Choisis ta réponse avant la fin du chrono.':
      'Réponse enregistrée. Tu peux encore changer d’avis.')+'</div>'+
      '<div class="center muted" style="margin-top:auto">'+(selected===null?1:2)+
      ' / 3 réponses reçues (simulation)</div>');
  } else if(phase==='reveal') {
    const right=selected===q.correct;
    const response=q.choices.map((value,i)=>{
      const kind=i===q.correct?'correct':selected===i?'wrong':'dim';
      return '<div class="choice '+kind+'" role="listitem"><span class="letter">'+letter[i]+
        '</span><span>'+esc(value)+'</span></div>';
    }).join('');
    const verdict=right?'BIEN JOUÉ !':selected===null?'TEMPS ÉCOULÉ':'DOMMAGE !';
    frame('<div class="kicker"><span>RÉSULTAT · '+nameOfHalf(q.half)+
      '</span><span class="pos">QUESTION '+numberOfHalf()+' / 2</span></div>'+
      '<div class="panel center" style="margin-bottom:16px"><div class="result-status '+(right?'good':'bad')+'">'+
      verdict+'</div><div class="score-gain">+'+earned+' POINT'+(earned===1?'':'S')+'</div>'+
      '<p class="muted">'+esc(q.text)+'</p></div>'+
      '<div class="choices" role="list" style="margin-top:0">'+response+'</div>'+
      '<p class="muted">Question fictive pour découvrir l’interface.</p>'+
      '<div class="section-title"><span class="eyebrow">CLASSEMENT PROVISOIRE</span></div>'+
      '<div class="panel" style="padding:8px 18px"><ol class="small-list">'+ranking()+'</ol></div>'+
      timer('QUESTION SUIVANTE DANS'));
  } else if(phase==='halftime') {
    frame(hero('45 MINUTES · MI-TEMPS','PAUSE <span class="gold">VESTIAIRE</span>',
      'Place au classement de la première partie.')+
      '<div class="panel"><span class="eyebrow">LE CLASSEMENT À LA PAUSE</span>'+
      '<ol class="small-list" style="margin-top:16px">'+ranking()+'</ol>'+
      timer('REPRISE DANS')+'</div>'+
      '<p class="muted center">La deuxième mi-temps portera sur le football en général.</p>');
  } else if(phase==='finished') {
    const top=players.slice().sort((a,b)=>b.score-a.score);
    const order=[top[1],top[0],top[2]];
    const podium=order.map(p=>{
      const pos=top.indexOf(p)+1;
      const tier=pos===1?'first':pos===3?'third':'';
      return '<div class="pod '+tier+'"><span class="circle">'+
        esc(p.name.charAt(0).toUpperCase())+'</span><span class="name">'+esc(p.name)+
        '</span><span class="points">'+p.score+' PTS</span><div class="step">'+pos+'</div></div>';
    }).join('');
    frame(hero('COUP DE SIFFLET FINAL','LE GRAND <span class="gold">VAINQUEUR</span>',
      'Le quiz est terminé. Voici le verdict du vestiaire.')+
      '<div class="panel center"><div class="eyebrow">CHAMPION DE LA DÉMONSTRATION</div>'+
      '<h2 class="display demo-winner">'+esc(top[0].name)+'</h2>'+
      '<div class="podium">'+podium+'</div></div>'+
      '<div class="section-title"><span class="eyebrow">CLASSEMENT FINAL</span></div>'+
      '<div class="panel" style="padding:8px 18px"><ol class="small-list">'+ranking(30)+'</ol></div>'+
      '<button type="button" class="primary" data-demo-restart>REJOUER LA DÉMO</button>'+
      '<p class="muted center">Ce résultat est fictif et n’est jamais enregistré.</p>');
  }
}
function switchPhase(next) {
  phase=next;
  began=Date.now();
  deadline=duration[next]?began+duration[next]:null;
  render();
}
function start() {
  index=0;selected=null;earned=0;
  players.forEach(p=>p.score=0);
  switchPhase('lobby');
}
function advance() {
  if(phase==='ready'||phase==='finished')return;
  if(phase==='lobby'){switchPhase('intro');return}
  if(phase==='intro'){switchPhase('question');return}
  if(phase==='question'){
    earned=selected===questions[index].correct?1:0;
    players[0].score+=earned;
    if([0,1,3].includes(index))players[1].score++;
    if([1,2].includes(index))players[2].score++;
    switchPhase('reveal');return;
  }
  if(phase==='reveal'){
    if(index===1){switchPhase('halftime');return}
    if(index===questions.length-1){switchPhase('finished');return}
    index++;selected=null;earned=0;switchPhase('question');return;
  }
  if(phase==='halftime'){index++;selected=null;earned=0;switchPhase('question')}
}
function tickClock() {
  const clock=document.getElementById('clock');
  if(clock) {
    const s=seconds();
    clock.textContent=s<60?s+'s':Math.floor(s/60)+':'+String(s%60).padStart(2,'0');
    clock.classList.toggle('urgent',remaining()<=5000 && remaining()>0);
  }
  const fill=document.getElementById('time-progress');
  if(fill && deadline && began) {
    const total=deadline-began;
    fill.style.width=(Math.max(0,Math.min(100,100*remaining()/total)))+'%';
  }
}
root.addEventListener('click',e=>{
  if(e.target.closest('[data-demo-start],[data-demo-restart]')){start();return}
  if(e.target.closest('[data-demo-next]')){advance();return}
  const answer=e.target.closest('[data-demo-answer]');
  if(answer && phase==='question' && remaining()>0){
    selected=Number(answer.dataset.demoAnswer);
    render();
  }
});
setInterval(()=>{
  if(deadline && Date.now()>=deadline && phase!=='finished')advance();
  tickClock();
},150);
render();
