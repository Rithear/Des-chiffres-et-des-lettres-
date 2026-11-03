-- ============================================================================
-- Des chiffres et des lettres v15 : duels entre amis (avec un compte)
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Ne touche à aucun résultat déjà enregistré (comptes, amis, partie du jour,
-- multijoueur, statistiques, tour par tour). On peut le relancer sans risque.
-- ============================================================================
--
-- Déroulement :
--   * après une manche (Le mot le plus long, Le compte est bon ou Les mots de la
--     fin), le joueur défie un ou plusieurs amis sur exactement le même tirage ;
--   * chaque ami voit le duel dans le jeu (pastille) et a 7 jours pour le relever ;
--   * un duel commencé ne peut pas être rejoué ;
--   * le résultat de l'ami revient tout seul à celui qui a lancé le duel ;
--   * tant que personne n'a répondu, celui qui a lancé le duel peut le supprimer :
--     il disparaît alors aussi chez les amis qui ne l'ont pas encore joué.
--
-- Le duel lui-même (tirage, résultat et fantôme du lanceur) est le même que celui
-- du duel par lien : il est rangé tel quel dans « payload ».

-- 1) LES DUELS ENVOYÉS (une ligne par ami défié)
create table if not exists public.duel_sends (
  id uuid primary key default gen_random_uuid(),
  duel text not null check (duel ~ '^[a-z0-9]{6,16}$'),                  -- identifiant du duel (le même pour tous les amis)
  from_id uuid not null references auth.users(id) on delete cascade,     -- celui qui défie
  to_id uuid not null references auth.users(id) on delete cascade,       -- l'ami défié
  game text not null check (game in ('l','c','w')),
  payload jsonb not null,
  status text not null default 'wait' check (status in ('wait','run','done','cancel')),
  answer jsonb,                                                          -- résultat de l'ami
  created_at timestamptz not null default now(),
  started_at timestamptz,
  answered_at timestamptz,
  check (from_id <> to_id)
);
create unique index if not exists duel_sends_pair_key on public.duel_sends (duel, to_id);
create index if not exists duel_sends_to_idx on public.duel_sends (to_id, created_at desc);
create index if not exists duel_sends_from_idx on public.duel_sends (from_id, created_at desc);
alter table public.duel_sends enable row level security;
revoke all on public.duel_sends from anon, authenticated;

-- ============================================================================
-- FONCTIONS appelées par le jeu
-- ============================================================================

-- Défier un ou plusieurs amis. Réponse pour chaque ami :
-- 'ok', 'notfriend', 'already' (déjà défié sur ce duel), 'fullfr' (trop de duels en attente),
-- ou une seule ligne 'auth' / 'bad'
create or replace function public.duel_send(p_duel text, p_game text, p_payload jsonb, p_friends uuid[])
returns table (friend uuid, status text) language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  f uuid;
begin
  if uid is null then return query select null::uuid, 'auth'::text; return; end if;
  if p_duel is null or p_duel !~ '^[a-z0-9]{6,16}$' or p_game not in ('l','c','w')
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

-- Mes duels entre amis (reçus et envoyés) des 60 derniers jours, sans le contenu du duel.
-- status : 'wait' (pas encore joué), 'run' (commencé), 'done', 'expired' (7 jours dépassés)
create or replace function public.duel_list()
returns table (id uuid, duel text, mine boolean, opp uuid, opp_name text, game text, status text,
               answer jsonb, created_at timestamptz, answered_at timestamptz)
language sql security definer set search_path = '' stable as $$
  select d.id, d.duel, d.from_id = auth.uid(),
         case when d.from_id = auth.uid() then d.to_id else d.from_id end,
         coalesce(p.pseudo, '?'), d.game,
         case when d.status in ('wait','run') and d.created_at < now() - interval '7 days' then 'expired' else d.status end,
         d.answer, d.created_at, d.answered_at
  from public.duel_sends d
  left join public.profiles p on p.id = case when d.from_id = auth.uid() then d.to_id else d.from_id end
  where (d.from_id = auth.uid() or d.to_id = auth.uid())
    and d.status <> 'cancel'
    and d.created_at > now() - interval '60 days'
  order by d.created_at desc
  limit 200
$$;

-- Contenu de plusieurs duels (seulement ceux qui me concernent)
create or replace function public.duel_get(p_ids uuid[])
returns table (id uuid, payload jsonb)
language sql security definer set search_path = '' stable as $$
  select d.id, d.payload from public.duel_sends d
  where d.id = any (p_ids[1:50]) and (d.from_id = auth.uid() or d.to_id = auth.uid()) and d.status <> 'cancel'
$$;

-- Je commence un duel reçu. Réponses : 'ok', 'run' (déjà commencé), 'done', 'expired', 'cancel', 'notfound', 'auth'
create or replace function public.duel_begin(p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  d public.duel_sends%rowtype;
begin
  if uid is null then return 'auth'; end if;
  select * into d from public.duel_sends where id = p_id for update;
  if not found or d.to_id <> uid then return 'notfound'; end if;
  if d.status = 'cancel' then return 'cancel'; end if;
  if d.status = 'done' then return 'done'; end if;
  if d.created_at < now() - interval '7 days' then return 'expired'; end if;
  if d.status = 'run' then return 'run'; end if;
  update public.duel_sends set status = 'run', started_at = now() where id = p_id;
  return 'ok';
end $$;

-- J'envoie mon résultat. Réponses : 'ok', 'done' (déjà envoyé), 'expired', 'cancel', 'notfound', 'bad', 'auth'
-- (un duel commencé avant la fin du délai peut encore être terminé pendant une heure)
create or replace function public.duel_answer(p_id uuid, p_ans jsonb)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  d public.duel_sends%rowtype;
begin
  if uid is null then return 'auth'; end if;
  if p_ans is null or jsonb_typeof(p_ans) <> 'object' or octet_length(p_ans::text) > 400 then return 'bad'; end if;
  select * into d from public.duel_sends where id = p_id for update;
  if not found or d.to_id <> uid then return 'notfound'; end if;
  if d.status = 'cancel' then return 'cancel'; end if;
  if d.status = 'done' then return 'done'; end if;
  if d.created_at < now() - interval '7 days'
     and not (d.status = 'run' and d.started_at > now() - interval '1 hour') then
    return 'expired';
  end if;
  update public.duel_sends set status = 'done', answer = p_ans, answered_at = now(),
         started_at = coalesce(started_at, now()) where id = p_id;
  return 'ok';
end $$;

-- Supprimer un de mes duels tant que personne n'a répondu. Réponses : 'ok', 'answered', 'auth'
create or replace function public.duel_cancel(p_duel text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then return 'auth'; end if;
  if exists (select 1 from public.duel_sends d where d.duel = p_duel and d.from_id = uid and d.status = 'done') then
    return 'answered';
  end if;
  update public.duel_sends set status = 'cancel' where duel = p_duel and from_id = uid and status in ('wait','run');
  return 'ok';
end $$;

-- Droits d'exécution
revoke execute on function public.duel_send(text, text, jsonb, uuid[]) from public, anon;
revoke execute on function public.duel_list() from public, anon;
revoke execute on function public.duel_get(uuid[]) from public, anon;
revoke execute on function public.duel_begin(uuid) from public, anon;
revoke execute on function public.duel_answer(uuid, jsonb) from public, anon;
revoke execute on function public.duel_cancel(text) from public, anon;
grant execute on function public.duel_send(text, text, jsonb, uuid[]) to authenticated;
grant execute on function public.duel_list() to authenticated;
grant execute on function public.duel_get(uuid[]) to authenticated;
grant execute on function public.duel_begin(uuid) to authenticated;
grant execute on function public.duel_answer(uuid, jsonb) to authenticated;
grant execute on function public.duel_cancel(text) to authenticated;
