// Gestes : balayage des cartes, glisser-déposer de Priorités.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Balayage des cartes ---------- */
const swipeThreshold = w => Math.max(80, Math.min(140, w * .4));

function paintSwipe(){
  const s = swipe;
  if (!s) return;
  const canDrop = !!state?.me?.can_discard;
  // échange indisponible : on freine le glissement au lieu de l'interdire sèchement
  const dx = (s.dx < 0 && !canDrop) ? s.dx / 3.5 : s.dx;
  const ratio = Math.min(1, Math.abs(dx) / swipeThreshold(s.w));
  s.el.style.transform = `translateX(${dx.toFixed(1)}px) rotate(${(dx / 28).toFixed(2)}deg)`;
  const play = s.box.querySelector('.cue.play'), drop = s.box.querySelector('.cue.drop');
  if (play) { play.style.opacity = dx > 0 ? ratio : 0; play.classList.toggle('armed', dx > 0 && ratio >= 1) }
  if (drop) { drop.style.opacity = dx < 0 ? ratio : 0; drop.classList.toggle('armed', dx < 0 && ratio >= 1) }
}

function clearSwipe(s){
  s.el.classList.remove('dragging');
  s.el.style.transform = ''; s.el.style.opacity = '';
  s.box.querySelectorAll('.cue').forEach(c => { c.style.opacity = 0; c.classList.remove('armed') });
}

function afterSwipe(){
  dragging = false;
  if (pendingRender) { pendingRender = false; render() }
}

async function runSwipe(id, dir){
  picks = [];
  await act(dir === 'play' ? 'submit_answer' : 'discard_card', { p_answer_id: id });
}

document.addEventListener('pointerdown', e => {
  // seules les cartes en main se balaient ; celles de Priorités se touchent
  const el = e.target.closest('.acard[data-act="select"]');
  if (!el || busy || flying || e.button > 0) return;
  swipe = { id:+el.dataset.id, el, box:el.parentElement, pid:e.pointerId,
            x0:e.clientX, y0:e.clientY, dx:0, on:false, w:el.getBoundingClientRect().width };
});

document.addEventListener('pointermove', e => {
  if (!swipe || e.pointerId !== swipe.pid) return;
  const dx = e.clientX - swipe.x0, dy = e.clientY - swipe.y0;
  if (!swipe.on) {
    if (Math.abs(dy) > 12 && Math.abs(dy) > Math.abs(dx)) { swipe = null; return }  // c'est un défilement
    if (Math.abs(dx) < 8) return;
    swipe.on = true; dragging = true;
    swipe.el.classList.add('dragging');
    try { swipe.el.setPointerCapture(e.pointerId) } catch {}
  }
  swipe.dx = dx;
  paintSwipe();
});

function endSwipe(e){
  const s = swipe;
  if (!s || (e && e.pointerId !== s.pid)) return;
  swipe = null;
  if (!s.on) return;                      // simple appui : le clic s'en charge
  lastSwipeEnd = Date.now();
  const canDrop = !!state?.me?.can_discard;
  const dir = s.dx > 0 ? 'play' : 'drop';
  const far = Math.abs(s.dx) >= swipeThreshold(s.w);
  // À deux trous le geste ne dit pas quelle carte va où : on passe par la
  // sélection et le bouton d'envoi.
  const deuxTrous = (state?.blanks || 1) > 1;

  if (!far || (dir === 'drop' && !canDrop) || (dir === 'play' && deuxTrous)) {
    clearSwipe(s);
    if (dir === 'play' && deuxTrous && Math.abs(s.dx) > 40) toast('Deux trous : touche deux cartes, puis envoie.');
    else if (dir === 'drop' && !canDrop && Math.abs(s.dx) > 40) toast('Tu as déjà échangé une carte cette manche.');
    return afterSwipe();
  }
  // la carte part sur le côté, puis on déclenche
  dragging = false; flying = true;
  s.el.style.transition = 'transform .17s ease-in, opacity .17s linear';
  s.el.style.transform = `translateX(${dir === 'play' ? 120 : -120}%) rotate(${dir === 'play' ? 8 : -8}deg)`;
  s.el.style.opacity = '0';
  setTimeout(() => { flying = false; pendingRender = false; runSwipe(s.id, dir) }, 170);
}
document.addEventListener('pointerup', endSwipe);
document.addEventListener('pointercancel', endSwipe);

/* ---------- Priorités : glisser-déposer ---------- */
// Une carte (de la main ou déjà classée) se glisse sur une marche. Au doigt,
// il faut la garder appuyée un instant, sinon le geste fait défiler la page ;
// à la souris, elle part dès qu'on bouge.
let rdrag = null;

// Pose la carte c sur la marche i. Si la marche est prise, les cartes se
// décalent vers la marche vide la plus proche (en dessous d'abord).
function placeRank(c, i){
  const n = (state?.rank_cards || []).length;
  const p = Array.from({ length:n }, (_, k) => picks[k] === c ? undefined : picks[k]);
  if (p[i]) {
    let k = i + 1; while (k < n && p[k]) k++;
    if (k < n) { for (let j = k; j > i; j--) p[j] = p[j - 1] }
    else { k = i - 1; while (k >= 0 && p[k]) k--; for (let j = k; j < i; j++) p[j] = p[j + 1] }
  }
  p[i] = c;
  picks = p;
}

// la marche visée : la plus proche du doigt, si on est sur l'échelle
function rankTarget(x, y){
  const ol = app.querySelector('.ladder'); if (!ol) return -1;
  const b = ol.getBoundingClientRect();
  if (x < b.left - 20 || x > b.right + 20 || y < b.top - 40 || y > b.bottom + 40) return -1;
  let best = -1, dist = Infinity;
  [...ol.children].forEach((li, i) => {
    const r = li.getBoundingClientRect(), d = Math.abs(y - (r.top + r.height / 2));
    if (d < dist) { dist = d; best = i }
  });
  return best;
}

function startRankDrag(){
  const d = rdrag, r = d.el.getBoundingClientRect();
  d.on = true; dragging = true;
  d.dx = d.x - r.left; d.dy = d.y - r.top;
  d.ghost = d.el.cloneNode(true);
  d.ghost.className = 'acard rank-float';
  d.ghost.removeAttribute('data-act');
  d.ghost.style.width = r.width + 'px';
  document.body.appendChild(d.ghost);
  d.el.classList.add('rank-src');
  try { d.el.setPointerCapture(d.pid) } catch {}
  try { navigator.vibrate?.(12) } catch {}
  moveRankDrag();
  const tick = () => {
    if (!rdrag?.on) return;
    const m = 70, v = rdrag.y < m ? -(m - rdrag.y) / 4 : rdrag.y > innerHeight - m ? (rdrag.y - innerHeight + m) / 4 : 0;
    if (v) { scrollBy(0, v); moveRankDrag() }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

function moveRankDrag(){
  const d = rdrag;
  d.ghost.style.transform = `translate(${d.x - d.dx}px,${d.y - d.dy}px) rotate(-2deg) scale(1.03)`;
  const t = rankTarget(d.x, d.y);
  if (t !== d.over) {
    app.querySelectorAll('.ladder li.over').forEach(li => li.classList.remove('over'));
    if (t >= 0) app.querySelector('.ladder').children[t]?.classList.add('over');
    d.over = t;
  }
}

function endRankDrag(e){
  const d = rdrag;
  if (!d || (e && e.pointerId !== d.pid)) return;
  rdrag = null; clearTimeout(d.timer);
  if (!d.on) return;                      // simple appui : le clic s'en charge
  lastSwipeEnd = Date.now();
  d.ghost.remove();
  dragging = false; pendingRender = false;
  if (e?.type === 'pointerup') {
    const t = rankTarget(e.clientX, e.clientY);
    if (t >= 0) placeRank(d.id, t);
    else if (d.fromLadder) { const i = picks.indexOf(d.id); if (i >= 0) picks[i] = undefined }
  }
  render();
}

document.addEventListener('pointerdown', e => {
  const el = e.target.closest('.acard[data-act="rank"],.acard[data-act="unrank"]');
  if (!el || busy || e.button > 0) return;
  rdrag = { id:+el.dataset.id, el, pid:e.pointerId, x0:e.clientX, y0:e.clientY, x:e.clientX, y:e.clientY,
            on:false, over:-1, fromLadder: el.dataset.act === 'unrank', touch: e.pointerType === 'touch' };
  if (rdrag.touch) rdrag.timer = setTimeout(() => { if (rdrag && !rdrag.on) startRankDrag() }, 180);
});

document.addEventListener('pointermove', e => {
  const d = rdrag;
  if (!d || e.pointerId !== d.pid) return;
  d.x = e.clientX; d.y = e.clientY;
  if (!d.on) {
    const far = Math.hypot(d.x - d.x0, d.y - d.y0) > (d.touch ? 10 : 6);
    if (!far) return;
    if (d.touch) { clearTimeout(d.timer); rdrag = null; return }   // trop tôt : c'est un défilement
    startRankDrag();
  }
  moveRankDrag();
});
// une fois la carte saisie, le doigt ne fait plus défiler la page
document.addEventListener('touchmove', e => { if (rdrag?.on) e.preventDefault() }, { passive:false });
document.addEventListener('pointerup', endRankDrag);
document.addEventListener('pointercancel', endRankDrag);
document.addEventListener('contextmenu', e => { if (rdrag) e.preventDefault() });

