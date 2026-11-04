// Résultats communs : réponse gagnante, classement, fin de manche et de partie, confettis.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
function result(){
  const r = state.room, q = state.question || '';
  const w = state.submissions.find(s => s.id === r.winning_submission_id);
  return qcard('Réponse gagnante', w ? fill(q, w.cards) : blank(q), 'win',
    w ? `<span class="by">${esc(w.author)}</span>` : '');
}
function rank(){
  return `<ol class="rank">${[...state.players].sort((a,b) => b.score - a.score).map((p,i) => `<li>
    <span class="pos">${i + 1}</span>${avatar(p.id, 'sm')}
    <span class="nm"><span class="who">${esc(p.name)}</span>${isMe(p.id) ? '<span class="tag">toi</span>' : ''}</span>
    <b>${p.score}</b></li>`).join('')}</ol>`;
}

// Une fois qu'on a validé, on voit qui n'a pas encore suivi.
function ackWaiting(){
  const r = state.room;
  if (state.me.next_ack !== r.round) return '';
  return waiting(state.players.filter(p => p.active !== false && p.next_ack !== r.round), 'C’est reparti…');
}
function sharedRoundNext(){
  const done = state.me.next_ack === state.room.round;
  return ackWaiting() + '<div class="dock"><button class="btn" data-act="bac-next" '
    + dis(done) + '>' + (done ? 'En attente des autres…' : 'Continuer')
    + '</button></div>';
}
function reveal(){
  if (isPrio()) return rankReveal() + sharedRoundNext();
  if (isWave()) return waveReveal() + sharedRoundNext();
  if (isBac()) return bacReveal();
  if (isWhite()) return whiteReveal();
  if (isMime()) return mimeReveal();
  const r = state.room;
  return `
    <p class="role">${avatar(r.winner_id)}Point pour <b>${isMe(r.winner_id) ? 'toi' : nameOf(r.winner_id)}</b> !</p>
    ${result()}
    <h3 class="sec">Classement</h3>${rank()}
    ${sharedRoundNext()}`;
}

function finished(){
  const r = state.room;
  // Priorités et Baromètre se jouent en manches comptées : plusieurs joueurs peuvent finir à égalité.
  const top = Math.max(...state.players.map(p => p.score));
  const best = isCounted() ? state.players.filter(p => p.score === top) : [];
  const title = best.length > 1 ? 'Égalité !' : isMe(r.winner_id) ? 'Tu gagnes !' : nameOf(r.winner_id) + ' gagne !';
  return `
    <p class="eyebrow">Partie terminée</p>
    <h1 class="bigwin">${title}</h1>
    ${isCounted()
      ? (best.length > 1 ? `<p class="role">${best.map(p => `<b>${isMe(p.id) ? 'Toi' : esc(p.name)}</b>`).join(', ').replace(/, ([^,]*)$/, ' et $1')} avec ${top} points.</p>` : '')
      : result()}
    ${punSection()}
    <h3 class="sec">Classement final</h3>${rank()}
    ${state.me.continue_requested ? waiting(state.players.filter(p => p.active !== false && !p.continue_requested), 'C’est reparti…') : ''}
    <div class="dock">
      <button class="btn" data-act="continue" ${dis(state.me.continue_requested)}>${state.me.continue_requested ? 'En attente des autres…' : 'Refaire une partie'}</button>
    </div>`;
}

function confetti(){
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  document.getElementById('confetti')?.remove();
  const wrap = document.createElement('div');
  wrap.className = 'confetti'; wrap.id = 'confetti'; wrap.setAttribute('aria-hidden','true');
  const colors = ['#FFC23D','#FF5C8D','#3FDC9C','#FFF6E6','#A88CFF'];
  for (let i = 0; i < 26; i++) {
    const s = document.createElement('i');
    s.style.left = Math.random() * 100 + 'vw';
    s.style.background = colors[i % colors.length];
    s.style.animationDelay = (Math.random() * .7).toFixed(2) + 's';
    s.style.animationDuration = (2.2 + Math.random() * 1.4).toFixed(2) + 's';
    wrap.appendChild(s);
  }
  document.body.appendChild(wrap);
  setTimeout(() => wrap.remove(), 4500);
}

