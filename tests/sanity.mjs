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
assert.match(html, /setInterval\(\(\)=>\{if\(!document\.hidden\)refresh\(\)\},4000\)/,
  'Fallback polling must remain at 4 seconds');
assert.match(html, /setTimeout\(refresh,250\)/,
  'Realtime bumps must remain debounced');
assert.match(scripts[0], /\[3,\s*5,\s*7,\s*10\]\s*\.map/,
  'Supported target scores changed unexpectedly');
assert.match(html, /data-act="target"/, 'Target-score control must remain available');
assert.match(html, /id="c-target" value="5"/, 'Default target score must stay at 5');
assert.match(html, /data-act="bot"/, 'Le bouton d’ajout de bot doit rester disponible');
assert.match(scripts[0], /bot_step/, 'Le client de l’hôte doit piloter les bots via bot_step');
assert.match(html, /data-act="ready"/, 'Ready control must remain available');

console.log('Frontend sanity checks passed.');
