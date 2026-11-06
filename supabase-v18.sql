-- =====================================================================
-- Des chiffres et des lettres — mise à jour v18
--   1) Les 4 défis (thème, calcul mental, l'un dans l'autre, orthographe)
--      acceptés dans les duels entre amis
--   2) Records : classement entre amis (toi + tes amis)
-- À coller tel quel dans Supabase › SQL Editor, puis « Run ».
-- Le script peut être relancé sans risque.
-- =====================================================================

-- 1) DUELS : accepter les défis (codes t, k, u, s) en plus de l, c, w
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.duel_sends'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%game%'
  loop
    execute format('alter table public.duel_sends drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.duel_sends add constraint duel_sends_game_check
  check (game in ('l','c','w','t','k','u','s'));

create or replace function public.duel_send(p_duel text, p_game text, p_payload jsonb, p_friends uuid[])
returns table (friend uuid, status text) language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  f uuid;
begin
  if uid is null then return query select null::uuid, 'auth'::text; return; end if;
  if p_duel is null or p_duel !~ '^[a-z0-9]{6,16}$' or p_game not in ('l','c','w','t','k','u','s')
     or p_payload is null or jsonb_typeof(p_payload) <> 'object' or octet_length(p_payload::text) > 20000
     or p_friends is null or coalesce(array_length(p_friends, 1), 0) < 1 or array_length(p_friends, 1) > 50 then
    return query select null::uuid, 'bad'::text; return;
  end if;
  -- un duel appartient à un seul joueur
  if exists (select 1 from public.duel_sends d where d.duel = p_duel and d.from_id <> uid) then
    return query select null::uuid, 'bad'::text; return;
  end if;
  for f in select distinct x from unnest(p_friends) as x loop
    if f is null or f = uid or not exists (
         select 1 from public.friends fr where fr.accepted
         and ((fr.from_id = uid and fr.to_id = f) or (fr.from_id = f and fr.to_id = uid))) then
      return query select f, 'notfriend'::text;
    elsif exists (select 1 from public.duel_sends d where d.duel = p_duel and d.to_id = f and d.status <> 'cancel') then
      return query select f, 'already'::text;
    elsif (select count(*) from public.duel_sends d where d.to_id = f and d.status in ('wait','run')
           and d.created_at > now() - interval '7 days') >= 50 then
      return query select f, 'fullfr'::text;
    else
      delete from public.duel_sends d where d.duel = p_duel and d.to_id = f and d.status = 'cancel';
      insert into public.duel_sends (duel, from_id, to_id, game, payload) values (p_duel, uid, f, p_game, p_payload);
      return query select f, 'ok'::text;
    end if;
  end loop;
end $$;

revoke execute on function public.duel_send(text, text, jsonb, uuid[]) from public, anon;
grant execute on function public.duel_send(text, text, jsonb, uuid[]) to authenticated;

-- 2) RECORDS ENTRE AMIS : mon meilleur résultat et celui de chacun de mes amis
--    (mêmes règles que top_records, mais limité à moi + mes amis)
create or replace function public.top_records_friends(p_g text, p_dict text default null)
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
      and (p.user_id = auth.uid() or p.user_id in (select public.friend_ids()))
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
  order by r.rk
  limit 200
$$;

revoke execute on function public.top_records_friends(text, text) from public, anon;
grant execute on function public.top_records_friends(text, text) to authenticated;
