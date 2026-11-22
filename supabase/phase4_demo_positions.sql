-- KOS TRADE Phase 4: secure demo position close-all
-- Run this file in Supabase SQL Editor as project owner.
-- Demo only: client supplies a manual XAUUSD close price. No broker/live execution.

drop policy if exists "positions_read_owner_or_admin" on public.positions;
create policy "positions_read_owner_or_admin" on public.positions
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
      from public.trading_accounts a
      where a.id = positions.account_id
        and a.user_id = (select auth.uid())
    )
  );

grant select on table public.positions to authenticated;

create or replace function public.client_close_all_demo_positions(
  p_account_id uuid,
  p_exit_price numeric
)
returns table(closed_count integer, total_realized_pnl numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_position public.positions%rowtype;
  v_pnl numeric;
  v_total numeric := 0;
  v_count integer := 0;
begin
  if (select auth.uid()) is null then
    raise exception 'Duhet të kyçesh.';
  end if;

  if p_exit_price is null or p_exit_price <= 0 then
    raise exception 'Çmimi i mbylljes duhet të jetë më i madh se zero.';
  end if;

  if not exists (
    select 1
    from public.trading_accounts a
    where a.id = p_account_id
      and a.user_id = (select auth.uid())
      and a.status = 'active'
  ) then
    raise exception 'Llogaria nuk u gjet ose nuk është aktive.';
  end if;

  for v_position in
    select p.*
    from public.positions p
    where p.account_id = p_account_id
      and p.status = 'open'
    for update
  loop
    -- Demo calculation assumes a 100 oz contract per 1.00 lot.
    if v_position.entry_price is null or v_position.entry_price <= 0 then
      raise exception 'Pozita % nuk ka çmim hyrës të vlefshëm.', v_position.id;
    end if;

    if v_position.side = 'buy' then
      v_pnl := (p_exit_price - v_position.entry_price) * v_position.volume * 100;
    else
      v_pnl := (v_position.entry_price - p_exit_price) * v_position.volume * 100;
    end if;

    update public.positions
    set exit_price = p_exit_price,
        realized_pnl = v_pnl,
        status = 'closed',
        closed_at = now()
    where id = v_position.id;

    v_total := v_total + v_pnl;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Nuk ka pozita të hapura për t’i mbyllur.';
  end if;

  if v_total <> 0 then
    insert into public.ledger_entries(
      account_id, entry_type, amount, description, created_by
    )
    values (
      p_account_id,
      'trade_pnl',
      v_total,
      'Mbyllje demo e të gjitha pozitiveve XAUUSD (' || v_count::text || ')',
      (select auth.uid())
    );
  end if;

  return query select v_count, v_total;
end;
$$;

revoke all on function public.client_close_all_demo_positions(uuid, numeric) from public;
grant execute on function public.client_close_all_demo_positions(uuid, numeric) to authenticated;
