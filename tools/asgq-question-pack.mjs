#!/usr/bin/env node
// Usage: node tools/asgq-question-pack.mjs private-questions.json private-import.sql
// Only run locally: neither the JSON nor the resulting SQL may be committed.
import fs from 'node:fs';
import path from 'node:path';

const [input, output] = process.argv.slice(2);
const fail = msg => { throw new Error(msg); };
const clean = val => typeof val === 'string' ? val.trim().replace(/\s+/gu,' ') : '';
const quote = val => "'" + String(val).replaceAll("'", "''") + "'";
const int = (v,min,max,label) => {
  if (!Number.isInteger(v) || v < min || v > max) fail(label + ' : entier attendu de ' + min + ' à ' + max);
  return v;
};

try {
  if (!input || !output || process.argv.length !== 4) {
    fail('Usage : node tools/asgq-question-pack.mjs questions.json import.sql');
  }
  const data = JSON.parse(fs.readFileSync(input,'utf8'));
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      Object.keys(data).sort().join(',') !== 'as_grinta,football_general') {
    fail('Le document doit contenir exactement as_grinta et football_general.');
  }
  const rows = [];
  const seen = new Set();
  for (const [half,key] of [[1,'as_grinta'],[2,'football_general']]) {
    const questions = data[key];
    if (!Array.isArray(questions) || questions.length < 10 || questions.length > 20) {
      fail(key + ' : il faut entre 10 et 20 questions.');
    }
    questions.forEach((q,i)=>{
      const where = key + ' question ' + (i+1);
      if (!q || typeof q !== 'object' || Array.isArray(q) ||
          Object.keys(q).some(k=>!['texte','choix','bonne_reponse','points','explication'].includes(k))) {
        fail(where + ' : objet invalide.');
      }
      const text = clean(q.texte);
      if (text.length < 3 || text.length > 220 || /question de test|\(test\)/iu.test(text)) {
        fail(where + ' : question vide, trop longue ou fictive.');
      }
      const normalized = text.toLocaleLowerCase('fr');
      if (seen.has(normalized)) fail(where + ' : doublon.');
      seen.add(normalized);
      if (!Array.isArray(q.choix) || q.choix.length < 2 || q.choix.length > 4) {
        fail(where + ' : 2 à 4 réponses requises.');
      }
      const choices = q.choix.map(clean);
      if (choices.some(x=>x.length < 1 || x.length > 160 || /\(test\)/iu.test(x)) ||
          new Set(choices.map(x=>x.toLocaleLowerCase('fr'))).size !== choices.length) {
        fail(where + ' : choix invalides ou identiques.');
      }
      const correct = int(q.bonne_reponse,0,choices.length-1,where+' bonne_reponse');
      const points = q.points === undefined ? 1 : int(q.points,1,3,where+' points');
      if (q.explication !== undefined && typeof q.explication !== 'string') {
        fail(where + ' : explication doit être du texte.');
      }
      const explanation = clean(q.explication);
      if (explanation.length > 500) fail(where + ' : explication trop longue.');
      rows.push('(' + [
        rows.length+1,half,quote(text),'ARRAY['+choices.map(quote).join(',')+']::text[]',
        correct,points,explanation?quote(explanation):'NULL'
      ].join(',') + ')');
    });
  }

  // Reject *any* file inside the repository: several folders besides grinta-quiz
  // are copied verbatim to the public site, and even unpublished folders can
  // accidentally be committed to Git. Use private paths outside this checkout.
  const projectRoot = path.resolve('.');
  const isInsideRepository = location => {
    const resolved = path.resolve(location);
    return resolved === projectRoot || resolved.startsWith(projectRoot + path.sep);
  };
  if (isInsideRepository(input) || isInsideRepository(output)) {
    fail('Le fichier des questions et le SQL doivent rester hors du dépôt Git privé ou public.');
  }
  if (path.resolve(input) === path.resolve(output)) fail('Entrée et sortie identiques.');

  const sql = [
    '-- PRIVE: importer dans le SQL Editor Supabase uniquement. NE PAS COMMITTER.',
    'BEGIN;',
    'SET LOCAL standard_conforming_strings = on;',
    'DO $guard$ DECLARE phase_now text; is_armed boolean; creator_hash text; BEGIN',
    ' SELECT phase, armed, host_token_hash INTO phase_now, is_armed, creator_hash FROM asgq_private.event WHERE id=1 FOR UPDATE;',
    " IF phase_now IS DISTINCT FROM 'lobby' THEN RAISE EXCEPTION 'Quiz deja commence'; END IF;",
    " IF is_armed THEN RAISE EXCEPTION 'Quiz deja active'; END IF;",
    " IF creator_hash IS NULL OR (SELECT count(*) FROM asgq_private.players WHERE event_id=1) <> 1",
    "  OR NOT EXISTS(SELECT 1 FROM asgq_private.players p WHERE p.event_id=1 AND p.token_hash=creator_hash)",
    "  THEN RAISE EXCEPTION 'Import refuse : seul l animateur doit etre inscrit'; END IF;",
    'END $guard$;',
    'DELETE FROM asgq_private.questions;',
    'INSERT INTO asgq_private.questions(position,half,prompt,choices,correct_index,points,explanation) VALUES',
    rows.join(',\n') + ';',
    'DO $verify$ BEGIN',
    " IF NOT asgq_private.ready_for_kickoff() THEN RAISE EXCEPTION 'Questions invalides'; END IF;",
    'END $verify$;',
    'COMMIT;',
    '-- L evenement reste verrouille (armed=false).',
    ''
  ].join('\n');
  fs.writeFileSync(output,sql,{flag:'wx',mode:0o600});
  console.log('Questions validees : '+ data.as_grinta.length + ' AS Grinta, '+
    data.football_general.length+' football general. Import SQL prive cree.');
} catch (err) {
  console.error('Import refuse : '+err.message);
  process.exitCode=1;
}
