-- ============================================================================
-- Des chiffres et des lettres v06 : comptes, pseudos uniques, amis, classements
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Le script garde tous les résultats déjà enregistrés dans daily_scores.
-- On peut le relancer sans risque.
-- ============================================================================

-- 1) PROFILS : un pseudo unique par compte (sans tenir compte des majuscules)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  pseudo text not null check (char_length(pseudo) between 1 and 12),
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_pseudo_key on public.profiles (lower(pseudo));
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;

-- Création automatique du profil quand un compte est créé
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  p text := btrim(regexp_replace(coalesce(new.raw_user_meta_data ->> 'pseudo', ''), '\s+', ' ', 'g'));
begin
  if char_length(p) < 1 or char_length(p) > 12 then
    p := 'Joueur' || substr(replace(new.id::text, '-', ''), 1, 6);
  end if;
  if exists (select 1 from public.profiles where lower(pseudo) = lower(p)) then
    raise exception 'PSEUDO_TAKEN';
  end if;
  insert into public.profiles (id, pseudo) values (new.id, p);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) AMIS : une demande, puis acceptation
create table if not exists public.friends (
  id bigint generated always as identity primary key,
  from_id uuid not null references auth.users(id) on delete cascade,
  to_id uuid not null references auth.users(id) on delete cascade,
  accepted boolean not null default false,
  created_at timestamptz not null default now(),
  check (from_id <> to_id)
);
create unique index if not exists friends_pair_key on public.friends (least(from_id, to_id), greatest(from_id, to_id));
create index if not exists friends_to_idx on public.friends (to_id);
alter table public.friends enable row level security;
revoke all on public.friends from anon, authenticated;

-- 3) CLASSEMENTS : on relie chaque résultat à un compte (les anciens résultats restent)
alter table public.daily_scores add column if not exists user_id uuid references auth.users(id) on delete cascade;
create index if not exists daily_scores_user_idx on public.daily_scores (user_id, day);
create index if not exists daily_scores_day_game_idx on public.daily_scores (day, game);
-- Plus d'accès direct à la table : tout passe par les fonctions ci-dessous
drop policy if exists "Lecture pour tous" on public.daily_scores;
drop policy if exists "Ajout du jour" on public.daily_scores;
revoke all on public.daily_scores from anon, authenticated;

-- ============================================================================
-- FONCTIONS appelées par le jeu
-- ============================================================================

-- Pseudo libre ? (avant la création du compte)
create or replace function public.pseudo_free(p_pseudo text)
returns boolean language sql security definer set search_path = '' stable as $$
  select not exists (
    select 1 from public.profiles
    where lower(pseudo) = lower(btrim(regexp_replace(p_pseudo, '\s+', ' ', 'g')))
  )
$$;

-- Mon profil : pseudo + nombre de demandes d'amis reçues
create or replace function public.my_profile()
returns table (pseudo text, pending integer)
language sql security definer set search_path = '' stable as $$
  select p.pseudo,
         (select count(*)::integer from public.friends f where f.to_id = p.id and not f.accepted)
  from public.profiles p where p.id = auth.uid()
$$;

-- Changer de pseudo : 'ok', 'taken' ou 'invalid'
create or replace function public.set_pseudo(p_pseudo text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  p text := btrim(regexp_replace(coalesce(p_pseudo, ''), '\s+', ' ', 'g'));
begin
  if uid is null then return 'auth'; end if;
  if char_length(p) < 1 or char_length(p) > 12 then return 'invalid'; end if;
  if exists (select 1 from public.profiles where lower(pseudo) = lower(p) and id <> uid) then return 'taken'; end if;
  update public.profiles set pseudo = p where id = uid;
  return 'ok';
end $$;

-- Envoyer un résultat de La partie du jour (compte connecté uniquement)
create or replace function public.submit_score(p_day date, p_game text, p_result integer, p_detail text, p_time_cs integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  today date := (now() at time zone 'Europe/Paris')::date;
  ps text;
begin
  if uid is null then raise exception 'NOT_LOGGED'; end if;
  if p_day is null or p_day < today - 30 or p_day > today then raise exception 'BAD_DAY'; end if;
  select pseudo into ps from public.profiles where id = uid;
  if ps is null then raise exception 'NO_PROFILE'; end if;
  insert into public.daily_scores (day, game, player_id, pseudo, result, detail, time_cs, user_id)
  values (p_day, p_game, uid::text, ps, p_result, left(coalesce(p_detail, ''), 20), p_time_cs, uid)
  on conflict (day, game, player_id) do nothing;
  return true;
end $$;

-- Mes résultats des 31 derniers jours (pour retrouver son historique sur un autre appareil)
create or replace function public.my_scores()
returns table (day date, game text, result integer, detail text, time_cs integer)
language sql security definer set search_path = '' stable as $$
  select s.day, s.game, s.result, s.detail, s.time_cs
  from public.daily_scores s
  where s.user_id = auth.uid()
    and s.day >= (now() at time zone 'Europe/Paris')::date - 31
$$;

-- Identifiants de mes amis (demandes acceptées)
create or replace function public.friend_ids()
returns setof uuid language sql security definer set search_path = '' stable as $$
  select case when f.from_id = auth.uid() then f.to_id else f.from_id end
  from public.friends f
  where f.accepted and (f.from_id = auth.uid() or f.to_id = auth.uid())
$$;

-- Classement d'un défi : p_scope = 'top' (top 10 + ma place) ou 'friends' (moi + mes amis)
create or replace function public.daily_rank(p_day date, p_game text, p_scope text default 'top')
returns table (pos integer, pseudo text, result integer, detail text, time_cs integer, me boolean)
language sql security definer set search_path = '' stable as $$
  with base as (
    select s.user_id, p.pseudo, s.result, s.detail, s.time_cs, s.created_at
    from public.daily_scores s
    join public.profiles p on p.id = s.user_id
    where s.day = p_day and s.game = p_game
      and (p_scope = 'top'
           or s.user_id = auth.uid()
           or s.user_id in (select public.friend_ids()))
  ), r as (
    select (row_number() over (order by case when p_game = 'c' then b.result else -b.result end,
                                        b.time_cs, b.created_at))::integer as pos, b.*
    from base b
  )
  select r.pos, r.pseudo, r.result, r.detail, r.time_cs, coalesce(r.user_id = auth.uid(), false)
  from r
  where p_scope <> 'top' or r.pos <= 10 or r.user_id = auth.uid()
  order by r.pos
$$;

-- Demander quelqu'un en ami par son pseudo
-- Réponses : 'sent', 'accepted' (il m'avait déjà demandé), 'already', 'pending', 'notfound', 'self', 'auth'
create or replace function public.friend_add(p_pseudo text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  oid uuid;
  lk record;
begin
  if uid is null then return 'auth'; end if;
  select id into oid from public.profiles
  where lower(pseudo) = lower(btrim(regexp_replace(coalesce(p_pseudo, ''), '\s+', ' ', 'g')));
  if oid is null then return 'notfound'; end if;
  if oid = uid then return 'self'; end if;
  select * into lk from public.friends
  where least(from_id, to_id) = least(uid, oid) and greatest(from_id, to_id) = greatest(uid, oid);
  if found then
    if lk.accepted then return 'already'; end if;
    if lk.from_id = uid then return 'pending'; end if;
    update public.friends set accepted = true where id = lk.id;
    return 'accepted';
  end if;
  insert into public.friends (from_id, to_id) values (uid, oid);
  return 'sent';
end $$;

-- Accepter (true) ou refuser (false) une demande reçue
create or replace function public.friend_answer(p_user uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return; end if;
  if p_ok then
    update public.friends set accepted = true where from_id = p_user and to_id = auth.uid();
  else
    delete from public.friends where from_id = p_user and to_id = auth.uid() and not accepted;
  end if;
end $$;

-- Retirer un ami ou annuler une demande envoyée
create or replace function public.friend_remove(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return; end if;
  delete from public.friends
  where (from_id = auth.uid() and to_id = p_user) or (from_id = p_user and to_id = auth.uid());
end $$;

-- Ma liste : amis ('friend'), demandes reçues ('in'), demandes envoyées ('out')
create or replace function public.friend_list()
returns table (id uuid, pseudo text, state text)
language sql security definer set search_path = '' stable as $$
  select o.oid, p.pseudo,
         case when o.accepted then 'friend' when o.to_id = auth.uid() then 'in' else 'out' end
  from (
    select case when f.from_id = auth.uid() then f.to_id else f.from_id end as oid, f.accepted, f.to_id
    from public.friends f
    where f.from_id = auth.uid() or f.to_id = auth.uid()
  ) o
  join public.profiles p on p.id = o.oid
  order by lower(p.pseudo)
$$;

-- Supprimer mon compte (profil, amis et résultats partent avec)
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'NOT_LOGGED'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- Droits d'exécution
revoke execute on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.pseudo_free(text) to anon, authenticated;
grant execute on function public.daily_rank(date, text, text) to anon, authenticated;
grant execute on function public.my_profile() to authenticated;
grant execute on function public.set_pseudo(text) to authenticated;
grant execute on function public.submit_score(date, text, integer, text, integer) to authenticated;
grant execute on function public.my_scores() to authenticated;
grant execute on function public.friend_ids() to authenticated;
grant execute on function public.friend_add(text) to authenticated;
grant execute on function public.friend_answer(uuid, boolean) to authenticated;
grant execute on function public.friend_remove(uuid) to authenticated;
grant execute on function public.friend_list() to authenticated;
grant execute on function public.delete_my_account() to authenticated;
