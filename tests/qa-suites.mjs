// Manifeste des tests métiers sur le schéma réel Supabase.
// Les scripts SQL sont exécutés sous ROLLBACK, sans laisser de parties fictives.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const suites = [
  ['qa_multiplayer_core_modes.sql', ['phrases','priorites','ondes']],
  ['qa_multiplayer_bac_mimes.sql', ['bac','mimes']],
  ['qa_multiplayer_white.sql', ['white']],
  ['qa_multiplayer_dico_dilemme.sql', ['dico','dilemme']],
  ['qa_multiplayer_resilience.sql', ['phrases','priorites','ondes','bac','white','mimes','dico','dilemme']],
  ['qa_multiplayer_timeouts.sql', ['phrases','priorites','ondes','bac','white','mimes','dico','dilemme']],
  ['qa_multiplayer_capacity.sql', ['phrases','priorites','ondes','bac','white','mimes','dico','dilemme']],
  ['qa_white_distribution_full.sql', ['white']],
  ['qa_white_shared_victory.sql', ['white']],
];
for (const [filename, games] of suites) {
  const s=readFileSync(new URL('../supabase/tests/'+filename,import.meta.url),'utf8');
  assert.match(s,/^begin;/im,filename+' doit ouvrir une transaction');
  assert.match(s,/^rollback;\s*$/im,filename+' doit annuler les parties de test');
  assert.match(s,/raise exception/i,filename+' doit avoir des assertions réelles');
  assert.match(s,/public\.(create_room|lancer_partie|submit_)/i,filename+' doit appeler les vraies fonctions');
  assert.doesNotMatch(s,/\b(drop table|truncate|alter role|grant all)\b/i,filename+' ne doit pas faire de DDL dangereux');
  for (const game of games) assert.ok(s.toLowerCase().includes(game),filename+' doit couvrir '+game);
}
const migration=readFileSync(new URL('../supabase/migrations/20261118120000_restore_dico_dilemme_revotes.sql',import.meta.url),'utf8');
assert.match(migration,/CREATE OR REPLACE FUNCTION public\.dico_vote/i);
assert.match(migration,/CREATE OR REPLACE FUNCTION public\.dilemme_vote/i);
assert.match(migration,/on conflict \(room_id, round, voter_id\) do update set def_id = excluded.def_id/i);
assert.match(migration,/Une proposition est présente plusieurs fois/);
assert.match(migration,/delete from public\.dilemme_votes where room_id = r\.id and round = r\.round and voter_id = me\.id/);
const dico=readFileSync(new URL('../js/jeux/dico.js',import.meta.url),'utf8');
const dil=readFileSync(new URL('../js/jeux/dilemme.js',import.meta.url),'utf8');
assert.match(dico,/Tu peux encore changer d’avis/);
assert.match(dil,/Tu peux encore changer d’avis/);
console.log('QA : 9 suites transactionnelles, capacités maximales et répartition Mr White.');
