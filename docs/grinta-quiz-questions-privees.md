# Préparer les deux mi-temps du Grand Quiz AS Grinta 2026

Le quiz est **unique**, réservé à cette soirée et sans éditeur accessible aux joueurs. Les questions et leurs bonnes réponses doivent rester **dans un fichier privé**, jamais dans GitHub, GitHub Pages ou l’application mobile.

## Fichier des questions

Créer un fichier local `questions-as-grinta-2026.json` contenant exactement deux tableaux : `as_grinta` et `football_general`. Chaque tableau doit avoir **10 à 20 questions**. Exemple de structure pour une question (à répéter pour les deux mi-temps) :

```json
{
  "as_grinta": [
    {
      "texte": "Question à rédiger pour le club ?",
      "choix": ["Proposition A", "Proposition B", "Proposition C", "Proposition D"],
      "bonne_reponse": 1,
      "points": 1,
      "explication": "Commentaire facultatif à afficher après la révélation."
    }
  ],
  "football_general": []
}
```

Ce bloc est **uniquement un exemple de format** : il ne peut pas être importé tel quel. `bonne_reponse` utilise un indice commençant à **0** : 0 pour A, 1 pour B, 2 pour C et 3 pour D. Entre 2 et 4 choix, et de 1 à 3 points par question.

## Préparer le SQL sans exposer les réponses

Depuis la racine du dépôt, avec Node 22 :

```sh
node tools/asgq-question-pack.mjs /chemin/prive/questions-as-grinta-2026.json /chemin/prive/asgq-import.sql
```

Le script refuse les séries incomplètes, les doublons, les choix incorrects et les questions marquées de test. Par sécurité, **le JSON et le fichier SQL généré doivent tous deux être situés hors du dépôt Git entier** : les dossiers `grinta-quiz/`, `js/`, `css/` et d'autres ressources sont publiés. **Ne jamais committer, partager en groupe ou publier les bonnes réponses.**

## Intégration avant la soirée

1. Faire relire les deux séries et leurs corrections par l’organisateur.
2. Dans l’éditeur SQL **restreint** du projet Supabase du Soulieteur, exécuter le SQL privé généré, **après la création de l'émission par l'animateur, mais avant qu'un invité ait rejoint**. L'unique personne déjà inscrite doit être l'animateur officiel. Le script fonctionne dans une transaction : il refuse l'import si l'émission est armée, commencée, privée de son animateur ou si un joueur invité est déjà présent. Les deux séries sont ensuite vérifiées.
3. Vérifier que `select asgq_private.ready_for_kickoff();` renvoie `true` et que le nombre de questions correspond aux deux mi-temps.
4. Répéter le parcours avec les tests transactionnels, puis vérifier le lien public sur plusieurs vrais téléphones.
5. **Avant l’arrivée des joueurs seulement**, activer la soirée via `update asgq_private.event set armed = true where id = 1 and phase = 'lobby';` depuis l’éditeur restreint. Le code d’accès secret est récupéré dans cet éditeur et n’est pas inclus dans l’application.

> **Aucun départ automatique :** même après activation, l'émission reste au vestiaire jusqu'au clic volontaire de l'animateur sur « LANCER LA PARTIE ». La suite est entièrement manuelle : question, révélation, mi-temps et podium ne sont jamais déclenchés par un compte à rebours. Ne lancer l'émission que lorsque les invités sont réellement présents.

Le quiz ne doit être activé ni publié comme « prêt à jouer » tant que la liste réelle des questions, la répétition sur téléphone et la vérification finale ne sont pas terminées.