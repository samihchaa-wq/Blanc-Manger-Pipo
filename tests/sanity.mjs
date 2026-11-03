import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
  .map(m => m[1].trim())
  .filter(Boolean);

assert.equal(scripts.length, 1, 'Expected exactly one inline application script');
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
// L'écran de résultat d'une manche passe seul après 5 s (2 min pour le classement de Priorités), sans bouton à valider.
assert.match(scripts[0], /status === 'reveal' \? \(isPrio\(\) \? 120000 : 5000\) : 120000/, 'Le résultat d’une manche doit durer 5 s, 2 min en Priorités');
// Seul le Petit bac (sans aucune notion de temps) garde un bouton « Manche suivante ».
assert.equal((scripts[0].match(/next_round/g) || []).length, 1, 'Seul le Petit bac valide la manche suivante');
assert.match(scripts[0], /a === 'bac-next'\) return act\('next_round'\)/, 'Le Petit bac avance par un bouton');
assert.match(scripts[0], /isBac\(\) \|\| !TIMED\.includes/, 'Le Petit bac ne doit avoir aucun minuteur');
assert.doesNotMatch(scripts[0], /bacTick|bac-cd/, 'Le Petit bac ne doit pas afficher de compte à rebours');

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

console.log('Frontend sanity checks passed.');
