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
  console.log('AS Grinta question pack validation: 8 scenarios OK');
} finally {
  fs.rmSync(temp,{recursive:true,force:true});
}
