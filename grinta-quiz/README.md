# Grand Quiz AS Grinta 2026 — maître du jeu

Le Grand Quiz est une page mobile indépendante du Soulieteur, avec un événement officiel à usage unique (`asgq_private`) et un espace de répétition distinct (`asgq_rehearsal_private`). Les questions, les réponses correctes et les scores restent côté serveur, dans des schémas privés protégés par RLS.

## Créer / rejoindre

- **Créer** : prénom et mot de passe Admin+ habituel. Le serveur crée le code de salon à huit chiffres et associe **le jeton du créateur** au rôle de maître du jeu. Ce jeton est conservé sur son appareil pour retrouver sa session. Le mot de passe n'est pas conservé.
- **Rejoindre** : prénom et code de salon à huit chiffres, sans Admin+. Le code peut être partagé par lien. Les tentatives de code erroné sont limitées côté serveur.
- Le maître du jeu est visible dans le vestiaire, mais **ne répond pas et n'apparaît jamais dans le classement ni sur le podium**.
- Une partie officielle n'est lançable que lorsque les deux mi-temps sont préparées (10 à 20 questions chacune) et que l'événement a été armé dans la base privée. Les quatre questions techniques d'origine ne peuvent pas lancer la soirée.

## Déroulement intégralement manuel

**Aucun chronomètre, compte à rebours, délai de réponse ou transition automatique.** Le serveur ne fait progresser aucune phase au cours des lectures d'état. Les réponses restent modifiables jusqu'au clic de révélation du maître du jeu.

| Écran | Action réservée au maître du jeu |
| --- | --- |
| Vestiaire | **LANCER LA PARTIE** |
| Présentation | **AFFICHER LA QUESTION** |
| Question | **RÉVÉLER LA RÉPONSE** (verrouille les choix et attribue les points une seule fois) |
| Résultat | **QUESTION SUIVANTE** (ou pause / podium à la fin d'une mi-temps) |
| Mi-temps | **REPRENDRE LE QUIZ** |
| Podium | Classement final, aucune action de progression |

Ces actions sont protégées **côté serveur** par le jeton du créateur, pas seulement par un bouton caché. Chaque appel de progression transmet la phase et la position attendues pour empêcher qu'un double clic ou un appel réseau retardé fasse sauter une étape. Le score est attribué seulement lors de la transition question → révélation. Les joueurs voient uniquement les réponses autorisées pour la phase courante.

## Récupération sécurisée des sessions

- **Animateur officiel** : depuis l'accueil du Grand Quiz, choisir « Reprendre l'émission (Admin+) ». Une vérification Admin+ côté serveur récupère l'identité de l'animateur existant et remplace son ancien jeton. **Ne crée pas une nouvelle partie.** La récupération est limitée à cinq tentatives par dix minutes et ne touche ni aux scores ni aux questions.
- **Joueur officiel** : si un joueur perd son accès, l'animateur ouvre « Rétablir l'accès d'un joueur » en bas de son écran, choisit le joueur et lui transmet en privé son **code temporaire à huit chiffres**, valable **dix minutes et une seule fois**. Le joueur entre son pseudo et le code habituel de la partie dans Le Soulieteur. Si l'accès échoue parce qu'il était déjà inscrit ou que la partie a commencé, un champ supplémentaire permet de saisir le code temporaire.
- Le serveur remplace uniquement le jeton du joueur récupéré : **même ID, mêmes réponses et mêmes points**. Le code de la salle et le prénom, seuls, ne permettent jamais de voler une identité existante. Seul l'animateur authentifié peut délivrer un code de remplacement.
- Les outils de récupération des invités sont propres au **Grand Quiz officiel** et ne modifient pas les jeux classiques ni la répétition avec bots.

## Répétition avec bots

Depuis le Soulieteur, sélectionner QCM puis Créer la partie pour accéder à la répétition. Le créateur peut ajouter ou retirer jusqu'à 20 bots avant de lancer, et un autre téléphone peut rejoindre la salle par son code. Les bots sont de vrais participants en base privée ; ils répondent **lorsque le maître du jeu révèle la réponse**, sans délai artificiel. La répétition contient 20 questions provisoires (10 + 10), séparées de celles de la soirée. Après le podium, une nouvelle répétition peut être créée avec Admin+ sans toucher à la partie officielle.

## Avant la soirée officielle

1. Dans l'éditeur SQL restreint de Supabase, remplacer les quatre questions techniques par 10–20 questions AS Grinta (mi-temps 1), puis 10–20 questions de football général (mi-temps 2), avec des positions consécutives.
2. Vérifier `select asgq_private.ready_for_kickoff();` → `true`.
3. Armer une fois l'événement en vestiaire : `update asgq_private.event set armed=true where id=1 and phase='lobby';`.
4. Le créateur conserve son appareil et sa session de maître du jeu. Il lance la partie quand les joueurs sont prêts, puis gère chaque révélation et chaque changement d'écran.

**Ne pas réinitialiser l'événement officiel ni ses joueurs en production.** Les modifications de la répétition restent isolées.

## Tests

- `node tests/grinta_quiz_client.mjs` vérifie l'interface, les boutons du maître du jeu, l'absence de chronomètre et les contrôles de sécurité attendus.
- `bash tests/sql/grinta_quiz_schema.sh <postgres-container-id>` rejoue les migrations et les scénarios transactionnels des deux schémas : autorisations, réponses modifiables, révélation, points uniques, 20 questions, mi-temps, bots et podium. Les données de test sont annulées par `ROLLBACK`.
- Une validation sur téléphones iOS et Android, avec plusieurs participants, reste nécessaire avant la soirée.
