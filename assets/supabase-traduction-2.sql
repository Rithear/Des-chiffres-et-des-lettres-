-- =====================================================================
-- Des chiffres et des lettres — mise à jour v20, étape 2 : 🌍 Défi traduction
--   1) Match au tour par tour : le défi traduction peut être tiré au sort
--      (pour les nouveaux matchs ; les matchs en cours ne changent pas)
--   2) Contre-la-montre : le défi traduction entre dans le tirage
--      à partir de la saison 2 (lundi 16 novembre 2026) ; la saison 1 ne change pas
-- Le script « supabase-traduction.sql » (étape 1) doit avoir été lancé avant.
-- À coller tel quel dans Supabase › SQL Editor, puis « Run ».
-- Le script peut être relancé sans risque.
-- =====================================================================

-- 1) TOUR PAR TOUR : programme des matchs (le défi traduction s'écrit v)
do $$
declare c record;
begin
  for c in select con.conname from pg_constraint con
           join pg_attribute a on a.attrelid = con.conrelid and a.attnum = any(con.conkey)
           where con.conrelid = 'public.tb_matches'::regclass and con.contype = 'c' and a.attname = 'steps'
             and array_length(con.conkey, 1) = 1
  loop
    execute format('alter table public.tb_matches drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.tb_matches add constraint tb_matches_steps_check
  check (steps ~ '^[clwtkusv]{1,3}(\|[clwtkusv]{1,3}){3,5}$');

create or replace function public.tb_tick(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m public.tb_matches%rowtype;
  a public.tb_plays%rowtype;
  b public.tb_plays%rowtype;
  fa boolean; fb boolean;
  st text; n integer; k integer; g text;
  pa integer; pb integer; ea jsonb; eb jsonb;
  oka boolean; okb boolean; ta integer; tb integer;
begin
  select * into m from public.tb_matches where id = p_id for update;
  if not found then return; end if;
  if m.status = 'invite' then
    if m.created_at < now() - interval '3 days' then
      update public.tb_matches set status = 'expired', ended_at = now() where id = p_id;
    end if;
    return;
  end if;
  if m.status <> 'run' then return; end if;

  loop
    st := split_part(m.steps, '|', m.tour);
    n := char_length(st);
    select * into a from public.tb_plays where match_id = m.id and tour = m.tour and user_id = m.p1;
    fa := found;
    select * into b from public.tb_plays where match_id = m.id and tour = m.tour and user_id = m.p2;
    fb := found;
    if not (fa and a.done and fb and b.done) and not (m.tour_at < now() - interval '3 days') then
      exit;
    end if;

    -- délai dépassé : celui qui n'a pas commencé a manqué le tour, celui qui a commencé garde ce qu'il a fait
    if not fa then
      insert into public.tb_plays (match_id, tour, user_id, done, missed, done_at)
      values (m.id, m.tour, m.p1, true, true, now()) returning * into a;
    elsif not a.done then
      update public.tb_plays set done = true, busy = false, done_at = now()
      where match_id = m.id and tour = m.tour and user_id = m.p1 returning * into a;
    end if;
    if not fb then
      insert into public.tb_plays (match_id, tour, user_id, done, missed, done_at)
      values (m.id, m.tour, m.p2, true, true, now()) returning * into b;
    elsif not b.done then
      update public.tb_plays set done = true, busy = false, done_at = now()
      where match_id = m.id and tour = m.tour and user_id = m.p2 returning * into b;
    end if;

    -- points du tour
    pa := 0; pb := 0;
    for k in 0 .. n - 1 loop
      g := substr(st, k + 1, 1);
      ea := a.res -> k; eb := b.res -> k;
      if g in ('t','k','u','s','v') then
        -- défi : 7 points pour la bonne réponse la plus rapide
        oka := coalesce(ea ->> 'ok', '') = 'true';
        okb := coalesce(eb ->> 'ok', '') = 'true';
        ta := coalesce(public.tb_int(ea ->> 't', 0, 999999), 999999);
        tb := coalesce(public.tb_int(eb ->> 't', 0, 999999), 999999);
        if oka and (not okb or ta <= tb) then pa := pa + 7; end if;
        if okb and (not oka or tb <= ta) then pb := pb + 7; end if;
      else
        pa := pa + coalesce(public.tb_int(ea ->> 'p', 0, case when g = 'w' then 52 else 10 end), 0);
        pb := pb + coalesce(public.tb_int(eb ->> 'p', 0, case when g = 'w' then 52 else 10 end), 0);
      end if;
    end loop;
    update public.tb_plays set pts = pa where match_id = m.id and tour = m.tour and user_id = m.p1;
    update public.tb_plays set pts = pb where match_id = m.id and tour = m.tour and user_id = m.p2;

    m.s1 := m.s1 + pa;
    m.s2 := m.s2 + pb;
    m.miss1 := case when a.missed then m.miss1 + 1 else 0 end;
    m.miss2 := case when b.missed then m.miss2 + 1 else 0 end;
    if m.miss1 >= 2 or m.miss2 >= 2 then
      m.status := 'done'; m.reason := 'forfeit'; m.ended_at := now();
      m.winner := case when m.miss1 >= 2 and m.miss2 >= 2 then null when m.miss1 >= 2 then m.p2 else m.p1 end;
    elsif m.tour >= array_length(string_to_array(m.steps, '|'), 1) then
      m.status := 'done'; m.reason := 'end'; m.ended_at := now();
      m.winner := case when m.s1 > m.s2 then m.p1 when m.s2 > m.s1 then m.p2 else null end;
    else
      m.tour := m.tour + 1;
      m.tour_at := now();
    end if;
    update public.tb_matches
      set s1 = m.s1, s2 = m.s2, miss1 = m.miss1, miss2 = m.miss2, status = m.status, reason = m.reason,
          ended_at = m.ended_at, winner = m.winner, tour = m.tour, tour_at = m.tour_at
      where id = m.id;
    if m.status <> 'run' then exit; end if;
  end loop;
end $$;

create or replace function public.tb_create(p_friend uuid, p_kind text, p_dict text)
returns table (status text, id uuid) language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  d text;
  st text;
  nid uuid;
begin
  if uid is null then return query select 'auth'::text, null::uuid; return; end if;
  if p_kind not in ('n','q') or p_dict not in ('fr','en') or p_friend is null or p_friend = uid then
    return query select 'bad'::text, null::uuid; return;
  end if;
  if not exists (select 1 from public.friends f where f.accepted
                 and ((f.from_id = uid and f.to_id = p_friend) or (f.from_id = p_friend and f.to_id = uid))) then
    return query select 'notfriend'::text, null::uuid; return;
  end if;
  perform public.tb_tick_user(uid);
  perform public.tb_tick_user(p_friend);
  if public.tb_active(uid) >= 10 then return query select 'full'::text, null::uuid; return; end if;
  if public.tb_active(p_friend) >= 10 then return query select 'fullfr'::text, null::uuid; return; end if;
  -- défis tirés au hasard (2 différents pour la partie complète, 1 pour la courte)
  select string_agg(x, '') into d from (select x from unnest(array['t','k','u','s','v']) as x order by random() limit 2) z;
  st := case when p_kind = 'n' then 'cll|cll|' || d || '|cll|cll|w' else 'cl|' || substr(d, 1, 1) || '|cl|w' end;
  insert into public.tb_matches (p1, p2, kind, dict, steps) values (uid, p_friend, p_kind, p_dict, st) returning tb_matches.id into nid;
  return query select 'ok'::text, nid;
end $$;

create or replace function public.tb_result(p_match uuid, p_tour integer, p_idx integer, p_r jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  m public.tb_matches%rowtype;
  p public.tb_plays%rowtype;
  st text; n integer; g text; e jsonb; fin boolean;
begin
  if uid is null then return jsonb_build_object('e','auth'); end if;
  select * into m from public.tb_matches where id = p_match for update;
  if not found or uid not in (m.p1, m.p2) then return jsonb_build_object('e','notfound'); end if;
  if m.status <> 'run' or m.tour <> p_tour then return jsonb_build_object('e','late'); end if;
  select * into p from public.tb_plays where match_id = m.id and tour = m.tour and user_id = uid for update;
  if not found or p.done or not p.busy or jsonb_array_length(p.res) <> p_idx then
    return jsonb_build_object('e','state');
  end if;
  st := split_part(m.steps, '|', m.tour);
  n := char_length(st);
  g := substr(st, p_idx + 1, 1);
  if jsonb_typeof(p_r) <> 'object' then p_r := '{}'::jsonb; end if;
  e := jsonb_build_object(
    'g', g,
    'p', case when g in ('t','k','u','s','v') then 0 else coalesce(public.tb_int(p_r ->> 'p', 0, case when g = 'w' then 52 else 10 end), 0) end,
    'r', coalesce(public.tb_int(p_r ->> 'r', 0, 9999), 0),
    'x', left(coalesce(p_r ->> 'x', ''), 24),
    't', coalesce(public.tb_int(p_r ->> 't', 0, 600000), 0));
  if g in ('t','k','u','s','v') then e := e || jsonb_build_object('ok', coalesce(p_r ->> 'ok', '') = 'true'); end if;
  if coalesce(p_r ->> 'z', '') = '1' then e := e || jsonb_build_object('z', 1); end if;   -- épreuve quittée
  fin := p_idx + 1 >= n;
  update public.tb_plays set res = p.res || jsonb_build_array(e), busy = false, done = fin,
         done_at = case when fin then now() end
    where match_id = m.id and tour = m.tour and user_id = uid;
  perform public.tb_tick(m.id);
  select * into m from public.tb_matches where id = p_match;
  return jsonb_build_object('ok', 1, 'done', fin, 'tour', m.tour, 'status', m.status);
end $$;

-- 2) CONTRE-LA-MONTRE
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
      -- défi traduction (v) seulement à partir de la saison 2
      if g is null or g not in ('t','k','u','s','v') or (g = 'v' and cur < 2) then return jsonb_build_object('e','cand'); end if;
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

revoke execute on function public.tb_tick(uuid) from public, anon, authenticated;
revoke execute on function public.tb_create(uuid, text, text) from public, anon;
revoke execute on function public.tb_result(uuid, integer, integer, jsonb) from public, anon;
grant execute on function public.tb_create(uuid, text, text) to authenticated;
grant execute on function public.tb_result(uuid, integer, integer, jsonb) to authenticated;
revoke execute on function public.cm_begin(integer, text, integer, jsonb) from public, anon;
grant execute on function public.cm_begin(integer, text, integer, jsonb) to authenticated;
