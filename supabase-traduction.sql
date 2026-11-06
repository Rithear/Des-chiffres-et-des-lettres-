-- =====================================================================
-- Des chiffres et des lettres — mise à jour v20 : 🌍 Défi traduction (code v)
--   1) Statistiques : les parties du défi traduction sont enregistrées
--   2) Multijoueur : le défi traduction accepté dans les résultats
--   3) Duels entre amis : le défi traduction accepté
-- À coller tel quel dans Supabase › SQL Editor, puis « Run ».
-- Ne touche à aucun résultat déjà enregistré. Le script peut être relancé sans risque.
-- =====================================================================

-- outil : supprime les contrôles qui portent sur une seule colonne d'une table
create or replace function public.tmp_drop_col_checks(p_table regclass, p_col text)
returns void language plpgsql as $$
declare c record;
begin
  for c in select con.conname from pg_constraint con
           join pg_attribute a on a.attrelid = con.conrelid and a.attnum = any(con.conkey)
           where con.conrelid = p_table and con.contype = 'c' and a.attname = p_col
             and array_length(con.conkey, 1) = 1
  loop
    execute format('alter table %s drop constraint %I', p_table, c.conname);
  end loop;
end $$;

-- 1) STATISTIQUES
select public.tmp_drop_col_checks('public.plays', 'g');
alter table public.plays add constraint plays_g_check
  check (g in ('n','q','l','c','w','t','k','u','s','v','y'));

-- 2) MULTIJOUEUR
select public.tmp_drop_col_checks('public.multi_results', 'game');
alter table public.multi_results add constraint multi_results_game_check
  check (game in ('n','q','l','c','w','p','t','k','u','s','v'));

-- 3) DUELS ENTRE AMIS
select public.tmp_drop_col_checks('public.duel_sends', 'game');
alter table public.duel_sends add constraint duel_sends_game_check
  check (game in ('l','c','w','t','k','u','s','v'));

drop function public.tmp_drop_col_checks(regclass, text);

create or replace function public.duel_send(p_duel text, p_game text, p_payload jsonb, p_friends uuid[])
returns table (friend uuid, status text) language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  f uuid;
begin
  if uid is null then return query select null::uuid, 'auth'::text; return; end if;
  if p_duel is null or p_duel !~ '^[a-z0-9]{6,16}$' or p_game not in ('l','c','w','t','k','u','s','v')
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
