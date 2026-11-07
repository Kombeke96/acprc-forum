-- ACPRC Forum 2027 : base de données (à coller dans Supabase > SQL Editor > Run)
-- Sûr à relancer : les tables existantes sont conservées.

-- ---------- Réglages ----------
create table if not exists settings (
  id int primary key default 1 check (id = 1),
  capacity int not null default 100,
  open boolean not null default true
);
insert into settings (id) values (1) on conflict do nothing;

-- ---------- Inscrits ----------
create table if not exists registrations (
  id           bigint generated always as identity primary key,
  -- Numéro unique de bordereau = numéro de facture de l'inscrit (RCF-2027-0001, 0002, ...)
  bordereau    text generated always as ('RCF-2027-' || lpad(id::text, 4, '0')) stored,
  nom          text not null check (char_length(nom) between 2 and 120),
  email        text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  tel          text not null check (char_length(tel) between 6 and 30),
  organisation text not null check (char_length(organisation) between 1 and 160),
  fonction     text not null check (char_length(fonction) between 1 and 120),
  secteur      text not null check (char_length(secteur) <= 120),
  membre       boolean not null,
  tarif        int generated always as (case when membre then 25000 else 35000 end) stored,
  attentes     text check (char_length(attentes) <= 500),
  statut       text not null default 'attente' check (statut in ('attente','paye','liste')),
  consent_at   timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create unique index if not exists registrations_bordereau_key on registrations (bordereau);
create unique index if not exists registrations_email_key on registrations (lower(email));

-- ---------- Preuves de paiement (inscrits) ----------
create table if not exists payments (
  id              bigint generated always as identity primary key,
  registration_id bigint references registrations(id) on delete set null,
  bordereau       text,                       -- repris de l'inscription trouvée par e-mail
  nom             text not null check (char_length(nom) <= 120),
  email           text not null check (char_length(email) <= 200),
  tarif           int  not null check (tarif in (25000, 35000)),
  mode            text not null check (char_length(mode) <= 60),
  proof_path      text,                       -- fichier dans le stockage privé « preuves »
  statut          text not null default 'wait' check (statut in ('wait','ok','ko')),
  archived        boolean not null default false,   -- essais mis de côté quand la personne recommence son inscription
  created_at      timestamptz not null default now()
);
alter table payments add column if not exists archived boolean not null default false;

-- ---------- Sponsors ----------
create table if not exists sponsors (
  id          bigint generated always as identity primary key,
  org         text not null check (char_length(org) <= 160),
  contact     text not null check (char_length(contact) <= 160),
  tier        text not null check (char_length(tier) <= 60),
  mode        text check (char_length(mode) <= 60),
  montant     int check (montant between 0 and 100000000),
  logo_path   text,
  proof_path  text,
  statut      text not null default 'wait' check (statut in ('wait','ok','ko')),
  created_at  timestamptz not null default now()
);

-- ---------- Accès : personne ne lit ni n'écrit directement depuis le site ----------
alter table settings      enable row level security;
alter table registrations enable row level security;
alter table payments      enable row level security;
alter table sponsors      enable row level security;
revoke all on settings, registrations, payments, sponsors from anon, authenticated;

-- ---------- Fonctions publiques (seule porte d'entrée du site) ----------
create or replace function register_participant(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s settings; n int; r registrations;
begin
  select * into s from settings where id = 1;
  if not s.open then raise exception 'inscriptions_closed'; end if;
  -- une place n'est prise que lorsque le paiement est confirmé
  select count(*) into n from registrations where statut = 'paye';
  begin
    insert into registrations (nom,email,tel,organisation,fonction,secteur,membre,attentes,statut)
    values (btrim(p->>'nom'), btrim(p->>'email'), btrim(p->>'tel'), btrim(p->>'organisation'),
            btrim(p->>'fonction'), coalesce(btrim(p->>'secteur'),''), coalesce((p->>'membre')::boolean,false),
            nullif(btrim(p->>'attentes'),''),
            case when n >= s.capacity then 'liste' else 'attente' end)
    returning * into r;
  exception when unique_violation then
    -- E-mail déjà inscrit. Si les 3 essais de preuve sont utilisés sans paiement confirmé
    -- et que 5 minutes se sont écoulées depuis le dernier essai, la personne recommence au début :
    -- on remet son compteur à zéro et on garde son bordereau.
    select * into r from registrations where lower(email) = lower(btrim(p->>'email'));
    if (select count(*) from payments where registration_id = r.id and not archived) >= 3
       and not exists (select 1 from payments where registration_id = r.id and statut = 'ok')
       and (select max(created_at) from payments where registration_id = r.id and not archived) <= now() - interval '5 minutes' then
      update payments set archived = true where registration_id = r.id and not archived;
      return jsonb_build_object('bordereau', r.bordereau, 'statut', r.statut, 'tarif', r.tarif, 'restart', true);
    end if;
    return jsonb_build_object('duplicate', true);
  end;
  return jsonb_build_object('bordereau', r.bordereau, 'statut', r.statut, 'tarif', r.tarif);
end $$;

create or replace function submit_payment(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare r registrations;
begin
  select * into r from registrations where lower(email) = lower(btrim(p->>'email')) limit 1;
  -- 3 essais maximum par inscription, ensuite il faut recommencer l'inscription
  if r.id is not null and (select count(*) from payments where registration_id = r.id and not archived) >= 3 then
    raise exception 'trop_d_essais';
  end if;
  insert into payments (registration_id, bordereau, nom, email, tarif, mode, proof_path)
  values (r.id, r.bordereau, btrim(p->>'nom'), btrim(p->>'email'),
          (p->>'tarif')::int, btrim(p->>'mode'), p->>'proof_path');
end $$;

create or replace function submit_sponsor(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into sponsors (org, contact, tier, mode, montant, logo_path, proof_path)
  values (btrim(p->>'org'), btrim(p->>'contact'), btrim(p->>'tier'), btrim(p->>'mode'),
          nullif(p->>'montant','')::int, p->>'logo_path', p->>'proof_path');
end $$;

revoke all on function register_participant(jsonb), submit_payment(jsonb), submit_sponsor(jsonb) from public;
grant execute on function register_participant(jsonb), submit_payment(jsonb), submit_sponsor(jsonb) to anon;

-- ---------- Stockage privé des captures et logos (dépôt seul, lecture réservée aux propriétaires) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('preuves', 'preuves', false, 5242880, array['image/png','image/jpeg','image/webp','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 5242880,
  allowed_mime_types = array['image/png','image/jpeg','image/webp','application/pdf'];

drop policy if exists preuves_depot on storage.objects;
create policy preuves_depot on storage.objects for insert to anon with check (bucket_id = 'preuves');

-- ---------- Tarifs : 25 000 FCFA (membres) et 35 000 FCFA (non-membres) ----------
-- Met aussi à jour une base créée avec l'ancienne version du script (20 000 / 30 000).
drop view if exists inscrits_export;
alter table registrations drop column if exists tarif;
alter table registrations add column tarif int generated always as (case when membre then 25000 else 35000 end) stored;
alter table payments drop constraint if exists payments_tarif_check;
alter table payments add constraint payments_tarif_check check (tarif in (25000, 35000)) not valid;

-- ---------- Tableau des inscrits pour les propriétaires ----------
-- Une ligne par inscrit : bordereau/facture, coordonnées, tarif, statut et dernière preuve de paiement.
create or replace view inscrits_export as
select r.bordereau                                   as "N° bordereau / facture",
       r.nom                                         as "Nom et prénom",
       r.email                                       as "E-mail",
       r.tel                                         as "Téléphone",
       r.organisation                                as "Organisation",
       r.fonction                                    as "Fonction",
       r.secteur                                     as "Secteur",
       case when r.membre then 'Membre ACPRC' else 'Non membre' end as "Statut",
       r.tarif                                       as "Montant (FCFA)",
       case r.statut when 'paye' then 'Payé' when 'liste' then 'Liste d''attente' else 'En attente de paiement' end as "Inscription",
       case pay.statut when 'ok' then 'Paiement confirmé' when 'ko' then 'Paiement refusé'
            when 'wait' then 'Preuve reçue, à vérifier' else 'Aucune preuve' end as "Paiement",
       pay.mode                                      as "Mode de paiement",
       (select count(*) from payments x where x.registration_id = r.id and not x.archived) as "Essais de paiement (sur 3)",
       pay.proof_path                                as "Fichier de la preuve",
       r.attentes                                    as "Attentes",
       to_char(r.created_at at time zone 'Africa/Douala', 'DD/MM/YYYY HH24:MI') as "Inscrit le"
from registrations r
left join lateral (select * from payments x where x.registration_id = r.id and not x.archived order by x.created_at desc limit 1) pay on true
order by r.id;
alter view inscrits_export set (security_invoker = true);
revoke all on inscrits_export from anon, authenticated;

-- =====================================================================
-- ESPACE SUPER ADMIN : comptes, tableau de bord, supervision
-- =====================================================================
create table if not exists staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  nom        text not null check (char_length(nom) between 2 and 120),
  email      text not null,
  role       text not null default 'supervision' check (role in ('proprietaire','supervision')),
  active     boolean not null default false,       -- une demande d'accès reste inactive tant qu'un propriétaire ne l'active pas
  created_at timestamptz not null default now()
);
alter table staff enable row level security;

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where user_id = auth.uid() and active)
$$;
create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where user_id = auth.uid() and active and role = 'proprietaire')
$$;
revoke all on function is_staff(), is_owner() from public;
grant execute on function is_staff(), is_owner() to authenticated;

revoke all on staff from anon, authenticated;
grant select, insert, update on staff to authenticated;

drop policy if exists staff_read      on staff;
drop policy if exists staff_request   on staff;
drop policy if exists staff_owner_ins on staff;
drop policy if exists staff_owner_upd on staff;
create policy staff_read      on staff for select to authenticated using (user_id = auth.uid() or is_staff());
-- une personne peut déposer sa propre demande d'accès, jamais active et jamais propriétaire
create policy staff_request   on staff for insert to authenticated with check (user_id = auth.uid() and active = false and role = 'supervision');
create policy staff_owner_ins on staff for insert to authenticated with check (is_owner());
create policy staff_owner_upd on staff for update to authenticated using (is_owner()) with check (is_owner());

-- Lecture des données par les comptes actifs (propriétaires et supervision)
grant select on registrations, payments, sponsors, inscrits_export to authenticated;
drop policy if exists reg_staff on registrations;
drop policy if exists pay_staff on payments;
drop policy if exists sp_staff  on sponsors;
create policy reg_staff on registrations for select to authenticated using (is_staff());
create policy pay_staff on payments      for select to authenticated using (is_staff());
create policy sp_staff  on sponsors      for select to authenticated using (is_staff());

-- Lecture des captures de paiement (stockage privé)
drop policy if exists preuves_lecture on storage.objects;
create policy preuves_lecture on storage.objects for select to authenticated using (bucket_id = 'preuves' and is_staff());

-- ---------------------------------------------------------------------
-- PREMIER PROPRIÉTAIRE (automatique)
-- 1) Remplacez VOTRE_EMAIL ci-dessous par l'adresse avec laquelle vous créerez votre compte sur la page.
-- 2) Exécutez le script. Ensuite, sur la page : « Créer un compte » avec cette adresse :
--    vous êtes connectée directement et vous arrivez sur le tableau de bord.
-- Cette adresse devient propriétaire une seule fois, tant qu'aucun propriétaire actif n'existe.
-- ---------------------------------------------------------------------
create table if not exists owner_bootstrap (email text primary key);
alter table owner_bootstrap enable row level security;
revoke all on owner_bootstrap from anon, authenticated;
insert into owner_bootstrap (email) values ('VOTRE_EMAIL') on conflict do nothing;

create or replace function claim_first_owner() returns boolean
language plpgsql security definer set search_path = public as $$
declare u auth.users;
begin
  select * into u from auth.users where id = auth.uid();
  if u.id is null then return false; end if;
  if exists (select 1 from staff where role = 'proprietaire' and active) then return false; end if;
  if not exists (select 1 from owner_bootstrap where lower(email) = lower(u.email)) then return false; end if;
  insert into staff (user_id, nom, email, role, active)
  values (u.id, coalesce(u.raw_user_meta_data->>'nom', u.email), u.email, 'proprietaire', true)
  on conflict (user_id) do update set role = 'proprietaire', active = true;
  return true;
end $$;
revoke all on function claim_first_owner() from public;
grant execute on function claim_first_owner() to authenticated;

-- ---------------------------------------------------------------------
-- Places restantes (public) et décision sur un paiement (propriétaires)
-- ---------------------------------------------------------------------
create or replace function seats_left() returns integer
language sql stable security definer set search_path = public as $$
  select greatest(0, (select capacity from settings where id = 1)
                     - (select count(*)::int from registrations where statut = 'paye'));
$$;
revoke all on function seats_left() from public;
grant execute on function seats_left() to anon, authenticated;

-- p = {"id": <payments.id>, "ok": true|false}
create or replace function decide_payment(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay payments; reg registrations;
begin
  if not is_owner() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into pay from payments where id = (p->>'id')::bigint;
  if pay.id is null then raise exception 'not found'; end if;
  select * into reg from registrations where id = pay.registration_id;
  if (p->>'ok')::boolean then
    if reg.statut <> 'paye' and seats_left() <= 0 then
      return jsonb_build_object('done', false, 'reason', 'full');
    end if;
    update payments set statut = 'ok' where id = pay.id;
    update registrations set statut = 'paye' where id = reg.id;
  else
    update payments set statut = 'ko' where id = pay.id;
  end if;
  return jsonb_build_object('done', true);
end $$;
revoke all on function decide_payment(jsonb) from public;
grant execute on function decide_payment(jsonb) to authenticated;

-- Droits d'exécution explicites (Supabase donne par défaut anon + authenticated)
revoke all on function register_participant(jsonb), submit_payment(jsonb), submit_sponsor(jsonb) from public, anon, authenticated;
grant execute on function register_participant(jsonb), submit_payment(jsonb), submit_sponsor(jsonb) to anon;
revoke all on function seats_left() from public, anon, authenticated;
grant execute on function seats_left() to anon, authenticated;
revoke all on function is_staff(), is_owner(), claim_first_owner(), decide_payment(jsonb) from public, anon, authenticated;
grant execute on function is_staff(), is_owner(), claim_first_owner(), decide_payment(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- BUREAU ET INTERVENANTS (déjà appliqué sur le projet ; script sûr à relancer)
-- Le super admin autorise des comptes de supervision à modifier (staff.can_speakers)
-- et décide seul de la présence dans le panel (speakers.en_panel).
-- ---------------------------------------------------------------------
alter table staff add column if not exists can_speakers boolean not null default false;
create table if not exists speakers (
  id           bigint generated always as identity primary key,
  nom          text not null check (char_length(nom) between 2 and 120),
  statut       text not null default 'Intervenant' check (char_length(statut) <= 60),
  fonction     text check (char_length(fonction) <= 160),
  organisation text check (char_length(organisation) <= 160),
  bio          text check (char_length(bio) <= 800),
  photo_path   text,
  confirme     boolean not null default false,
  en_panel     boolean not null default false,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table speakers enable row level security;
revoke all on speakers from anon, authenticated;
grant select, insert, update, delete on speakers to authenticated;

create or replace function can_edit_speakers() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where user_id = auth.uid() and active and (role = 'proprietaire' or can_speakers))
$$;
create or replace function speakers_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then
    if tg_op = 'INSERT' then new.en_panel := false; else new.en_panel := old.en_panel; end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists speakers_guard_trg on speakers;
create trigger speakers_guard_trg before insert or update on speakers for each row execute function speakers_guard();

drop policy if exists spk_read on speakers; drop policy if exists spk_ins on speakers;
drop policy if exists spk_upd on speakers;  drop policy if exists spk_del on speakers;
create policy spk_read on speakers for select to authenticated using (is_staff());
create policy spk_ins  on speakers for insert to authenticated with check (can_edit_speakers());
create policy spk_upd  on speakers for update to authenticated using (can_edit_speakers()) with check (can_edit_speakers());
create policy spk_del  on speakers for delete to authenticated using (can_edit_speakers());

create or replace function public_speakers() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'statut', statut, 'fonction', fonction,
         'organisation', organisation, 'bio', bio, 'photo_path', photo_path) order by id), '[]'::jsonb)
  from speakers where en_panel and confirme
$$;
revoke all on function can_edit_speakers(), speakers_guard(), public_speakers() from public, anon, authenticated;
grant execute on function can_edit_speakers() to authenticated;
grant execute on function public_speakers() to anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('intervenants', 'intervenants', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists spk_photo_ins on storage.objects; drop policy if exists spk_photo_upd on storage.objects; drop policy if exists spk_photo_del on storage.objects;
create policy spk_photo_ins on storage.objects for insert to authenticated with check (bucket_id = 'intervenants' and can_edit_speakers());
create policy spk_photo_upd on storage.objects for update to authenticated using (bucket_id = 'intervenants' and can_edit_speakers());
create policy spk_photo_del on storage.objects for delete to authenticated using (bucket_id = 'intervenants' and can_edit_speakers());

-- ---------------------------------------------------------------------
-- Réglages (places, ouverture), décision sur les sponsors, protection anti-spam
-- (déjà appliqué sur le projet ; script sûr à relancer)
-- ---------------------------------------------------------------------
create or replace function public_settings() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('capacity', capacity, 'open', open) from settings where id = 1
$$;
create or replace function update_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c int;
begin
  if not is_owner() then raise exception 'forbidden' using errcode = '42501'; end if;
  c := (p->>'capacity')::int;
  if c is null or c < 1 or c > 5000 then raise exception 'capacite_invalide'; end if;
  update settings set capacity = c, open = coalesce((p->>'open')::boolean, open) where id = 1;
  return public_settings();
end $$;
create or replace function decide_sponsor(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'forbidden' using errcode = '42501'; end if;
  update sponsors set statut = case when (p->>'ok')::boolean then 'ok' else 'ko' end where id = (p->>'id')::bigint;
  if not found then raise exception 'not found'; end if;
  return jsonb_build_object('done', true);
end $$;
revoke all on function public_settings(), update_settings(jsonb), decide_sponsor(jsonb) from public, anon, authenticated;
grant execute on function public_settings() to anon, authenticated;
grant execute on function update_settings(jsonb), decide_sponsor(jsonb) to authenticated;
-- Anti-spam : les fonctions register_participant, submit_payment et submit_sponsor ignorent les envois
-- dont le champ piège « website » est rempli et refusent plus de 40 / 60 / 20 envois sur 10 minutes.

-- Paiements envoyés avant l'inscription : rattachés au bordereau quand la personne s'inscrit avec le même e-mail
-- (register_participant) ; decide_payment refuse de confirmer un paiement sans inscription liée.
-- Voir les définitions à jour dans la base ; elles remplacent celles ci-dessus.

-- Rôles : proprietaire (Super admin), gerant, moderateur
alter table staff drop constraint if exists staff_role_check;
update staff set role = 'moderateur' where role = 'supervision';
alter table staff add constraint staff_role_check check (role in ('proprietaire','gerant','moderateur'));
-- is_manager() (proprietaire ou gerant) : decide_payment l'exige. owner_bootstrap : seul contact@acprc-global.org.
