-- KOS TRADE: live XAUUSD spot feed + server-side execution pricing
-- Run this entire file in Supabase SQL Editor after deploying the sync-xauusd Edge Function.

create table if not exists public.market_quotes (
  symbol text primary key,
  price numeric(18,6) not null check (price > 0),
  source text not null,
  provider_updated_at timestamptz not null,
  received_at timestamptz not null default now()
);

create table if not exists public.market_ticks (
  id bigint generated always as identity primary key,
  symbol text not null,
  price numeric(18,6) not null check (price > 0),
  source text not null,
  provider_updated_at timestamptz not null,
  received_at timestamptz not null default now(),
  unique(symbol, provider_updated_at)
);

create index if not exists market_ticks_symbol_time_idx
  on public.market_ticks(symbol, provider_updated_at desc);

alter table public.market_quotes enable row level security;
alter table public.market_ticks enable row level security;

revoke all on public.market_quotes from anon, authenticated;
revoke all on public.market_ticks from anon, authenticated;
grant all on public.market_quotes to service_role;
grant all on public.market_ticks to service_role;
grant usage, select on sequence public.market_ticks_id_seq to service_role;

create or replace function public.get_fresh_xauusd_price()
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_price numeric;
begin
  select q.price into v_price
  from public.market_quotes q
  where q.symbol = 'XAUUSD'
    and q.provider_updated_at >= now() - interval '90 seconds'
    and q.provider_updated_at <= now() + interval '30 seconds'
  order by q.provider_updated_at desc
  limit 1;

  if v_price is null then
    raise exception 'Kuota live XAUUSD mungon ose është e vjetruar. Provo rifreskimin.';
  end if;
  return v_price;
end;
$$;

revoke all on function public.get_fresh_xauusd_price() from public, anon, authenticated;

create or replace function public.client_demo_market_snapshot(p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_price numeric;
  v_candles jsonb;
  v_pos public.positions%rowtype;
  v_pnl numeric;
  v_closed integer := 0;
  v_quote_time timestamptz;
begin
  if v_uid is null then raise exception 'Duhet të kyçesh.'; end if;
  if not exists (
    select 1 from public.trading_accounts a
    where a.id = p_account_id and a.user_id = v_uid and a.status = 'active'
  ) then raise exception 'Llogaria nuk është aktive.'; end if;

  v_price := public.get_fresh_xauusd_price();
  select q.provider_updated_at into v_quote_time
  from public.market_quotes q where q.symbol = 'XAUUSD';

  for v_pos in
    select p.* from public.positions p
    where p.account_id = p_account_id and p.status = 'open'
      and (
        (p.side = 'buy' and ((p.stop_loss is not null and v_price <= p.stop_loss)
          or (p.take_profit is not null and v_price >= p.take_profit)))
        or
        (p.side = 'sell' and ((p.stop_loss is not null and v_price >= p.stop_loss)
          or (p.take_profit is not null and v_price <= p.take_profit)))
      )
    for update
  loop
    if v_pos.side = 'buy' then
      v_pnl := (v_price - v_pos.entry_price) * v_pos.volume * 100;
    else
      v_pnl := (v_pos.entry_price - v_price) * v_pos.volume * 100;
    end if;
    update public.positions
      set exit_price = v_price, realized_pnl = v_pnl, status = 'closed', closed_at = now()
      where id = v_pos.id and status = 'open';
    if found then
      insert into public.ledger_entries(account_id, entry_type, amount, description, created_by)
      values (p_account_id, 'trade_pnl', v_pnl,
        'Mbyllje automatike XAUUSD · ' || upper(v_pos.side) || ' · SL/TP', v_uid);
      v_closed := v_closed + 1;
    end if;
  end loop;

  with minute_rows as (
    select date_trunc('minute', t.provider_updated_at) as minute_start,
      (array_agg(t.price order by t.provider_updated_at))[1] as candle_open,
      max(t.price) as candle_high,
      min(t.price) as candle_low,
      (array_agg(t.price order by t.provider_updated_at desc))[1] as candle_close
    from public.market_ticks t
    where t.symbol = 'XAUUSD'
      and t.provider_updated_at >= now() - interval '120 minutes'
    group by date_trunc('minute', t.provider_updated_at)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'time', extract(epoch from minute_start)::bigint,
    'open', candle_open, 'high', candle_high, 'low', candle_low, 'close', candle_close
  ) order by minute_start), '[]'::jsonb)
  into v_candles
  from minute_rows;

  return jsonb_build_object(
    'symbol', 'XAUUSD',
    'price', v_price,
    'server_time', extract(epoch from clock_timestamp())::bigint,
    'provider_updated_at', v_quote_time,
    'source', 'Gold API · XAU spot',
    'candles', v_candles,
    'auto_closed', v_closed
  );
end;
$$;

create or replace function public.client_open_demo_market_position(
  p_account_id uuid,
  p_side text,
  p_volume numeric,
  p_stop_loss numeric default null,
  p_take_profit numeric default null
)
returns table(position_id uuid, fill_price numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_price numeric;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Duhet të kyçesh.'; end if;
  if p_side not in ('buy', 'sell') then raise exception 'Zgjedh BUY ose SELL.'; end if;
  if p_volume is null or p_volume < 0.01 or p_volume > 10 then
    raise exception 'Vëllimi duhet të jetë 0.01 deri 10.00 lot.';
  end if;
  if p_stop_loss is not null and p_stop_loss <= 0 then raise exception 'SL jo i vlefshëm.'; end if;
  if p_take_profit is not null and p_take_profit <= 0 then raise exception 'TP jo i vlefshëm.'; end if;
  if not exists (
    select 1 from public.trading_accounts a
    where a.id = p_account_id and a.user_id = v_uid and a.status = 'active'
  ) then raise exception 'Llogaria nuk është aktive.'; end if;

  v_price := public.get_fresh_xauusd_price();
  if p_side = 'buy' and (
    (p_stop_loss is not null and p_stop_loss >= v_price) or
    (p_take_profit is not null and p_take_profit <= v_price)
  ) then raise exception 'Për BUY: SL nën çmim dhe TP mbi çmim.'; end if;
  if p_side = 'sell' and (
    (p_stop_loss is not null and p_stop_loss <= v_price) or
    (p_take_profit is not null and p_take_profit >= v_price)
  ) then raise exception 'Për SELL: SL mbi çmim dhe TP nën çmim.'; end if;

  insert into public.positions(account_id, symbol, side, volume, entry_price, stop_loss, take_profit, status)
  values (p_account_id, 'XAUUSD', p_side, p_volume, v_price, p_stop_loss, p_take_profit, 'open')
  returning id into v_id;
  return query select v_id, v_price;
end;
$$;

create or replace function public.client_close_demo_position(p_position_id uuid)
returns table(exit_price numeric, realized_pnl numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_pos public.positions%rowtype;
  v_price numeric;
  v_pnl numeric;
begin
  if v_uid is null then raise exception 'Duhet të kyçesh.'; end if;
  select p.* into v_pos
  from public.positions p
  join public.trading_accounts a on a.id = p.account_id
  where p.id = p_position_id and a.user_id = v_uid and a.status = 'active'
  for update of p;
  if not found or v_pos.status <> 'open' then raise exception 'Pozita nuk është e hapur.'; end if;

  v_price := public.get_fresh_xauusd_price();
  if v_pos.side = 'buy' then
    v_pnl := (v_price - v_pos.entry_price) * v_pos.volume * 100;
  else
    v_pnl := (v_pos.entry_price - v_price) * v_pos.volume * 100;
  end if;

  update public.positions set exit_price = v_price, realized_pnl = v_pnl,
    status = 'closed', closed_at = now()
  where id = v_pos.id and status = 'open';
  if not found then raise exception 'Pozita u mbyll nga një veprim tjetër.'; end if;

  insert into public.ledger_entries(account_id, entry_type, amount, description, created_by)
  values (v_pos.account_id, 'trade_pnl', v_pnl,
    'Mbyllje XAUUSD · ' || upper(v_pos.side), v_uid);
  return query select v_price, v_pnl;
end;
$$;

create or replace function public.client_close_all_demo_positions(p_account_id uuid)
returns table(closed_count integer, total_realized_pnl numeric, exit_price numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_pos public.positions%rowtype;
  v_price numeric;
  v_pnl numeric;
  v_total numeric := 0;
  v_count integer := 0;
begin
  if v_uid is null then raise exception 'Duhet të kyçesh.'; end if;
  if not exists (
    select 1 from public.trading_accounts a
    where a.id = p_account_id and a.user_id = v_uid and a.status = 'active'
  ) then raise exception 'Llogaria nuk është aktive.'; end if;

  v_price := public.get_fresh_xauusd_price();
  for v_pos in
    select p.* from public.positions p
    where p.account_id = p_account_id and p.status = 'open'
    for update
  loop
    if v_pos.side = 'buy' then
      v_pnl := (v_price - v_pos.entry_price) * v_pos.volume * 100;
    else
      v_pnl := (v_pos.entry_price - v_price) * v_pos.volume * 100;
    end if;
    update public.positions set exit_price = v_price, realized_pnl = v_pnl,
      status = 'closed', closed_at = now()
    where id = v_pos.id and status = 'open';
    if found then
      insert into public.ledger_entries(account_id, entry_type, amount, description, created_by)
      values (p_account_id, 'trade_pnl', v_pnl, 'Mbyllje XAUUSD · CLOSE ALL', v_uid);
      v_total := v_total + v_pnl;
      v_count := v_count + 1;
    end if;
  end loop;
  if v_count = 0 then raise exception 'Nuk ka pozita të hapura.'; end if;
  return query select v_count, v_total, v_price;
end;
$$;

revoke all on function public.client_demo_market_snapshot(uuid) from public;
revoke all on function public.client_open_demo_market_position(uuid, text, numeric, numeric, numeric) from public;
revoke all on function public.client_close_demo_position(uuid) from public;
revoke all on function public.client_close_all_demo_positions(uuid) from public;

grant execute on function public.client_demo_market_snapshot(uuid) to authenticated;
grant execute on function public.client_open_demo_market_position(uuid, text, numeric, numeric, numeric) to authenticated;
grant execute on function public.client_close_demo_position(uuid) to authenticated;
grant execute on function public.client_close_all_demo_positions(uuid) to authenticated;
