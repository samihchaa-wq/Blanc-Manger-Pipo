# Grand Quiz AS Grinta — répétition générale avant les questions

**Périmètre :** répétition avec l'environnement `?repetition=1` et les bots, **jamais** sur le salon officiel. Ne pas importer de questions officielles, ne pas modifier `asgq_private.event.armed` et ne pas divulguer le mot de passe Admin+.

## Niveau 1 — vérifications automatisées

La CI exécute trois ensembles de tests différents :

| Test | Ce qu'il démontre | Ce qu'il ne démontre pas |
|---|---|---|
| `tests/grinta_quiz_dress_rehearsal.py` | Trois contextes Chromium indépendants, véritables écrans HTML/CSS/JS, 20 questions de test, réponses modifiables, 20 révélations, pause, podium, reprise du stockage local, coupure/reconnexion simulée | Le serveur est un double HTTP local, pas le projet Supabase de production ni des téléphones physiques |
| `tests/sql/grinta_quiz_schema.sh` | Fonctions SQL et contraintes réelles sur base PostgreSQL isolée, dont 29 invités + 1 animateur et calcul des scores | Le Wi-Fi réel, la latence mobile et le quota de l'hébergement |
| `tests/qa_browser.py` | Écrans responsive, texte long, 29 prénoms au verdict, deux mi-temps, accès séparés, erreurs d'interface, non-régression des autres mini-jeux | L'ergonomie tactile et l'accessibilité de chaque appareil réel |

Toutes les questions produites par ces tests sont fictives. Les tests **ne doivent pas** avoir la possibilité de démarrer une vraie partie.

## Niveau 2 — répétition sur appareils physiques (à faire avec les participants)

### Préparation

1. Choisir **un animateur et au moins deux joueurs**, idéalement un iPhone et un Android. Prévoir Wi-Fi et réseau mobile.
2. Depuis Le Soulieteur, ouvrir le Grand Quiz puis **Tester avec des bots**. Créer la **répétition**, pas l'émission officielle, avec Admin+.
3. L'animateur transmet **le code de cette répétition uniquement**. Les invités entrent leur prénom et le code depuis l'onglet **Rejoindre** de Le Soulieteur, sans renseigner Admin+.
4. Ajouter quelques bots depuis le vestiaire pour augmenter les réponses simultanées. Ils restent séparés de l'événement officiel.

### Parcours à vérifier

- [ ] Les joueurs invités apparaissent au vestiaire ; l'animateur est identifié séparément.
- [ ] Les invités ne voient aucun bouton permettant de lancer la partie ou d'avancer une phase.
- [ ] L'animateur lance la première mi-temps ; la première question **ne s'affiche qu'après son clic**.
- [ ] Une bonne réponse, une mauvaise réponse et une absence sont correctement identifiées après la révélation.
- [ ] Un joueur change de choix avant la révélation : seul le dernier choix compte et les points ne sont attribués qu'une fois.
- [ ] Sur l'écran de l'animateur, **« On attend : »** énumère uniquement les joueurs sans réponse ; les noms disparaissent après enregistrement.
- [ ] Tenter de révéler trop tôt, choisir **ATTENDRE**, puis constater que personne n'a été verrouillé.
- [ ] Confirmer une révélation anticipée : les abstentions sont affichées, sans double attribution des points.
- [ ] Parcourir la mi-temps, les classements et le podium. **Aucun compte à rebours ne doit avancer le quiz.**
- [ ] Tester une très longue question, quatre réponses longues, un très long prénom, le paysage et une police agrandie.
- [ ] Fermer puis rouvrir l'application installée sur Android et l'onglet iPhone pendant une question ; retrouver sa session et son score.
- [ ] Couper puis rétablir le réseau pendant une question : afficher une erreur compréhensible, puis se resynchroniser sans créer de joueur.
- [ ] Vérifier l'absence de superposition de portraits, les trois catégories du verdict et la lisibilité du podium.
- [ ] Faire au moins un test de lecture avec VoiceOver (iOS) ou TalkBack (Android).
- [ ] Vérifier les autres mini-jeux après la répétition, sans changement de comportement.

### Cas à ne pas tester sur la production

La **reprise Admin+ de l'animateur** invalide volontairement son ancien jeton. Les codes de récupération des participants changent également des jetons. Ces essais doivent rester dans les tests automatisés isolés ou être faits plus tard sur un **environnement Supabase de staging**, jamais sur l'événement officiel de la soirée.

## Décision de passage aux questions

- **GO contenu :** CI verte, partie officielle toujours non armée, questionnaire privé hors dépôt. La rédaction des questions peut commencer indépendamment des derniers essais physiques.
- **GO soirée :** tests physiques réussis, réponses officielles relues, import privé validé, aucune question provisoire, capacité et réseau confirmés, puis armement **manuel**.
- **NO-GO soirée :** appareil incapable de reprendre la session, score incohérent, transition involontaire, fuite de bonne réponse ou échec majeur du réseau.

À chaque problème : noter appareil, navigateur/PWA, taille d'écran, étape, comportement attendu/réel, Wi-Fi ou mobile, et conserver une capture **sans mot de passe Admin+ ni jeton**.
