import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const home=readFileSync(new URL('../js/ecrans/accueil.js',import.meta.url),'utf8');
const commun=readFileSync(new URL('../js/ecrans/commun.js',import.meta.url),'utf8');
const css=readFileSync(new URL('../css/app.css',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/migrations/20261115120000_secure_eight_digit_room_codes.sql',import.meta.url),'utf8');

const beforeHomeEffects=home.slice(0,home.indexOf('// Accueil : la taille des vignettes'));
assert.ok(beforeHomeEffects.includes('function home()'));
function showHome(search){
  const context=vm.createContext({
    URLSearchParams,location:{search},localStorage:{getItem:()=>''},
    GAMES:{phrases:{name:'Phrases à trou',pitch:'Joue',cat:'cartes'}},
    dernierJeu:()=> 'phrases',joueurs:()=> '3 joueurs',
    tileImg:()=> 'phrases.webp',esc:x=>String(x),
  });
  vm.runInContext(beforeHomeEffects,context);
  return vm.runInContext('home()',context);
}

const huit=showHome('?code=00123456');
assert.match(huit,/id="pane-join"[^>]*>/);
assert.match(huit,/id="j-code"[^>]*maxlength="8"/);
assert.match(huit,/value="00123456"/,'Conserver les zéros de tête des liens invités');
assert.match(huit,/data-tab="join"[^>]*aria-selected="true"/);

const quatre=showHome('?code=0031');
assert.match(quatre,/value="0031"/,'Les liens des anciens salons doivent encore marcher');
assert.match(home,/c\.length !== 4 && c\.length !== 8/,'Accepter uniquement 4 ou 8 chiffres');
assert.match(home,/replace\(\/\\D\/g,''\)\.slice\(0,8\)/,'Les invitations longues ne doivent pas être tronquées');
assert.match(home,/if \(e\.target\.id === 'j-code'\) homeCode = e\.target\.value = e\.target\.value\.replace/);

assert.match(commun,/bigcode\$\{r\.code\.length === 8 \? ' long' : ''\}/,'Adapter les salons à 8 chiffres');
assert.match(css,/\.bigcode\.long \.ch\{/,'Rétrécir les cases sur petits écrans');
assert.match(migration,/pg_catalog\.gen_random_uuid\(\)/,'Source cryptographique native');
assert.match(migration,/raw_random >= 4200000000/,'Éliminer le biais modulo');
assert.match(migration,/100000000/,'Espace de 100 millions de codes');
assert.match(migration,/revoke all on function public\._new_code\(\)/,'Le générateur reste interne');
assert.doesNotMatch(migration,/\brandom\(\)/,'Ne plus utiliser de pseudo-aléatoire non cryptographique');

console.log('Invitations à 8 chiffres : interface et sécurité compatibles.');
