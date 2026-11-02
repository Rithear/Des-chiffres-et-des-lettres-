-- ============================================================================
-- Des chiffres et des lettres v11.1 : code ami (6 chiffres) et invitation par lien
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Donne un code ami à chaque compte (y compris les comptes déjà créés).
-- Ne touche à aucun résultat ni à aucune amitié. On peut le relancer sans risque.
-- ============================================================================

-- 1) Fabrique un code de 6 chiffres qui n'est pas déjà pris
create or replace function public.new_friend_code()
returns text language plpgsql volatile set search_path = '' as $$
declare c text;
begin
  loop
    c := (100000 + floor(random() * 900000))::int::text;
    exit when not exists (select 1 from public.profiles where friend_code = c);
  end loop;
  return c;
end $$;

-- 2) Nouvelle colonne, remplie pour les comptes existants, puis automatique pour les nouveaux
alter table public.profiles add column if not exists friend_code text;
do $$
declare r record;
begin
  for r in select id from public.profiles where friend_code is null loop
    update public.profiles set friend_code = public.new_friend_code() where id = r.id;
  end loop;
end $$;
create unique index if not exists profiles_friend_code_key on public.profiles (friend_code);
alter table public.profiles alter column friend_code set default public.new_friend_code();
alter table public.profiles alter column friend_code set not null;

-- 3) Mon profil : pseudo + demandes reçues + code ami
drop function if exists public.my_profile();
create function public.my_profile()
returns table (pseudo text, pending integer, code text)
language sql security definer set search_path = '' stable as $$
  select p.pseudo,
         (select count(*)::integer from public.friends f where f.to_id = p.id and not f.accepted),
         p.friend_code
  from public.profiles p where p.id = auth.uid()
$$;

-- 4) Demander quelqu'un en ami avec son code
-- status : 'sent', 'accepted' (il m'avait déjà demandé), 'already', 'pending', 'notfound', 'self', 'auth'
create or replace function public.friend_add_code(p_code text)
returns table (status text, who text)
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  c text := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
  oid uuid;
  ps text;
  lk record;
begin
  if uid is null then return query select 'auth'::text, null::text; return; end if;
  select p.id, p.pseudo into oid, ps from public.profiles p where p.friend_code = c;
  if oid is null then return query select 'notfound'::text, null::text; return; end if;
  if oid = uid then return query select 'self'::text, ps; return; end if;
  select * into lk from public.friends f
  where least(f.from_id, f.to_id) = least(uid, oid) and greatest(f.from_id, f.to_id) = greatest(uid, oid);
  if found then
    if lk.accepted then return query select 'already'::text, ps; return; end if;
    if lk.from_id = uid then return query select 'pending'::text, ps; return; end if;
    update public.friends set accepted = true where id = lk.id;
    return query select 'accepted'::text, ps; return;
  end if;
  insert into public.friends (from_id, to_id) values (uid, oid);
  return query select 'sent'::text, ps;
end $$;

-- Droits d'exécution
revoke execute on function public.new_friend_code() from public, anon, authenticated;
grant execute on function public.my_profile() to authenticated;
grant execute on function public.friend_add_code(text) to authenticated;
