-- ============================================================================
-- Des chiffres et des lettres v21 : notifications sur le téléphone
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Ne touche à aucun résultat déjà enregistré (comptes, amis, duels, tour par
-- tour, statistiques…). On peut le relancer sans risque.
-- ============================================================================
--
-- Déroulement :
--   * le joueur active les notifications dans ⚙️ Réglages : son téléphone est
--     enregistré dans push_subs (un compte peut avoir plusieurs appareils) ;
--   * quand il se passe quelque chose (demande d'ami, duel, invitation ou tour
--     au tour par tour), une notification est mise en attente dans push_queue ;
--   * chaque minute, push_cron() prépare les rappels (24 h et 48 h après le début
--     d'un tour pas encore joué), vérifie que chaque notification est toujours
--     utile, puis les confie à la fonction « push » qui les envoie aux téléphones ;
--   * rien n'est envoyé entre 22 h et 8 h (heure française) : les notifications
--     de la nuit partent à 8 h, sauf si elles ne servent plus à rien.
--
-- Pour tout arrêter un jour : select cron.unschedule('dcl-notifications');

-- 0) OUTILS DE SUPABASE : planificateur (pg_cron) et appels web (pg_net)
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- 1) LES TÉLÉPHONES QUI ACCEPTENT LES NOTIFICATIONS
create table if not exists public.push_subs (
  endpoint text primary key,                                             -- adresse fournie par le navigateur
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  lang text not null default 'fr' check (lang in ('fr','en')),           -- langue des notifications
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists push_subs_user_idx on public.push_subs (user_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

-- 2) CE QUE CHAQUE JOUEUR VEUT RECEVOIR
create table if not exists public.push_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  amis boolean not null default true,                                    -- demandes d'ami
  defis boolean not null default true,                                   -- duels et invitations à un match
  tours boolean not null default true,                                   -- c'est ton tour
  rappels boolean not null default true,                                 -- rappels 24 h et 48 h
  updated_at timestamptz not null default now()
);
alter table public.push_prefs enable row level security;
revoke all on public.push_prefs from anon, authenticated;

-- 3) LES NOTIFICATIONS EN ATTENTE D'ENVOI
create table if not exists public.push_queue (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,                                                    -- fr, fracc, duel, tbinv, tbgo, tbturn, rem1, rem2, test
  ref text not null default '',                                          -- demande, duel ou match concerné
  tour integer not null default 0,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists push_queue_user_idx on public.push_queue (user_id, kind, ref);
alter table public.push_queue enable row level security;
revoke all on public.push_queue from anon, authenticated;

-- 4) RAPPELS DÉJÀ PRÉPARÉS (pour ne jamais envoyer deux fois le même)
create table if not exists public.push_rem (
  match_id uuid not null references public.tb_matches(id) on delete cascade,
  tour integer not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  n integer not null,                                                    -- 1 = 24 h, 2 = 48 h
  at timestamptz not null default now(),
  primary key (match_id, tour, user_id, n)
);
alter table public.push_rem enable row level security;
revoke all on public.push_rem from anon, authenticated;

-- ============================================================================
-- OUTILS INTERNES (pas appelables depuis le jeu)
-- ============================================================================

-- Met une notification en attente (seulement si le joueur a un téléphone enregistré).
-- Une nouvelle notification du même type pour le même objet remplace l'ancienne.
create or replace function public.push_add(p_user uuid, p_kind text, p_ref text, p_tour integer, p_data jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or not exists (select 1 from public.push_subs s where s.user_id = p_user) then return; end if;
  delete from public.push_queue q where q.user_id = p_user and q.kind = p_kind and q.ref = coalesce(p_ref, '');
  insert into public.push_queue (user_id, kind, ref, tour, data)
  values (p_user, p_kind, coalesce(p_ref, ''), coalesce(p_tour, 0), coalesce(p_data, '{}'::jsonb));
end $$;

-- Demandes d'ami (nouvelle demande, demande acceptée)
create or replace function public.push_trg_friends()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_op = 'INSERT' and not new.accepted then
      perform public.push_add(new.to_id, 'fr', new.id::text, 0, jsonb_build_object('u', new.from_id));
    elsif tg_op = 'UPDATE' and new.accepted and not old.accepted then
      perform public.push_add(new.from_id, 'fracc', new.id::text, 0, jsonb_build_object('u', new.to_id));
    end if;
  exception when others then null;   -- une notification ne doit jamais bloquer le jeu
  end;
  return null;
end $$;
drop trigger if exists push_friends on public.friends;
create trigger push_friends after insert or update of accepted on public.friends
  for each row execute function public.push_trg_friends();

-- Duels entre amis
create or replace function public.push_trg_duels()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if new.status = 'wait' then
      perform public.push_add(new.to_id, 'duel', new.id::text, 0, jsonb_build_object('u', new.from_id, 'g', new.game));
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_duels on public.duel_sends;
create trigger push_duels after insert on public.duel_sends
  for each row execute function public.push_trg_duels();

-- Match au tour par tour : invitation, puis chaque nouveau tour.
-- Celui dont l'action ouvre le tour est déjà dans le jeu : seul l'autre est prévenu.
create or replace function public.push_trg_tb()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  me uuid;
begin
  begin
    if tg_op = 'INSERT' then
      if new.status = 'invite' then
        perform public.push_add(new.p2, 'tbinv', new.id::text, 0, jsonb_build_object('u', new.p1));
      end if;
    elsif new.status = 'run' and new.tour is distinct from old.tour then
      me := auth.uid();
      if new.p1 is distinct from me then
        perform public.push_add(new.p1, case when new.tour = 1 then 'tbgo' else 'tbturn' end, new.id::text, new.tour, jsonb_build_object('u', new.p2));
      end if;
      if new.p2 is distinct from me then
        perform public.push_add(new.p2, 'tbturn', new.id::text, new.tour, jsonb_build_object('u', new.p1));
      end if;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_tb on public.tb_matches;
create trigger push_tb after insert or update of tour, status on public.tb_matches
  for each row execute function public.push_trg_tb();

-- Temps restant avant la fin d'un tour, en clair
create or replace function public.push_left(p_until timestamptz, p_lang text)
returns text language plpgsql stable set search_path = '' as $$
declare h integer := greatest(1, floor(extract(epoch from (p_until - now())) / 3600)::integer);
begin
  if h >= 24 then
    return case when p_lang = 'en' then (h / 24) || 'd ' || (h % 24) || 'h' else (h / 24) || ' j ' || (h % 24) || ' h' end;
  end if;
  return h || ' h';
end $$;

-- Texte d'une notification : {t: titre, b: texte}
create or replace function public.push_text(p_kind text, p_lang text, n text, g text, k integer, nt integer, lft text)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare en boolean := p_lang = 'en';
begin
  return case p_kind
    when 'fr' then jsonb_build_object('t', case when en then '👥 Friend request' else '👥 Demande d''ami' end,
      'b', case when en then n || ' wants to be your friend.' else n || ' veut devenir ton ami.' end)
    when 'fracc' then jsonb_build_object('t', case when en then '👥 New friend' else '👥 Nouvel ami' end,
      'b', case when en then n || ' accepted your friend request.' else n || ' a accepté ta demande d''ami.' end)
    when 'duel' then jsonb_build_object('t', case when en then '⚔️ New duel' else '⚔️ Nouveau duel' end,
      'b', case when en then n || ' sent you a duel (' || g || '). You have 7 days to take it on!'
                else n || ' te lance un duel (' || g || '). Tu as 7 jours pour le relever !' end)
    when 'tbinv' then jsonb_build_object('t', case when en then '🎲 Turn-based match' else '🎲 Match au tour par tour' end,
      'b', case when en then n || ' invites you to a match. Accept it within 3 days!'
                else n || ' t''invite à un match. Accepte-le sous 3 jours !' end)
    when 'tbgo' then jsonb_build_object('t', case when en then '🎲 Game on!' else '🎲 C''est parti !' end,
      'b', case when en then n || ' accepted your match: your turn to play round 1/' || nt || '.'
                else n || ' a accepté ton match : à toi de jouer le tour 1/' || nt || '.' end)
    when 'tbturn' then jsonb_build_object('t', case when en then '🎲 Your turn!' else '🎲 À toi de jouer !' end,
      'b', case when en then 'Round ' || k || '/' || nt || ' against ' || n || ' is open.'
                else 'Le tour ' || k || '/' || nt || ' contre ' || n || ' est ouvert.' end)
    when 'rem1' then jsonb_build_object('t', case when en then '⏰ Your turn is waiting' else '⏰ Ton tour t''attend' end,
      'b', case when en then 'Against ' || n || ': ' || lft || ' left to play round ' || k || '/' || nt || '.'
                else 'Contre ' || n || ' : plus que ' || lft || ' pour jouer le tour ' || k || '/' || nt || '.' end)
    when 'rem2' then jsonb_build_object('t', case when en then '⏰ Last reminder' else '⏰ Dernier rappel' end,
      'b', case when en then 'Against ' || n || ': ' || lft || ' left to play round ' || k || '/' || nt || ', or it will count as 0 points.'
                else 'Contre ' || n || ' : plus que ' || lft || ' pour jouer le tour ' || k || '/' || nt || ', sinon il comptera 0 point.' end)
    else jsonb_build_object('t', case when en then '🔔 Notifications on' else '🔔 Notifications activées' end,
      'b', case when en then 'Everything works: you will be notified on this phone.'
                else 'Tout fonctionne : tu seras prévenu sur ce téléphone.' end)
  end;
end $$;

-- Nom d'un jeu (pour les duels)
create or replace function public.push_game(g text, p_lang text)
returns text language sql immutable set search_path = '' as $$
  select case when p_lang = 'en' then
    case g when 'l' then 'Longest Word' when 'c' then 'Countdown Numbers' when 'w' then 'Final Words'
           when 't' then 'Theme challenge' when 'k' then 'Mental maths challenge' when 'u' then 'One inside the other'
           when 's' then 'Spelling challenge' when 'v' then 'Translation challenge' else 'Duel' end
  else
    case g when 'l' then 'Le mot le plus long' when 'c' then 'Le compte est bon' when 'w' then 'Les mots de la fin'
           when 't' then 'Défi thème' when 'k' then 'Défi calcul mental' when 'u' then 'L''un dans l''autre'
           when 's' then 'Défi orthographe' when 'v' then 'Défi traduction' else 'Duel' end
  end
$$;

-- Sort les notifications prêtes de la file : vérifie qu'elles servent encore et que le
-- joueur les veut, puis prépare un message par téléphone.
-- p_all = false : la nuit, seule la notification de test part.
create or replace function public.push_take(p_all boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  q record; s record; m public.tb_matches%rowtype;
  ok boolean; pf public.push_prefs%rowtype; nm text; nt integer; tx jsonb;
  url text; tag text;
  out jsonb := '[]'::jsonb;
begin
  for q in select * from public.push_queue x where p_all or x.kind = 'test' order by x.id limit 300 loop
    delete from public.push_queue where id = q.id;
    begin
      ok := q.created_at > now() - interval '3 days';
      m := null;
      if ok and q.kind in ('tbinv','tbgo','tbturn','rem1','rem2') then
        select * into m from public.tb_matches where id = q.ref::uuid;
        ok := found;
      end if;
      if ok then
        ok := case q.kind
          when 'test' then true
          when 'fr' then exists (select 1 from public.friends f where f.id = q.ref::bigint and not f.accepted and f.to_id = q.user_id)
          when 'fracc' then exists (select 1 from public.friends f where f.id = q.ref::bigint and f.accepted)
          when 'duel' then exists (select 1 from public.duel_sends d where d.id = q.ref::uuid and d.status = 'wait'
                                   and d.created_at > now() - interval '7 days')
          when 'tbinv' then m.status = 'invite' and m.created_at > now() - interval '3 days'
          else m.status = 'run' and m.tour = q.tour and m.tour_at > now() - interval '3 days'
               and not exists (select 1 from public.tb_plays p where p.match_id = m.id and p.tour = m.tour
                               and p.user_id = q.user_id and p.done)
        end;
      end if;
      if ok and q.kind <> 'test' then
        select * into pf from public.push_prefs where user_id = q.user_id;
        if found then
          ok := case when q.kind in ('fr','fracc') then pf.amis
                     when q.kind in ('duel','tbinv') then pf.defis
                     when q.kind in ('tbgo','tbturn') then pf.tours
                     else pf.rappels end;
        end if;
      end if;
      if ok then
        select pseudo into nm from public.profiles where id = (q.data ->> 'u')::uuid;
        nm := coalesce(nm, '?');
        nt := case when m.id is null then 0 else coalesce(array_length(string_to_array(m.steps, '|'), 1), 0) end;
        url := case when q.kind in ('fr','fracc') then './?nf=fr'
                    when q.kind = 'duel' then './?nf=da'
                    when q.kind = 'test' then './'
                    else './?nf=tb&m=' || q.ref end;
        tag := case when q.kind in ('fr','fracc') then 'fr-' || q.ref
                    when q.kind = 'duel' then 'da-' || q.ref
                    when q.kind = 'test' then 'test'
                    else 'tb-' || q.ref end;
        for s in select * from public.push_subs where user_id = q.user_id loop
          tx := public.push_text(q.kind, s.lang, nm, public.push_game(q.data ->> 'g', s.lang), q.tour, nt,
                                 case when m.id is null then '' else public.push_left(m.tour_at + interval '3 days', s.lang) end);
          out := out || jsonb_build_array(jsonb_build_object('e', s.endpoint, 'k', s.p256dh, 'a', s.auth,
                   'p', (tx || jsonb_build_object('u', url, 'g', tag))::text));
        end loop;
      end if;
    exception when others then null;   -- une notification abîmée est simplement oubliée
    end;
  end loop;
  return out;
end $$;

-- Travail de chaque minute (lancé par pg_cron)
create or replace function public.push_cron()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record; h integer; batch jsonb; o uuid;
begin
  -- 1) les matchs dont le délai de 3 jours est dépassé avancent tout seuls
  --    (avant, il fallait qu'un des deux joueurs ouvre le jeu)
  for r in select id from public.tb_matches
           where (status = 'run' and tour_at < now() - interval '3 days')
              or (status = 'invite' and created_at < now() - interval '3 days') loop
    begin perform public.tb_tick(r.id); exception when others then null; end;
  end loop;

  -- 2) rappels : 24 h puis 48 h après le début d'un tour pas encore joué
  for r in select m.id, m.p1, m.p2, m.tour, m.tour_at, u.uid
           from public.tb_matches m cross join lateral (values (m.p1), (m.p2)) as u(uid)
           where m.status = 'run' and m.tour_at < now() - interval '24 hours'
             and not exists (select 1 from public.tb_plays p where p.match_id = m.id and p.tour = m.tour
                             and p.user_id = u.uid and p.done) loop
    o := case when r.uid = r.p1 then r.p2 else r.p1 end;
    if r.tour_at < now() - interval '48 hours' then
      if not exists (select 1 from public.push_rem x where x.match_id = r.id and x.tour = r.tour and x.user_id = r.uid and x.n = 2) then
        insert into public.push_rem (match_id, tour, user_id, n) values (r.id, r.tour, r.uid, 1), (r.id, r.tour, r.uid, 2) on conflict do nothing;
        delete from public.push_queue where user_id = r.uid and kind = 'rem1' and ref = r.id::text;
        perform public.push_add(r.uid, 'rem2', r.id::text, r.tour, jsonb_build_object('u', o));
      end if;
    elsif not exists (select 1 from public.push_rem x where x.match_id = r.id and x.tour = r.tour and x.user_id = r.uid and x.n = 1) then
      insert into public.push_rem (match_id, tour, user_id, n) values (r.id, r.tour, r.uid, 1) on conflict do nothing;
      perform public.push_add(r.uid, 'rem1', r.id::text, r.tour, jsonb_build_object('u', o));
    end if;
  end loop;

  -- 3) ménage
  delete from public.push_rem x where not exists (
    select 1 from public.tb_matches m where m.id = x.match_id and m.status = 'run' and m.tour = x.tour);
  delete from public.push_queue where created_at < now() - interval '3 days';
  if extract(minute from now())::integer = 7 then   -- une fois par heure : historique du planificateur
    begin execute 'delete from cron.job_run_details where end_time < now() - interval ''3 days'''; exception when others then null; end;
  end if;

  -- 4) envoi (rien entre 22 h et 8 h, heure française, sauf le test)
  h := extract(hour from now() at time zone 'Europe/Paris')::integer;
  batch := public.push_take(h >= 8 and h < 22);
  if jsonb_array_length(batch) > 0 then
    perform net.http_post(
      url := 'https://destghbdqigegolliggd.supabase.co/functions/v1/push',
      body := jsonb_build_object('msgs', batch),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 20000);
  end if;
end $$;

-- ============================================================================
-- FONCTIONS APPELÉES PAR LE JEU
-- ============================================================================

-- Enregistrer ce téléphone (ou mettre à jour sa langue). Réponses : 'ok', 'auth', 'bad'
create or replace function public.push_save(p_endpoint text, p_p256dh text, p_auth text, p_lang text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return 'auth'; end if;
  if p_endpoint is null or char_length(p_endpoint) > 1000
     or p_endpoint !~ '^https://([a-z0-9-]+\.)*(googleapis\.com|push\.services\.mozilla\.com|push\.apple\.com|notify\.windows\.com)/'
     or coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_-]{80,100}=*$' or coalesce(p_auth, '') !~ '^[A-Za-z0-9_-]{16,40}=*$' then
    return 'bad';
  end if;
  insert into public.push_subs (endpoint, user_id, p256dh, auth, lang)
  values (p_endpoint, uid, p_p256dh, p_auth, case when p_lang = 'en' then 'en' else 'fr' end)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
                                       lang = excluded.lang, updated_at = now();
  -- au plus 10 appareils par compte
  delete from public.push_subs s where s.user_id = uid and s.endpoint not in (
    select x.endpoint from public.push_subs x where x.user_id = uid order by x.updated_at desc limit 10);
  insert into public.push_prefs (user_id) values (uid) on conflict do nothing;
  return 'ok';
end $$;

-- Oublier ce téléphone (notifications désactivées ou déconnexion)
create or replace function public.push_remove(p_endpoint text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return 'auth'; end if;
  delete from public.push_subs where endpoint = p_endpoint and user_id = uid;
  return 'ok';
end $$;

-- Mes choix de notifications
create or replace function public.push_prefs_get()
returns jsonb language plpgsql security definer set search_path = '' stable as $$
declare uid uuid := auth.uid(); p public.push_prefs%rowtype;
begin
  if uid is null then return null; end if;
  select * into p from public.push_prefs where user_id = uid;
  if not found then return jsonb_build_object('amis', true, 'defis', true, 'tours', true, 'rappels', true); end if;
  return jsonb_build_object('amis', p.amis, 'defis', p.defis, 'tours', p.tours, 'rappels', p.rappels);
end $$;

create or replace function public.push_prefs_set(p jsonb)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return 'auth'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then return 'bad'; end if;
  insert into public.push_prefs (user_id) values (uid) on conflict do nothing;
  update public.push_prefs set
    amis = case when jsonb_typeof(p -> 'amis') = 'boolean' then (p ->> 'amis')::boolean else amis end,
    defis = case when jsonb_typeof(p -> 'defis') = 'boolean' then (p ->> 'defis')::boolean else defis end,
    tours = case when jsonb_typeof(p -> 'tours') = 'boolean' then (p ->> 'tours')::boolean else tours end,
    rappels = case when jsonb_typeof(p -> 'rappels') = 'boolean' then (p ->> 'rappels')::boolean else rappels end,
    updated_at = now()
  where user_id = uid;
  return 'ok';
end $$;

-- Notification de test (arrive dans la minute, même la nuit). Réponses : 'ok', 'auth', 'nosub'
create or replace function public.push_test()
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return 'auth'; end if;
  if not exists (select 1 from public.push_subs where user_id = uid) then return 'nosub'; end if;
  perform public.push_add(uid, 'test', '', 0, '{}'::jsonb);
  return 'ok';
end $$;

-- Appelée par la fonction « push » : téléphones qui n'acceptent plus les notifications
create or replace function public.push_gone(p_ends text[])
returns void language sql security definer set search_path = '' as $$
  delete from public.push_subs where p_ends is not null and coalesce(array_length(p_ends, 1), 0) <= 500
    and endpoint = any (p_ends)
$$;

-- ============================================================================
-- DROITS
-- ============================================================================
revoke execute on function public.push_add(uuid, text, text, integer, jsonb) from public, anon, authenticated;
revoke execute on function public.push_trg_friends() from public, anon, authenticated;
revoke execute on function public.push_trg_duels() from public, anon, authenticated;
revoke execute on function public.push_trg_tb() from public, anon, authenticated;
revoke execute on function public.push_take(boolean) from public, anon, authenticated;
revoke execute on function public.push_cron() from public, anon, authenticated;
revoke execute on function public.push_save(text, text, text, text) from public, anon;
revoke execute on function public.push_remove(text) from public, anon;
revoke execute on function public.push_prefs_get() from public, anon;
revoke execute on function public.push_prefs_set(jsonb) from public, anon;
revoke execute on function public.push_test() from public, anon;
revoke execute on function public.push_gone(text[]) from public;
grant execute on function public.push_save(text, text, text, text) to authenticated;
grant execute on function public.push_remove(text) to authenticated;
grant execute on function public.push_prefs_get() to authenticated;
grant execute on function public.push_prefs_set(jsonb) to authenticated;
grant execute on function public.push_test() to authenticated;
grant execute on function public.push_gone(text[]) to anon, authenticated;

-- ============================================================================
-- LANCEMENT : push_cron() chaque minute
-- ============================================================================
select cron.schedule('dcl-notifications', '* * * * *', 'select public.push_cron()');
