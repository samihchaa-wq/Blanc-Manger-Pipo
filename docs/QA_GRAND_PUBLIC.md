# Campagne de validation « grand public » — Le Soulièteur

> Date de cadrage : 8 novembre 2026. Ce document sépare **preuves automatisées**, **essais physiques** et **critères bloquants**. Un test « non exécuté » ne doit jamais être marqué « réussi ». La publication grand public est un jalon distinct du déploiement GitHub Pages.

## 1. Principes de publication

- **P0 / bloquant** : accès indu à un salon/secret, mauvaise distribution de rôles, score attribué deux fois, perte de partie, action interdite acceptée, partie irrécupérable, fuite d'informations privées.
- **P1 / majeur** : déconnexion mal rattrapée, erreur fréquente de synchronisation, minuteur bloqué, interface inexploitable sur un téléphone supporté, mode de jeu incomplet.
- **P2 / mineur** : animation ou libellé imprécis, léger problème d'espacement, ressenti perfectible sans blocage.
- **Critère de sortie** : 0 P0 et 0 P1 ouverts, couverture complète des scénarios essentiels des huit jeux, taux d'échecs et latence mesurés, sauvegarde et restauration validées. Les P2 doivent être arbitrés explicitement.
- Ne jamais tester la triche ou les scénarios de charge sur des parties d'utilisateurs réels. Utiliser une base isolée ou des transactions **ROLLBACK**, et réserver les tests de charge à une infrastructure dédiée.

## 2. Preuves obtenues par automatisation (et leurs limites)

| Famille | Couverture automatisée | Statut |
|---|---|---|
| Phrases à trou | sélection de question, cartes possédées, deux réponses, score gagnant, refus du double score | SQL transactionnel exécuté |
| Priorités | cinq cartes, refus d'un classement dupliqué, trois classements, points, révélation | SQL transactionnel exécuté |
| Baromètre | cible cachée, indice, deux estimations, score parfait, révélation | SQL transactionnel exécuté |
| Petit Bac | six catégories, grilles figées, douze votes, barème et manche terminée | SQL transactionnel exécuté |
| Mr White | six joueurs, deux rôles intrus, confidentialité, vote, sortie d'un Civil, reprise du cycle | SQL transactionnel exécuté |
| Mimes | juge, deux intensités, refus de notes invalides, score et fin de manche | SQL transactionnel exécuté |
| Le Dico | vraies/fausses définitions, rôle du meneur, auteurs cachés, changement du vote avant clôture, score | SQL transactionnel exécuté, correctif déployé |
| Dilemme | propositions cachées, refus du vote sur soi / ID dupliqué, modification du vote avant clôture, score | SQL transactionnel **avec migration correctrice en attente** |
| Les 8 jeux | départ sous le nombre minimum, ancien jeton refusé, retour salon, reconnexion | SQL transactionnel exécuté |
| Les 8 jeux | délai expiré, participant silencieux, score non compté deux fois, phase finale | SQL transactionnel exécuté |
| Les 8 jeux | sept salons complets à 12 participants, refus du 13e, Petit Bac limité à 2 | SQL transactionnel exécuté |
| Mr White | tailles 3 à 12 : rôle civil/intrus, au plus un Mr White et répartition sans erreur | SQL transactionnel exécuté |
| 8 clients simulés | lectures désordonnées, huit actions, clic répété, session remplacée, erreur réseau et reprise | Node VM automatisé dans CI |
| Concurrence Dico / Dilemme | 24 appels de RPC sur six connexions à la fois, vrai verrou PostgreSQL FOR UPDATE, aucune réponse mélangée | Postgres 17 jetable + fonctions RPC réelles ; avancement de phase simulé |
| Interface Chromium | 8 salons hôte/invité, largeurs 320 à 430 px, invitations, écrans de vote et interactions de saisie | Vrai moteur Chrome, vrais HTML/CSS/JS, Supabase mocké |
| PWA hors ligne | installation du service worker, mise en cache après première visite, navigation ensuite hors réseau | Chromium, vrai cache Service Worker ; sans session réseau active |

**Limite importante :** les suites SQL transactionnelles sur Supabase restent séquentielles. Le nouveau test de concurrence exécute des fonctions de vote réellement parallèles, mais sur **PostgreSQL jetable avec helpers d'avancement simulés**, pas sur la plateforme Supabase sous charge. Le test Node simule huit clients ; le test Chromium charge les vrais éléments visuels mais remplace Supabase par une API mockée. Aucun de ces tests ne remplace huit appareils physiques iOS/Android, la mesure de latence p95/p99, ou une véritable charge en production.

Scripts : `supabase/tests/qa_multiplayer_*.sql`, `tests/reseau-multiclient.mjs`, `tests/qa-suites.mjs`, `tests/qa_browser.py`, `tests/sql/check_concurrency.sh`. Toujours conserver le `ROLLBACK` pour les tests du backend réel.

## 3. Matrice des appareils physiques — à exécuter

Pour chaque configuration, noter : modèle, version OS/navigateur, résolution utile, réseau, identifiant de cas, heure, commit de l'application, résultat **OK / KO / non exécuté**, capture et description. Tester au minimum :

| Appareil et installation | 2 joueurs | 3 joueurs | 6 joueurs | 12 joueurs |
|---|---|---|---|---|
| iPhone Safari (onglet web) | ☐ | ☐ | ☐ | ☐ |
| iPhone PWA « écran d'accueil » | ☐ | ☐ | ☐ | ☐ |
| Android Chrome (onglet web) | ☐ | ☐ | ☐ | ☐ |
| Android PWA installée | ☐ | ☐ | ☐ | ☐ |
| Plusieurs modèles et générations mélangés | ☐ | ☐ | ☐ | ☐ |

**Règle confirmée :** Petit Bac accepte deux joueurs seulement. **Mr White se joue à partir de trois joueurs**, sans exception. Si les Civils ne sont plus majoritaires, les adversaires gagnent. Si Mr White et l'Imposteur sont encore vivants (par exemple face au dernier Civil), **ils gagnent ensemble** ; leurs barèmes de points restent distincts. Une égalité des voix pendant un vote n'élimine personne et le jeu continue.

## 4. Scénarios obligatoires communs à tous les jeux

- **SAL-01** Création de salon : le code est à 8 chiffres, y compris les zéros en tête ; copié/collé et lien de partage identiques.
- **SAL-02** Le même code ouvert simultanément sur Android et iPhone rejoint le même salon, avec les bons pseudos.
- **SAL-03** Deux joueurs avec le même pseudo : erreur claire ; aucune session incorrecte n'est enregistrée.
- **SAL-04** Salle inexistante ou code incorrect : refus lisible ; test avec 4 chiffres d'ancien salon encore actif.
- **SAL-05** Un salon plein refuse les nouvelles entrées sans modifier la partie existante.
- **SAL-06** Un non-hôte ne peut lancer, modifier les règles, exclure un joueur ou agir pour l'hôte.
- **SAL-07** Départ de l'hôte dans le salon : successeur désigné, invitation toujours valide, lancement possible.
- **SAL-08** Départ sous le minimum de joueurs : retour cohérent au salon pour tous les téléphones.
- **SAL-09** Expulsion : ancien jeton invalide ; aucun état secret ni action ultérieure accessible.
- **SAL-10** Reprise de la PWA après fermeture complète : même place, nom, droits, phase et score, sans joueur fantôme.
- **NET-01** Un téléphone en mode avion pendant une phase ; les autres continuent selon les règles, puis l'écran rattrape le bon état.
- **NET-02** Changer du Wi-Fi vers la 4G/5G et retour, dans et hors écran de vote.
- **NET-03** Revenir après 15 secondes, 2 minutes et plus de 5 minutes ; vérifier la politique de session et l'interface.
- **NET-04** Mettre en arrière-plan puis ouvrir depuis l'icône installée ; vérifier le réveil et les minuteries.
- **NET-05** Deux actions simultanées sur des téléphones distincts ne produisent pas un score double.
- **NET-06** Doubler/tripler un clic de vote, y compris pendant une connexion lente ; une seule action logique compte.
- **NET-07** L'écran reçoit une réponse RPC ancienne après une plus récente ; aucune régression de phase ou de manche.
- **NET-08** Changement de salon pendant une requête ; aucune information ni action du salon précédent n'apparaît.
- **NET-09** Reprise après déploiement d'une nouvelle version ; pas de conflit ancien/nouveau script, ni perte de partie.
- **NET-10** Échec temporaire de Supabase : pas de fausse réussite, message intelligible, possibilité de réessayer.
- **UI-01** Écrans 320, 360, 375, 390, 430 px de large, orientation portrait : aucune coupe de bouton, clavier, carte ou nom.
- **UI-02** Zoom/accessibilité du texte 125 % et 150 % : navigation utilisable.
- **UI-03** Clavier numérique/code et champs de réponse : aucun envoi involontaire ou bouton masqué.
- **UI-04** Touches retour, focus et lecteurs d'écran : logique et étiquettes compréhensibles.
- **UI-05** Changement de phase sur les autres téléphones sans actualisation manuelle.

## 5. Scénarios métier par jeu

### Phrases à trou
- **PHR-01** Vérifier main privée, question et nombre de trous.
- **PHR-02** Carte absente de la main / même carte deux fois / réponse du lecteur : refus serveur.
- **PHR-03** Deux joueurs répondent au même instant, puis le juge choisit.
- **PHR-04** Une réponse manque à l'expiration, et une autre a été soumise : vote possible sans blocage.
- **PHR-05** Juge déconnecté après réception des réponses ; reprendre sans compter deux fois.
- **PHR-06** Score cible atteint, écran final ; « rejouer » remet les scores à zéro.

### Priorités
- **PRI-01** Les cinq cartes sont les mêmes pour tous et visibles dans le même ordre.
- **PRI-02** Chaque classement contient une fois chacune des cinq cartes ; doublons interdits.
- **PRI-03** Vérifier précisément les barèmes du juge et des autres sur ordre identique, inverse et partiel.
- **PRI-04** Tous les joueurs classent simultanément : une seule révélation et un seul calcul de points.
- **PRI-05** Juge ou joueur disparaît pendant le classement ; calcul/reprise corrects.

### Baromètre
- **OND-01** Les non-médiums ne voient jamais la cible avant révélation, y compris dans la réponse réseau.
- **OND-02** Variantes normal/inverse, thème préalable et indicateur de responsabilité.
- **OND-03** Estimation 0, 100, exacte, à ±3, ±9 et ±15 : barèmes et arrondis.
- **OND-04** Une estimation manque à l'expiration ; score des autres non affecté.
- **OND-05** Départ du médium avant l'indice ; retour à une manche jouable.

### Petit Bac
- **BAC-01** Exactement deux joueurs ; six catégories uniques, rotation du proposant.
- **BAC-02** Lettre de départ et caractères accentués dans les réponses.
- **BAC-03** Autosauvegarde de la grille, fermeture de l'appli pendant l'écriture, puis reprise.
- **BAC-04** Après « Terminer », la grille est figée ; pas de remplacement par API.
- **BAC-05** Chaque catégorie : deux validations distinctes, 0/1/2 points ; cases vides à 0.
- **BAC-06** Interruption / expiration pendant l'écriture ou le vote ; résultat final exact.

### Mr White
- **WHI-01** De 3 à 5 joueurs : 1 intrus. De 6 à 12 : 2 intrus au total ; Mr White remplace un intrus.
- **WHI-02** Répartition et confidentialité de chaque mot sur tous les téléphones (et requêtes réseau).
- **WHI-03** Affichage des cartes : Civils et Imposteurs sans rôle visible ; Mr White identifié.
- **WHI-04** Personne ne vote pour soi, double vote refusé, joueurs sortis exclus des votes.
- **WHI-05** Majorité, égalité et vote incomplet au délai : résultat correct.
- **WHI-06** Élimination d'un Civil / Imposteur / Mr White : issue et bon écran.
- **WHI-07** Tentative de deviner le mot / arbitre / fausse réponse : aucune victoire indue.
- **WHI-08** Victoire des Civils / Imposteurs / Mr White ou **victoire commune Imposteur + Mr White vivants**, dont le cas un Civil contre les deux ; barèmes inchangés.
- **WHI-09** Départ de joueurs de chaque rôle entre indice et vote, puis reprise.
- **WHI-10** Distinguer une égalité des voix (pas d'élimination) d'une égalité numérique Civils/Adversaires (victoire des adversaires).
- **WHI-11** Confirmer le texte des gagnants dans l'écran final : afficher les deux noms et leurs rôles en cas de victoire commune.

### Mimes
- **MIM-01** Card action / intensité secrète : le juge ne doit pas voir les intensités avant sa note.
- **MIM-02** Rotation du juge et passage un par un ; aucun joueur ne passe deux fois dans la même manche.
- **MIM-03** Notes de 1 à 10, refus de hors plage, scores exacts / ±1 / ±2 / autres.
- **MIM-04** Juge déconnecté au milieu de la session ; reprendre sans réattribuer de points.
- **MIM-05** Timer indicatif, changement de prestation manuel et juge absent : parcours explicite.

### Le Dico
- **DIC-01** Choix du mot / définition correcte réservé au meneur.
- **DIC-02** Écriture et validation de chaque fausse définition, auteurs masqués avant révélation.
- **DIC-03** Interdiction de voter pour sa propre définition, le meneur ne vote pas.
- **DIC-04** Changement d'avis **tant que le vote est ouvert** ; une seule voix effective.
- **DIC-05** Score +2 pour la vraie définition, +1 par joueur dupé et bonus du meneur si personne ne trouve.
- **DIC-06** Départ du meneur / d'un auteur / minuterie expirée : partie toujours jouable.

### Dilemme
- **DIL-01** Choix de la situation de départ réservé au meneur.
- **DIL-02** Propositions, cibles et auteurs cachés jusqu'à révélation.
- **DIL-03** Tous les autres répondent Oui/Non à **chaque** proposition, jamais à la leur.
- **DIL-04** Changement d'avis pendant la phase ouverte ; pas de doublons, recalcul exact.
- **DIL-05** Scénarios de cibles 0 %, 50 %, 100 %, nombre pair et impair de votants.
- **DIL-06** Départ avant/après rédaction, vote incomplet au délai, attribution des points cohérente.

## 6. Résistance à la montée en charge — NON EXÉCUTÉ

Sur un **environnement isolé** avec mêmes politiques SQL et mêmes contenus :
- 10, 30 puis 100 salons en parallèle, avec 3/6/12 clients virtuels.
- Mesurer débits, temps de réponse médian/p95/p99 de `get_full_state`, nombre de requêtes, connexions Realtime, erreurs HTTP/SQL, CPU et coût Supabase.
- Tester la perte d'une connexion Realtime et le polling de secours sur 30 minutes.
- Tester deux votes réellement simultanés (sessions PostgreSQL distinctes, pas une transaction séquentielle).
- Vérifier les 16 index de clés étrangères conseillés par Supabase et comparer les plans avant/après.

Aucun chiffre de performance n'est à déclarer sans mesure. Les bots temporaires doivent être retirés et revalidés à part avant lancement public.

## 7. Modèle de fiche d'anomalie

- **ID / jeu / gravité :**
- **Version Git / migration Supabase :**
- **Appareils / navigateurs / réseau :**
- **Nombre de joueurs / rôle / statut :**
- **Étapes exactes de reproduction :**
- **Résultat attendu / observé :**
- **Impact sur score / confidentialité / progression :**
- **Capture, heure UTC, console et code RPC sans secret :**
- **Correctif PR / test de non-régression / validation après publication :**

**Décision finale de lancement : NON VALIDÉE** tant que la grille physique, le test de charge et le contrôle de sécurité restants ne sont pas terminés.
