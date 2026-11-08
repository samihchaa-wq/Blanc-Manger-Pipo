// Résilience de 8 téléphones SIMULÉS : vraies fonctions de gestion réseau
// du frontend, 8 contextes JavaScript indépendants, backend RPC contrôlé.
// Ne remplace pas une campagne sur huit appareils physiques.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../js/core.js', import.meta.url), 'utf8');
const begin = source.indexOf('/* ---------- Réseau ---------- */');
const end = source.indexOf('function connect(){', begin);
assert.ok(begin >= 0 && end > begin, 'Bloc réseau du client absent');
const network = source.slice(begin, end);
const pending = [];
const clients = [];

for (let i = 0; i < 8; i++) {
  let renders = 0, alerts = 0;
  const session = {code:'12345678', token:'joueur-' + i};
  const context = vm.createContext({
    session, state:null, last:'', pun:null, busy:false, pressedEl:null,
    lastSync:0, picks:[], picked:null, readIndex:0, rankView:null, qpick:null,
    dialVal:50, clueDraft:'', mimeNotes:{}, dicoPage:null, dicoSel:null,
    dicoDraft:'', dilChoix:null, dilStartDraft:'', dilButDraft:'', dilVotes:{},
    dealPending:false, punDrafts:[], punAnimAt:0, punTimer:null,
    GAMES:{phrases:{}}, Date, JSON, clearTimeout, setTimeout,
    sb:{rpc:(name,args)=>new Promise(resolve=>pending.push({i,name,args,resolve}))},
    toast:()=>{alerts++}, render:()=>{renders++}, scheduleAuto:()=>{},
    rechargerSiPossible:()=>{}, ping:()=>{}, bacSync:()=>{}, minPlayers:()=>3,
    leaveLocal:()=>{throw Error('Ne pas effacer une session changée')},
  });
  vm.runInContext(network, context);
  clients.push({context,session,get renders(){return renders},get alerts(){return alerts}});
}
const state = (round,room='12345678') => ({
  room:{code:room,status:'lobby',mode:'phrases',round},players:[],me:{id:'id'}
});
const respond = (call, round, room='12345678') => call.resolve({
  data:{state:state(round,room),white:null,pun:null},error:null
});
const one = (i,name) => {
  const ix = pending.findIndex(p=>p.i===i && p.name===name);
  assert.notEqual(ix,-1,'Appel '+name+' du client '+i+' absent');
  return pending.splice(ix,1)[0];
};

// Chaque appareil effectue deux lectures simultanées.
// Le réseau livre ensuite la nouvelle lecture AVANT l'ancienne.
const stale = clients.map(x=>vm.runInContext('refresh(true)',x.context));
const recent = clients.map(x=>vm.runInContext('refresh(true)',x.context));
assert.equal(pending.length,16,'Deux lectures doivent partir de chacun des huit appareils');
for(let i=7;i>=0;i--){respond(one(i,'get_full_state'),1)}
// On vient de résoudre ici la PREMIÈRE lecture, plus ancienne, pour chaque
// client. La seconde n'est pas encore répondue : aucun client ne doit afficher 1.
await Promise.all(stale);
for(const x of clients)assert.equal(x.context.state,null,'Ancien état affiché prématurément');
for(let i=0;i<8;i++)respond(one(i,'get_full_state'),2);
await Promise.all(recent);
for(const x of clients)assert.equal(x.context.state.room.round,2);
assert.equal(pending.length,0);
assert.equal(clients.reduce((n,x)=>n+x.renders,0),8);

// Huit actions en vol : chacune doit utiliser son propre jeton sans collision.
const actions=clients.map(x=>vm.runInContext("act('submit_guess',{p_value:50})",x.context));
assert.equal(pending.length,8);
const calls=pending.splice(0);
assert.equal(new Set(calls.map(x=>x.args.p_token)).size,8,'Jeton partagé entre clients');
for(const x of calls)assert.equal(x.args.p_code,'12345678');
for(const x of calls.reverse())x.resolve({data:null,error:null});
for(let i=0;i<30 && pending.length<8;i++)await Promise.resolve();
assert.equal(pending.length,8,'Les actions doivent déclencher une nouvelle lecture');
for(let i=0;i<8;i++)respond(one(i,'get_full_state'),3);
assert.deepEqual(await Promise.all(actions),Array(8).fill(true));
for(const x of clients)assert.equal(x.context.state.room.round,3);

// Double clic sur le même client : seule UNE action atteint le serveur.
const first=vm.runInContext("act('white_vote',{p_target:'cible'})",clients[0].context);
const second=await vm.runInContext("act('white_vote',{p_target:'cible'})",clients[0].context);
assert.equal(second,false,'Double clic : le deuxième appel doit être ignoré');
assert.equal(pending.length,1);
const req=one(0,'white_vote');req.resolve({data:null,error:null});
for(let i=0;i<20 && !pending.length;i++)await Promise.resolve();
respond(one(0,'get_full_state'),4);
assert.equal(await first,true);
assert.equal(clients[0].context.state.room.round,4);

// Changer de salon pendant une requête : l'ancien état est ignoré.
const old=vm.runInContext('refresh(true)',clients[1].context);
const reqOld=one(1,'get_full_state');
clients[1].context.session={code:'87654321',token:'nouvelle-session'};
const current=vm.runInContext('refresh(true)',clients[1].context);
const reqNew=one(1,'get_full_state');
assert.equal(reqOld.args.p_token,'joueur-1');
assert.equal(reqNew.args.p_token,'nouvelle-session');
respond(reqNew,1,'87654321');
await current;
respond(reqOld,99,'12345678');
await old;
assert.equal(clients[1].context.state.room.code,'87654321');
assert.equal(clients[1].context.state.room.round,1);

// Coupure réseau sur le troisième téléphone, puis reprise.
const beforeAlerts=clients[2].alerts;
const offline=vm.runInContext('refresh(true)',clients[2].context);
one(2,'get_full_state').resolve({data:null,error:{message:'Connexion indisponible'}});
await offline;
assert.equal(clients[2].context.state.room.round,3,'Une erreur réseau ne doit pas détruire la partie');
assert.equal(clients[2].alerts,beforeAlerts,'L'erreur non liée à une expiration ne doit pas déconnecter');
const back=vm.runInContext('refresh(true)',clients[2].context);
respond(one(2,'get_full_state'),5);
await back;
assert.equal(clients[2].context.state.room.round,5,'Un retour en ligne doit rattraper le nouvel état');
assert.equal(pending.length,0,'Aucune requête simulée en fuite');

console.log('QA 8 clients simulés : 16 lectures, 8 actions, double clic, changement de salon, coupure/reprise.');
