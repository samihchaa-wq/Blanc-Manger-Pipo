import fs from 'node:fs';
import assert from 'node:assert/strict';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
  .map(m => m[1].trim())
  .filter(Boolean);

assert.equal(scripts.length, 1, 'Expected exactly one inline application script');
new Function(scripts[0]);

assert.match(html, /@supabase\/supabase-js@2\.116\.0\/dist\/umd\/supabase\.js/,
  'Supabase JS must stay pinned to the reviewed version');
assert.match(html, /sb_publishable_[A-Za-z0-9_-]+/,
  'Client must use a publishable Supabase key');
assert.doesNotMatch(html, /service[_-]?role|sb_secret_/i,
  'Never expose a service-role or secret key in the browser');
assert.match(html, /setInterval\(\(\)=>\{if\(!document\.hidden\)refresh\(\)\},12000\)/,
  'Fallback polling must remain at 12 seconds');
assert.match(html, /setTimeout\(refresh,250\)/,
  'Realtime bumps must remain debounced');
assert.match(html, /<option>3<\/option><option selected>5<\/option><option>7<\/option><option>10<\/option>/,
  'Supported target scores changed unexpectedly');
assert.match(html, /data-act="bot"/, 'Bot control must remain available');
assert.match(html, /data-act="ready"/, 'Ready control must remain available');

console.log('Frontend sanity checks passed.');
