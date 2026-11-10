import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const temp = fs.mkdtempSync(path.join(os.tmpdir(),'grinta-quiz-pack-'));
const script = path.resolve('tools/asgq-question-pack.mjs');
const sample = n => ({
  texte:'Question numéro '+n+' pour le quiz ?',
  choix:["L'option A", 'Option B '+n, 'Option C','Option D'],
  bonne_reponse:n%4,
  points:1,
  explication:'Commentaire pour la révélation.'
});
const pack = (first,second) => ({
  as_grinta:Array.from({length:first},(_,i)=>sample(i+1)),
  football_general:Array.from({length:second},(_,i)=>sample(i+100))
});
let runId=0;
function run(data,success) {
  const id=++runId;
  const input=path.join(temp,'questions-'+id+'.json');
  const output=path.join(temp,'import-'+id+'.sql');
  fs.writeFileSync(input,JSON.stringify(data));
  const result=spawnSync(process.execPath,[script,input,output],{encoding:'utf8'});
  assert.equal(result.status,success?0:1,'Wrong exit status: '+result.stderr);
  assert.equal(fs.existsSync(output),success,'Output should only exist for valid packs');
  return success?fs.readFileSync(output,'utf8'):result.stderr;
}
try {
  const sql=run(pack(10,10),true);
  assert.match(sql,/L''option A/,'Apostrophes must be escaped in SQL');
  assert.match(sql,/FOR UPDATE/,'Database event must be locked before replacement');
  assert.match(sql,/as?gq_private\.ready_for_kickoff\(\)/,'Database readiness must be checked');
  assert.doesNotMatch(sql,/armed\s*=\s*true/iu,'Import must never activate the event');
  assert.match(sql,/SELECT phase, armed, host_token_hash/, 'Importer must identify the real host row');
  assert.match(sql,/count\(\*\) FROM asgq_private\.players WHERE event_id=1\) <> 1/, 'Import may continue with exactly one original host only');
  assert.match(sql,/p\.token_hash=creator_hash/, 'The single allowed account must be the current host');
  assert.doesNotMatch(sql,/IF EXISTS\(SELECT 1 FROM asgq_private\.players\) THEN/, 'Previous guard blocked every valid official event');
  run(pack(20,20),true);
  run(pack(9,10),false);
  run(pack(10,21),false);
  const duplicate=pack(10,10);
  duplicate.football_general[0].texte=duplicate.as_grinta[0].texte;
  run(duplicate,false);
  const badAnswer=pack(10,10);
  badAnswer.as_grinta[0].bonne_reponse=4;
  run(badAnswer,false);
  const duplicateChoice=pack(10,10);
  duplicateChoice.as_grinta[0].choix=['A','A'];
  run(duplicateChoice,false);
  const placeholder=pack(10,10);
  placeholder.as_grinta[0].texte='QUESTION DE TEST 1';
  run(placeholder,false);
  // The public app is not the only published folder; reject private answers
  // anywhere in the checkout (including tools/, js/, root and grinta-quiz/).
  const repositoryOutput=path.resolve('grinta-quiz/private-answers.sql');
  const protectedResult=spawnSync(process.execPath,[script,path.join(temp,'questions-1.json'),repositoryOutput],{encoding:'utf8'});
  assert.notEqual(protectedResult.status,0,'Must reject SQL saved under public app');
  assert.equal(fs.existsSync(repositoryOutput),false,'SQL must never be created in the repo');
  const rootOutput=path.resolve('asgq-import-private.sql');
  const rootResult=spawnSync(process.execPath,[script,path.join(temp,'questions-1.json'),rootOutput],{encoding:'utf8'});
  assert.notEqual(rootResult.status,0,'Must reject SQL saved at the repository root');
  assert.equal(fs.existsSync(rootOutput),false,'No SQL answers written into the repository');
  console.log('AS Grinta question pack validation: 10 scenarios OK');
} finally {
  fs.rmSync(temp,{recursive:true,force:true});
}
