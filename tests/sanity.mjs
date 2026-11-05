import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const page = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
// L'appli est découpée en scripts classiques (js/…) chargés dans l'ordre de la
// page : ils partagent une seule portée globale, on les relit donc bout à bout.
const inline = [...page.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)].map(m => m[1].trim()).filter(Boolean);
assert.equal(inline.length, 0, 'Le code de l’appli vit dans js/, pas dans la page');
const appFiles = [...page.matchAll(/<script src="(js\/[^"]+\.js)"><\/script>/g)].map(m => m[1]);
assert.ok(appFiles.length >= 2 && appFiles[0] === 'js/core.js' && appFiles.at(-1) === 'js/actions.js',
  'core.js doit se charger en premier et actions.js (démarrage) en dernier');
const read = f => fs.readFileSync(new URL('../' + f, import.meta.url), 'utf8');
const scripts = [appFiles.map(read).join('\n')];
assert.match(page, /<link rel="stylesheet" href="css\/app\.css">/, 'Feuille de style de l’appli');
const css = read('css/app.css');
assert.doesNotMatch(css, /url\((?!["']?(?:data:|\.\.\/|%23|#))/, 'Les url() du CSS doivent remonter à la racine (../)');
// Les vérifications portent sur la page, le style et le code réunis.
const html = page + '\n' + css + '\n' + scripts[0];
new Function(scripts[0]);

// `new Function` compiles the script as a FUNCTION BODY, where names like `top`
// are ordinary locals. In a browser the same code runs at GLOBAL scope, where a
// top-level `function top(){}` collides with the read-only `window.top` and
// throws "Identifier 'top' has already been declared" — killing the whole page
// before anything renders. Re-run the script against a global object that owns
// the same read-only properties so that collision surfaces here instead.
const READ_ONLY_GLOBALS = ['top', 'window', 'self', 'document', 'location', 'parent', 'frames', 'closed'];
const fakeWindow = vm.createContext({});
for (const key of READ_ONLY_GLOBALS) {
  Object.defineProperty(fakeWindow, key, { value: undefined, writable: false, enumerable: true, configurable: false });
}
try {
  vm.runInContext(scripts[0], fakeWindow, { timeout: 2000 });
} catch (error) {
  // Runtime errors are expected (there is no real DOM or Supabase client here);
  // a SyntaxError means the declarations themselves cannot be installed.
  // `instanceof` is useless here: the error comes from the vm realm, so compare names.
  assert.notEqual(error?.name, 'SyntaxError',
    `Top-level declaration collides with a read-only browser global: ${error?.message}`);
}

const usesPinnedCdn = /@supabase\/supabase-js@2\.116\.0\/dist\/umd\/supabase\.js/.test(html);
const usesVendoredClient = /\.\/vendor\/supabase\.js/.test(html);
assert.ok(usesPinnedCdn || usesVendoredClient,
  'Supabase JS must use the reviewed pinned CDN build or the vendored copy');
if (usesVendoredClient) {
  const vendor = fs.readFileSync(new URL('../vendor/supabase.js', import.meta.url), 'utf8');
  assert.match(vendor, /^var supabase=/, 'Vendored Supabase client is missing or invalid');
}
assert.match(html, /sb_publishable_[A-Za-z0-9_-]+/,
  'Client must use a publishable Supabase key');
assert.doesNotMatch(html, /service[_-]?role|sb_secret_/i,
  'Never expose a service-role or secret key in the browser');
// Relecture de secours : 4 s si le temps réel est coupé, 30 s s'il marche
// (chaque relecture coûte une requête journalisée et tout l'état en sortie).
assert.match(html, /\(rtOk \? 30000 : 4000\)/,
  'Fallback polling must be 4 s without realtime and 30 s with it');
assert.match(html, /\}, 4000\);/,
  'The polling check must still run every 4 seconds');
assert.match(html, /setTimeout\(refresh,250\)/,
  'Realtime bumps must remain debounced');
// Manches, tours et punitions se règlent avec − et + dans le salon, dans les bornes du serveur.
assert.match(scripts[0], /const BORNES = \{ target:\[1, 20\], turns:\[1, 5\] \}/,
  'Les bornes des réglages doivent suivre celles du serveur (manches 1-20, tours 1-5)');
assert.match(scripts[0], /const OPT_BORNES = \{ \.\.\.BORNES, pun:\[0, 5\] \}/, 'Punitions de 0 (aucune) à 5 par joueur');
assert.match(scripts[0], /data-act="step" data-k="\$\{k\}" data-d="-1"/, 'Le réglage de manches/tours se fait avec − et +');
assert.match(html, /id="c-target" value="5"/, 'Default target score must stay at 5');
assert.match(html, /data-act="bot"/, 'Le bouton d’ajout de bot doit rester disponible');
assert.match(scripts[0], /bot_step/, 'Le client de l’hôte doit piloter les bots via bot_step');
assert.match(html, /data-act="ready"/, 'Ready control must remain available');

// La barre d'action est fixe : si la page réserve une hauteur devinée au lieu
// de la hauteur mesurée, le bouton finit par recouvrir la fin du contenu —
// l'écran de fin, à deux boutons, dépassait les 150px autrefois codés en dur.
assert.match(html, /padding:calc\(30px \+ env\(safe-area-inset-top\)\) 18px calc\(var\(--dock-h/,
  'La réserve du bas doit suivre --dock-h, pas une valeur fixe');
assert.match(scripts[0], /function fitDock\(\)/,
  'fitDock doit mesurer la barre d’action après chaque rendu');
// En appli installée, la barre d'état d'iOS se superpose à la page : sans ce
// voile, le contenu qui défile se chevauche avec l'heure et la batterie.
assert.match(html, /<div class="scrim" aria-hidden="true">/,
  'Le voile de la barre d’état doit rester dans la page');

// Les joueurs sont désignés à tour de rôle : plus de roue nulle part.
assert.doesNotMatch(html, /wheel|spinning\(/i, 'La roue de tirage au sort ne doit pas revenir');
// Le serveur fournit les durées et dates limites ; les votes subjectifs restent manuels.
assert.match(scripts[0], /function timeField\(host\)/, 'Réglage Temps dans le salon');
assert.match(scripts[0], /act\('set_time_mode', \{ p_mode: el\.dataset\.v \}\)/, 'Option persistée');
assert.match(scripts[0], /phase_deadline/, 'Échéance serveur');
assert.match(scripts[0], /advisoryPhase\(\)/, 'Chronos oraux non bloquants');
assert.match(scripts[0], /function sharedRoundNext\(\)/, 'Validation manuelle des résultats');
assert.match(scripts[0], /a === 'bac-next'\) return act\('next_round'\)/, 'Manches synchronisées');
assert.match(scripts[0], /rpc\('reap_idle'/, 'Expiration traitée côté serveur');
assert.doesNotMatch(scripts[0], /bacTick|bac-cd/, 'Pas de minuteur autonome Petit Bac');

// Petit bac : deux joueurs exactement, comme côté serveur (_max_players).
assert.match(scripts[0], /const maxPlayers = mode => mode === 'bac' \? 2 : 12/,
  'Le Petit bac doit rester limité à deux joueurs');
// La grille ne doit pas passer par act() : son refresh() redessinerait les
// champs et fermerait le clavier à chaque enregistrement automatique.
assert.match(scripts[0], /rpc\('bac_save', \{ p_code:session\.code, p_token:session\.token, p_answers:bacDraft, p_done:false \}\)/,
  'L’enregistrement au fil de la frappe doit appeler rpc directement');

// Petit bac : le nombre de manches est celui tapé par l'hôte, borné de 1 à 20.
assert.match(scripts[0], /const bacRounds = \(\) => Math\.min\(20, Math\.max\(1, \+state\.room\.target \|\| 5\)\)/,
  'Le Petit bac joue le nombre de manches choisi (1 à 20)');
assert.doesNotMatch(scripts[0], /BAC_ROUNDS/, 'Le nombre de manches du Petit bac ne doit plus être fixe');



// Mr White doit rester branché sur les salons, bots, catalogues et rôles privés.
assert.match(scripts[0], /white:\s*\{ name:'Mr White'/, 'Jeu Mr White présent');
assert.match(scripts[0], /white_clue:whiteClue, white_vote:whiteVote, white_guess:whiteGuess/, 'Phases Mr White déclarées');
assert.match(scripts[0], /s\.white = await rpc\('white_state'/, 'Rôles secrets issus du serveur');
assert.match(scripts[0], /act\('white_open_vote'\)/, 'En présentiel, l’hôte ouvre le vote');
assert.match(scripts[0], /act\('white_vote', \{ p_target:id \}\)/, 'Votes côté joueur');
assert.match(scripts[0], /act\('white_oral_verdict', \{ p_correct:el\.dataset\.correct==='1' \}\)/, 'La réponse orale est validée par un Civil');
assert.match(scripts[0], /white_bot_step/, 'Bots côté serveur');
// L'écran en présentiel doit rester volontairement minimal : carte + bouton de vote.
const whiteCardView = scripts[0].split('function whiteSecret(){')[1].split('function whitePeople(){')[0];
const whiteClueView = scripts[0].split('function whiteClue(){')[1].split('function whiteVote(){')[0];
assert.ok(whiteCardView && whiteClueView, 'Écrans du jeu Mr White disponibles');
assert.match(whiteCardView, /Ta Carte :/, 'Une étiquette unique sur la carte');
assert.doesNotMatch(whiteCardView, /<small>|Ta carte secrète|Ton mot secret|Ne la montre à personne/,
  'Aucun paragraphe explicatif sur la carte');
assert.match(whiteClueView, /whiteSecret\(\)/, 'La carte est toujours visible');
assert.match(whiteClueView, /host[\s\S]*Passer au vote/, 'Le bouton reste réservé à l’hôte');
assert.doesNotMatch(whiteClueView, /<h1|<h3|whiteNote\(\)|white-feed|white-seats|class="role"|class="waiting"/,
  'Pas de titre, ordre de passage, indices des bots ni consignes sur cet écran');

// Vote Mr White : la carte précède le titre, les listes de rôles ne sont pas affichées,
// et le suivi des votes réutilise les pastilles d'attente communes aux autres jeux.
const whiteVoteView = scripts[0].split('function whiteVote(){')[1]?.split('function whiteGuess(){')[0];
assert.ok(whiteVoteView, 'Écran de vote Mr White présent');
assert.ok(whiteVoteView.indexOf('whiteSecret()') < whiteVoteView.indexOf('Qui est l’imposteur ?'),
  'La carte doit apparaître avant le titre de vote');
assert.match(whiteVoteView, /<h3 class="sec">Ton vote<\/h3>/, 'Le titre Ton vote est conservé');
assert.match(whiteVoteView, /waiting\(pending,'Tout le monde a voté.'\)/,
  'Utiliser la même attente de joueurs que les autres mini-jeux');
assert.match(whiteVoteView, /!p\.out&&!p\.voted&&P\(p\.player_id\)\?\.active/,
  'N’attendre que les joueurs actifs encore en jeu qui n’ont pas voté');
assert.doesNotMatch(whiteVoteView, /whitePeople\(\)|Discutez ensemble|<h3 class="sec">Joueurs<\/h3>|whiteNote\(\)|Vote enregistré/,
  'Pas d’explication, de liste des joueurs ni de message redondant');
assert.match(scripts[0], /Tu es Mr White/, 'Mr White voit son propre rôle et l’emblème du jeu');
assert.doesNotMatch(scripts[0], /MrWhitz/, 'Le nom Mr White est orthographié correctement dans les vues');
assert.match(scripts[0], /games\/white\.svg/, 'Mr White voit le logo');
assert.doesNotMatch(scripts[0], /Ton rôle · Ne le montre à personne|white-clue-input|white-guess-input/,
  'Un Civil ou un imposteur ne voit pas son rôle et les indices sont donnés à l’oral');
assert.match(scripts[0], /white:\[\['m','Paires de mots'\]\]/, 'Catalogue admin Mr White');
assert.match(scripts[0], /games\/\$\{k === 'white' \? 'white-home\.jpg'/, 'Nouvelle vignette de Mr White sur l’accueil');
assert.ok(fs.statSync(new URL('../games/white-home.jpg', import.meta.url)).size > 5000,
  'La vignette Mr White fournie doit être un vrai fichier image');
assert.match(scripts[0], /class="white-mark" src="games\/white\.svg"/,
  'La carte secrète de Mr White reste inchangée');


// Mr White : une élimination non décisive n'est pas une fin de manche.
// Son verdict doit s'afficher puis permettre de reprendre le même mot au tour suivant.
assert.match(scripts[0], /white_elimination:whiteElimination/,
  'L’état intermédiaire après élimination doit avoir son propre écran');
assert.match(scripts[0], /a === 'white-resume'\) return act\('white_resume'\)/,
  'L’hôte doit pouvoir relancer les indices depuis le verdict');
const whiteElimView = scripts[0].split('function whiteElimination(){')[1]?.split('function whiteReveal(){')[0];
const whiteFinalView = scripts[0].split('function whiteReveal(){')[1]?.split('/* ---------- Mimes ---------- */')[0];
assert.ok(whiteElimView && whiteFinalView, 'Les résultats intermédiaire et final existent');
assert.match(whiteElimView, /Résultat du vote/, 'Un vote non décisif ne doit pas annoncer la fin de la manche');
assert.match(whiteElimView, /impostors_remaining/, 'Le décompte affiché provient de la base de données');
assert.match(whiteElimView, /remaining>1\?'s':''/, 'Accord du pluriel selon les imposteurs restants');
assert.match(whiteElimView, /Il ne reste plus d’Imposteur/, 'Cas particulier où seul Mr White peut rester');
assert.match(whiteElimView, /la partie continue/, 'La continuité de la partie est explicite');
assert.match(whiteElimView, /whiteEliminationSentence\(\)/, 'Le joueur éliminé est annoncé');
assert.doesNotMatch(whiteElimView, /civil_word|undercover_word|whiteWinnerSentence/,
  'Un vote non décisif ne révèle pas les mots ni les gagnants');
assert.match(whiteFinalView, /whiteEliminationSentence\(\)/, 'La finale annonce le dernier joueur éliminé');
assert.match(whiteFinalView, /whiteWinnerSentence\(\)/, 'La finale annonce les gagnants nommément');
assert.match(whiteFinalView, /Mot des Civils :/, 'Le mot des civils est affiché à la fin');
assert.match(whiteFinalView, /Mot de l’Imposteur :/, 'Le mot imposteur est affiché à la fin si présent');
assert.match(whiteFinalView, /!hasMrWhite\?/, 'Ne jamais révéler le mot imposteur si Mr White était présent');
assert.doesNotMatch(whiteFinalView, /whitePeople\(\)|<h3 class="sec">Classement<\/h3>|whiteNote\(\)/,
  'Pas de liste superflue ni de classement sur le verdict');
const whiteVerdictMigration=fs.readFileSync(new URL('../supabase/migrations/20261104190000_mr_white_elimination_results.sql',import.meta.url),'utf8');
assert.match(whiteVerdictMigration, /white_elimination/, 'Le serveur connaît la nouvelle phase');
assert.match(whiteVerdictMigration, /create or replace function public.white_resume/, 'La reprise est contrôlée côté serveur');
assert.match(whiteVerdictMigration, /r.host_id<>me.id/, 'Seul l’hôte peut relancer le tour');
assert.match(whiteVerdictMigration, /when p_winner='civils' then civil_survivors/,
  'Tous les Civils marquent le nombre de Civils survivants en cas de victoire');
assert.match(whiteVerdictMigration, /when 'undercover' then opposing_eliminated/,
  'Tous les imposteurs gagnent le même point par adversaire éliminé');
assert.match(whiteVerdictMigration, /wr\.role in \('civil','white'\) and wr\.eliminated_cycle is not null/,
  'Un Civil ou Mr White éliminé rapporte un point aux imposteurs');
assert.match(whiteVerdictMigration, /other\.player_id<>wr\.player_id/,
  'Mr White ne peut jamais gagner de points pour sa propre élimination');
assert.match(whiteVerdictMigration, /other\.eliminated_cycle<wr\.eliminated_cycle/,
  'Mr White ne gagne aucun point sur les éliminations postérieures à sa sortie');
assert.match(whiteVerdictMigration, /\)\*2/,
  'Mr White gagne deux points par autre joueur éliminé tant qu’il est en vie');
assert.doesNotMatch(whiteVerdictMigration, /when 'undercover' then civil_eliminated/,
  'Le score de l’imposteur n’est plus limité aux seuls Civils');
assert.doesNotMatch(whiteVerdictMigration, /p_winner='white' and wr\.role='white' then 3/,
  'Le bonus forfaitaire de victoire de Mr White est supprimé');

const whiteCountMigration=fs.readFileSync(new URL('../supabase/migrations/20261104200000_mr_white_imposteurs_restants.sql',import.meta.url),'utf8');
assert.match(whiteCountMigration, /'impostors_remaining'/, 'Décompte serveur disponible');
assert.match(whiteCountMigration, /r.status='white_elimination'/, 'Décompte limité au verdict intermédiaire');
assert.match(whiteCountMigration, /wr.role='undercover' and not wr.eliminated/, 'Seuls les imposteurs vivants sont comptés');
assert.doesNotMatch(whiteCountMigration, /wr.role in \('undercover','white'\)/, 'Mr White ne compte pas comme Imposteur');

// Mr White : la consigne de tour de parole est affichée sur l'écran des indices.
assert.match(whiteClueView, /whiteTurn\(\)/, 'La consigne de tour est affichée sous la carte');
assert.match(scripts[0], /Chacun son tour, vous devez donner un indice\./, 'Consigne de tour Mr White');
assert.match(scripts[0], /Vous avez droit à 3 indices chacun au maximum\./, 'Limite de 3 indices annoncée');
assert.match(scripts[0], /state\.white\?\.starter_id/, 'Le premier joueur vient du serveur');

// Baromètre : mode Normal ou Inversé, choisi par l'hôte dans le salon.
assert.match(scripts[0], /act\('set_wave_variant', \{ p_variant: el\.dataset\.v \}\)/, 'Choix du mode Inversé');
assert.match(scripts[0], /act\('submit_theme', \{ p_theme: t \}\)/, 'Le thème est envoyé au serveur');
assert.match(scripts[0], /if \(isInverse\(\)\) return inverseClue\(\);/, 'Écran de thème en mode inversé');
assert.match(scripts[0], /'wave_bot_step'/, 'Bots du mode inversé');

// Mimes : nouveau jeu, minuteur indicatif, notes du juge envoyées en une fois.
assert.match(scripts[0], /mimes:\s*\{ name:'Mimes'/, 'Jeu Mimes présent');
assert.match(scripts[0], /mime_play:mimePlay/, 'Phase Mimes déclarée');
assert.match(scripts[0], /act\('mime_rate', \{ p_players: ids, p_notes: ids\.map\(x => mimeNotes\[x\]\) \}\)/, 'Notes du juge');
assert.match(scripts[0], /'mime_bot_step'/, 'Bots Mimes');
assert.match(scripts[0], /act\('mime_progress', \{ p_action:'next' \}\)/, 'Chrono de Mimes déclenché par le juge');
assert.ok(fs.existsSync(new URL('../games/mimes.svg', import.meta.url)), 'Vignette Mimes présente');
const mimeMigration = fs.readFileSync(new URL('../supabase/migrations/20261105120000_barometre_inverse_mimes_white_tour.sql', import.meta.url), 'utf8');
assert.match(mimeMigration, /when 0 then 3 when 1 then 2 when 2 then 1 else 0/, 'Barème Mimes : 3, 2, 1 points');
assert.match(mimeMigration, /'intensity', case when r\.status in \('reveal','finished'\)/, 'Les intensités restent secrètes jusqu’au résultat');
assert.match(mimeMigration, /if r\.reader_id <> me\.id then raise exception 'Seul le juge note les mimes\.'/, 'Seul le juge note');

// Une seule lecture d'état par relecture, avec repli sur les trois appels
// d'avant tant que la migration n'est pas appliquée.
assert.match(scripts[0], /rpc\('get_full_state', args\)/, 'La relecture passe par get_full_state');
assert.match(scripts[0], /function readStateLegacy\(args\)/, 'Repli sur get_state, white_state et punish_state');
const fullMigration = fs.readFileSync(new URL('../supabase/migrations/20261104175401_etat_complet_phase_false.sql', import.meta.url), 'utf8');
// punish_state renvoie phase:false hors saisie : la relecture doit s'y faire aussi
assert.match(fullMigration, /coalesce\(pu->>'phase', ''\) in \('', 'false'\)/, 'Relecture quand phase vaut false');
assert.match(fullMigration, /security definer set search_path to ''/, 'get_full_state : search_path vide');
assert.match(fullMigration, /public\.white_state\(p_code, p_token\)/, 'Les mots secrets passent toujours par white_state');
assert.match(fullMigration, /revoke execute on function public\.get_full_state\(text, uuid\) from public;/, 'Pas d’exécution par public');

// Direction artistique : pastilles, icônes SVG, mises en scène jouées une fois,
// carte secrète de Mr White floue tant qu'on ne la maintient pas.
assert.doesNotMatch(scripts[0], /avatar\(/, 'Plus de pastilles de joueurs : le nom suffit');
assert.doesNotMatch(scripts[0], /[\u{1F44D}\u{1F44E}\u{1F7F0}\u{1F389}\u{1F3A1}]/u, 'Icônes SVG plutôt qu’emojis');
assert.match(css, /#app\.fresh /, 'Les animations clés ne se jouent qu’à l’arrivée sur l’écran');
assert.match(scripts[0], /class="white-secret hold" data-hold/, 'Carte secrète Mr White : maintenir pour voir');
assert.match(css, /\.white-secret\.hold \.secret\{filter:blur/, 'Carte secrète floue au repos');
assert.doesNotMatch(css, /\.ic\.fill/, '.fill est déjà le trou rempli des phrases');

// Le Dico : le livre statique existe, et chaque fichier de pages cité par l'index aussi.
const dicoIndex = JSON.parse(fs.readFileSync(new URL('../dico/index.json', import.meta.url), 'utf8'));
assert.ok(dicoIndex.pages > 1000 && dicoIndex.parFichier > 0, 'Le dictionnaire doit compter des milliers de pages');
for (let f = 0; f * dicoIndex.parFichier < dicoIndex.pages; f++)
  assert.ok(fs.existsSync(new URL(`../dico/p${String(f).padStart(3, '0')}.json`, import.meta.url)), `Fichier de pages manquant : p${f}`);
assert.match(dicoIndex.source, /Wiktionnaire.*CC BY-SA/, 'Attribution du Wiktionnaire');
assert.ok(fs.existsSync(new URL('../dico/LICENCE.md', import.meta.url)), 'Licence des données du Dico');

// Le Dico côté serveur : pas de vote pour sa propre définition, ni pour le meneur ;
// la vraie définition et les auteurs restent cachés jusqu'à la révélation.
const dicoMigration = fs.readFileSync(new URL('../supabase/migrations/20261104230000_le_dico.sql', import.meta.url), 'utf8');
assert.match(dicoMigration, /d\.player_id is not distinct from me\.id then raise exception 'Tu ne peux pas voter pour ta propre définition\.'/, 'Vote pour soi refusé');
assert.match(dicoMigration, /'definition', case when fin or r\.reader_id = me\.id then r\.dico_def end/, 'Vraie définition cachée aux joueurs');
assert.match(dicoMigration, /'author_id', case when fin then d\.player_id end/, 'Auteurs cachés jusqu’à la révélation');
assert.match(dicoMigration, /^begin;$[\s\S]*^commit;$/m, 'Migration en une seule transaction');

// Mise à jour : un téléphone resté ouvert compare le contenu du code en ligne
// (page, scripts, styles) à celui qu'il fait tourner, et se recharge.
const pagesWorkflow = fs.readFileSync(new URL('../.github/workflows/pages.yml', import.meta.url), 'utf8');
assert.match(pagesWorkflow, /\?v=\$V/, 'Scripts et feuilles de style versionnés à la mise en ligne');
assert.match(scripts[0], /headers: etag \? \{ 'If-None-Match': etag \}/, 'Vérification légère tant que rien n’a changé');
assert.match(scripts[0], /enLigne\.texte !== connu\.texte/, 'Comparaison du contenu, pas de la date de mise en ligne');
assert.match(scripts[0], /const sansVersion = t => t\.replace\(\/\\\?v=/, 'Les ?v=… de la mise en ligne ne comptent pas');
assert.match(scripts[0], /if \(state && !GAMES\[state\.room\.mode\]\) return recharger\(\)/, 'Jeu inconnu : rechargement immédiat');

// Accueil : la taille des vignettes vient de la place libre, mesurée en CSS
// (requête de conteneur), et non d'un calcul JavaScript lancé au mauvais moment.
assert.match(css, /\.home \.gamesfit\{position:absolute;inset:0;container-type:size/, 'Cadre des vignettes mesuré en CSS');
assert.match(css, /100cqh - \(var\(--rows\) - 1\) \* 8px\) \/ var\(--rows\)/, 'Vignettes limitées par la hauteur libre');
assert.match(scripts.join('\n'), /<div class="gamesbox" style="--rows:/, 'Nombre de rangées transmis au CSS');

console.log('Frontend sanity checks passed.');

// Dilemme parfait : jeu déclaré, phases branchées, bots pilotés par l'hôte, barème au 50/50.
assert.match(scripts[0], /dilemme:\s*\{ name:'Dilemme parfait'/, 'Jeu Dilemme parfait présent');
assert.match(scripts[0], /dilemme_pick:dilemmePick, dilemme_write:dilemmeWrite, dilemme_vote:dilemmeVote/, 'Phases du Dilemme déclarées');
assert.match(scripts[0], /if \(isDilemme\(\)\) return dilemmeReveal\(\) \+ sharedRoundNext\(\)/, 'Révélation du Dilemme');
assert.match(scripts[0], /rpc\('dilemme_bot_step'/, 'Bots du Dilemme');
assert.match(scripts[0], /act\('dilemme_vote', \{ p_buts:ids, p_yes:/, 'Oui/Non envoyés d’un coup');
const dilemmeMigration = fs.readFileSync(new URL('../supabase/migrations/20261107120000_dilemme_parfait.sql', import.meta.url), 'utf8');

assert.match(dilemmeMigration, /raise exception 'Tu ne votes pas pour ta propre proposition\.'/, 'Vote pour soi refusé');
assert.match(dilemmeMigration, /'author_id', case when fin then b\.player_id end/, 'Auteurs cachés jusqu’à la révélation');
assert.match(dilemmeMigration, /^begin;$[\s\S]*^commit;$/m, 'Migration en une seule transaction');
// Dilemme : cibles secrètes de 10 à 90 %, cachées aux autres jusqu'à la révélation.
const ciblesMigration = fs.readFileSync(new URL('../supabase/migrations/20261108120000_dilemme_cibles.sql', import.meta.url), 'utf8');
assert.match(ciblesMigration, /case when n >= 2 then 1 \+ floor\(random\(\) \* \(n - 1\)\)::integer else n end/, 'Cible atteignable : entre 1 et votants − 1 Oui');
assert.match(ciblesMigration, /'target', case when fin then/, 'Cibles des autres cachées jusqu’à la révélation');
assert.match(ciblesMigration, /'my_target', \(select jsonb_build_object\('pct', t\.target, 'yes', t\.target_yes, 'voters', t\.voters\)\s+from public\.dilemme_cibles t where t\.room_id = r\.id and t\.round = r\.round and t\.player_id = me\.id\)/, 'Chacun reçoit sa propre cible');
assert.match(ciblesMigration, /greatest\(0, 3 - ceil\(trop \/ 20\.0\)\)/, 'Barème : 3, 2, 1, 0 selon l’écart à la cible');
assert.match(ciblesMigration, /^begin;$[\s\S]*^commit;$/m, 'Migration en une seule transaction');
assert.match(scripts[0], /dilCible\(d\.my_target\)/, 'Cible secrète affichée pendant la rédaction');
