-- =====================================================================
-- Des chiffres et des lettres — v19.1 : statistiques du ⏱ Contre-la-montre
-- (à lancer après supabase-contre-la-montre.sql)
-- À coller tel quel dans Supabase › SQL Editor, puis « Run ».
-- Le script peut être relancé sans risque.
-- =====================================================================

-- Mes statistiques : mes saisons (temps, place) et mes épreuves, en français et en anglais
create or replace function public.cm_my_stats()
returns jsonb language sql security definer set search_path = '' stable as $$
  with mine as (
    select distinct season, lang from public.cm_plays where user_id = auth.uid()
  ), pl as (
    select p.season, p.lang, p.user_id,
           count(*) filter (where p.done or public.cm_stale(p.done, p.started_at))::integer as n,
           coalesce(sum(case when p.done then p.time_ms when public.cm_stale(p.done, p.started_at) then public.cm_max(p.idx) else 0 end), 0)::bigint as total_ms,
           max(coalesce(p.finished_at, p.started_at)) as last_at
    from public.cm_plays p join mine m on m.season = p.season and m.lang = p.lang
    group by p.season, p.lang, p.user_id
  ), fin as (
    select pl.season, pl.lang, pl.user_id,
           (row_number() over (partition by pl.season, pl.lang order by pl.total_ms, pl.last_at))::integer as pos,
           (count(*) over (partition by pl.season, pl.lang))::integer as nfin
    from pl where pl.n >= 10
  )
  select jsonb_build_object(
    'cur', public.cm_season_at(now()),
    'seasons', coalesce((select jsonb_agg(jsonb_build_object('season', pl.season, 'lang', pl.lang, 'n', pl.n, 'total_ms', pl.total_ms,
        'pos', f.pos, 'nfin', coalesce(f.nfin, (select count(*) from fin f2 where f2.season = pl.season and f2.lang = pl.lang)))
        order by pl.season, pl.lang)
      from pl left join fin f on f.season = pl.season and f.lang = pl.lang and f.user_id = pl.user_id
      where pl.user_id = auth.uid()), '[]'::jsonb),
    'plays', coalesce((select jsonb_agg(jsonb_build_object('season', p.season, 'lang', p.lang, 'idx', p.idx,
        'g', (select d.d ->> 'g' from public.cm_draws d where d.season = p.season and d.lang = p.lang and d.idx = p.idx),
        'ok', p.done and p.ok, 'ms', case when p.done then p.time_ms else public.cm_max(p.idx) end))
      from public.cm_plays p where p.user_id = auth.uid() and (p.done or public.cm_stale(p.done, p.started_at))), '[]'::jsonb))
$$;

revoke execute on function public.cm_my_stats() from public, anon;
grant execute on function public.cm_my_stats() to authenticated;
