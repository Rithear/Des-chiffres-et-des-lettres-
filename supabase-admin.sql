-- =====================================================================
-- Des chiffres et des lettres — écran Admin
--
-- AVANT DE LANCER : remplace TON_ADRESSE_ICI (ligne 28) par l'adresse
-- e-mail de TON COMPTE DE JOUEUR (celle avec laquelle tu te connectes
-- au jeu, pas le Gmail du jeu). Garde bien les apostrophes autour.
--
-- Puis : Supabase › SQL Editor › New query › coller tout le texte › Run.
-- Le script ne modifie aucune donnée des joueurs. On peut le relancer
-- sans risque (par exemple pour ajouter un autre administrateur).
-- =====================================================================

-- 1) LA LISTE DES ADMINISTRATEURS (rangés par identifiant de compte)
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

-- 2) TON COMPTE DEVIENT ADMINISTRATEUR
do $$
declare
  adr text;
  uid uuid;
begin
  -- ↓↓↓ remplace TON_ADRESSE_ICI par ton adresse, entre les apostrophes ↓↓↓
  adr := 'riri.sok@hotmail.fr';
  -- ↑↑↑ ----------------------------------------------------------------- ↑↑↑
  select id into uid from auth.users where lower(email) = lower(btrim(adr));
  if uid is null then
    raise exception 'Aucun compte avec l''adresse « % ». Vérifie l''adresse à la ligne 28, puis relance.', adr;
  end if;
  insert into public.admins (user_id) values (uid) on conflict do nothing;
  raise notice 'C''est fait : ce compte est administrateur.';
end $$;

-- 3) EST-CE QUE JE SUIS ADMINISTRATEUR ? (le jeu s'en sert pour afficher la touche)
create or replace function public.is_admin()
returns boolean language sql security definer set search_path = '' stable as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid())
$$;

-- 4) TOUTE L'ACTIVITÉ DES COMPTES, EN UNE SEULE LISTE (usage interne)
--    k : p = partie solo ; m = multijoueur en direct ; ds = duel envoyé ;
--        da = duel relevé ; tn = match au tour par tour lancé ; tb = tour joué
create or replace function public.adm_ev()
returns table (uid uuid, at timestamptz, k text, g text, m text, dict text,
               pts integer, val integer, detail text, oth text)
language sql security definer set search_path = '' stable as $$
  -- parties solo (les manches d'une partie complète/courte sont regroupées dans la partie)
  select p.user_id, p.played_at, 'p', p.g, p.m, p.dict, p.pts, p.val, p.detail, null::text
  from public.plays p
  where p.g <> 'y' and not (p.m = 'o' and p.g not in ('n','q'))
  union all
  -- multijoueur en direct
  select r.user_id, r.created_at, 'm', r.game, r.mode, r.dict, r.points, r.rank, r.detail, r.players::text
  from public.multi_results r
  union all
  -- duels envoyés à un ami
  select d.from_id, d.created_at, 'ds', d.game, null, null, null, null, null, pr.pseudo
  from public.duel_sends d left join public.profiles pr on pr.id = d.to_id
  where d.status <> 'cancel'
  union all
  -- duels relevés
  select d.to_id, d.answered_at, 'da', d.game, null, null, null, null, null, pr.pseudo
  from public.duel_sends d left join public.profiles pr on pr.id = d.from_id
  where d.answered_at is not null
  union all
  -- matchs au tour par tour lancés
  select mt.p1, mt.created_at, 'tn', mt.kind, null, mt.dict, null, null, null, pr.pseudo
  from public.tb_matches mt left join public.profiles pr on pr.id = mt.p2
  union all
  -- tours joués
  select tp.user_id, tp.done_at, 'tb', mt.kind, null, mt.dict, tp.pts, tp.tour, null, pr.pseudo
  from public.tb_plays tp
  join public.tb_matches mt on mt.id = tp.match_id
  left join public.profiles pr on pr.id = case when mt.p1 = tp.user_id then mt.p2 else mt.p1 end
  where tp.done and not tp.missed and tp.done_at is not null
$$;
revoke execute on function public.adm_ev() from public, anon, authenticated;

-- 5) VUE D'ENSEMBLE
create or replace function public.admin_overview()
returns jsonb language plpgsql security definer set search_path = '' stable as $$
declare
  today date := (now() at time zone 'Europe/Paris')::date;
  res jsonb;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  with ev as (
    select e.*, (e.at at time zone 'Europe/Paris')::date as dy
    from public.adm_ev() e
    where e.at >= now() - interval '31 days'
  )
  select jsonb_build_object(
    'accounts', (select count(*) from public.profiles),
    'new7',  (select count(*) from public.profiles where created_at >= now() - interval '7 days'),
    'new30', (select count(*) from public.profiles where created_at >= now() - interval '30 days'),
    'act1',  (select count(distinct uid) from ev where dy = today),
    'act7',  (select count(distinct uid) from ev where dy > today - 7),
    'act30', (select count(distinct uid) from ev where dy > today - 30),
    'ev1',   (select count(*) from ev where dy = today),
    'ev7',   (select count(*) from ev where dy > today - 7),
    'ev30',  (select count(*) from ev where dy > today - 30),
    'daily', (select count(distinct user_id) from public.daily_scores where day = today and user_id is not null),
    'days',  (select jsonb_agg(jsonb_build_object('d', s.d, 'n',
                (select count(*) from ev where dy = s.d),
                'u', (select count(distinct uid) from ev where dy = s.d)) order by s.d)
              from (select g0::date as d from generate_series(today - 29, today, interval '1 day') g0) s),
    'games', (select coalesce(jsonb_agg(jsonb_build_object('g', x.g, 'n', x.n) order by x.n desc), '[]'::jsonb)
              from (select g, count(*) as n from ev where k = 'p' and dy > today - 30 group by g) x),
    'modes', (select coalesce(jsonb_agg(jsonb_build_object('m', x.m, 'n', x.n) order by x.n desc), '[]'::jsonb)
              from (select m, count(*) as n from ev where k = 'p' and dy > today - 30 group by m) x)
  ) into res;
  return res;
end $$;

-- 6) LA LISTE DES JOUEURS
create or replace function public.admin_players()
returns table (id uuid, pseudo text, created_at timestamptz, last_login timestamptz, last_play timestamptz,
               n7 integer, n30 integer, nall integer, fav text, friends integer)
language plpgsql security definer set search_path = '' stable as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return query
  with ev as (select * from public.adm_ev())
  select p.id, p.pseudo, p.created_at, u.last_sign_in_at,
    (select max(e.at) from ev e where e.uid = p.id),
    (select count(*)::integer from ev e where e.uid = p.id and e.at >= now() - interval '7 days'),
    (select count(*)::integer from ev e where e.uid = p.id and e.at >= now() - interval '30 days'),
    (select count(*)::integer from ev e where e.uid = p.id),
    (select e.g from ev e where e.uid = p.id and e.k = 'p' group by e.g order by count(*) desc, e.g limit 1),
    (select count(*)::integer from public.friends f where f.accepted and (f.from_id = p.id or f.to_id = p.id))
  from public.profiles p
  left join auth.users u on u.id = p.id
  order by 5 desc nulls last, p.created_at desc;
end $$;

-- 7) LE DÉTAIL D'UN JOUEUR
create or replace function public.admin_player(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' stable as $$
declare res jsonb;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  with ev as (select * from public.adm_ev() e where e.uid = p_id)
  select jsonb_build_object(
    'pseudo', p.pseudo,
    'created_at', p.created_at,
    'last_login', u.last_sign_in_at,
    'friends', (select coalesce(jsonb_agg(x.pseudo order by lower(x.pseudo)), '[]'::jsonb) from (
                  select pr.pseudo from public.friends f
                  join public.profiles pr on pr.id = case when f.from_id = p_id then f.to_id else f.from_id end
                  where f.accepted and (f.from_id = p_id or f.to_id = p_id)) x),
    'solo', (select coalesce(jsonb_agg(jsonb_build_object('g', x.g, 'n', x.n, 'avg', x.a) order by x.n desc), '[]'::jsonb)
             from (select g, count(*) as n, round(avg(pts), 1) as a from ev where k = 'p' group by g) x),
    'modes', (select coalesce(jsonb_agg(jsonb_build_object('m', x.m, 'n', x.n) order by x.n desc), '[]'::jsonb)
              from (select m, count(*) as n from ev where k = 'p' group by m) x),
    'daily', (select count(distinct day) from public.daily_scores where user_id = p_id),
    'multi', (select jsonb_build_object('n', count(*), 'wins', count(*) filter (where rank = 1))
              from public.multi_results where user_id = p_id),
    'duels', jsonb_build_object(
               'sent', (select count(distinct duel) from public.duel_sends where from_id = p_id and status <> 'cancel'),
               'got',  (select count(*) from public.duel_sends where to_id = p_id and status <> 'cancel'),
               'done', (select count(*) from public.duel_sends where to_id = p_id and status = 'done')),
    'tb', (select jsonb_build_object('n', count(*), 'run', count(*) filter (where status = 'run'),
                    'wins', count(*) filter (where status = 'done' and winner = p_id))
           from public.tb_matches where p1 = p_id or p2 = p_id),
    'recent', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb) from (
                 select e.at, e.k, e.g, e.m, e.dict, e.pts, e.val, e.detail, e.oth
                 from ev e order by e.at desc limit 40) x)
  ) into res
  from public.profiles p left join auth.users u on u.id = p.id
  where p.id = p_id;
  return res;
end $$;

-- 8) LE FIL D'ACTIVITÉ (les plus récentes d'abord, par pages)
create or replace function public.admin_feed(p_before timestamptz default null, p_limit integer default 60)
returns table (at timestamptz, uid uuid, pseudo text, k text, g text, m text, dict text,
               pts integer, val integer, detail text, oth text)
language plpgsql security definer set search_path = '' stable as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return query
  select e.at, e.uid, pr.pseudo, e.k, e.g, e.m, e.dict, e.pts, e.val, e.detail, e.oth
  from public.adm_ev() e
  left join public.profiles pr on pr.id = e.uid
  where p_before is null or e.at < p_before
  order by e.at desc
  limit least(greatest(coalesce(p_limit, 60), 1), 200);
end $$;

-- 9) LE MULTIJOUEUR : dernières parties en direct, matchs au tour par tour, duels entre amis
create or replace function public.admin_multi()
returns jsonb language plpgsql security definer set search_path = '' stable as $$
declare res jsonb;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select jsonb_build_object(
    'live', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb) from (
               select r.gid, max(r.created_at) as at, min(r.mode) as mode, min(r.game) as game, min(r.dict) as dict,
                      max(r.players) as players,
                      string_agg(pr.pseudo, ', ' order by r.rank) as who,
                      min(pr.pseudo) filter (where r.rank = 1) as win
               from public.multi_results r join public.profiles pr on pr.id = r.user_id
               group by r.gid order by max(r.created_at) desc limit 30) x),
    'tb', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb) from (
             select mt.created_at as at, a.pseudo as p1, b.pseudo as p2, mt.kind, mt.dict, mt.status,
                    mt.tour, mt.s1, mt.s2, w.pseudo as win, mt.reason
             from public.tb_matches mt
             left join public.profiles a on a.id = mt.p1
             left join public.profiles b on b.id = mt.p2
             left join public.profiles w on w.id = mt.winner
             order by mt.created_at desc limit 30) x),
    'duels', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb) from (
                select d.created_at as at, a.pseudo as fr, b.pseudo as tt, d.game, d.status
                from public.duel_sends d
                left join public.profiles a on a.id = d.from_id
                left join public.profiles b on b.id = d.to_id
                where d.status <> 'cancel'
                order by d.created_at desc limit 30) x)
  ) into res;
  return res;
end $$;

-- 10) DROITS : seules les fonctions ci-dessous sont appelables, et elles
--     refusent tout compte qui n'est pas dans la liste des administrateurs
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.admin_overview() from public, anon;
revoke execute on function public.admin_players() from public, anon;
revoke execute on function public.admin_player(uuid) from public, anon;
revoke execute on function public.admin_feed(timestamptz, integer) from public, anon;
revoke execute on function public.admin_multi() from public, anon;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.admin_overview() to authenticated;
grant execute on function public.admin_players() to authenticated;
grant execute on function public.admin_player(uuid) to authenticated;
grant execute on function public.admin_feed(timestamptz, integer) to authenticated;
grant execute on function public.admin_multi() to authenticated;
