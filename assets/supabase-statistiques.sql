-- ============================================================================
-- Des chiffres et des lettres v13 : statistiques et records
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Ne touche à aucun résultat déjà enregistré (comptes, amis, partie du jour,
-- multijoueur). On peut le relancer sans risque.
-- ============================================================================

-- 1) JOURNAL DES PARTIES SOLO : une ligne par jeu terminé (et une par partie
--    complète ou courte terminée). Sert aux records et aux statistiques.
--    g : n/q = partie complète/courte ; l = mot le plus long ; c = compte est bon ;
--        w = mots de la fin ; t/k/u/s = défis ; y = duel par lien (résultat)
--    m : o = Jeu original ; f = Partie rapide ; e = Entraînement ; d = Partie du jour ;
--        x = défi par lien
create table if not exists public.plays (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  cid text not null check (char_length(cid) between 4 and 32),           -- identifiant créé par le téléphone (évite les doublons)
  g text not null check (g in ('n','q','l','c','w','t','k','u','s','y')),
  m text not null check (m in ('o','f','e','d','x')),
  dict text check (dict in ('fr','en')),
  dur integer check (dur between 0 and 600),                             -- durée du chrono choisie (0 = infini)
  pts integer not null default 0 check (pts between 0 and 9999),
  val integer check (val between -1 and 9999),                           -- longueur du mot, écart avec la cible, mots trouvés…
  time_ms integer check (time_ms between 0 and 3600000),                 -- temps du meilleur résultat
  detail text check (char_length(detail) <= 24),
  rec boolean not null default false,                                    -- compte pour les records
  sec integer check (sec between 0 and 36000),                           -- temps passé sur le jeu
  played_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, cid)
);
create index if not exists plays_user_idx on public.plays (user_id, id);
create index if not exists plays_rec_idx on public.plays (g, dict) where rec;
alter table public.plays enable row level security;
revoke all on public.plays from anon, authenticated;

-- Envoyer des parties jouées (par paquets de 200 au maximum)
create or replace function public.submit_plays(p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  r record;
  n integer := 0;
begin
  if uid is null then raise exception 'NOT_LOGGED'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 200 then raise exception 'BAD_ROWS'; end if;
  for r in select * from jsonb_to_recordset(p_rows) as x(cid text, g text, m text, dict text, dur integer, pts integer,
           val integer, time_ms integer, detail text, rec boolean, sec integer, played_at timestamptz) loop
    begin
      insert into public.plays (user_id, cid, g, m, dict, dur, pts, val, time_ms, detail, rec, sec, played_at)
      values (uid, r.cid, r.g, r.m, r.dict, r.dur, coalesce(r.pts, 0), r.val, r.time_ms, left(coalesce(r.detail, ''), 24),
              coalesce(r.rec, false), r.sec, least(coalesce(r.played_at, now()), now()))
      on conflict (user_id, cid) do nothing;
      n := n + 1;
    exception when others then
      null; -- une ligne invalide est ignorée, les autres passent
    end;
  end loop;
  return n;
end $$;

-- Mes parties (par pages de 1000, pour les statistiques sur tous mes appareils)
create or replace function public.my_plays(p_after bigint default 0)
returns table (id bigint, cid text, g text, m text, dict text, dur integer, pts integer, val integer,
               time_ms integer, detail text, rec boolean, sec integer, played_at timestamptz)
language sql security definer set search_path = '' stable as $$
  select p.id, p.cid, p.g, p.m, p.dict, p.dur, p.pts, p.val, p.time_ms, p.detail, p.rec, p.sec, p.played_at
  from public.plays p
  where p.user_id = auth.uid() and p.id > coalesce(p_after, 0)
  order by p.id
  limit 1000
$$;

-- Records de tous les joueurs : le meilleur résultat de chaque compte, top 10 + ma place
--   p_g : n, q, l, c ou w ; p_dict : fr ou en (pour l et w)
create or replace function public.top_records(p_g text, p_dict text default null)
returns table (pos integer, pseudo text, pts integer, val integer, time_ms integer, detail text, played_at timestamptz, me boolean)
language sql security definer set search_path = '' stable as $$
  with base as (
    select p.user_id, p.pts, p.val, p.time_ms, p.detail, p.played_at,
      case when p_g = 'c' then p.val when p_g = 'l' then -p.val else -p.pts end as k1,
      case when p_g in ('n','q') then 0 else coalesce(p.time_ms, 0) end as k2
    from public.plays p
    where p.g = p_g and p.rec
      and (p_g in ('n','q','c') or p.dict = p_dict)
      and (case when p_g = 'c' then p.val is not null and p.val >= 0
                when p_g = 'l' then p.val > 0
                else p.pts > 0 end)
  ), best as (
    select distinct on (b.user_id) b.*
    from base b
    order by b.user_id, b.k1, b.k2, b.played_at
  ), r as (
    select (row_number() over (order by b.k1, b.k2, b.played_at))::integer as rk, b.*, pr.pseudo as ps
    from best b
    join public.profiles pr on pr.id = b.user_id
  )
  select r.rk, r.ps, r.pts, r.val, r.time_ms, r.detail, r.played_at, coalesce(r.user_id = auth.uid(), false)
  from r
  where r.rk <= 10 or r.user_id = auth.uid()
  order by r.rk
$$;

-- Partie du jour : ma place et le nombre de joueurs classés, pour chacun de mes résultats
create or replace function public.my_daily_stats()
returns table (day date, game text, pos integer, players integer)
language sql security definer set search_path = '' stable as $$
  with mine as (
    select s.day, s.game from public.daily_scores s where s.user_id = auth.uid()
  ), r as (
    select s.day, s.game, s.user_id,
      (row_number() over (partition by s.day, s.game
                          order by case when s.game = 'c' then s.result else -s.result end, s.time_cs, s.created_at))::integer as rk,
      (count(*) over (partition by s.day, s.game))::integer as nb
    from public.daily_scores s
    join public.profiles p on p.id = s.user_id
    where (s.day, s.game) in (select mine.day, mine.game from mine)
  )
  select r.day, r.game, r.rk, r.nb from r
  where r.user_id = auth.uid()
  order by r.day desc
  limit 1000
$$;

-- 2) MULTIJOUEUR
-- La partie personnalisée (mode 'p') est acceptée dans les résultats
alter table public.multi_results drop constraint if exists multi_results_mode_check;
alter table public.multi_results add constraint multi_results_mode_check check (mode in ('o','q','p'));
-- Défis au buzzer : nombre de buzz, bonnes réponses, buzz le plus rapide (ms)
alter table public.multi_results add column if not exists buzz integer;
alter table public.multi_results add column if not exists buzz_ok integer;
alter table public.multi_results add column if not exists buzz_ms integer;
create index if not exists multi_results_gid_idx on public.multi_results (gid);

-- Enregistrer mon résultat (version avec le buzzer)
create or replace function public.submit_multi2(p_gid text, p_mode text, p_game text, p_dict text,
  p_rank integer, p_players integer, p_points integer, p_detail text,
  p_buzz integer, p_buzz_ok integer, p_buzz_ms integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'NOT_LOGGED'; end if;
  insert into public.multi_results (user_id, gid, mode, game, dict, rank, players, points, detail, buzz, buzz_ok, buzz_ms)
  values (uid, p_gid, p_mode, p_game, p_dict, p_rank, greatest(p_players, p_rank), p_points, left(coalesce(p_detail, ''), 20),
          least(greatest(coalesce(p_buzz, 0), 0), 999), least(greatest(coalesce(p_buzz_ok, 0), 0), 999),
          case when p_buzz_ms between 0 and 60000 then p_buzz_ms else null end)
  on conflict (user_id, gid) do nothing;
  return true;
end $$;

-- Toutes mes parties multijoueur (par pages de 1000)
create or replace function public.my_multi_all(p_after bigint default 0)
returns table (id bigint, created_at timestamptz, mode text, game text, dict text, rank integer, players integer,
               points integer, detail text, buzz integer, buzz_ok integer, buzz_ms integer)
language sql security definer set search_path = '' stable as $$
  select m.id, m.created_at, m.mode, m.game, m.dict, m.rank, m.players, m.points, m.detail, m.buzz, m.buzz_ok, m.buzz_ms
  from public.multi_results m
  where m.user_id = auth.uid() and m.id > coalesce(p_after, 0)
  order by m.id
  limit 1000
$$;

-- Rivalités : mon bilan contre chaque adversaire qui a un compte (mêmes parties en direct)
create or replace function public.my_rivals()
returns table (pseudo text, games integer, wins integer, losses integer, ties integer)
language sql security definer set search_path = '' stable as $$
  select pr.pseudo,
    count(*)::integer,
    (count(*) filter (where m.rank < o.rank))::integer,
    (count(*) filter (where m.rank > o.rank))::integer,
    (count(*) filter (where m.rank = o.rank))::integer
  from public.multi_results m
  join public.multi_results o on o.gid = m.gid and o.user_id <> m.user_id
  join public.profiles pr on pr.id = o.user_id
  where m.user_id = auth.uid()
  group by pr.pseudo
  order by count(*) desc, pr.pseudo
  limit 50
$$;

-- Droits d'exécution
grant execute on function public.submit_plays(jsonb) to authenticated;
grant execute on function public.my_plays(bigint) to authenticated;
grant execute on function public.top_records(text, text) to anon, authenticated;
grant execute on function public.my_daily_stats() to authenticated;
grant execute on function public.submit_multi2(text, text, text, text, integer, integer, integer, text, integer, integer, integer) to authenticated;
grant execute on function public.my_multi_all(bigint) to authenticated;
grant execute on function public.my_rivals() to authenticated;
