-- =====================================================================
-- LIVRAISON : à exécuter une seule fois, dans Supabase > SQL Editor
-- =====================================================================
-- 1) Remplacez PROPRIETAIRE@EXEMPLE.ORG par l'adresse e-mail du propriétaire.
--    Dès qu'il crée son compte sur le site (icône utilisateur > Créer un compte)
--    avec cette adresse, il devient super admin automatiquement et arrive sur le tableau de bord.
--    Ensuite, c'est lui qui ajoute les autres comptes depuis la page « Comptes de supervision ».
delete from owner_bootstrap;
insert into owner_bootstrap (email) values ('PROPRIETAIRE@EXEMPLE.ORG');

-- 2) Données de test : décommentez pour les effacer avant l'ouverture au public (irréversible).
-- delete from payments;
-- delete from registrations;
-- delete from sponsors;
-- delete from speakers;

-- 3) Comptes de test éventuels : supprimez-les ici (remplacez l'adresse).
-- delete from auth.users where lower(email) = 'adresse.de.test@exemple.org';

-- 4) Vérification : doit afficher l'adresse du propriétaire et aucun compte super admin actif avant sa première connexion.
select 'bootstrap' as k, email as v from owner_bootstrap
union all select 'super admins actifs', count(*)::text from staff where role = 'proprietaire' and active;
