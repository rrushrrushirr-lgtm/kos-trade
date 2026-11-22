-- KOS TRADE Phase 2: admin access and protected account operations
-- Run this file in Supabase SQL Editor as project owner.

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
  );
$$;

grant execute on function public.is_admin() to authenticated;

drop policy if exists "profile_read_self" on public.profiles;
drop policy if exists "profiles_read_self_or_admin" on public.profiles;
create policy "profiles_read_self_or_admin" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or public.is_admin());

drop policy if exists "account_read_self" on public.trading_accounts;
drop policy if exists "accounts_read_self_or_admin" on public.trading_accounts;
create policy "accounts_read_self_or_admin" on public.trading_accounts
  for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());

drop policy if exists "ledger_read_owner_or_admin" on public.ledger_entries;
create policy "ledger_read_owner_or_admin" on public.ledger_entries
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.trading_accounts a
      where a.id = ledger_entries.account_id
        and a.user_id = (select auth.uid())
    )
  );

create or replace function public.admin_create_trading_account(p_user_id uuid)
returns table(account_id uuid, account_number bigint, status public.account_status)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account public.trading_accounts%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Nuk ke leje administratori.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = p_user_id and p.role = 'client'
  ) then
    raise exception 'Klienti nuk u gjet ose nuk është klient.';
  end if;

  if exists (
    select 1 from public.trading_accounts a where a.user_id = p_user_id
  ) then
    raise exception 'Ky klient tashmë ka llogari.';
  end if;

  insert into public.trading_accounts(user_id, status)
  values (p_user_id, 'active')
  returning * into v_account;

  return query select v_account.id, v_account.account_number, v_account.status;
end;
$$;

create or replace function public.admin_adjust_balance(
  p_account_id uuid,
  p_amount numeric,
  p_description text
)
returns table(entry_id uuid, new_entry_amount numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.ledger_entries%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Nuk ke leje administratori.';
  end if;

  if p_amount is null or p_amount = 0 then
    raise exception 'Shuma duhet të jetë ndryshe nga zero.';
  end if;

  if abs(p_amount) > 1000000 then
    raise exception 'Shuma tejkalon kufirin e lejuar.';
  end if;

  if not exists (
    select 1 from public.trading_accounts a where a.id = p_account_id
  ) then
    raise exception 'Llogaria nuk u gjet.';
  end if;

  insert into public.ledger_entries(
    account_id, entry_type, amount, description, created_by
  )
  values (
    p_account_id, 'adjustment', p_amount,
    coalesce(nullif(trim(p_description), ''), 'Rregullim nga administratori'),
    (select auth.uid())
  )
  returning * into v_entry;

  return query select v_entry.id, v_entry.amount, v_entry.created_at;
end;
$$;

revoke all on function public.admin_create_trading_account(uuid) from public;
revoke all on function public.admin_adjust_balance(uuid, numeric, text) from public;
grant execute on function public.admin_create_trading_account(uuid) to authenticated;
grant execute on function public.admin_adjust_balance(uuid, numeric, text) to authenticated;
