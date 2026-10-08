-- Priorités : premier paquet de cartes, des registres volontairement éloignés.

insert into public.priority_cards(text, theme) values
-- football
('Zinédine Zidane','foot'),('Kylian Mbappé','foot'),('Le PSG','foot'),('L''OM','foot'),('La Coupe du monde 98','foot'),
('Les tirs au but','foot'),('La VAR','foot'),('Le coup de boule de 2006','foot'),('Un match de district le dimanche matin','foot'),
('Lionel Messi','foot'),('Cristiano Ronaldo','foot'),('Le maillot floqué à ton nom','foot'),('Un hors-jeu imaginaire','foot'),
('La Ligue des champions','foot'),('Le five du jeudi soir','foot'),('Antoine Griezmann','foot'),
-- autres sports
('Le Tour de France','sport'),('Roland-Garros','sport'),('Teddy Riner','sport'),('La pétanque au camping','sport'),
('Le Tournoi des Six Nations','sport'),('Les Jeux olympiques','sport'),('La salle de sport en janvier','sport'),('Le padel','sport'),
('Le curling','sport'),('Un marathon','sport'),('Le ski en février','sport'),('La NBA','sport'),
-- films
('Titanic','film'),('Le Dîner de cons','film'),('Les Visiteurs','film'),('Le Roi lion','film'),('Star Wars','film'),
('Intouchables','film'),('Bienvenue chez les Ch''tis','film'),('Harry Potter','film'),('Le Seigneur des anneaux','film'),
('La Haine','film'),('OSS 117','film'),('Shrek','film'),('Astérix : Mission Cléopâtre','film'),('Le Parrain','film'),
('Les Bronzés font du ski','film'),('Retour vers le futur','film'),
-- séries
('Friends','série'),('Game of Thrones','série'),('Kaamelott','série'),('Plus belle la vie','série'),('Breaking Bad','série'),
('Les Simpson','série'),('La Casa de papel','série'),('Stranger Things','série'),('Engrenages','série'),('Lupin','série'),
('Dix pour cent','série'),('Hélène et les Garçons','série'),('Les Feux de l''amour','série'),('The Office','série'),
-- artistes
('Johnny Hallyday','artiste'),('Céline Dion','artiste'),('Jul','artiste'),('Aya Nakamura','artiste'),('Stromae','artiste'),
('Michel Sardou','artiste'),('Beyoncé','artiste'),('Mozart','artiste'),('Picasso','artiste'),('Claude François','artiste'),
('Booba','artiste'),('Mylène Farmer','artiste'),('Patrick Sébastien','artiste'),('Taylor Swift','artiste'),('Les Daft Punk','artiste'),
('Édith Piaf','artiste'),('Angèle','artiste'),('Francis Cabrel','artiste'),
-- actions du quotidien
('Faire la sieste','action'),('Ranger sa chambre','action'),('Faire la vaisselle','action'),('Répondre à ses mails','action'),
('Appeler sa mère','action'),('Se brosser les dents','action'),('Faire les courses','action'),('Arroser les plantes','action'),
('Plier le linge','action'),('Prendre une douche chaude','action'),('Mettre un réveil','action'),('Sortir les poubelles','action'),
('Faire son lit','action'),('Boire un café le matin','action'),('Scroller sur son téléphone au lit','action'),('Faire le plein','action'),
-- saisons et moments de l'année
('L''été','saison'),('L''hiver','saison'),('Le printemps','saison'),('L''automne','saison'),('Noël','saison'),
('Le 14 Juillet','saison'),('La rentrée de septembre','saison'),('Les soldes','saison'),('Le Nouvel An','saison'),
('Son anniversaire','saison'),('Les vacances de la Toussaint','saison'),('Le premier jour du printemps','saison'),('Halloween','saison'),
-- jours et heures
('Le lundi','jour'),('Le mardi','jour'),('Le mercredi','jour'),('Le jeudi','jour'),('Le vendredi soir','jour'),
('Le samedi','jour'),('Le dimanche','jour'),('Le dimanche soir','jour'),('Un jour férié','jour'),('3 heures du matin','jour'),
('L''heure de l''apéro','jour'),('La pause de midi','jour'),('Le pont de l''Ascension','jour'),
-- travail
('Une augmentation','taff'),('Les tickets-resto','taff'),('Le télétravail','taff'),('Un patron sympa','taff'),('La machine à café','taff'),
('Le pot de départ','taff'),('Une réunion qui aurait pu être un mail','taff'),('Les RTT','taff'),('Le séminaire d''entreprise','taff'),
('Un collègue qui parle trop','taff'),('Le vendredi à 16 h','taff'),('L''entretien annuel','taff'),('Les congés payés','taff'),
('Une voiture de fonction','taff'),('Le CDI','taff'),('Un open space','taff'),
-- prénoms
('Kevin','prénom'),('Jean-Michel','prénom'),('Brenda','prénom'),('Gérard','prénom'),('Jennifer','prénom'),('Mohamed','prénom'),
('Chantal','prénom'),('Enzo','prénom'),('Bernadette','prénom'),('Dylan','prénom'),('Marie-Thérèse','prénom'),('Jordan','prénom'),
('Sophie','prénom'),('Patrick','prénom'),('Inès','prénom'),('Thierry','prénom'),
-- dilemmes et sacrifices
('Ne plus jamais manger de fromage','dilemme'),('Ne plus jamais boire de café','dilemme'),('Vivre sans téléphone pendant un an','dilemme'),
('Avoir le hoquet à vie','dilemme'),('Toujours avoir 10 minutes de retard','dilemme'),('Ne plus jamais partir en vacances','dilemme'),
('Dire tout ce que tu penses','dilemme'),('Ne plus pouvoir mentir','dilemme'),('Chanter au lieu de parler','dilemme'),
('Avoir toujours du sable dans les chaussures','dilemme'),('Ne plus jamais dormir plus de 5 heures','dilemme'),
('Perdre tous ses contacts','dilemme'),('Être célèbre mais détesté','dilemme'),('Vivre sans internet','dilemme'),
('Revivre ses années collège','dilemme'),('Connaître la date de sa mort','dilemme'),
-- nourriture
('La raclette','bouffe'),('Un kebab à 2 h du matin','bouffe'),('Le croissant du dimanche','bouffe'),('Les frites','bouffe'),
('Le chocolat','bouffe'),('Les sushis','bouffe'),('Le couscous de mamie','bouffe'),('La pizza à l''ananas','bouffe'),
('Le Nutella','bouffe'),('Une bonne baguette','bouffe'),('Les endives au jambon','bouffe'),('Le foie gras','bouffe'),
('Un tacos 3 viandes','bouffe'),('Les brocolis','bouffe'),('Le saucisson','bouffe'),('Les crêpes','bouffe'),
-- objets
('Son téléphone','objet'),('Le chargeur','objet'),('Une couette bien épaisse','objet'),('Ses clés','objet'),('La télécommande','objet'),
('Le PQ','objet'),('Ses lunettes','objet'),('Le grille-pain','objet'),('Un parapluie','objet'),('La PlayStation','objet'),
('Les écouteurs','objet'),('Un bon matelas','objet'),('La carte Vitale','objet'),('Le sèche-cheveux','objet'),
-- lieux
('Paris','lieu'),('Marseille','lieu'),('La Bretagne','lieu'),('New York','lieu'),('La maison de ses grands-parents','lieu'),
('Ikea un samedi','lieu'),('La plage','lieu'),('La montagne','lieu'),('Son canapé','lieu'),('Le Futuroscope','lieu'),
('Disneyland','lieu'),('Un camping 3 étoiles','lieu'),('La boulangerie du coin','lieu'),('Le Japon','lieu'),
-- animaux
('Son chien','animal'),('Son chat','animal'),('Les pandas','animal'),('Les moustiques','animal'),('Les abeilles','animal'),
('Un poisson rouge','animal'),('Les pigeons','animal'),('Les dauphins','animal'),('Une araignée dans la douche','animal'),
('Les lions','animal'),('Un hamster','animal'),
-- valeurs et grandes choses
('La santé','valeur'),('L''argent','valeur'),('L''amour','valeur'),('La famille','valeur'),('Les amis','valeur'),
('La liberté','valeur'),('Le bonheur','valeur'),('La paix dans le monde','valeur'),('La planète','valeur'),('Le respect','valeur'),
('L''honnêteté','valeur'),('La réussite','valeur'),('Le temps libre','valeur'),('La sécurité','valeur'),
-- famille et proches
('Sa mère','famille'),('Son père','famille'),('Sa belle-mère','famille'),('Son meilleur ami','famille'),('Son ex','famille'),
('Ses grands-parents','famille'),('Son petit frère','famille'),('Le cousin qu''on voit une fois par an','famille'),
('Le voisin du dessus','famille'),('Son parrain','famille'),('Sa grande sœur','famille'),
-- technologie
('Le Wi-Fi','tech'),('Netflix','tech'),('WhatsApp','tech'),('Instagram','tech'),('TikTok','tech'),('Google Maps','tech'),
('ChatGPT','tech'),('La batterie à 100 %','tech'),('Le mot de passe du Wi-Fi','tech'),('Un iPhone','tech'),('Le Bluetooth','tech'),
('Spotify','tech'),
-- soirées
('L''apéro','soirée'),('Le karaoké','soirée'),('La boîte de nuit','soirée'),('Un barbecue entre potes','soirée'),('Le Uno','soirée'),
('Un mariage','soirée'),('La soirée raclette','soirée'),('Un enterrement de vie de garçon','soirée'),('Le Monopoly en famille','soirée'),
('Une soirée Koh-Lanta','soirée'),
-- enfance
('Les Pokémon','enfance'),('Le Club Dorothée','enfance'),('Les Kinder Surprise','enfance'),('La récré','enfance'),
('Les colonies de vacances','enfance'),('Les Tamagotchis','enfance'),('Le goûter','enfance'),('Les cartes Panini','enfance'),
('Les dessins animés du samedi matin','enfance'),('La Game Boy','enfance'),
-- célébrités et personnages
('Thomas Pesquet','célébrité'),('Cyril Hanouna','célébrité'),('Jean-Pierre Pernaut','célébrité'),('Napoléon','célébrité'),
('Le Père Noël','célébrité'),('Kim Kardashian','célébrité'),('Michel Drucker','célébrité'),('Omar Sy','célébrité'),
('Barack Obama','célébrité'),('Elon Musk','célébrité'),('Bob l''éponge','célébrité'),('Mario','célébrité'),
-- petits plaisirs
('Le premier rayon de soleil','plaisir'),('L''odeur du pain chaud','plaisir'),('Dormir jusqu''à midi','plaisir'),
('Un compliment inattendu','plaisir'),('Trouver 20 € dans une poche','plaisir'),('Les draps propres','plaisir'),
('Un bain moussant','plaisir'),('Annuler un plan et rester chez soi','plaisir'),('Le bruit de la pluie','plaisir'),
('Un fou rire','plaisir'),('Le dernier épisode d''une série','plaisir'),('Une place de parking devant chez soi','plaisir')
on conflict (lower(text)) do nothing;
