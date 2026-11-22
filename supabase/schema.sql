-- KOS TRADE — Phase 1 database foundation
-- Run only in a NEW Supabase project after reviewing the SQL.
-- This schema deliberately denies client-side writes to financial tables.

create extension if not exists pgcrypto;

do $$ begin
  create type public.account_status as enum ('pending', 'active', 'suspended', 'closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.ledger_entry_type as enum ('deposit', 'withdrawal', 'adjustment', 'trade_pnl', 'fee', 'correction');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.position_status as enum ('open', 'closed', 'cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  role text not null default 'client' check (role in ('client', 'admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.trading_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  account_number bigint generated always as identity unique,
  currency text not null default 'USD' check (currency = 'USD'),
  status public.account_status not null default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.trading_accounts(id),
  entry_type public.ledger_entry_type not null,
  amount numeric(20, 8) not null,
  currency text not null default 'USD' check (currency = 'USD'),
  reference text,
  description text not null default '',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint ledger_amount_nonzero check (amount <> 0)
);

create table if not exists public.positions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.trading_accounts(id),
  symbol text not null default 'XAUUSD' check (symbol = 'XAUUSD'),
  side text not null check (side in ('buy', 'sell')),
  volume numeric(12, 4) not null check (volume > 0),
  entry_price numeric(20, 8),
  exit_price numeric(20, 8),
  stop_loss numeric(20, 8),
  take_profit numeric(20, 8),
  realized_pnl numeric(20, 8),
  status public.position_status not null default 'open',
  opened_at timestamptz not null default now(),
  closed_at timestamptz
);

alter table public.profiles enable row level security;
alter table public.trading_accounts enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.positions enable row level security;

drop policy if exists "profile_read_self" on public.profiles;
create policy "profile_read_self" on public.profiles
  for select to authenticated using (id = auth.uid());

drop policy if exists "account_read_self" on public.trading_accounts;
create policy "account_read_self" on public.trading_accounts
  for select to authenticated using (user_id = auth.uid());

-- Ledger and positions intentionally have no client policies yet.
-- Financial changes must be made only by trusted server-side functions.
-- Never expose the Supabase service_role key in frontend code.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', ''),
    'client'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
