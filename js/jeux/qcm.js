// QCM : le quiz personnalisé. L'animateur (l'hôte) a écrit ses questions à
// l'avance ; la même question s'affiche sur tous les téléphones, chacun touche
// sa réponse, puis la bonne réponse apparaît avec qui a répondu quoi. C'est
// l'animateur qui passe à la question suivante.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html.
/* ---------- QCM ---------- */
// Une lettre et une couleur par réponse : on les repère d'un coup d'œil.
const QCM_LETTRES = ['A', 'B', 'C', 'D'];

// La carte de la question, avec son numéro et ses points.
function qcmCarte(cls = ''){
  const q = state.qcm || {};
  const tag = `Question ${q.position || state.room.round}${q.total ? ' / ' + q.total : ''}${q.points > 1 ? ` · ${q.points} points` : ''}`;
  return qcard(tag, esc(q.text || ''), ('qcm-q ' + cls).trim());
}

// Qui a déjà répondu (sans dire quoi), comme dans les autres jeux.
function qcmSuivi(){
  const r = state.room, faits = state.qcm?.answered || [];
  const joueurs = state.players.filter(p => p.active !== false && p.id !== r.reader_id);
  const reste = joueurs.filter(p => !faits.includes(p.id)), n = joueurs.length - reste.length;
  return `<p class="meta" style="margin-top:18px">${n}/${joueurs.length} ${n > 1 ? 'ont' : 'a'} répondu</p>
    <div class="bar"><i style="width:${joueurs.length ? Math.round(n / joueurs.length * 100) : 0}%"></i></div>
    ${waiting(reste, 'Tout le monde a répondu.')}`;
}

// La question : l'animateur voit la bonne réponse cochée, les joueurs touchent la leur
// (et peuvent en changer tant que la question est ouverte).
function qcmQuestion(){
  const r = state.room, q = state.qcm || {}, choix = q.choices || [];
  if (isMe(r.reader_id)) return `
    <p class="role"><b>Tu animes.</b> Lis la question à voix haute. La bonne réponse est cochée : toi seul la vois.</p>
    ${qcmCarte()}
    <ol class="qcm-choices">${choix.map((c, i) => `<li><div class="ddef qcm-c c${i}${i === q.correct ? ' ok' : ''}">
      <span class="dnum">${QCM_LETTRES[i]}</span><span class="dtx">${esc(c)}${i === q.correct ? '<small>Bonne réponse</small>' : ''}</span>${
      i === q.correct ? ic('check', 'qcm-ok') : ''}</div></li>`).join('')}</ol>
    ${q.note ? `<p class="hint qcm-noteprev">Après la réponse, ton commentaire : « ${esc(q.note)} »</p>` : ''}
    ${qcmSuivi()}
    <div class="dock"><button class="btn" data-act="qcm-reveal" ${dis()}>Révéler la réponse</button></div>`;
  const mien = q.my_choice;
  return `
    <p class="role">${mien != null ? '<b>Réponse envoyée.</b> Tu peux encore changer d’avis.' : '<b>Touche ta réponse.</b>'}</p>
    ${qcmCarte()}
    <ol class="qcm-choices">${choix.map((c, i) => `<li><button type="button" class="ddef qcm-c c${i}${i === mien ? ' on' : ''}"
      data-act="qcm-answer" data-i="${i}" aria-pressed="${i === mien}" ${dis()}><span class="dnum">${QCM_LETTRES[i]}</span><span class="dtx">${esc(c)}</span></button></li>`).join('')}</ol>
    ${qcmSuivi()}`;
}

// Révélation : la bonne réponse en vert, qui a choisi quoi, le bonus de
// rapidité, le commentaire de l'animateur et le classement.
function qcmReveal(){
  const r = state.room, q = state.qcm || {}, choix = q.choices || [];
  const anim = isMe(r.reader_id), dernier = q.total && q.position >= q.total;
  const reps = (q.answers || []).filter(a => P(a.player_id));
  const moi = reps.find(a => a.player_id === state.me.id), bonus = reps.find(a => a.bonus);
  const role = anim ? '<b>Réponse révélée.</b> Commente, puis passe à la suite.'
    : !moi ? '<b>Pas de réponse</b> cette fois.'
    : moi.choice === q.correct ? `<b>Bonne réponse !</b> +${moi.points} point${moi.points > 1 ? 's' : ''}${moi.bonus ? ', dont 1 pour la rapidité' : ''}.`
    : '<b>Raté…</b> La bonne réponse est en vert.';
  return `
    <p class="role">${role}</p>
    ${qcmCarte('short')}
    <ol class="qcm-choices res">${choix.map((c, i) => {
      const qui = reps.filter(a => a.choice === i), ok = i === q.correct, mien = moi?.choice === i;
      return `<li><div class="ddef qcm-c c${i}${ok ? ' ok' : ' ko'}${mien ? ' mine' : ''}">
        <span class="dnum">${QCM_LETTRES[i]}</span>
        <span class="dtx">${esc(c)}<small>${qui.length ? `${qui.length} joueur${qui.length > 1 ? 's' : ''}` : 'Personne'}${mien ? ' · ta réponse' : ''}</small></span>${
        ok ? ic('check', 'qcm-ok') : ''}</div>${
        qui.length ? `<div class="found">${qui.map(a => `<span class="chip${ok ? ' hit' : ''}">${nameOf(a.player_id)}</span>`).join('')}</div>` : ''}</li>`;
    }).join('')}</ol>
    ${bonus ? `<p class="qcm-bonus">${ic('bolt')}<span><b>${isMe(bonus.player_id) ? 'Toi' : nameOf(bonus.player_id)}</b> a trouvé en premier : +1 point</span></p>` : ''}
    ${q.note ? `<section class="dbox qcm-note"><p class="eyebrow">Le mot de l’animateur</p><p>${esc(q.note)}</p></section>` : ''}
    <h3 class="sec">Classement</h3>${rank()}
    <div class="dock">${anim
      ? `<button class="btn" data-act="qcm-next" ${dis()}>${dernier ? 'Voir le classement final' : 'Question suivante'}</button>`
      : `<p class="dockhint"><b>${nameOf(r.reader_id)}</b> passe à la ${dernier ? 'fin du quiz' : 'question suivante'}.</p>`}</div>`;
}

/* ---------- Actions ---------- */
surAction('qcm-answer', el => act('qcm_answer', { p_choice: +el.dataset.i }));
surAction('qcm-reveal', () => act('qcm_reveal'));
surAction('qcm-next', () => act('qcm_next'));
