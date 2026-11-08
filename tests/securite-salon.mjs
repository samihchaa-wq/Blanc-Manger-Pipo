// Contrat client + SQL : une connexion refusée ne crée jamais de session.
// La vérification SQL dynamique est dans supabase/tests/room_join_rate_limits.sql.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source=readFileSync(new URL('../js/ecrans/accueil.js',import.meta.url),'utf8');
const begin=source.indexOf('async function enter(call, name){');
const end=source.indexOf('/* ---------- Actions ---------- */',begin);
assert.ok(begin>=0 && end>begin,'Fonction enter introuvable');

let saved=null, started=0, feedback='';
const ctx=vm.createContext({
  busy:false,homeCode:null,reply:null,
  localStorage:{setItem(){}},
  history:{replaceState(){}},
  location:{pathname:'/jeu/'},
  save:value=>{saved=value},
  startSession:()=>{started++},
  toast:value=>{feedback=value},
});
vm.runInContext(source.slice(begin,end),ctx);

ctx.reply={error:'Trop de tentatives. Réessaie dans quelques minutes.',error_code:'RATE_LIMITED'};
await vm.runInContext("enter(() => Promise.resolve(reply), 'Test')",ctx);
assert.equal(saved,null,'Un refus ne doit pas créer de session');
assert.equal(started,0,'Un refus ne doit pas lancer le jeu');
assert.match(feedback,/Trop de tentatives/);
assert.equal(ctx.busy,false,'La saisie doit se débloquer après un refus');

feedback='';
ctx.reply={error:'Aucune partie avec ce code.',error_code:'JOIN_REJECTED'};
await vm.runInContext("enter(() => Promise.resolve(reply), 'Test')",ctx);
assert.equal(started,0);
assert.match(feedback,/Aucune partie/);

feedback='';
ctx.reply={};
await vm.runInContext("enter(() => Promise.resolve(reply), 'Test')",ctx);
assert.equal(started,0);
assert.match(feedback,/Réponse du serveur invalide/);

ctx.reply={code:'1234',token:'session-de-test'};
await vm.runInContext("enter(() => Promise.resolve(reply), 'Test')",ctx);
assert.equal(started,1,'Une connexion valable doit rester possible');
assert.equal(saved.code,'1234');
assert.equal(saved.token,'session-de-test');

const sql=readFileSync(new URL('../supabase/migrations/20261114120000_room_join_rate_limits.sql',import.meta.url),'utf8');
assert.match(sql,/create table if not exists public\.room_join_limits/i);
assert.match(sql,/alter table public\.room_join_limits enable row level security/i);
assert.match(sql,/revoke all on table public\.room_join_limits from PUBLIC, anon, authenticated/i);
assert.match(sql,/pg_advisory_xact_lock/,'Les tentatives concurrentes doivent être sérialisées');
assert.match(sql,/on conflict \(client_hash\) do update set/,'Le compteur doit persister dans la base');
assert.match(sql,/failures = failures \+ 1/,'Les échecs doivent être comptés');
assert.match(sql,/if rl\.requests > 48 or rl\.failures >= 8/,'Limiter la fréquence et les mauvais codes');
assert.match(sql,/return json_build_object\('error', err/,'Ne pas annuler les compteurs avec une exception SQL');
assert.doesNotMatch(sql,/raise exception/i,'Les refus attendus ne doivent pas provoquer de rollback SQL');
const pages=readFileSync(new URL('../.github/workflows/pages.yml',import.meta.url),'utf8');
assert.match(pages,/needs: test/,'Le déploiement attend la CI');
for (const script of ['sanity','reseau','securite-salon'])
  assert.ok(pages.includes('node tests/'+script+'.mjs'),script+' doit bloquer un déploiement cassé');

console.log('Sécurité des connexions : tests client et invariants SQL réussis.');
