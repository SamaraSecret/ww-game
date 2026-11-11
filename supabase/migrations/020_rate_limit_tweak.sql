-- Bank deposit/withdraw share a throttle key; a 1s min-gap blocked a withdraw
-- immediately after a deposit and hid the real row-lock race. Keep a 30/5min
-- cap, drop the min-gap, and make the updates conditional so a race cannot
-- overdraw. Attack spam is still capped at 8 per 5 minutes; energy and the
-- 10-minute PvP cooldown already space individual fights.

create or replace function public.bank_deposit(p_token text, p_amount bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); p game.players; fee bigint; n int;
begin
  perform game.rate_limit(pid, 'bank', 30, interval '5 minutes', interval '0');
  if p_amount is null or p_amount < 1 then raise exception 'Enter a positive amount.'; end if;
  p := game.tick(pid);
  if p.cash < p_amount then raise exception 'You only have $% in cash.', p.cash; end if;
  fee := ceil(p_amount * 0.01);
  update game.players set cash = cash - p_amount, bank = bank + (p_amount - fee)
   where id = pid and cash >= p_amount;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'You only have $% in cash.', p.cash; end if;
  return jsonb_build_object('message', format('Deposited $%s (fee $%s).', p_amount - fee, fee), 'me', game.me_json(pid));
end
$fn$;

create or replace function public.bank_withdraw(p_token text, p_amount bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); p game.players; n int;
begin
  perform game.rate_limit(pid, 'bank', 30, interval '5 minutes', interval '0');
  if p_amount is null or p_amount < 1 then raise exception 'Enter a positive amount.'; end if;
  p := game.tick(pid);
  if p.bank < p_amount then raise exception 'You only have $% in the bank.', p.bank; end if;
  update game.players set cash = cash + p_amount, bank = bank - p_amount
   where id = pid and bank >= p_amount;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'You only have $% in the bank.', p.bank; end if;
  return jsonb_build_object('message', format('Withdrew $%s.', p_amount), 'me', game.me_json(pid));
end
$fn$;

-- Recreate attack only to drop the 3s min-gap (8 / 5 minutes remains).
-- We do this by replacing the first rate_limit call via a new wrapper? No,
-- patch by redefining a one-line helper used only here is messy.
-- Instead, set a tighter cap without min-gap by updating the call in-place
-- through a small SQL rewrite of just that perform. The function body is
-- large, so we alter it with a statement-level execute of the current source
-- is not available. Use a dedicated pre-check function invoked at the start
-- that we can change... attack already calls game.rate_limit directly.

-- Easier path: keep public.attack as-is and change game.rate_limit for the
-- 'attack' action by documenting... no, we must change the call. Recreate
-- a thin shim: replace game.rate_limit's attack min-gap at the call site
-- by creating game.rate_limit_attack.

create or replace function game.limit_attack(pid bigint)
returns void
language sql
security definer
set search_path = ''
as $fn$
  select game.rate_limit(pid, 'attack', 8, interval '5 minutes', interval '0')
$fn$;
revoke all on function game.limit_attack(bigint) from public, anon, authenticated;

-- Swap the 3-second min-gap call for the new helper without rewriting combat.
do $d$
declare def text;
begin
  select pg_get_functiondef('public.attack(text,bigint)'::regprocedure) into def;
  if position($p$game.rate_limit(pid, 'attack', 8, interval '5 minutes', interval '3 seconds')$p$ in def) = 0 then
    raise notice 'attack rate_limit call not in expected form, leaving as-is';
    return;
  end if;
  def := replace(def,
    $p$perform game.rate_limit(pid, 'attack', 8, interval '5 minutes', interval '3 seconds');$p$,
    $p$perform game.limit_attack(pid);$p$);
  execute def;
end
$d$;

grant execute on function public.bank_deposit(text, bigint) to anon;
grant execute on function public.bank_withdraw(text, bigint) to anon;
grant execute on function public.attack(text, bigint) to anon;
grant execute on function public.bank_deposit(text, bigint) to service_role;
grant execute on function public.bank_withdraw(text, bigint) to service_role;
grant execute on function public.attack(text, bigint) to service_role;
