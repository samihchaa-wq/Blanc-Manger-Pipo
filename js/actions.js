// Démarrage de l'appli et distribution des clics : chaque écran déclare ses
// actions avec surAction (voir core.js) dans son propre fichier ; ici, un seul
// écouteur les retrouve par le data-act du bouton touché.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, celui-ci en dernier.

document.addEventListener('click', e => {
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  // un balayage se termine par un clic fantôme : on l'ignore
  if (el.classList.contains('acard') && Date.now() - lastSwipeEnd < 400) return;
  // certains navigateurs n'accordent le verrou d'écran qu'après un geste
  if (session && !wakeLock) keepAwake();
  const action = ACTIONS[el.dataset.act];
  if (!action) return;
  // le bouton touché passe en « envoi en cours » pendant l'appel au serveur (voir act)
  if (action.marque) pressedEl = el;
  return action.fn(el, el.dataset.id, e);
});

// Barre du haut : inviter, quitter.
surAction('share', () => shareInvite(), { marque:false });
surAction('leave', async () => {
  if (busy || !session) return;
  // En pleine partie, un tap par erreur sur la croix sortait le joueur : confirmation.
  if (state && state.room.status !== 'lobby' && !confirm('Quitter la partie en cours ?')) return;
  const expectedSession = session;
  busy = true;
  try {
    await rpc('leave_room', { p_code:expectedSession.code, p_token:expectedSession.token });
    if (session !== expectedSession) return;
    ping();
    leaveLocal();
  } catch (e) {
    if (session !== expectedSession) return;
    if (/Session expirée/.test(e.message)) leaveLocal();
    else toast('Départ non confirmé. Vérifie ta connexion et réessaie : ta place est conservée.');
  } finally { busy = false }
}, { marque:false });

// De retour dans l'appli : relecture, écran allumé, et une mise à jour éventuelle.
document.addEventListener('visibilitychange', () => { if (!document.hidden) { refresh(true); keepAwake(); verifierVersion() } });

const urlCode = (new URLSearchParams(location.search).get('code') || '').replace(/\D/g,'');
// Un lien d'invitation ne doit pas abandonner silencieusement une partie active.
if (session && urlCode && urlCode !== session.code) {
  history.replaceState(null, '', location.pathname + '?code=' + session.code);
  setTimeout(() => toast('Tu es déjà dans une partie : quitte-la avant d’en rejoindre une autre.'), 0);
}
session ? startSession() : render();
