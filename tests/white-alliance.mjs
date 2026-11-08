// Teste le VRAI rendu des résultats de Mr White, sans navigateur externe.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source=readFileSync(new URL('../js/jeux/mr-white.js',import.meta.url),'utf8');
const start=source.indexOf('function whiteTeamNames(group){');
const end=source.indexOf('// La carte de l\'éliminé se retourne',start);
assert.ok(start!==-1 && end>start,'Fonctions de résultat Mr White introuvables');

const players=[
  {id:'civ1',name:'Camille',active:true},
  {id:'under',name:'Léo',active:true},
  {id:'white',name:'Nour',active:true},
  {id:'civ2',name:'Aïcha',active:true}
];
const ctx=vm.createContext({
  state:{white:null},
  P:id=>players.find(p=>p.id===id),
  nameOf:id=>players.find(p=>p.id===id)?.name||'?',
});
vm.runInContext(source.slice(start,end),ctx);
const display=(winner,roles)=> {
  ctx.state.white={winner,roles};
  return vm.runInContext('whiteWinnerSentence()',ctx);
};
const roles=[
  {player_id:'civ1',role:'civil',out:false},
  {player_id:'under',role:'undercover',out:false},
  {player_id:'white',role:'white',out:false},
  {player_id:'civ2',role:'civil',out:true}
];
const together=display('alliance',roles);
assert.match(together,/Léo.*Imposteur/);
assert.match(together,/Nour.*Mr White/);
assert.match(together,/ont gagné ensemble/);
assert.doesNotMatch(together,/Camille|Aïcha/,'Un Civil n\'a pas gagné avec eux');

const noWhite=display('imposteurs',roles.map(r=>r.player_id==='white'?{...r,out:true}:r));
assert.match(noWhite,/Léo/);
assert.doesNotMatch(noWhite,/Nour/,'Mr White éliminé ne gagne pas');

const onlyWhite=display('white',roles.map(r=>r.player_id==='under'?{...r,out:true}:r));
assert.match(onlyWhite,/Nour/);
assert.match(onlyWhite,/a gagné/);
assert.doesNotMatch(onlyWhite,/Léo/);

const civils=display('civils',roles.map(r=>r.player_id==='under'||r.player_id==='white'?{...r,out:true}:r));
assert.match(civils,/Camille/);
assert.doesNotMatch(civils,/Léo|Nour/);

assert.equal(display('alliance',roles.map(r=>r.player_id==='white'?{...r,out:true}:r)),'',
 'Victoire mixte impossible si Mr White est éliminé');

const sql=readFileSync(new URL('../supabase/migrations/20261119120000_white_impostor_shared_victory.sql',import.meta.url),'utf8');
assert.match(sql,/_white_check_end\(p_room uuid\)/);
assert.match(sql,/_white_finish\(p_room uuid, p_winner text\)/);
assert.match(sql,/public\._white_finish\(p_room,'alliance'\)/);
assert.match(sql,/when 'alliance' then 'Mr White et l’Imposteur gagnent ensemble\.'/);
assert.match(sql,/when 'civil' then case when p_winner='civils' then civil_survivors else 0 end/);
assert.match(sql,/where wr\.eliminated_cycle is null or other\.eliminated_cycle<wr\.eliminated_cycle|wr\.eliminated_cycle is null or other\.eliminated_cycle<wr\.eliminated_cycle/);
assert.match(sql,/SECURITY DEFINER/i);
assert.ok((sql.match(/SET search_path TO ''/g)||[]).length===2);
const scenario=readFileSync(new URL('../supabase/tests/qa_white_shared_victory.sql',import.meta.url),'utf8');
assert.match(scenario,/^begin;/im);
assert.match(scenario,/^rollback;\s*$/im);
for(const name of ['alliance_one_civil','alliance_parity','undercover_only','white_only','civils','continue'])
  assert.ok(scenario.includes("'"+name+"'"),'Scénario SQL absent : '+name);
console.log('Mr White : co-victoire affichée, six règles de sortie SQL et barèmes préservés.');
