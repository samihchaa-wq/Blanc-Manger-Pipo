// Baromètre : cadran, modes normal et inversé, aiguille au doigt.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Baromètre ---------- */
// Le cadran va de 0 (extrême gauche) à 100 (extrême droite), en demi-cercle.
const DC = { x:100, y:100, r:90 };
function dpt(v, rad = DC.r){
  const a = Math.PI * (1 - v / 100);
  return [(DC.x + rad * Math.cos(a)).toFixed(2), (DC.y - rad * Math.sin(a)).toFixed(2)];
}
function wedge(a, b, cls){
  a = Math.max(0, a); b = Math.min(100, b);
  if (b <= a) return '';
  const [x1,y1] = dpt(a), [x2,y2] = dpt(b);
  return `<path class="${cls}" d="M${DC.x},${DC.y} L${x1},${y1} A${DC.r},${DC.r} 0 0 1 ${x2},${y2} Z"/>`;
}
// Les trois bandes de la cible : 2 points à 15 crans ou moins, 3 à 9, 4 à 3.
function bands(t){
  const num = (v, n) => v < 0 || v > 100 ? '' : (([x,y]) => `<text class="bn" x="${x}" y="${y}">${n}</text>`)(dpt(v, DC.r - 9));
  return wedge(t - 15, t + 15, 'b2') + wedge(t - 9, t + 9, 'b3') + wedge(t - 3, t + 3, 'b4')
    + num(t, 4) + num(t - 6, 3) + num(t + 6, 3) + num(t - 12, 2) + num(t + 12, 2);
}
function needle(v, color, me = false){
  const [x,y] = dpt(v, DC.r - 4);
  if (me) return `<line class="ndl me" id="myneedle" x1="${DC.x}" y1="${DC.y}" x2="${x}" y2="${y}"/>`;
  return `<line class="halo" x1="${DC.x}" y1="${DC.y}" x2="${x}" y2="${y}"/>
    <line class="ndl" x1="${DC.x}" y1="${DC.y}" x2="${x}" y2="${y}" style="stroke:${color}"/>
    <circle class="tip" cx="${x}" cy="${y}" r="4" style="fill:${color}"/>`;
}
// Graduations tous les 5 crans, plus marquées tous les 10 et au milieu : on
// lit enfin une position, plus seulement « à gauche » ou « à droite ».
function ticks(){
  return Array.from({ length:21 }, (_, i) => i * 5).map(v => {
    const k = v % 50 === 0 ? 'M' : v % 10 === 0 ? 'm' : '';
    const [x1, y1] = dpt(v, DC.r - 1.5), [x2, y2] = dpt(v, DC.r - (k === 'M' ? 9 : k ? 6 : 3.5));
    return `<line class="tk ${k}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}"/>`;
  }).join('');
}
// opts : target (bandes visibles), needles [{v,color}], mine (aiguille déplaçable)
function dial({ target = null, needles = [], mine = null, sweep = false } = {}){
  // en mode inversé, l'échelle est celle du thème écrit par un joueur
  const w = isInverse() ? { left:'−', right:'+' } : (state.wave || {});
  return `<div class="dialbox">
    <svg class="dial${mine != null ? ' drag' : ''}" id="dial" viewBox="0 -4 200 112" role="img" aria-label="Cadran entre ${isInverse() ? 'le moins et le plus' : esc(w.left) + ' et ' + esc(w.right)}">
      <path class="face" d="M${DC.x - DC.r},${DC.y} A${DC.r},${DC.r} 0 0 1 ${DC.x + DC.r},${DC.y} Z"/>
      ${ticks()}
      ${target == null ? '' : sweep ? `<g class="sweep" style="--t:${(-1.8 * target).toFixed(1)}deg">${bands(target)}</g>` : bands(target)}
      <path class="rim" d="M${DC.x - DC.r},${DC.y} A${DC.r},${DC.r} 0 0 1 ${DC.x + DC.r},${DC.y} Z"/>
      ${needles.map(n => `<g class="gn">${needle(n.v, n.color)}</g>`).join('')}
      ${mine != null ? needle(mine, null, true) : ''}
      <circle class="hub" cx="${DC.x}" cy="${DC.y}" r="7"/>
    </svg>
    <div class="wlabs${isInverse() ? ' signs' : ''}"><span class="wlab">${esc(w.left)}</span><span class="wlab r">${esc(w.right)}</span></div>
  </div>`;
}

// Mode inversé, phase « clue » : d'abord le thème, puis la réponse du médium.
function themeCard(){ return qcard('Thème', esc(state.wave?.theme || ''), 'clue') }
function inverseClue(){
  const r = state.room, w = state.wave || {};
  const asker = P(w.asker_id), canWrite = !isMe(r.reader_id) && (isMe(w.asker_id) || !asker);
  if (w.theme == null) {
    if (canWrite) return `
    <p class="role"><b>Écris un thème.</b> ${nameOf(r.reader_id)} y répondra selon la cible qu’il voit.</p>
    <label><span>Ton thème</span><input id="w-theme" maxlength="80" autocomplete="off" autocapitalize="sentences" placeholder="Ex. : un salaire que j’aimerais toucher" value="${esc(themeDraft)}"></label>
    <div class="dock"><button class="btn" data-act="theme" ${dis()}>Envoyer le thème</button></div>`;
    return `
    <p class="role">${isMe(r.reader_id) ? '<b>Tu es le médium.</b> ' : `<b>${nameOf(r.reader_id)}</b> est le médium. `}${asker ? `<b>${nameOf(w.asker_id)}</b> écrit le thème…` : 'On attend le thème…'}</p>
    ${dial(isMe(r.reader_id) ? { target: w.target } : {})}`;
  }
  if (!isMe(r.reader_id)) return `
    <p class="role"><b>${nameOf(r.reader_id)}</b> est le médium.</p>
    ${themeCard()}${dial()}
    <p class="muted" style="margin-top:22px;text-align:center"><span class="pulse"></span>Il cherche sa réponse…</p>${scoreStrip()}`;
  return `
    <p class="role"><b>Tu es le médium.</b> Réponds au thème selon la position de la cible.</p>
    ${themeCard()}${dial({ target: w.target })}
    <label style="margin-top:22px"><span>Ta réponse</span><input id="w-clue" maxlength="60" autocomplete="off" placeholder="Un mot, un nombre, une idée…" value="${esc(clueDraft)}"></label>
    <div class="dock"><button class="btn" data-act="clue" ${dis()}>Envoyer ma réponse</button></div>`;
}

function clue(){
  const r = state.room, w = state.wave || {};
  if (isInverse()) return inverseClue();
  if (!isMe(r.reader_id)) return `
    <p class="role"><b>${nameOf(r.reader_id)}</b> est le médium.</p>
    ${dial()}
    <p class="muted" style="margin-top:22px;text-align:center"><span class="pulse"></span>Il cherche un indice…</p>${scoreStrip()}`;
  return `
    <p class="role"><b>Tu es le médium.</b></p>
    ${dial({ target: w.target })}
    <label style="margin-top:22px"><span>Ton indice</span><input id="w-clue" maxlength="60" autocomplete="off" placeholder="Un mot, un nom, une idée…" value="${esc(clueDraft)}"></label>
    <div class="dock"><button class="btn" data-act="clue" ${dis()}>Donner l’indice</button></div>`;
}

function guessing(){
  const r = state.room, w = state.wave || {};
  const others = state.players.filter(p => p.id !== r.reader_id);
  const left = others.filter(p => !p.guessed), done = others.length - left.length;
  const progress = `<p class="meta" style="margin-top:18px">${done}/${others.length} ont visé</p>
    <div class="bar"><i style="width:${others.length ? Math.round(done / others.length * 100) : 0}%"></i></div>
    ${waiting(left, 'Tout le monde a visé.')}${scoreStrip('l')}`;
  const card = isInverse()
    ? themeCard() + qcard(isMe(r.reader_id) ? 'Ta réponse' : `Réponse de ${nameOf(r.reader_id)}`, esc(w.clue), 'clue')
    : qcard(isMe(r.reader_id) ? 'Ton indice' : `Indice de ${nameOf(r.reader_id)}`, esc(w.clue), 'clue');

  if (isMe(r.reader_id)) return `
    <p class="role"><b>Les autres cherchent ta cible.</b></p>${card}${dial({ target: w.target })}${progress}`;
  if (w.my_guess != null) return `
    <p class="role"><b>Aiguille posée.</b> Verdict quand tout le monde aura visé.</p>${card}${dial({ mine: w.my_guess })}${progress}`;
  return `
    <p class="role"><b>${nameOf(r.reader_id)}</b> est le médium.</p>
    ${card}${dial({ mine: dialVal })}
    <p class="swipehint">Fais glisser l’aiguille sur le cadran</p>
    <div class="dock"><button class="btn" data-act="guess" ${dis()}>Valider ma position</button></div>`;
}

function waveReveal(){
  const r = state.room, w = state.wave || {};
  const gs = (w.guesses || []).filter(g => P(g.player_id));
  const guessers = gs.filter(g => g.player_id !== r.reader_id);
  const pts = [...gs].sort((a,b) => b.points - a.points);
  return `
    <p class="role">${isMe(r.reader_id) ? '<b>Ta cible</b>' : `La cible de <b>${nameOf(r.reader_id)}</b>`}</p>
    ${isInverse() ? themeCard() + qcard('Réponse', esc(w.clue), 'clue') : qcard('Indice', esc(w.clue), 'clue')}
    ${dial({ target: w.target, needles: guessers.map(g => ({ v: g.value, color: seatColor(g.player_id) })), sweep: true })}
    <div class="legend">${guessers.map(g => `<span class="chip"><i style="background:${seatColor(g.player_id)}"></i>${nameOf(g.player_id)}</span>`).join('')}</div>
    <h3 class="sec">Points de la manche</h3>
    <ol class="rank">${pts.map(g => `<li>
      <span class="nm"><span class="who">${nameOf(g.player_id)}</span>${g.player_id === r.reader_id ? '<span class="tag host">médium</span>' : g.points === 4 ? '<span class="tag">dans le mille</span>' : ''}</span>
      <b class="plus" data-n="${g.points ?? 0}">+${g.points ?? 0}</b></li>`).join('')}</ol>
    <h3 class="sec">Classement</h3>${rank()}`;
}

// L'aiguille suit le doigt sans re-rendre l'écran : seule la ligne bouge.
function dialValueAt(e){
  const svg = document.getElementById('dial'), b = svg.getBoundingClientRect();
  const k = 200 / b.width;
  const x = (e.clientX - b.left) * k, y = (e.clientY - b.top) * k - 4;
  let a = Math.atan2(DC.y - y, x - DC.x);
  if (a < 0) a = x < DC.x ? Math.PI : 0;     // sous le moyeu : on colle au bord le plus proche
  return Math.round(100 * (1 - a / Math.PI));
}
function moveNeedle(v){
  dialVal = v;
  const el = document.getElementById('myneedle');
  if (!el) return;
  const [x,y] = dpt(v, DC.r - 4);
  el.setAttribute('x2', x); el.setAttribute('y2', y);
}
document.addEventListener('pointerdown', e => {
  const svg = e.target.closest('svg.dial.drag');
  if (!svg || busy || state?.wave?.my_guess != null) return;
  dialDrag = e.pointerId; dragging = true;
  try { svg.setPointerCapture(e.pointerId) } catch {}
  moveNeedle(dialValueAt(e));
});
document.addEventListener('pointermove', e => { if (dialDrag === e.pointerId) moveNeedle(dialValueAt(e)) });
function endDial(e){
  if (dialDrag !== e.pointerId) return;
  dialDrag = null;
  afterSwipe();
}
document.addEventListener('pointerup', endDial);
document.addEventListener('pointercancel', endDial);


