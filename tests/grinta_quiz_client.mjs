import fs from 'node:fs';
import assert from 'node:assert/strict';
import path from 'node:path';

const root=path.resolve(import.meta.dirname,'..');
const read = p => fs.readFileSync(path.join(root,p),'utf8');
const page=read('grinta-quiz/index.html');
const script=read('grinta-quiz/app.js');
const style=read('grinta-quiz/style.css');
const home=read('js/ecrans/accueil.js');
const db=read('supabase/migrations/20261122140000_as_grinta_quiz_preflight_guard.sql');

new Function(script);
const serverBots=read('supabase/migrations/20261122180000_as_grinta_real_bot_rehearsal.sql');
assert.match(serverBots, /create schema if not exists asgq_rehearsal_private/, 'Must isolate test engine from official game');
assert.match(serverBots, /public\.asgq_rehearsal_create/, 'Admin+ rehearsal create missing');
assert.match(serverBots, /public\.asgq_rehearsal_join_room/, 'Guests need a standard room code in rehearsal');
assert.match(serverBots, /bot_order/, 'Server-side bot participant marker missing');
assert.match(serverBots, /insert into asgq_rehearsal_private\.answers\(/, 'Bots must submit stored real answers');
assert.match(serverBots, /as(g)?q_rehearsal_private\.tick\(\)/, 'Rehearsal must use the real timer state machine');
assert.match(script, /repetition/, 'Rehearsal launcher missing');
assert.match(script, /TESTER AVEC DES BOTS/, 'Link to real bot testing missing');
assert.match(script, /p_bots:0/, 'Bot rooms must start empty, ready to add bots one by one');
assert.match(script, /data-add-bot/, 'No add-bot lobby button');
assert.match(script, /data-start-quiz/, 'No manual kickoff');
assert.match(script, /asgq_rehearsal_add_bot/, 'Bot RPC missing');
assert.match(script, /asgq_rehearsal_start/, 'Host launch RPC missing');
assert.match(script, /asgq_rehearsal_remove_bot/, 'Bot removal RPC missing');
assert.match(script, /data-remove-bot/, 'Missing remove-bot button in roster');
const removeMigration=read('supabase/migrations/20261122191000_asgq_remove_bot_before_kickoff.sql');
assert.match(removeMigration, /host_token_hash is distinct from host_player\.token_hash/, 'Remove bot must be host-only');
assert.match(removeMigration, /bot_player\.bot_order is null/, 'Cannot remove real players via bot control');

const lobbyMigration=read('supabase/migrations/20261122190000_as_grinta_manual_lobby_20_provisional.sql');
assert.match(lobbyMigration, /ev\.manual_started and ev\.created/, 'Do not auto-start with bots');
assert.match(lobbyMigration, /create or replace function public\.asgq_rehearsal_add_bot/, 'Secure add bot RPC missing');
assert.match(lobbyMigration, /create or replace function public\.asgq_rehearsal_start/, 'Secure manual kickoff RPC missing');
assert.match(lobbyMigration, /delete from asgq_rehearsal_private\.players where event_id=1/, 'Rehearsal reset must limit player deletion to its event');
assert.match(lobbyMigration, /delete from asgq_rehearsal_private\.join_attempts where client_hash is not null/, 'Rehearsal reset must not run unrestricted deletes');
assert.doesNotMatch(lobbyMigration, /delete from asgq_rehearsal_private\.[a-z_]+\s*;/i, 'Every rehearsal DELETE must have a WHERE clause');
assert.doesNotMatch(script, /Ajoute tes bots dans le vestiaire|Les 20 questions sont réservées/, 'Do not clutter mobile game screens with explanatory copy');

assert.match(read('js/ecrans/accueil.js'), /repetition.*'1'/, 'The normal QCM create path must be repeatable until finalized');
assert.match(script, /asgq_rehearsal_state/, 'Test must read server-side state');
assert.match(script, /asgq_rehearsal_answer/, 'Test must submit answers to server');
assert.match(home, /asgq_rehearsal_join_room/, 'Rehearsal join must happen from Soulieteur');
assert.doesNotMatch(serverBots,/delete from asgq_private\.|update asgq_private\./, 'Rehearsal cannot touch official event tables');

const manual=read('supabase/migrations/20261122200000_asgq_host_manual_control.sql');
assert.match(manual,/create or replace function public\.asgq_advance\(p_token uuid,p_expected_phase text,p_expected_position integer\)/, 'Official host advance RPC missing');
assert.match(manual,/create or replace function public\.asgq_rehearsal_advance\(p_token uuid,p_expected_phase text,p_expected_position integer\)/, 'Rehearsal host advance RPC missing');
assert.match(manual,/ev\.host_token_hash is distinct from host_player\.token_hash/g, 'Host authentication must be enforced on server');
assert.match(manual,/ev\.phase is distinct from p_expected_phase or ev\.current_position is distinct from p_expected_position/, 'Duplicate presses must not skip phases');
assert.match(manual,/ev\.phase<>'question'/, 'Answers must be phase-locked, not time-locked');
assert.match(manual,/Bots answer when the host closes the question/, 'Bot answers must be host-triggered');
assert.match(manual,/where p\.token_hash is distinct from ev\.host_token_hash/, 'Host must be excluded from standings');
assert.doesNotMatch(script,/timerLine|timeRemaining|updateClocks|TEMPS RESTANT|TEMPS ÉCOULÉ|SUITE DANS|REPRISE DANS|setInterval\(updateClocks/, 'Quiz must not show any countdown');
assert.match(script,/hostControl\(s,'RÉVÉLER LA RÉPONSE'\)/, 'Host needs a reveal button');
// The host sees the actual player names still awaiting an answer, not 0/3.
const waitingMigration=read('supabase/migrations/20261123020000_asgq_waiting_names_and_room_mode.sql');
assert.equal((waitingMigration.match(/'waiting_players',case when ev.phase='question'/g)||[]).length,2,
 'Both quiz modes must return a pending list during a question only');
assert.equal((waitingMigration.match(/player_row.token_hash=ev.host_token_hash/g)||[]).length,2,
 'Pending names must only be returned to the host');
assert.match(waitingMigration,/participant.bot_order is null/, 'Bot simulations cannot be treated as real pending players');
assert.match(waitingMigration,/not exists\(/, 'Only players with no stored answer are pending');
assert.match(waitingMigration,/public\.asgq_room_mode\(p_code text\)/, 'The main Soulieteur home must recognize AS Grinta codes');
assert.match(waitingMigration,/v_requests>200 or v_failures>=12/, 'Router must be rate limited without exhausting legitimate shared-WiFi guest joins');
assert.match(waitingMigration,/asgq_private\.route_attempts/, 'Router must have an independent quota');
assert.equal((waitingMigration.match(/end \$fn\$;/g)||[]).length,2,'Terminate both RPC definitions before the router');
const waitingFn=script.match(/function waitingPlayersHtml\(s\) \{[\s\S]*?\n\}/)?.[0];
assert.ok(waitingFn,'Missing host waiting list renderer');
const waitingPlayersHtml=new Function('const safe=(v)=>String(v).replace(/</g,"&lt;");\n'+waitingFn+'\nreturn waitingPlayersHtml;')();
assert.match(waitingPlayersHtml({question:{waiting_players:[{name:'Camille'},{name:'Nina'}]}}),
  /On attend :[\s\S]*Camille[\s\S]*Nina/, 'List pending participant names');
assert.match(waitingPlayersHtml({question:{waiting_players:[]}}),
  /Tout le monde a répondu !/, 'Show all-answered status without auto advancing');
assert.match(waitingPlayersHtml({question:{waiting_players:null}}),
  /On attend les réponses/, 'Do not fabricate names without server data');
assert.doesNotMatch(waitingPlayersHtml({question:{waiting_players:[{name:'<script>'}]}}),
  /<script>/, 'Names must remain escaped');
assert.match(script,/counter\.innerHTML=waitingPlayersHtml\(state\)/,
  'Polling must refresh the pending names without reanimating the screen');
assert.match(script,/waiting_players:null/, 'Names changing during polling must not rerender the question');
assert.match(script,/id="answer-counter" role="status" aria-live="polite"/,
  'The list is an accessible live status');
assert.doesNotMatch(script,/\$\{q\.answered_count \|\| 0\} \/ \$\{playerCount\} réponses/,
  'Old numeric 0/3-style counter must be gone');
assert.doesNotMatch(script,/data-entry-mode=|id="room-code"|class="entry-tagline"/,
 'There must be no duplicate join option or welcome subtitle on the quiz landing');
assert.match(home,/asgq_room_mode/, 'The Soulieteur join screen needs code recognition');
assert.match(home,/asgq_join_room/, 'Official guests must join directly from Soulieteur');
assert.match(home,/asgq_rehearsal_join_room/, 'Rehearsal guests must join directly from Soulieteur');

const roundMigration=read('supabase/migrations/20261123010000_asgq_reveal_player_outcomes.sql');
assert.equal((roundMigration.match(/'responses',case when ev\.phase='reveal'/g)||[]).length,2,
  'Both state endpoints must hide all player outcomes until manual reveal');
assert.match(roundMigration,/left join asgq_private\.answers response/, 'Official quiz needs real stored answers');
assert.match(roundMigration,/left join asgq_rehearsal_private\.answers response/, 'Bot rehearsal needs real stored answers');
assert.match(roundMigration,/participant\.token_hash is distinct from ev\.host_token_hash/g, 'Never list the game master as a player');
assert.match(script,/function renderResponseBreakdown\(s\)/, 'The post-reveal response list is missing');
assert.match(script,/const responses=s\.question\?\.responses/, 'Only server-provided results may be displayed');
assert.match(script,/\$\{renderResponseBreakdown\(s\)\}/, 'Show responses on reveal, before standings');
assert.match(style,/response-group--correct/, 'Correct answer badge missing');
assert.match(style,/response-group--incorrect/, 'Incorrect answer badge missing');
assert.match(style,/response-group--unanswered/, 'Unanswered badge missing');
assert.match(script,/hostControl\(s,'LANCER LA 2E MI-TEMPS'\)/, 'Host needs halftime control matching the approved mockup');
assert.match(script,/state\.is_host \|\| sendingAnswer/, 'Host must not submit answers');
assert.match(script,/asgq_rehearsal_advance/, 'Host phase control must work in rehearsal');
assert.match(script,/asgq_start/, 'Official kickoff must be host-only');
const presenterNames=['trophy','thumbs','confused','pointing','laughter','cheer','facepalm','thinking','arms','surprised','skeptical','amazed'];
for (const name of presenterNames) {
  const asset=path.join(root,'grinta-quiz/presenters',name+'.png');
  const bytes=fs.readFileSync(asset);
  assert.ok(bytes.length>150000, 'Full-resolution cutout missing: '+name);
  assert.equal(bytes.subarray(1,4).toString(), 'PNG', 'Not a PNG: '+name);
  assert.equal(bytes.readUInt32BE(16),1024,'Cutout width changed: '+name);
  assert.equal(bytes.readUInt32BE(20),1536,'Cutout height changed: '+name);
  assert.equal(bytes[25],6,'Transparent RGBA PNG required: '+name);
  assert.match(script,new RegExp("[\\'\\\"]"+name+"[\\'\\\"]"),'Pose not mapped: '+name);
}
assert.match(script,/class="presenter-photo" src="\.\/presenters\//, 'Use a sharp separate transparent image per pose');
assert.doesNotMatch(script+style,/presenter-atlas\.png|data:image\/webp;base64|background-image:url\("\.\/presenter-atlas/, 'Never use the tiny atlas again');
assert.match(style,/object-fit:contain/, 'Full portrait must preserve aspect ratio');
assert.match(script, /amazed:'amazed'/, 'Enthusiastic pose must use the uploaded photo');
assert.match(script, /doubt:'skeptical'/, 'Skeptical pose must use the uploaded photo');
assert.match(script, /stage\('<h2>MI-TEMPS<\/h2><p>On souffle/, 'Halftime needs the approved subtitle');
assert.match(script, /'thinking','halftime'/, 'Halftime needs the supplied thoughtful pose');
assert.match(script, /'excited','welcome'/, 'Creating the quiz must welcome the host with the thumbs-up pose');
assert.match(script, /const resultPose = presenterPoseForReveal\(s, success, answered\)/, 'Result screens must select a pose by outcome');
assert.match(script, /resultPose,'reveal'/, 'Result stage must use the selected reaction');
const poseDefinition=script.match(/function presenterPoseForReveal\(s, success, answered\) \{[\s\S]*?\n\}/)?.[0];
assert.ok(poseDefinition, 'Semantic presenter pose selector is missing');
const choosePose=new Function(poseDefinition+'\nreturn presenterPoseForReveal;')();
const host={position:1,is_host:true};
const guest=(position)=>({position,is_host:false});
assert.equal(choosePose(host,true,true),'confident','The game master stays neutral while revealing');
assert.equal(choosePose(guest(1),true,true),'amazed','The new delighted face celebrates an early correct answer');
assert.equal(choosePose(guest(2),true,true),'excited','Thumbs-up on the next correct answer');
assert.equal(choosePose(guest(3),true,true),'welcome','The third correct answer can use the laughing pose');
assert.equal(choosePose(guest(1),false,true),'facepalm','Facepalm is an incorrect answer reaction');
assert.equal(choosePose(guest(2),false,true),'doubt','The new skeptical face must be used for an incorrect answer');
assert.equal(choosePose(guest(1),false,false),'surprised','A missing answer should be a surprised reaction');
assert.equal(choosePose(guest(2),false,false),'puzzled','A missing answer can receive a puzzled reaction');
assert.equal(choosePose(guest(2),false,true),choosePose(guest(2),false,true),'Polling must not randomly change the expression');
assert.match(script, /tied\?'CHAMPIONS DU QUIZ':'CHAMPION DU QUIZ'/, 'Finale must preserve the original title for a sole winner and pluralize tied champions');
assert.match(script, /'victory','podium'/, 'Trophy presenter should accompany finalists');
assert.match(script, /data-add-bot/, 'Host cannot add bots');
assert.match(script, /data-start-quiz/, 'Host cannot start');
assert.match(page, /<main id="app"/, 'Dedicated phone screen missing');
assert.match(page, /\.\/app\.js/, 'Dedicated script missing');
assert.match(page, /\.\.\/vendor\/supabase\.js/, 'Use the existing pinned Supabase client');
assert.match(script, /\basgq_create\b/, 'Admin+ create RPC missing');
assert.match(home, /\basgq_join_room\b/, 'Guests enter by Soulieteur’s join screen');
assert.doesNotMatch(script,/data-entry-mode=/, 'No redundant join tabs in the quiz');
assert.match(script, /id="admin-password" type="password"/, 'Admin+ only on creation screen');
assert.match(home, /id="j-code" type="text" inputmode="numeric"/, 'Guests use the original Soulieteur code field');
assert.doesNotMatch(script, /api\.rpc\('asgq_join',/, 'The old invitation-code RPC must not be used');
assert.match(script, /\basgq_state\b/, 'Server-driven status missing');
assert.match(script, /\basgq_answer\b/, 'Server-driven answer submission missing');
assert.match(script, /setInterval\(\(\)=>\{if\(token && !requesting\)/, 'Automatic polling missing');
assert.match(script, /renderHalftime/, 'Second-half separation missing');
assert.match(script, /renderFinished/, 'Podium missing');
const entry=read('supabase/migrations/20261122160000_grinta_quiz_admin_plus_entry.sql');
const salon=read('js/ecrans/salon.js');
const commun=read('js/ecrans/commun.js');
const room=read('supabase/migrations/20261122170000_grinta_quiz_create_and_join.sql');
assert.match(room, /public\._is_admin_plus\(p_password\)/, 'Require Admin+ for creating the unique room');
assert.match(room, /public\.asgq_join_room\(p_code text, p_name text\)/, 'Guests must enter with room code only');
assert.match(room, /not ev\.created/, 'Guest join before creation must be rejected');
assert.match(room, /eight digits|8-digit|\[0-9\]\{8\}/i, 'The generated code must be eight digits');
assert.match(room, /and ev\.created and ev\.armed/, 'Countdown must not start before creation');
assert.match(entry, /revoke execute on function public\.asgq_join\(text,text,uuid\)/, 'Close the old invite-code entrance');
assert.doesNotMatch(room+script, /admin_plus_hash\s*=|password\s*=\s*['"][^'"]+['"]/i, 'Never embed Admin+ secret in source');
assert.doesNotMatch(script, /api\.rpc\('asgq_join_admin_plus'/, 'Guests must never be asked for Admin+');
const tileAction = home.split("surAction('mode', el => {")[1]?.split("}, { marque:false });")[0];
assert.ok(tileAction, 'Game thumbnail handler missing');
assert.doesNotMatch(tileAction, /ouvrirGrintaQuiz/, 'QCM thumbnail must only select game, not open quiz');
assert.match(tileAction, /box\.value = el\.dataset\.v/, 'QCM should update selected hidden game like other tiles');
assert.match(home, /if \(jeu === 'qcm'\)[\s\S]*?ouvrirGrintaQuiz\(false, 'create'\)/,
  'QCM should open only after clicking Créer la partie');
assert.match(page, /class="brand-back" href="\.\.\//, 'All Grinta screens need a back-to-home control');
assert.match(style, /\.brand-back\{/, 'Back button styling missing');
assert.match(salon, /if \(m === 'qcm'\) return ouvrirGrintaQuiz\(\)/, 'Game picker must bypass generic QCM');
assert.match(commun, /state\?\.room\?\.mode === 'qcm'/, 'Existing QCM rooms must also redirect');
assert.match(db, /first_half between 10 and 20/, 'Missing real question count gate');
assert.match(db, /second_half between 10 and 20/, 'Missing second half gate');
assert.match(db, /ev\.armed and asgq_private\.ready_for_kickoff\(\)/, 'Cannot arm a test-only quiz');
assert.doesNotMatch(page+script+style, /sb_secret_|service_role|private[_-]?key/i, 'Never expose privileged secrets');
assert.doesNotMatch(page+script+style, /QUESTION DE TEST|Réponse A \(test\)/i, 'Do not ship test questions to browsers');
assert.ok(fs.statSync(path.join(root,'grinta-quiz/as-grinta-crest.webp')).size>10000, 'AS Grinta official crest is missing');
assert.match(page, /as-grinta-crest\.webp/, 'Show the real club crest on every screen');
assert.doesNotMatch(page, /<span>AG<\/span>/, 'Fake AG club badge must be removed');
assert.match(style, /safe-area-inset-top/, 'iPhone notch and upper controls must remain reachable');
assert.match(style, /stage-head/, 'Full-body presenter stage layout is required');
assert.match(script, /PRESENTER_FILES/, 'Each pose must reference one of the full-quality uploaded photographs');
assert.match(script, /question-topline/, 'Place the cut-out presenter beside question metadata');
const stageSource=script.split('const stage = (title,pose,kind=')[1]?.split('function headerText')[0];
assert.ok(stageSource, 'Host stage renderer must exist');
assert.ok(stageSource.indexOf('${presenter(pose)}') < stageSource.indexOf('class="stage-copy"'), 'Presenter must be on the left of the screen heading');
const questionSource=script.split('function renderQuestion(s) {')[1]?.split('function rankingRows')[0];
assert.ok(questionSource.indexOf('${presenter(\'question\')}') < questionSource.indexOf('class="kicker"'), 'Presenter must be left of the question counter');
assert.match(script, /stage\('<h2>VESTIAIRE<\/h2>','confident','lobby'\)/, 'Use a confident original photo in lobby');
assert.match(style, /\.stage-lobby\{min-height:228px/, 'Give the presenter enough room without covering the lobby panel');
assert.match(style, /\.stage-lobby \.presenter-photo\{width:min\(100%,clamp\(148px,46vw,190px\)\)/, 'Lobby presenter should be much larger than before');
assert.match(style, /\.scene\[data-screen="question"\] \.question-topline\{[\s\S]*?display:grid;[\s\S]*?grid-template-columns/, 'Question portrait must have a dedicated left column');
assert.match(style, /@media\(max-height:740px\)/, 'Presenter should remain responsive on short screens');
const lobbyMarkup=script.split('function renderLobby(s) {')[1]?.split('function renderIntro(s) {')[0];
assert.ok(lobbyMarkup, 'Lobby screen missing');
assert.doesNotMatch(lobbyMarkup, /class="avatar"/, 'No circular letter icon in the lobby player list');
assert.doesNotMatch(lobbyMarkup, /class="(?:host|bot)-label"|MAÎTRE DU JEU/, 'No role badges beside player names');
assert.match(lobbyMarkup, /p\.is_bot/, 'Keep bot-only removal controls');
assert.match(lobbyMarkup, /data-remove-bot/, 'Bot removal must remain usable');
assert.doesNotMatch(script, /RETOUR AUX JEUX/, 'Redundant return-to-games text must be removed from quiz screens');
assert.match(page, /class="brand-back"/, 'Keep the header exit X when removing text links');
assert.match(style, /\.brand\{[^}]*background:transparent;backdrop-filter:none;-webkit-backdrop-filter:none/, 'Header must not have a contrasting color bar or blur');

// The quiz screen must have its own premium show design without changing quiz data.
assert.match(script,/question-card-top/, 'Question needs an AS Grinta identity strip');
assert.match(script,/question-card-index/, 'Question number should read like a show episode');
assert.match(script,/class="choice-text"/, 'Each answer should have a dedicated readable text region');
assert.match(script,/class="choice-indicator"/, 'A selected answer must have an accessible visual indicator');
assert.match(script,/role="group" aria-label="Choix de réponse"/, 'Answer options should be grouped for accessibility');
assert.match(script,/answer-reveal-label/, 'Reveal needs an elevated answer panel');
assert.match(script,/answer-reveal-tick/, 'Correct answer must be visually recognizable');
assert.match(script,/rank-no/, 'Ranking should preserve readable rank numbers');
assert.doesNotMatch(script.split('function rankingRows(s, count = 5)')[1]?.split('function presenterPoseForReveal')[0]||'',/class="avatar"/,
  'Scoreboard should not bring back initials beside player names');
assert.match(style,/CLUB-NIGHT BROADCAST ART DIRECTION/, 'Grand Quiz custom visual identity is absent');
assert.match(style,/question-card::before\{[\s\S]*?as-grinta-crest\.webp/, 'Question card should subtly echo the real club crest');
assert.match(style,/\.scene\[data-screen="question"\] \.choice\.selected/, 'Answer selection should have an unmistakable visual state');
assert.match(style,/\.scene\[data-screen="reveal"\] \.answer-reveal/, 'Reveal needs a special ceremony panel');
assert.match(style,/\.stage-intro::after/, 'First-half introduction needs event staging');
assert.match(style,/\.pod\.first \.step/, 'Champion podium needs a distinct top step');
assert.doesNotMatch(script,/timeRemaining|timerLine|updateClocks/, 'The redesign must not reintroduce a timer');
assert.match(script,/hostControl\(s,'RÉVÉLER LA RÉPONSE'\)/, 'Only the master can reveal the answer');
assert.match(script,/data-answer/, 'Participant choices must remain interactive');

// All six approved sports-broadcast screen layouts must be present in the app.
assert.match(style,/SIX SCREEN MATCHED MOCKUPS 2026/, 'Approved six-screen direction is missing');
assert.match(script,/PRÊT POUR<br>LE GRAND<br>QUIZ \?/, 'Welcome should show the approved hero copy');
assert.doesNotMatch(script,/class="entry-tagline"|Entre dans l’émission/, 'User removed redundant tagline');
assert.match(script,/JOUEURS \(\$\{participantCount\}\)/, 'Lobby player count must exclude the non-playing host');
assert.match(script,/class="show-progress"/, 'On-screen question progress dots are missing');
assert.match(script,/allQuestions\(s\)/, 'Question count must show the whole episode');
assert.match(script,/class="halftime-board"/, 'Halftime ranking board must match the approved layout');
assert.match(script,/class="halftime-stat"/, 'Halftime should show a genuine leader statistic');
assert.match(script,/class="pod-crown"/, 'Final podium needs crown motifs');
assert.match(script,/data-repeat-rehearsal>REJOUER/, 'Rehearsal finale needs the approved replay label');
assert.match(script,/Number\(top\?\.score \|\| 0\)/, 'Halftime statistic must be derived from a real score');
assert.match(script,/\$\{p\.score\} pts/, 'Podium points must come from the real leaderboard');
assert.match(style,/\.scene\[data-screen="reveal"\] \.response-groups\{[^}]*grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/,
  'Reveal must use the three result columns from the mockup');
assert.match(style,/\.scene\[data-screen="question"\] \.choice\.selected\{[^}]*background:var\(--show-gild\)/,
  'Selected answers must turn gold');
assert.match(style,/\.scene\[data-screen="finished"\] \.pod\.first \.step\{[^}]*height:160px/,
  'Winning podium needs the tallest gold block');
assert.doesNotMatch(script,/setInterval\(updateClocks|timeRemaining|TEMPS RESTANT|COMPTE À REBOURS/,
  'No countdown is permitted in this visual redesign');

// Audit regression checks: reveal data is public only after the manual reveal.
assert.equal((waitingMigration.match(/'explanation',case when ev.phase='reveal' then q.explanation else null end/g)||[]).length,2,
  'Both quiz modes must protect explanations until reveal');
assert.match(script,/class="reveal-question"/, 'Verdict must recall the question');
assert.match(script,/class="reveal-explanation"/, 'Verdict must show the server-provided explanation');
assert.match(script,/class="personal-answer"/, 'Players should be reminded of their own wrong answer');
assert.match(script,/sendingAnswer \? 'Enregistrement…'/, 'Answer confirmation must wait for server completion');
assert.match(script,/class="champion-name"/, 'Final must name the champion');
assert.match(style,/AUDIT GRAND QUIZ 2026/, 'Missing audited responsive adjustments');
assert.match(style,/@media\(max-width:620px\)\{[\s\S]*?\.scene\[data-screen="reveal"\] \.response-groups/, 'Outcome groups must stack on phones');
assert.match(style,/\.scene\[data-screen="finished"\] \.champion-name\{\s*display:block/, 'Champion must not remain hidden');
assert.match(script,/manyPlayers=participantCount > 12/, 'Dense lobby must adapt to many players');
assert.match(script,/class="launch-hint"/, 'Disabled start button must be explained');
const rankFn=script.match(/function rankingRows\(s, count = 5\) \{[\s\S]*?\n\}/)?.[0];
assert.ok(rankFn, 'Ranking renderer missing');
const rankHelper=script.match(/function competitionRank\(standings,index\) \{[\s\S]*?\n\}/)?.[0] || '';
const renderRank=new Function('const safe=v=>String(v);\n'+rankHelper+'\n'+rankFn+'\nreturn rankingRows;')();
const standings=Array.from({length:7},(_,i)=>({id:'id'+i,name:'Joueur '+i,score:10-i}));
const belowTop=renderRank({standings,me:{id:'id6'},is_host:false});
assert.match(belowTop,/personal-rank/, 'A player outside the top five must see their own rank');
assert.match(belowTop,/Joueur 6/, 'Personal rank shows the correct player');
assert.doesNotMatch(renderRank({standings,me:{id:'host'},is_host:true}),/personal-rank/,
  'Host must not be added to player rankings');
// Wave 2: Admin+-only host token recovery, without modifying the official event.
const hostRecoverySql=read('supabase/migrations/20261123030000_asgq_host_session_recovery.sql');
const hostRecoveryQA=read('supabase/tests/qa_as_grinta_host_recovery.sql');
assert.match(hostRecoverySql,/create or replace function public\.asgq_recover_host\(p_password text\)/, 'Official host recovery RPC missing');
assert.match(hostRecoverySql,/public\._is_admin_plus\(p_password\)/, 'Existing Admin+ must authenticate recovery');
assert.match(hostRecoverySql,/v_attempts>5/, 'Host recovery must be rate limited');
assert.match(hostRecoverySql,/host_player\.id/, 'Recover the existing host, never add a new participant');
assert.match(hostRecoverySql,/update asgq_private\.players set token_hash=v_token_hash/, 'Old host token must be rotated');
assert.match(hostRecoverySql,/update asgq_private\.event set host_token_hash=v_token_hash/, 'Event must point to the new host token');
assert.doesNotMatch(hostRecoverySql,/delete from asgq_private|update asgq_private\.questions|set phase=/i, 'Recovery must never reset live quiz data');
assert.match(hostRecoveryQA,/rollback;/, 'Host recovery tests must roll back the simulated event');
assert.match(script,/api\.rpc\('asgq_recover_host'/, 'Host recovery must call the authenticated RPC');
assert.match(script,/data-host-recovery/, 'Creator must be able to resume an existing emission');
assert.match(script,/id="recover-host-form"/, 'Resume must have an Admin+-only form');
assert.match(script,/localStorage\.setItem\(storeKey,token\)/, 'Recovered token must be persisted');
assert.doesNotMatch(script,/api\.rpc\('asgq_recover_host',[^\n]*p_name/, 'Do not trust a client-supplied name for host recovery');

// Shared scores get the same rank, with all champions named (no join-time winner).
const rankFunction=script.match(/function competitionRank\(standings,index\) \{[\s\S]*?\n\}/)?.[0];
assert.ok(rankFunction, 'Competition ranking function missing');
const rankFor=new Function(rankFunction+'\nreturn competitionRank;')();
const tiedStandings=[
  {id:'p1',name:'Camille',score:12},
  {id:'p2',name:'Nina',score:12},
  {id:'p3',name:'Sam',score:10},
  {id:'p4',name:'Alex',score:10},
  {id:'p5',name:'Robin',score:7}
];
assert.deepEqual(tiedStandings.map((_,i)=>rankFor(tiedStandings,i)),[1,1,3,3,5], 'Equal scores must share competition ranks');
assert.match(script,/const winners=winnerScore===undefined \? \[\] : standings\.filter/, 'All tied champions must be identified');
assert.match(script,/CHAMPIONS DU QUIZ/, 'Tied champions need plural podium headline');
assert.match(script,/championNames=winners\.length/, 'Champion heading must display every tied winner');
assert.match(script,/class="joint-champions"/, 'Podium must indicate shared first place');
console.log('ASGQ frontend / preflight checks OK');
