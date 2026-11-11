-- Themed rate-limit copy (no change to limits).
create or replace function game.rate_limit(
  pid bigint, act text, max_hits int, win interval, min_gap interval default interval '0'
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare r game.rpc_throttle;
begin
  if pid is null then return; end if;
  insert into game.rpc_throttle (player_id, action, last_at, window_start, hits)
       values (pid, act, 'epoch'::timestamptz, now(), 0)
    on conflict (player_id, action) do nothing;
  select * into r from game.rpc_throttle where player_id = pid and action = act for update;
  if min_gap > interval '0' and r.last_at > now() - min_gap then
    raise exception 'Slow down. Try again in a moment.';
  end if;
  if r.window_start <= now() - win then
    r.hits := 0;
    r.window_start := now();
  end if;
  r.hits := r.hits + 1;
  if r.hits > max_hits then
    raise exception 'Too many requests. Wait a little and try again.';
  end if;
  update game.rpc_throttle
     set hits = r.hits, window_start = r.window_start, last_at = now()
   where player_id = pid and action = act;
end
$fn$;
revoke all on function game.rate_limit(bigint, text, int, interval, interval) from public, anon, authenticated;
