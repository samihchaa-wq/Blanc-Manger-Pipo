// Mr White : carte secrète, vote, verdicts.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Mr White ---------- */
// Les rôles et les mots sont demandés à un RPC distinct : personne ne peut lire
// ceux des autres dans le HTML, le salon ou les tables exposées.

// En présentiel, le voisin voit l'écran : la carte reste floue et ne se lit
// qu'en gardant le doigt dessus (ou Espace / Entrée au clavier).
function whiteSecret(){
  const w=state.white||{};
  const inner=w.role==='white'
    ? `<img class="white-mark" src="games/white.svg" alt="Emblème de Mr White">
    <strong>Tu es Mr White</strong>`
    : `<strong>${esc(w.word||'—')}</strong>`;
  return `<section class="white-secret hold" data-hold tabindex="0" role="button" aria-label="Ta carte, maintiens pour la voir">
    <p class="eyebrow">Ta Carte :</p>
    <div class="secret">${inner}</div>
    <span class="holdhint" aria-hidden="true">${ic('eye')}Maintiens pour voir</span>
  </section>`;
}
function whitePeople(){
  const w=state.white||{};
  return `<ul class="white-list">${(w.roles||[]).map(p=>
    `<li class="${p.out?'out':''}"><span class="nm">${nameOf(p.player_id)}${isMe(p.player_id)?' · toi':''}</span>
      <span class="meta">${p.out?esc(p.role==='civil'?'Civil':p.role==='white'?'Mr White':'Imposteur'):'En jeu'}${p.voted&&state.room.status==='white_vote'?' · a voté':''}</span></li>`).join('')}</ul>`;
}
function whiteNote(){
  return state.white?.note?`<div class="white-note">${esc(state.white.note)}</div>`:'';
}
// Qui commence : tiré au sort à la première manche, puis chacun son tour (serveur).
function whiteTurn(){
  const id=state.white?.starter_id;
  const qui=!id?'':isMe(id)?' <b>Tu commences.</b>':` <b>${nameOf(id)}</b> commence.`;
  return `<p class="white-turn">Chacun son tour, vous devez donner un indice.${qui} Vous avez droit à 3 indices chacun au maximum.</p>`;
}
function whiteClue(){
  const host=isMe(state.room.host_id);
  return `${whiteSecret()}${whiteTurn()}${host
    ? `<div class="dock"><button class="btn" data-act="white-open-vote" ${dis()}>Passer au vote</button></div>`
    : ''}`;
}
function whiteVote(){
  const w=state.white||{}, roles=w.roles||[];
  const available=roles.filter(p=>!p.out&&!isMe(p.player_id));
  // Même attente que dans les autres mini-jeux : seuls les joueurs encore
  // en jeu et n'ayant pas voté apparaissent dans les pastilles.
  const pending=roles.filter(p=>!p.out&&!p.voted&&P(p.player_id)?.active).map(p=>P(p.player_id));
  return `
    ${whiteSecret()}
    <h1 class="bigstate">Qui est l’imposteur ?</h1>
    ${w.voted||w.eliminated?'':
       `<h3 class="sec">Ton vote</h3><ul class="white-list ballot">${available.map(p=>
        `<li><button data-act="white-vote" data-id="${p.player_id}" ${dis()}><span>${nameOf(p.player_id)}</span></button></li>`).join('')}</ul>`}
    ${waiting(pending,'Tout le monde a voté.')}`;
}
function whiteGuess(){
  const w=state.white||{}, mine=w.role==='white'&&w.last_eliminated===state.me.id;
  return `
    <h1 class="bigstate">Mr White démasqué !</h1>
    ${whiteNote()}
    <p class="role">Mr White peut encore gagner : il annonce le mot des Civils à voix haute. Un Civil vérifie la proposition.</p>
    ${mine?'<p class="waiting">Dis à voix haute le mot que tu proposes. Un Civil confirmera la réponse.</p>':
      w.can_validate?`<section class="white-secret"><p class="eyebrow">Mot des Civils à vérifier</p>
        <strong>${esc(w.civil_word||'?')}</strong>
        <small>Écoute la proposition prononcée par Mr White, sans lui montrer ton écran.</small></section>
        <div class="dock"><button class="btn alt" data-act="white-oral-verdict" data-correct="0" ${dis()}>Mauvaise réponse</button>
          <button class="btn" data-act="white-oral-verdict" data-correct="1" ${dis()}>Bonne réponse</button></div>`:
      '<p class="waiting">Un Civil vérifie la réponse de Mr White…</p>'}`;
}

function whiteEliminationSentence(){
  const w=state.white||{}, person=(w.roles||[]).find(p=>p.player_id===w.last_eliminated);
  if (!person) return '';
  const role=person.role==='civil'?'Civil':person.role==='undercover'?'Imposteur':person.role==='white'?'Mr White':null;
  return role?`<p class="role"><b>${nameOf(person.player_id)}</b> est éliminé, il était <b>${role}</b>.</p>`:'';
}
function whiteTeamNames(group){
  const names=group.map(p=>nameOf(p.player_id));
  return names.length>1?names.slice(0,-1).join(', ')+' et '+names.at(-1):(names[0]||'');
}
function whiteWinnerSentence(){
  const w=state.white||{}, roles=w.roles||[];
  if (w.winner==='civils') {
    const civils=roles.filter(p=>p.role==='civil'&&P(p.player_id)?.active);
    return civils.length?`<p class="role"><b>${whiteTeamNames(civils)}</b> ${civils.length>1?'étaient Civils, ils ont gagné':'était Civil, il a gagné'}.</p>`:'';
  }
  if (w.winner==='white') {
    const mr=roles.filter(p=>p.role==='white');
    return mr.length?`<p class="role"><b>${whiteTeamNames(mr)}</b> était Mr White, il a gagné.</p>`:'';
  }
  if (w.winner==='imposteurs') {
    const imposteurs=roles.filter(p=>p.role==='undercover'&&P(p.player_id)?.active);
    if (!imposteurs.length) return '';
    if (imposteurs.length===1)
      return `<p class="role"><b>${whiteTeamNames(imposteurs)}</b> était l’imposteur, il a gagné.</p>`;
    return `<p class="role"><b>${whiteTeamNames(imposteurs)}</b> étaient les imposteurs, ils ont gagné.</p>`;
  }
  return '';
}
// La carte de l'éliminé se retourne sur son rôle. Décorative : la phrase
// d'élimination juste en dessous dit la même chose aux lecteurs d'écran.
function whiteFlip(){
  const w=state.white||{}, person=(w.roles||[]).find(p=>p.player_id===w.last_eliminated);
  const role=person&&{civil:'Civil',undercover:'Imposteur',white:'Mr White'}[person.role];
  if (!role) return '';
  return `<div class="flip" aria-hidden="true"><div class="in">
    <div class="face front"><span class="fn">${nameOf(person.player_id)}</span><span class="eyebrow">Éliminé</span></div>
    <div class="face back r-${person.role}">${person.role==='white'?'<img src="games/white.svg" alt="">':''}
      <span class="eyebrow">${nameOf(person.player_id)} était</span><strong>${role}</strong></div>
  </div></div>`;
}
function whiteElimination(){
  const w=state.white||{}, host=isMe(state.room.host_id);
  const remaining=Math.max(0,Number(w.impostors_remaining)||0);
  const remainingText=remaining===0?'Il ne reste plus d’Imposteur':
    `Il reste <b>${remaining} Imposteur${remaining>1?'s':''}</b>`;
  return `
    <p class="eyebrow">Résultat du vote</p>
    ${whiteFlip()}
    ${whiteEliminationSentence()||`<p class="role">${esc(w.note||'Personne n’est éliminé.')}</p>`}
    <p class="role">${remainingText}, la partie continue.</p>
    ${host?`<div class="dock"><button class="btn" data-act="white-resume" ${dis()}>Tour suivant</button></div>`:''}`;
}
function whiteReveal(){
  const w=state.white||{}, hasMrWhite=(w.roles||[]).some(p=>p.role==='white');
  return `
    <p class="eyebrow">Fin de la manche ${state.room.round}</p>
    ${whiteFlip()}
    ${whiteEliminationSentence()}
    ${whiteWinnerSentence()}
    <div class="white-secret">
      <p class="eyebrow">Mot des Civils :</p><strong>${esc(w.civil_word||'—')}</strong>
      ${!hasMrWhite?`<p class="eyebrow">Mot de l’Imposteur :</p><strong>${esc(w.undercover_word||'—')}</strong>`:''}
    </div>
    ${ackWaiting()}
    <div class="dock"><button class="btn" data-act="bac-next" ${dis(state.me.next_ack===state.room.round)}>
      ${state.me.next_ack===state.room.round?'En attente des autres…':
        state.room.round>=bacRounds()?'Voir le résultat':'Manche suivante'}</button></div>`;
}

