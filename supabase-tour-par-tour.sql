-- ============================================================================
-- Des chiffres et des lettres v14 : match au tour par tour (entre amis, avec un compte)
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Ne touche à aucun résultat déjà enregistré (comptes, amis, partie du jour,
-- multijoueur, statistiques). On peut le relancer sans risque.
-- ============================================================================
--
-- Déroulement :
--   * un joueur invite un ami (partie complète en 6 tours ou courte en 4 tours,
--     langue choisie par le créateur) ; l'ami a 3 jours pour accepter ;
--   * chaque tour regroupe plusieurs épreuves ; chacun le joue quand il veut ;
--     le tour suivant se débloque quand les deux ont joué, ou au bout de 3 jours
--     (celui qui n'a pas joué marque 0 point sur le tour) ;
--   * 2 tours manqués d'affilée = défaite par forfait ;
--   * défis : 7 points pour la bonne réponse la plus rapide des deux ;
--   * le tirage d'une épreuve n'est donné qu'au moment de la jouer, et une
--     épreuve commencée puis quittée compte 0 point (on ne peut pas la rejouer).
--
-- Tours (lettres : c = chiffres, l = lettres, w = mots de la fin, t/k/u/s = défis)
--   partie complète : cll | cll | 2 défis | cll | cll | w
--   partie courte   : cl  | 1 défi | cl | w

-- 1) LES MATCHS
create table if not exists public.tb_matches (
  id uuid primary key default gen_random_uuid(),
  p1 uuid not null references auth.users(id) on delete cascade,          -- celui qui invite
  p2 uuid not null references auth.users(id) on delete cascade,          -- l'ami invité
  kind text not null check (kind in ('n','q')),                          -- n = complète, q = courte
  dict text not null check (dict in ('fr','en')),
  steps text not null check (steps ~ '^[clwtkus]{1,3}(\|[clwtkus]{1,3}){3,5}$'),
  status text not null default 'invite' check (status in ('invite','run','done','declined','expired','cancel')),
  tour integer not null default 0,                                       -- tour en cours (0 = invitation)
  tour_at timestamptz,                                                   -- début du tour en cours
  s1 integer not null default 0,
  s2 integer not null default 0,
  miss1 integer not null default 0,                                      -- tours manqués d'affilée
  miss2 integer not null default 0,
  winner uuid,
  reason text check (reason in ('end','forfeit','abandon')),
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  check (p1 <> p2)
);
create index if not exists tb_matches_p1_idx on public.tb_matches (p1, status);
create index if not exists tb_matches_p2_idx on public.tb_matches (p2, status);
alter table public.tb_matches enable row level security;
revoke all on public.tb_matches from anon, authenticated;

-- 2) CE QUE CHAQUE JOUEUR A FAIT À CHAQUE TOUR (une entrée par épreuve dans res)
create table if not exists public.tb_plays (
  match_id uuid not null references public.tb_matches(id) on delete cascade,
  tour integer not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  res jsonb not null default '[]'::jsonb,
  busy boolean not null default false,                                   -- une épreuve est en cours
  done boolean not null default false,
  missed boolean not null default false,                                 -- n'a pas joué le tour à temps
  pts integer,                                                           -- points du tour (une fois le tour terminé)
  started_at timestamptz not null default now(),
  done_at timestamptz,
  primary key (match_id, tour, user_id)
);
alter table public.tb_plays enable row level security;
revoke all on public.tb_plays from anon, authenticated;

-- 3) LES TIRAGES (fixés par le premier des deux qui joue l'épreuve, identiques pour l'autre)
create table if not exists public.tb_draws (
  match_id uuid not null references public.tb_matches(id) on delete cascade,
  tour integer not null,
  idx integer not null,
  d jsonb not null,
  primary key (match_id, tour, idx)
);
alter table public.tb_draws enable row level security;
revoke all on public.tb_draws from anon, authenticated;

-- ============================================================================
-- OUTILS INTERNES (pas appelables depuis le jeu)
-- ============================================================================

-- Nombre entier lu dans un texte, borné (null si ce n'est pas un nombre)
create or replace function public.tb_int(p text, lo integer, hi integer)
returns integer language sql immutable set search_path = '' as $$
  select case when p ~ '^-?[0-9]{1,9}$' then least(hi, greatest(lo, p::integer)) else null end
$$;

-- Fait avancer un match : invitation expirée, tour terminé (les deux ont joué ou délai
-- de 3 jours dépassé), calcul des points, forfait, fin du match
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
      if g in ('t','k','u','s') then
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

-- Fait avancer tous les matchs en cours d'un joueur
create or replace function public.tb_tick_user(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select id from public.tb_matches where (p1 = p_user or p2 = p_user) and status in ('invite','run') order by id loop
    perform public.tb_tick(r.id);
  end loop;
end $$;

-- Nombre de matchs en cours (invitations comprises) d'un joueur
create or replace function public.tb_active(p_user uuid)
returns integer language sql security definer set search_path = '' stable as $$
  select count(*)::integer from public.tb_matches where (p1 = p_user or p2 = p_user) and status in ('invite','run')
$$;

-- ============================================================================
-- FONCTIONS APPELÉES PAR LE JEU
-- ============================================================================

-- Inviter un ami. status : 'ok', 'auth', 'bad', 'notfriend', 'full' (j'ai déjà 10 matchs), 'fullfr' (lui aussi)
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
  select string_agg(x, '') into d from (select x from unnest(array['t','k','u','s']) as x order by random() limit 2) z;
  st := case when p_kind = 'n' then 'cll|cll|' || d || '|cll|cll|w' else 'cl|' || substr(d, 1, 1) || '|cl|w' end;
  insert into public.tb_matches (p1, p2, kind, dict, steps) values (uid, p_friend, p_kind, p_dict, st) returning tb_matches.id into nid;
  return query select 'ok'::text, nid;
end $$;

-- Répondre à une invitation (true = accepter). Réponses : 'ok', 'auth', 'notfound', 'expired', 'full'
create or replace function public.tb_answer(p_match uuid, p_ok boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  m public.tb_matches%rowtype;
begin
  if uid is null then return 'auth'; end if;
  perform public.tb_tick(p_match);
  select * into m from public.tb_matches where id = p_match for update;
  if not found or m.p2 <> uid then return 'notfound'; end if;
  if m.status <> 'invite' then return 'expired'; end if;
  if not p_ok then
    update public.tb_matches set status = 'declined', ended_at = now() where id = p_match;
    return 'ok';
  end if;
  perform public.tb_tick_user(uid);
  if public.tb_active(uid) > 10 then return 'full'; end if;   -- l'invitation elle-même compte déjà
  update public.tb_matches set status = 'run', tour = 1, tour_at = now() where id = p_match;
  return 'ok';
end $$;

-- Annuler mon invitation, ou abandonner un match en cours (l'autre gagne). Réponses : 'ok', 'auth', 'notfound', 'over'
create or replace function public.tb_leave(p_match uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  m public.tb_matches%rowtype;
begin
  if uid is null then return 'auth'; end if;
  perform public.tb_tick(p_match);
  select * into m from public.tb_matches where id = p_match for update;
  if not found or uid not in (m.p1, m.p2) then return 'notfound'; end if;
  if m.status = 'invite' then
    update public.tb_matches set status = case when uid = m.p1 then 'cancel' else 'declined' end, ended_at = now() where id = p_match;
    return 'ok';
  end if;
  if m.status <> 'run' then return 'over'; end if;
  update public.tb_matches set status = 'done', reason = 'abandon', ended_at = now(),
         winner = case when uid = m.p1 then m.p2 else m.p1 end
    where id = p_match;
  return 'ok';
end $$;

-- Commencer l'épreuve suivante du tour. p_idx = l'épreuve que le jeu pense jouer,
-- p_cand = un tirage proposé (gardé seulement si c'est le premier des deux à jouer cette épreuve).
-- Réponse : {tour, idx, d} ou {e: 'auth'|'notfound'|'over'|'done'|'idx'|'cand', tour, idx, g}
create or replace function public.tb_begin(p_match uuid, p_idx integer, p_cand jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  m public.tb_matches%rowtype;
  p public.tb_plays%rowtype;
  st text; n integer; i integer; g text; dr jsonb;
begin
  if uid is null then return jsonb_build_object('e','auth'); end if;
  perform public.tb_tick(p_match);
  select * into m from public.tb_matches where id = p_match for update;
  if not found or uid not in (m.p1, m.p2) then return jsonb_build_object('e','notfound'); end if;
  if m.status <> 'run' then return jsonb_build_object('e','over'); end if;
  st := split_part(m.steps, '|', m.tour);
  n := char_length(st);
  select * into p from public.tb_plays where match_id = m.id and tour = m.tour and user_id = uid for update;
  if not found then
    insert into public.tb_plays (match_id, tour, user_id) values (m.id, m.tour, uid) returning * into p;
  end if;
  if p.done then return jsonb_build_object('e','done','tour',m.tour); end if;
  i := jsonb_array_length(p.res);
  if p.busy then
    -- l'épreuve précédente a été quittée ou interrompue : 0 point
    p.res := p.res || jsonb_build_array(jsonb_build_object('g', substr(st, i + 1, 1), 'z', 1));
    i := i + 1;
    update public.tb_plays set res = p.res, busy = false, done = (i >= n), done_at = case when i >= n then now() end
      where match_id = m.id and tour = m.tour and user_id = uid;
    if i >= n then
      perform public.tb_tick(m.id);
      return jsonb_build_object('e','done','tour',m.tour);
    end if;
  end if;
  g := substr(st, i + 1, 1);
  if p_idx is distinct from i then return jsonb_build_object('e','idx','tour',m.tour,'idx',i,'g',g); end if;
  select d into dr from public.tb_draws where match_id = m.id and tour = m.tour and idx = i;
  if not found then
    if p_cand is null or jsonb_typeof(p_cand) <> 'object' or (p_cand ->> 'g') is distinct from g or char_length(p_cand::text) > 6000 then
      return jsonb_build_object('e','cand','tour',m.tour,'idx',i,'g',g);
    end if;
    insert into public.tb_draws (match_id, tour, idx, d) values (m.id, m.tour, i, p_cand);
    dr := p_cand;
  end if;
  update public.tb_plays set busy = true where match_id = m.id and tour = m.tour and user_id = uid;
  return jsonb_build_object('tour', m.tour, 'idx', i, 'd', dr);
end $$;

-- Enregistrer le résultat de l'épreuve en cours.
-- p_r : {p: points, r: résultat, x: réponse, t: temps en ms, ok: bonne réponse (défis)}
-- Réponse : {ok: 1, done: tour fini pour moi, tour: tour en cours du match, status} ou {e: ...}
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
    'p', case when g in ('t','k','u','s') then 0 else coalesce(public.tb_int(p_r ->> 'p', 0, case when g = 'w' then 52 else 10 end), 0) end,
    'r', coalesce(public.tb_int(p_r ->> 'r', 0, 9999), 0),
    'x', left(coalesce(p_r ->> 'x', ''), 24),
    't', coalesce(public.tb_int(p_r ->> 't', 0, 600000), 0));
  if g in ('t','k','u','s') then e := e || jsonb_build_object('ok', coalesce(p_r ->> 'ok', '') = 'true'); end if;
  if coalesce(p_r ->> 'z', '') = '1' then e := e || jsonb_build_object('z', 1); end if;   -- épreuve quittée
  fin := p_idx + 1 >= n;
  update public.tb_plays set res = p.res || jsonb_build_array(e), busy = false, done = fin,
         done_at = case when fin then now() end
    where match_id = m.id and tour = m.tour and user_id = uid;
  perform public.tb_tick(m.id);
  select * into m from public.tb_matches where id = p_match;
  return jsonb_build_object('ok', 1, 'done', fin, 'tour', m.tour, 'status', m.status);
end $$;

-- Mes matchs : en cours, invitations, et terminés (les 300 derniers)
create or replace function public.tb_list()
returns table (id uuid, opp uuid, opp_name text, first boolean, kind text, dict text, steps text, status text,
               tour integer, tour_at timestamptz, my_score integer, opp_score integer,
               my_idx integer, my_busy boolean, my_done boolean, opp_done boolean,
               my_miss integer, opp_miss integer, result text, reason text, created_at timestamptz, ended_at timestamptz)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then return; end if;
  perform public.tb_tick_user(uid);
  return query
  select m.id,
         case when m.p1 = uid then m.p2 else m.p1 end,
         coalesce(pr.pseudo, '?'),
         m.p1 = uid,
         m.kind, m.dict, m.steps, m.status, m.tour, m.tour_at,
         case when m.p1 = uid then m.s1 else m.s2 end,
         case when m.p1 = uid then m.s2 else m.s1 end,
         case when mp.user_id is null then null else jsonb_array_length(mp.res) end,
         coalesce(mp.busy, false),
         coalesce(mp.done, false),
         coalesce(op.done, false),
         case when m.p1 = uid then m.miss1 else m.miss2 end,
         case when m.p1 = uid then m.miss2 else m.miss1 end,
         case when m.status <> 'done' then null when m.winner is null then 'draw' when m.winner = uid then 'win' else 'loss' end,
         m.reason, m.created_at, m.ended_at
  from public.tb_matches m
  left join public.profiles pr on pr.id = case when m.p1 = uid then m.p2 else m.p1 end
  left join public.tb_plays mp on mp.match_id = m.id and mp.tour = m.tour and mp.user_id = uid
  left join public.tb_plays op on op.match_id = m.id and op.tour = m.tour and op.user_id <> uid
  where m.p1 = uid or m.p2 = uid
  order by (m.status in ('invite','run')) desc, coalesce(m.ended_at, m.created_at) desc
  limit 300;
end $$;

-- Le détail d'un match, tour par tour. Les réponses et les tirages de l'adversaire
-- ne sont visibles qu'une fois le tour terminé.
create or replace function public.tb_detail(p_match uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  m public.tb_matches%rowtype;
  ot uuid; k integer; nt integer; rv boolean;
  mp public.tb_plays%rowtype; op public.tb_plays%rowtype; fm boolean; fo boolean;
  acc jsonb := '[]'::jsonb; dr jsonb; lim integer;
begin
  if uid is null then return null; end if;
  perform public.tb_tick(p_match);
  select * into m from public.tb_matches where id = p_match;
  if not found or uid not in (m.p1, m.p2) then return null; end if;
  ot := case when m.p1 = uid then m.p2 else m.p1 end;
  nt := case when m.status = 'run' then m.tour when m.status = 'done' then greatest(m.tour, 1) else 0 end;
  for k in 1 .. nt loop
    select * into mp from public.tb_plays where match_id = m.id and tour = k and user_id = uid; fm := found;
    select * into op from public.tb_plays where match_id = m.id and tour = k and user_id = ot; fo := found;
    rv := k < m.tour or m.status <> 'run';
    lim := case when rv then 99 when fm then jsonb_array_length(mp.res) else 0 end;
    select coalesce(jsonb_agg(jsonb_build_object('i', x.idx, 'd', x.d) order by x.idx), '[]'::jsonb) into dr
      from public.tb_draws x where x.match_id = m.id and x.tour = k and x.idx < lim;
    acc := acc || jsonb_build_array(jsonb_build_object(
      'tour', k, 'rv', rv, 'draws', dr,
      'me', case when fm then jsonb_build_object('res', mp.res, 'pts', mp.pts, 'missed', mp.missed, 'done', mp.done, 'busy', mp.busy) end,
      'opp', case when not fo then null
                  when rv then jsonb_build_object('res', op.res, 'pts', op.pts, 'missed', op.missed, 'done', op.done)
                  else jsonb_build_object('done', op.done) end));
  end loop;
  return jsonb_build_object('tours', acc);
end $$;

-- Droits d'exécution
revoke execute on function public.tb_int(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.tb_tick(uuid) from public, anon, authenticated;
revoke execute on function public.tb_tick_user(uuid) from public, anon, authenticated;
revoke execute on function public.tb_active(uuid) from public, anon, authenticated;
revoke execute on function public.tb_create(uuid, text, text) from public, anon;
revoke execute on function public.tb_answer(uuid, boolean) from public, anon;
revoke execute on function public.tb_leave(uuid) from public, anon;
revoke execute on function public.tb_begin(uuid, integer, jsonb) from public, anon;
revoke execute on function public.tb_result(uuid, integer, integer, jsonb) from public, anon;
revoke execute on function public.tb_list() from public, anon;
revoke execute on function public.tb_detail(uuid) from public, anon;
grant execute on function public.tb_create(uuid, text, text) to authenticated;
grant execute on function public.tb_answer(uuid, boolean) to authenticated;
grant execute on function public.tb_leave(uuid) to authenticated;
grant execute on function public.tb_begin(uuid, integer, jsonb) to authenticated;
grant execute on function public.tb_result(uuid, integer, integer, jsonb) to authenticated;
grant execute on function public.tb_list() to authenticated;
grant execute on function public.tb_detail(uuid) to authenticated;
