import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const main=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const files=[...main.matchAll(/<script src="(js\/[^"]+\.js)"><\/script>/g)].map(m=>m[1]);
assert.ok(files.length>=15,'La liste des scripts client est incomplète');
const script=files.map(f=>readFileSync(new URL('../'+f,import.meta.url),'utf8')).join('\n');
const called=new Set([...script.matchAll(/(?:rpc|act)\(\s*['"]([a-z][a-z_]+)['"]/g)].map(m=>m[1]));
// Sélection dynamique du bot et du jeu par la logique de l'hôte.
for(const fn of ['bot_step','white_bot_step','mime_bot_step','wave_bot_step']) called.add(fn);

const sql=readFileSync(new URL('../supabase/migrations/20261116120000_revoke_legacy_public_rpcs.sql',import.meta.url),'utf8');
const revoked=[...sql.matchAll(/^revoke execute on function public\.([a-z0-9_]+)\([^\n]*\) from PUBLIC, anon, authenticated;$/gim)].map(m=>m[1]);
assert.equal(revoked.length,26,'26 anciens points d’entrée doivent être fermés');
assert.equal(new Set(revoked).size,26,'Révocations en double');
for (const fn of revoked) assert.ok(!called.has(fn),fn+' est toujours appelé par le client');
for (const essential of [
  'create_room','join_room','get_full_state','get_state',
  'leave_room','lancer_partie','admin_level','admin_cards_list','punish_state',
  'white_state','white_vote','bot_step','reap_idle'
]) assert.ok(!revoked.includes(essential),essential+' doit rester accessible');

assert.match(sql,/^begin;$/m);
assert.match(sql,/^commit;$/m);
console.log('Audit des 26 anciens RPC publics : aucun appel client cassé.');
