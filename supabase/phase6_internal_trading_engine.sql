-- KOS TRADE Phase 6: internal simulated XAUUSD trading engine
-- This is a SIMULATOR, not a connection to a live exchange or broker.
-- Run once in Supabase SQL Editor as project owner.

create or replace function public.demo_xau_price_at(p_time timestamptz)
returns numeric
language sql
stable
set search_path = ''
as $$
  select round((2650
    + 18 * sin(extract(epoch from p_time)::double precision / 73.0)
    + 8 * sin(extract(epoch from p_time)::double precision / 19.0)
    + 3 * sin(extract(epoch from p_time)::double precision / 7.0))::numeric, 2);
$$;

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
begin
  if v_uid is null then raise exception 'Duhet të kyçesh.'; end if;
  if not exists (
    select 1 from public.trading_accounts a
    where a.id = p_account_id and a.user_id = v_uid and a.status = 'active'
  ) then raise exception 'Llogaria nuk është aktive.'; end if;

  v_price := public.demo_xau_price_at(clock_timestamp());

  -- Server-side automatic SL/TP handling whenever the terminal refreshes.
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
        'Mbyllje automatike demo XAUUSD · ' || upper(v_pos.side) || ' · SL/TP',
        v_uid);
      v_closed := v_closed + 1;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
    'time', extract(epoch from minute_start)::bigint,
    'open', public.demo_xau_price_at(minute_start),
    'high', greatest(
      public.demo_xau_price_at(minute_start),
      public.demo_xau_price_at(minute_start + interval '15 seconds'),
      public.demo_xau_price_at(minute_start + interval '30 seconds'),
      public.demo_xau_price_at(minute_start + interval '45 seconds'),
      public.demo_xau_price_at(minute_start + interval '59 seconds')),
    'low', least(
      public.demo_xau_price_at(minute_start),
      public.demo_xau_price_at(minute_start + interval '15 seconds'),
      public.demo_xau_price_at(minute_start + interval '30 seconds'),
      public.demo_xau_price_at(minute_start + interval '45 seconds'),
      public.demo_xau_price_at(minute_start + interval '59 seconds')),
    'close', public.demo_xau_price_at(minute_start + interval '59 seconds')
  ) order by minute_start), '[]'::jsonb)
  into v_candles
  from generate_series(
    date_trunc('minute', clock_timestamp()) - interval '119 minutes',
    date_trunc('minute', clock_timestamp()),
    interval '1 minute'
  ) as g(minute_start);

  return jsonb_build_object(
    'symbol', 'XAUUSD',
    'price', v_price,
    'server_time', extract(epoch from clock_timestamp())::bigint,
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

  v_price := public.demo_xau_price_at(clock_timestamp());
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

  v_price := public.demo_xau_price_at(clock_timestamp());
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
    'Mbyllje demo XAUUSD · ' || upper(v_pos.side), v_uid);
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

  v_price := public.demo_xau_price_at(clock_timestamp());
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
      values (p_account_id, 'trade_pnl', v_pnl, 'Mbyllje demo XAUUSD · CLOSE ALL', v_uid);
      v_total := v_total + v_pnl;
      v_count := v_count + 1;
    end if;
  end loop;
  if v_count = 0 then raise exception 'Nuk ka pozita të hapura.'; end if;
  return query select v_count, v_total, v_price;
end;
$$;

revoke all on function public.demo_xau_price_at(timestamptz) from public, anon, authenticated;
revoke all on function public.client_demo_market_snapshot(uuid) from public;
revoke all on function public.client_open_demo_market_position(uuid, text, numeric, numeric, numeric) from public;
revoke all on function public.client_close_demo_position(uuid) from public;
revoke all on function public.client_close_all_demo_positions(uuid) from public;

grant execute on function public.client_demo_market_snapshot(uuid) to authenticated;
grant execute on function public.client_open_demo_market_position(uuid, text, numeric, numeric, numeric) to authenticated;
grant execute on function public.client_close_demo_position(uuid) to authenticated;
grant execute on function public.client_close_all_demo_positions(uuid) to authenticated;
