# ACPRC · Risk & Compliance Annual Forum 2027

Page d'inscription et espace propriétaires du **RISK & COMPLIANCE ANNUAL FORUM** (1ère édition, 5 février 2027, Élite Offices, Akwa, Douala).

## Contenu
- `index.html` : la plateforme complète, un seul fichier (FR/EN). Pas de compilation.
- `supabase/setup.sql` : tables, règles d'accès, numéros de bordereau (RCF-2027-NNNN), vue d'export, espace propriétaires.

## Mise en ligne
1. Hébergeur (Netlify, Vercel, Cloudflare Pages ou GitHub Pages) : brancher ce dépôt, aucun build, dossier racine `/`.
2. Supabase : ouvrir `supabase/setup.sql`, remplacer `VOTRE_EMAIL`, l'exécuter dans le SQL Editor.
3. Supabase > Authentication : désactiver « Confirm email » et renseigner « Site URL » avec l'adresse du site.
4. Sur le site : icône utilisateur > « Créer un compte » avec l'adresse du script : vous arrivez sur le tableau de bord.

## Sécurité
- La page contient uniquement l'URL du projet et la clé publique (`sb_publishable_…`). Ne jamais y mettre la clé `service_role`.
- Les données ne sont lisibles que par les comptes actifs de la table `staff` (règles RLS).
