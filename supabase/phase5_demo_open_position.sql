-- KOS TRADE Phase 5: secure demo position opening
-- Run in Supabase SQL Editor. Demo only; manual entry price, no live execution.

create or replace function public.client_open_demo_position(
  p_account_id uuid,
  p_side text,
  p_volume numeric,
  p_entry_price numeric,
  p_stop_loss numeric default null,
  p_take_profit numeric default null
)
returns table(position_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Duhet të kyçesh.';
  end if;

  if p_side not in ('buy', 'sell') then
    raise exception 'Zgjedh BUY ose SELL.';
  end if;

  if p_volume is null or p_volume < 0.01 or p_volume > 10 then
    raise exception 'Vëllimi duhet të jetë nga 0.01 deri në 10.00 lot.';
  end if;

  if p_entry_price is null or p_entry_price <= 0 then
    raise exception 'Çmimi hyrës duhet të jetë më i madh se zero.';
  end if;

  if p_stop_loss is not null and p_stop_loss <= 0 then
    raise exception 'Stop Loss duhet të jetë më i madh se zero.';
  end if;

  if p_take_profit is not null and p_take_profit <= 0 then
    raise exception 'Take Profit duhet të jetë më i madh se zero.';
  end if;

  if p_side = 'buy' and (
    (p_stop_loss is not null and p_stop_loss >= p_entry_price) or
    (p_take_profit is not null and p_take_profit <= p_entry_price)
  ) then
    raise exception 'Për BUY: SL duhet të jetë nën hyrje dhe TP mbi hyrje.';
  end if;

  if p_side = 'sell' and (
    (p_stop_loss is not null and p_stop_loss <= p_entry_price) or
    (p_take_profit is not null and p_take_profit >= p_entry_price)
  ) then
    raise exception 'Për SELL: SL duhet të jetë mbi hyrje dhe TP nën hyrje.';
  end if;

  if not exists (
    select 1 from public.trading_accounts a
    where a.id = p_account_id
      and a.user_id = (select auth.uid())
      and a.status = 'active'
  ) then
    raise exception 'Llogaria nuk u gjet ose nuk është aktive.';
  end if;

  insert into public.positions (
    account_id, symbol, side, volume, entry_price, stop_loss, take_profit, status
  )
  values (
    p_account_id, 'XAUUSD', p_side, p_volume, p_entry_price,
    p_stop_loss, p_take_profit, 'open'
  )
  returning id into v_id;

  return query select v_id;
end;
$$;

revoke all on function public.client_open_demo_position(uuid, text, numeric, numeric, numeric, numeric) from public;
grant execute on function public.client_open_demo_position(uuid, text, numeric, numeric, numeric, numeric) to authenticated;
