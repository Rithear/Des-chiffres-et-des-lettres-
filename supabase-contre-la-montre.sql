-- =====================================================================
-- Des chiffres et des lettres — mise à jour v19 : ⏱ Contre-la-montre
--   Saisons de 2 semaines (heure française) :
--     saison 1 : de la mise en ligne au dimanche 15 novembre 2026, 23 h 59
--     saison 2 : du lundi 16 novembre au dimanche 29 novembre 2026, et ainsi de suite
--   10 épreuves par saison, en français et en anglais (classements séparés),
--   le même tirage pour tout le monde, le chrono part côté serveur.
-- À coller tel quel dans Supabase › SQL Editor, puis « Run ».
-- Le script peut être relancé sans risque.
-- =====================================================================

-- 1) TABLES
create table if not exists public.cm_draws (
  season integer not null,
  lang text not null check (lang in ('fr','en')),
  idx integer not null check (idx between 0 and 9),
  d jsonb not null,
  created_at timestamptz not null default now(),
  primary key (season, lang, idx)
);
alter table public.cm_draws enable row level security;
revoke all on public.cm_draws from anon, authenticated;

create table if not exists public.cm_plays (
  season integer not null,
  lang text not null check (lang in ('fr','en')),
  user_id uuid not null references auth.users(id) on delete cascade,
  idx integer not null check (idx between 0 and 9),
  started_at timestamptz not null default now(),
  done boolean not null default false,
  ok boolean not null default false,
  time_ms integer,
  answer text,
  auto boolean not null default false,
  finished_at timestamptz,
  primary key (season, lang, user_id, idx)
);
create index if not exists cm_plays_rank_idx on public.cm_plays (season, lang);
alter table public.cm_plays enable row level security;
revoke all on public.cm_plays from anon, authenticated;

-- 2) OUTILS : saisons et temps maximum de chaque épreuve
-- numéro de la saison à un instant donné
create or replace function public.cm_season_at(p_ts timestamptz)
returns integer language sql stable set search_path = '' as $$
  select case when (p_ts at time zone 'Europe/Paris')::date < date '2026-11-16' then 1
              else 2 + (((p_ts at time zone 'Europe/Paris')::date - date '2026-11-16') / 14) end
$$;
-- fin d'une saison (= début de la suivante, lundi 0 h, heure française)
create or replace function public.cm_season_end(p_season integer)
returns timestamptz language sql stable set search_path = '' as $$
  select ((date '2026-11-16' + 14 * (p_season - 1))::timestamp) at time zone 'Europe/Paris'
$$;
-- temps maximum : 45 s pour les chiffres (épreuves 1, 3, 6, 8), 30 s pour le reste
create or replace function public.cm_max(p_idx integer)
returns integer language sql immutable set search_path = '' as $$
  select case when p_idx in (0,2,5,7) then 45000 else 30000 end
$$;
-- une épreuve lancée puis abandonnée (appli fermée) compte au temps maximum au bout de 3 minutes
create or replace function public.cm_stale(p_done boolean, p_started timestamptz)
returns boolean language sql stable set search_path = '' as $$
  select not p_done and p_started < now() - interval '3 minutes'
$$;

-- 3) LANCER UNE ÉPREUVE
-- p_cand : tirage proposé par le téléphone, gardé seulement si personne n'a encore joué cette épreuve
-- réponses : {d, idx} ou {e: 'auth' | 'over' | 'idx' | 'cand' | 'done'}
create or replace function public.cm_begin(p_season integer, p_lang text, p_idx integer, p_cand jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  cur integer := public.cm_season_at(now());
  n integer; g text; g4 text; dr jsonb;
begin
  if uid is null then return jsonb_build_object('e','auth'); end if;
  if p_season is distinct from cur then return jsonb_build_object('e','over','season',cur); end if;
  if p_lang not in ('fr','en') then return jsonb_build_object('e','cand'); end if;
  perform pg_advisory_xact_lock(hashtext('cm|' || uid::text));
  -- une épreuve lancée et jamais terminée compte au temps maximum
  update public.cm_plays set done = true, ok = false, time_ms = public.cm_max(idx), auto = true, finished_at = now()
    where season = cur and lang = p_lang and user_id = uid and not done;
  select count(*) into n from public.cm_plays where season = cur and lang = p_lang and user_id = uid;
  if n >= 10 then return jsonb_build_object('e','done'); end if;
  if p_idx is distinct from n then return jsonb_build_object('e','idx','idx',n); end if;
  select d into dr from public.cm_draws where season = cur and lang = p_lang and idx = n;
  if not found then
    if p_cand is null or jsonb_typeof(p_cand) <> 'object' or octet_length(p_cand::text) > 6000 then
      return jsonb_build_object('e','cand');
    end if;
    g := p_cand ->> 'g';
    if n in (0,2,5,7) then
      if g is distinct from 'c' then return jsonb_build_object('e','cand'); end if;
    elsif n in (1,3,6,8) then
      if g is distinct from 'a' or char_length(coalesce(p_cand ->> 'w','')) <> (case n when 1 then 5 when 3 then 6 when 6 then 7 else 8 end) then
        return jsonb_build_object('e','cand');
      end if;
    else
      if g is null or g not in ('t','k','u','s') then return jsonb_build_object('e','cand'); end if;
      if n = 9 then
        select d ->> 'g' into g4 from public.cm_draws where season = cur and lang = p_lang and idx = 4;
        if g = g4 then return jsonb_build_object('e','cand','avoid',g4); end if;
      end if;
    end if;
    insert into public.cm_draws (season, lang, idx, d) values (cur, p_lang, n, p_cand) on conflict do nothing;
    select d into dr from public.cm_draws where season = cur and lang = p_lang and idx = n;
  end if;
  insert into public.cm_plays (season, lang, user_id, idx) values (cur, p_lang, uid, n);
  return jsonb_build_object('d', dr, 'idx', n);
end $$;

-- 4) ENVOYER LE RÉSULTAT D'UNE ÉPREUVE
create or replace function public.cm_result(p_season integer, p_lang text, p_idx integer, p_ok boolean, p_ms integer, p_ans text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  p public.cm_plays%rowtype;
  mx integer := public.cm_max(p_idx);
begin
  if uid is null then return jsonb_build_object('e','auth'); end if;
  select * into p from public.cm_plays
    where season = p_season and lang = p_lang and user_id = uid and idx = p_idx for update;
  if not found then return jsonb_build_object('e','none'); end if;
  -- déjà enregistré (sauf une épreuve clôturée automatiquement, si le résultat arrive dans les 30 minutes)
  if p.done and not (p.auto and now() < p.started_at + interval '30 minutes') then return jsonb_build_object('ok',true); end if;
  if now() > public.cm_season_end(p_season) + interval '1 day' then return jsonb_build_object('e','over'); end if;
  update public.cm_plays set done = true, auto = false, finished_at = now(),
    ok = coalesce(p_ok, false),
    time_ms = case when coalesce(p_ok, false) then greatest(0, least(mx, coalesce(p_ms, mx))) else mx end,
    answer = left(coalesce(p_ans, ''), 24)
    where season = p_season and lang = p_lang and user_id = uid and idx = p_idx;
  return jsonb_build_object('ok',true);
end $$;

-- 5) MA SAISON : mes épreuves (et les tirages une fois la saison terminée)
create or replace function public.cm_state(p_season integer, p_lang text)
returns jsonb language sql security definer set search_path = '' stable as $$
  select jsonb_build_object(
    'cur', public.cm_season_at(now()),
    'plays', coalesce((select jsonb_agg(jsonb_build_object(
        'idx', p.idx, 'g', (select dd.d ->> 'g' from public.cm_draws dd where dd.season = p.season and dd.lang = p.lang and dd.idx = p.idx),
        'done', p.done or public.cm_stale(p.done, p.started_at), 'ok', p.ok and p.done,
        'ms', case when p.done then p.time_ms else public.cm_max(p.idx) end,
        'ans', case when p.done then p.answer else '' end, 'auto', p.auto or not p.done) order by p.idx)
      from public.cm_plays p where p.season = p_season and p.lang = p_lang and p.user_id = auth.uid()), '[]'::jsonb),
    'draws', case when p_season < public.cm_season_at(now()) then coalesce((select jsonb_agg(jsonb_build_object('idx', d.idx, 'd', d.d) order by d.idx)
      from public.cm_draws d where d.season = p_season and d.lang = p_lang), '[]'::jsonb) else '[]'::jsonb end)
$$;

-- 6) CLASSEMENT d'une saison : p_scope = 'top' (top 10 + ma place) ou 'friends' (moi + mes amis)
-- pos est vide pour les joueurs qui n'ont pas encore terminé les 10 épreuves
create or replace function public.cm_rank(p_season integer, p_lang text, p_scope text default 'top')
returns table (pos integer, pseudo text, n integer, total_ms bigint, me boolean, nfin integer)
language sql security definer set search_path = '' stable as $$
  with pl as (
    select p.user_id,
           count(*) filter (where p.done or public.cm_stale(p.done, p.started_at))::integer as n,
           coalesce(sum(case when p.done then p.time_ms when public.cm_stale(p.done, p.started_at) then public.cm_max(p.idx) else 0 end), 0)::bigint as total_ms,
           max(coalesce(p.finished_at, p.started_at)) as last_at
    from public.cm_plays p
    where p.season = p_season and p.lang = p_lang
      and (p_scope = 'top' or p.user_id = auth.uid() or p.user_id in (select public.friend_ids()))
    group by p.user_id
  ), fin as (
    select (row_number() over (order by pl.total_ms, pl.last_at))::integer as pos, pl.* from pl where pl.n >= 10
  ), run as (
    select (row_number() over (order by pl.n desc, pl.total_ms, pl.last_at))::integer as rk, pl.* from pl where pl.n < 10
  ), allr as (
    select f.pos, f.user_id, f.n, f.total_ms, f.pos as ord, 0 as grp from fin f
      where p_scope <> 'top' or f.pos <= 10 or f.user_id = auth.uid()
    union all
    select null::integer, r.user_id, r.n, r.total_ms, r.rk, 1 from run r
      where p_scope <> 'top' or r.rk <= 10 or r.user_id = auth.uid()
  )
  select a.pos, pr.pseudo, a.n, a.total_ms, coalesce(a.user_id = auth.uid(), false), (select count(*)::integer from fin)
  from allr a join public.profiles pr on pr.id = a.user_id
  order by a.grp, a.ord
$$;

-- 7) DROITS
revoke execute on function public.cm_begin(integer, text, integer, jsonb) from public, anon;
revoke execute on function public.cm_result(integer, text, integer, boolean, integer, text) from public, anon;
revoke execute on function public.cm_state(integer, text) from public, anon;
revoke execute on function public.cm_rank(integer, text, text) from public, anon;
grant execute on function public.cm_begin(integer, text, integer, jsonb) to authenticated;
grant execute on function public.cm_result(integer, text, integer, boolean, integer, text) to authenticated;
grant execute on function public.cm_state(integer, text) to authenticated;
grant execute on function public.cm_rank(integer, text, text) to authenticated;
