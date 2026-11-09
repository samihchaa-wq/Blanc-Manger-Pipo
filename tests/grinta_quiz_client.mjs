import fs from 'node:fs';
import assert from 'node:assert/strict';
import path from 'node:path';

const root=path.resolve(import.meta.dirname,'..');
const read = p => fs.readFileSync(path.join(root,p),'utf8');
const page=read('grinta-quiz/index.html');
const script=read('grinta-quiz/app.js');
const style=read('grinta-quiz/style.css');
const db=read('supabase/migrations/20261122140000_as_grinta_quiz_preflight_guard.sql');

new Function(script);
assert.match(page, /<main id="app"/, 'Dedicated phone screen missing');
assert.match(page, /\.\/app\.js/, 'Dedicated script missing');
assert.match(page, /\.\.\/vendor\/supabase\.js/, 'Use the existing pinned Supabase client');
assert.match(script, /\basgq_join\b/, 'Secret invite code join missing');
assert.match(script, /\basgq_state\b/, 'Server-driven status missing');
assert.match(script, /\basgq_answer\b/, 'Server-driven answer submission missing');
assert.match(script, /setInterval\(\(\)=>\{if\(token && !requesting\)/, 'Automatic polling missing');
assert.match(script, /renderHalftime/, 'Second-half separation missing');
assert.match(script, /renderFinished/, 'Podium missing');
assert.match(db, /first_half between 10 and 20/, 'Missing real question count gate');
assert.match(db, /second_half between 10 and 20/, 'Missing second half gate');
assert.match(db, /ev\.armed and asgq_private\.ready_for_kickoff\(\)/, 'Cannot arm a test-only quiz');
assert.doesNotMatch(page+script+style, /sb_secret_|service_role|private[_-]?key/i, 'Never expose privileged secrets');
assert.doesNotMatch(page+script+style, /QUESTION DE TEST|Réponse A \(test\)/i, 'Do not ship test questions to browsers');
console.log('ASGQ frontend / preflight checks OK');
