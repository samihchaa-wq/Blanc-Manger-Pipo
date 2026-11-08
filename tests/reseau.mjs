// Régressions réseau : deux relectures concurrentes, changement de session et départ hors ligne.
// Ces tests utilisent le vrai code, isolé dans une VM, sans appeler Supabase.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const core = readFileSync(new URL('../js/core.js', import.meta.url), 'utf8');
const start = core.indexOf('/* ---------- Réseau ---------- */');
const end = core.indexOf('function connect(){', start);
assert.ok(start > 0 && end > start, 'Bloc réseau introuvable');
const network = core.slice(start, end);

const calls = [];
const alerts = [];
let renders = 0;
const ctx = vm.createContext({
  session: { code:'1234', token:'ancien' }, state:null, last:'', pun:null,
  busy:false, pressedEl:null, lastSync:0, picks:[], picked:null, readIndex:0,
  rankView:null, qpick:null, dialVal:50, clueDraft:'', mimeNotes:{}, dicoPage:null,
  dicoSel:null, dicoDraft:'', dilChoix:null, dilStartDraft:'', dilButDraft:'',
  dilVotes:{}, dealPending:false, punDrafts:[], punAnimAt:0, punTimer:null,
  GAMES:{ phrases:{} }, Date, JSON, clearTimeout, setTimeout,
  sb:{rpc:(name,args)=>new Promise(resolve=>calls.push({name,args,resolve}))},
  toast:m=>alerts.push(m), render:()=>{renders++}, scheduleAuto:()=>{},
  rechargerSiPossible:()=>{}, ping:()=>{}, bacSync:()=>{}, minPlayers:()=>3,
  leaveLocal:()=>{throw Error('Ne jamais effacer la nouvelle session')},
});
vm.runInContext(network, ctx);

const example = round => ({
  room:{ status:'lobby', mode:'phrases', round }, players:[], me:{id:'moi'}
});
const reply = (call, round) => call.resolve({
  data:{ state:example(round), white:null, pun:null }, error:null
});

// La réponse ancienne arrive en dernier : elle ne doit pas écraser la récente.
const a = vm.runInContext('refresh(true)',ctx);
const b = vm.runInContext('refresh(true)',ctx);
assert.equal(calls.length, 2);
reply(calls[1], 2);
await b;
reply(calls[0], 1);
await a;
assert.equal(ctx.state.room.round, 2, 'Une réponse obsolète a écrasé le salon');
assert.equal(renders, 1, 'La réponse obsolète a provoqué un affichage');

// Le serveur annonce une session expirée, mais l'utilisateur a déjà rejoint un autre salon.
const ancienne = vm.runInContext('refresh(true)',ctx);
assert.equal(calls.length, 3);
ctx.session = { code:'5678', token:'nouveau' };
calls[2].resolve({ data:null, error:{message:'Session expirée. Rejoins la partie.'} });
await ancienne;
assert.equal(ctx.session.code, '5678', 'Une ancienne erreur a détruit la nouvelle session');

// Le chemin de repli (ancien serveur) doit garder le token de sa lecture initiale.
const fallback = vm.runInContext('refresh(true)',ctx);
calls[3].resolve({ data:null, error:{message:'PGRST202 Could not find the function get_full_state'} });
await Promise.resolve(); await Promise.resolve();
assert.equal(calls[4]?.name, 'get_state', 'Repli get_state attendu');
ctx.session = { code:'9999', token:'encore-un-autre' };
reply(calls[4], 3); // Le salon a changé pendant la lecture.
await Promise.resolve(); await Promise.resolve();
assert.equal(ctx.session.code, '9999');
assert.equal(calls[4].args.p_token, 'nouveau', 'Le repli doit utiliser le token initial');
// En mode lobby le repli appelle également punish_state, on le résout.
if (calls[5]?.name === 'punish_state') calls[5].resolve({data:null,error:null});
await fallback;
assert.equal(ctx.state.room.round, 2, 'Une lecture du salon précédent a été affichée');

// Quitter : ne jamais abandonner le token si le serveur n'a pas confirmé.
const actions = readFileSync(new URL('../js/actions.js', import.meta.url), 'utf8');
const leave = actions.slice(actions.indexOf("surAction('leave'"), actions.indexOf('// De retour dans l’appli'));
let leaveFn, left=0, errorMessage='';
const lc=vm.createContext({
  session:{code:'1234',token:'secret'}, state:{room:{status:'lobby'}},busy:false,
  surAction:(name,fn)=>{if(name==='leave') leaveFn=fn},
  rpc:async()=>{throw Error('Erreur réseau')}, ping:()=>{},
  leaveLocal:()=>{left++}, toast:m=>{errorMessage=m}, confirm:()=>true,
});
vm.runInContext(leave,lc);
await leaveFn();
assert.equal(left,0, 'Le départ non confirmé ne doit pas vider la session');
assert.ok(errorMessage.includes('Départ non confirmé'));
assert.equal(lc.session.token,'secret');
assert.equal(lc.busy,false,'Le verrou doit être libéré après erreur');

console.log('Tests de fiabilité réseau et de départ réussis.');
