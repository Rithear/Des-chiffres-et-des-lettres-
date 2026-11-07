-- ============================================================================
-- Des chiffres et des lettres v21.2 : copier les e-mails des joueurs (écran Admin)
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Ne modifie rien : ajoute seulement une fonction réservée à l'administrateur.
-- ============================================================================

-- Pseudo et adresse e-mail de chaque compte confirmé (administrateur seulement)
create or replace function public.admin_emails()
returns table (pseudo text, email text)
language plpgsql security definer set search_path = '' stable as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return query
  select p.pseudo, u.email::text
  from public.profiles p
  join auth.users u on u.id = p.id
  where u.email is not null and u.email_confirmed_at is not null
  order by p.pseudo;
end $$;

revoke execute on function public.admin_emails() from public, anon;
grant execute on function public.admin_emails() to authenticated;
