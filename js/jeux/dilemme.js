// Dilemme parfait : le meneur pose le début d'un dilemme, chacun écrit la suite
// après « mais… », puis tout le monde répond Oui ou Non aux propositions des
// autres. Le but : couper la table pile en deux.
// Script classique (pas un module) : tous les fichiers partagent la même portée
// globale et se chargent dans l'ordre d'index.html, comme l'ancien script unique.
/* ---------- Dilemme parfait ---------- */
// Idées de débuts proposées au meneur (il peut aussi écrire le sien).
const DILEMME_DEBUTS = [
  'Tu gagnes un million d’euros', 'Tu peux voler', 'Tu deviens invisible quand tu veux',
  'Tu ne travailles plus jamais', 'Tu peux lire dans les pensées', 'Tu vis jusqu’à 150 ans en pleine forme',
  'Tu peux te téléporter n’importe où', 'Tu parles toutes les langues du monde', 'Tu deviens la personne la plus célèbre de France',
  'Tu manges ce que tu veux sans grossir', 'Tu n’as plus jamais besoin de dormir', 'Tu peux remonter le temps de 10 minutes',
  'Tu reçois 5 000 € par mois à vie', 'Tu vis dans une villa avec piscine, gratuitement', 'Tu as un chef cuisinier personnel',
  'Tu peux parler aux animaux', 'Tu ne tombes plus jamais malade', 'Tu gagnes au loto chaque année',
  'Tu deviens footballeur professionnel', 'Tu as 10 ans de moins', 'Tu voyages gratuitement partout, toute ta vie',
  'Tu as le corps de tes rêves', 'Tu deviens un génie', 'Tu peux arrêter le temps',
  'Tu deviens président de la République', 'Tu as un jet privé', 'Tu sais toujours quand on te ment',
  'Tu as Internet gratuit et illimité partout', 'Tu rencontres l’amour de ta vie demain', 'Tu connais la date de ta mort',
  'Tu deviens le meilleur chanteur du monde', 'Tu ne fais plus jamais la queue nulle part', 'Tu peux respirer sous l’eau',
  'Tu reçois une voiture de luxe neuve chaque année', 'Tu peux revivre ta meilleure journée quand tu veux', 'Ton loyer est payé à vie',
  'Tu deviens immortel', 'Tu vois l’avenir, une minute à l’avance', 'Tu as 100 000 abonnés sur chaque réseau',
  'Tu peux changer de visage quand tu veux', 'Tu prends 30 cm', 'Tu gagnes tous tes débats',
  'Tu as une mémoire parfaite', 'Tu peux cloner ton corps une fois par jour', 'Tu as un majordome robot',
  'Tu gagnes 1 € à chaque pas que tu fais', 'Tu peux mettre n’importe quelle série en pause dans la vraie vie', 'Tu trouves 100 € par terre chaque matin',
];
// Suites écrites par les bots.
const DILEMME_MAIS = [
  'tu dois chanter tout ce que tu dis', 'tu sens le fromage en permanence', 'tes parents lisent tous tes messages',
  'tu ne peux plus jamais manger de chocolat', 'tu éternues à chaque fois que quelqu’un dit ton prénom', 'tu dois porter un costume de pingouin',
  'tu perds un ami au hasard chaque année', 'tu ne peux plus utiliser ton téléphone', 'tu dois vivre chez ta belle-mère',
  'tu cries chaque fois que tu as peur, même un peu', 'tu as toujours un caillou dans ta chaussure', 'tu ne peux plus jamais mentir',
  'tu dois dire « je t’aime » à chaque inconnu', 'tu perds tes cheveux d’un coup', 'tu ne peux plus parler, seulement mimer',
  'ton historique Internet est public', 'tu dois prendre une douche froide chaque matin', 'tu ne peux plus jamais quitter ta ville',
  'tu as le hoquet tous les jours à midi', 'tu dois manger des épinards à chaque repas', 'tu oublies une date importante par an',
  'tout le monde entend tes pensées le lundi', 'tu ne peux écouter qu’une seule chanson', 'tu marches en crabe en public',
];
let dilChoix = null, dilStartDraft = '', dilButDraft = '', dilVotes = {};

const melange = list => list.map(x => [Math.random(), x]).sort((a, b) => a[0] - b[0]).map(x => x[1]);
// Trois débuts au hasard, différents du tirage précédent quand c'est possible.
function dilTirer(){
  const avant = new Set(dilChoix || []);
  const pool = DILEMME_DEBUTS.filter(x => !avant.has(x));
  dilChoix = melange(pool.length >= 3 ? pool : DILEMME_DEBUTS).slice(0, 3);
}
// Ce que le téléphone de l'hôte envoie au serveur pour faire jouer les bots.
const dilemmeBotArgs = () => ({ p_starts: melange(DILEMME_DEBUTS).slice(0, 1), p_buts: melange(DILEMME_MAIS).slice(0, 12) });

// Le dilemme entier : « début, mais suite ».
const dilPhrase = (start, but) => `<span class="dlm-a">${esc(start)},</span> <span class="dlm-b">mais ${esc(but)}</span>`;
const dilDebut = (cls = '') => qcard('Le dilemme', `<span class="dlm-a">${esc(state.dilemme?.start || '')},</span> <span class="dlm-b">mais…</span>`, 'dlm-card short ' + cls);

function dilSuivi(faits, mot){
  const tous = state.players.filter(p => p.active !== false);
  const reste = tous.filter(p => !faits.includes(p.id)), n = tous.length - reste.length;
  return `<p class="meta" style="margin-top:18px">${n}/${tous.length} ${mot}</p>
    <div class="bar"><i style="width:${tous.length ? Math.round(n / tous.length * 100) : 0}%"></i></div>
    ${waiting(reste, 'Tout le monde a fini.')}`;
}

// Choix du début : trois idées, ou celui que le meneur écrit lui-même.
function dilemmePick(){
  const r = state.room;
  if (!isMe(r.reader_id)) return `<div class="waitScreen">
    <h2 class="bigstate">${nameOf(r.reader_id)} prépare le dilemme</h2>
    <p class="muted"><span class="pulse"></span>Préparez vos « mais »…</p>${scoreStrip()}</div>`;
  if (!dilChoix) dilTirer();
  return `
    <p class="role"><b>Tu es le meneur.</b> Choisis le début du dilemme. Chacun écrira la suite après « mais… ».</p>
    <ul class="dlm-sugg">${dilChoix.map((t, i) => `<li><button type="button" class="dlm-idea${t === dilStartDraft ? ' on' : ''}" data-act="dil-idea" data-i="${i}"
      aria-pressed="${t === dilStartDraft}">${esc(t)}<span class="dlm-b">, mais…</span></button></li>`).join('')}</ul>
    <button type="button" class="btn ghost small dlm-reroll" data-act="dil-reroll">Autres idées</button>
    <label class="dwrite"><span>Ou écris le tien</span><input id="dil-start" maxlength="120" autocomplete="off" autocapitalize="sentences"
      placeholder="Tu gagnes…" value="${esc(dilStartDraft)}"></label>
    <div class="dock"><button class="btn" data-act="dil-start" ${dis()}>Poser le dilemme</button></div>`;
}

// Rédaction : tout le monde, meneur compris, écrit sa suite.
function dilemmeWrite(){
  const d = state.dilemme || {}, suivi = dilSuivi(d.written || [], 'ont écrit');
  if (d.mine) return `
    <p class="role"><b>Proposition envoyée.</b> Les autres diront s’ils acceptent.</p>
    ${qcard('Ta proposition', dilPhrase(d.start, d.mine), 'dlm-card')}
    ${suivi}`;
  return `
    <p class="role"><b>Complète le dilemme.</b> Vise une suite qui coupe la table en deux : la moitié dit oui, l’autre non.</p>
    ${dilDebut()}
    <label class="dwrite"><span>mais…</span><textarea id="dil-but" rows="2" maxlength="140" autocapitalize="off"
      placeholder="tu dois…">${esc(dilButDraft)}</textarea></label>
    <div class="dock"><button class="btn" data-act="dil-send" ${dis()}>Envoyer ma proposition</button></div>`;
}

// Vote : Oui ou Non à chaque proposition des autres, envoyés d'un coup.
function dilemmeVote(){
  const d = state.dilemme || {}, buts = d.buts || [], autres = buts.filter(x => !x.mine);
  autres.forEach(x => { if (!(x.id in dilVotes) && x.my_vote != null) dilVotes[x.id] = x.my_vote });
  const envoye = (d.voted || []).includes(state.me.id);
  const reste = autres.filter(x => dilVotes[x.id] == null).length;
  const change = envoye && autres.some(x => dilVotes[x.id] !== x.my_vote);
  const items = buts.map(x => `<li class="dlm-item${x.mine ? ' own' : ''}">
    <p class="dlm-txt">${dilPhrase(d.start, x.text)}</p>
    ${x.mine ? '<p class="dlm-own">Ta proposition</p>' : `<div class="dlm-yn" role="group" aria-label="Tu acceptes ?">
      <button type="button" class="yes${dilVotes[x.id] === true ? ' on' : ''}" data-act="dil-yn" data-id="${x.id}" data-v="1" aria-pressed="${dilVotes[x.id] === true}">Oui</button>
      <button type="button" class="no${dilVotes[x.id] === false ? ' on' : ''}" data-act="dil-yn" data-id="${x.id}" data-v="0" aria-pressed="${dilVotes[x.id] === false}">Non</button>
    </div>`}</li>`).join('');
  const label = reste ? `Encore ${reste} à trancher` : envoye ? (change ? 'Envoyer mes changements' : 'Réponses envoyées') : 'Envoyer mes réponses';
  return `
    <p class="role">${envoye ? '<b>Réponses envoyées.</b> Tu peux encore changer d’avis.' : '<b>Tu acceptes ?</b> Réponds Oui ou Non à chaque dilemme.'}</p>
    <ol class="dlm-list">${items}</ol>
    ${dilSuivi(d.voted || [], 'ont répondu')}
    <div class="dock"><button class="btn" data-act="dil-vote" ${dis(reste > 0 || (envoye && !change))}>${label}</button></div>`;
}

// Révélation : chaque proposition avec son auteur, la part de Oui et de Non, et ses points.
function dilemmeReveal(){
  const d = state.dilemme || {};
  const buts = (d.buts || []).filter(x => P(x.author_id))
    .sort((a, b) => (b.points ?? 0) - (a.points ?? 0) || Math.abs(a.yes.length - a.no.length) - Math.abs(b.yes.length - b.no.length));
  const pts = (d.points || []).filter(x => P(x.player_id)).sort((a, b) => b.points - a.points);
  const qui = ids => ids.map(id => `<span class="chip">${nameOf(id)}</span>`).join('');
  return `
    <p class="role">Le dilemme de <b>${isMe(state.room.reader_id) ? 'toi' : nameOf(state.room.reader_id)}</b></p>
    <ol class="dlm-list">${buts.map(x => {
      const y = x.yes.length, n = x.no.length, tot = y + n, py = tot ? Math.round(y / tot * 100) : 0;
      const parfait = tot > 0 && y === n;
      return `<li class="dlm-item res${parfait ? ' perfect' : ''}">
        <p class="dlm-txt">${dilPhrase(d.start, x.text)}</p>
        <p class="dby"><span><b>${isMe(x.author_id) ? 'Toi' : nameOf(x.author_id)}</b></span>${parfait ? '<span class="tag">50/50 parfait</span>' : ''}<b class="plus" data-n="${x.points ?? 0}">+${x.points ?? 0}</b></p>
        <div class="dlm-split" role="img" aria-label="${y} oui, ${n} non">
          <i class="y" style="width:${tot ? py : 50}%"><span>${tot ? py + ' % oui' : ''}</span></i><i class="n" style="width:${tot ? 100 - py : 50}%"><span>${tot ? 100 - py + ' % non' : ''}</span></i>
        </div>
        <div class="dlm-who"><div><small>Oui</small>${y ? qui(x.yes) : '<span class="muted">Personne</span>'}</div><div><small>Non</small>${n ? qui(x.no) : '<span class="muted">Personne</span>'}</div></div>
      </li>` }).join('')}</ol>
    <h3 class="sec">Points de la manche</h3>
    <ol class="rank">${pts.map(x => `<li><span class="nm"><span class="who">${nameOf(x.player_id)}</span>${
      x.player_id === state.room.reader_id ? '<span class="tag host">meneur</span>' : ''}</span><b class="plus" data-n="${x.points}">+${x.points}</b></li>`).join('')}</ol>
    <h3 class="sec">Classement</h3>${rank()}`;
}
