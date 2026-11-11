-- Noir Syndicate: garage, fronts, swiss accounts, bounties, turf, raids, hits, breaks, specialization.

-- ---------- garage / grand theft ----------
create or replace function public.list_garage(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; mods jsonb; steal_cd int;
begin
  p := game.tick(pid);
  mods := game.path_mods(p.specialization);
  steal_cd := case when p.last_steal_at is null then 0
                   else greatest(0, 480 - extract(epoch from (now() - p.last_steal_at)))::int end;
  return jsonb_build_object(
    'slots', (select count(*) from game.player_vehicles where player_id = pid),
    'max_slots', 20,
    'steal_cooldown', steal_cd,
    'export_cooldown', case when p.last_export_at is null then 0
                            else greatest(0, 21600 - extract(epoch from (now() - p.last_export_at)))::int end,
    'cars', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id, 'vehicle_id', v.id, 'name', v.name, 'description', v.description, 'icon', v.icon,
        'tune_level', u.tune_level,
        'chop_value', floor(v.chop_value * (1 + u.tune_level * 0.10) * coalesce((mods->>'chop')::numeric, 1))::bigint,
        'export_value', floor(v.export_value * (1 + u.tune_level * 0.12))::bigint,
        'tune_cost', floor(v.chop_value * 0.40 * (u.tune_level + 1))::bigint
      ) order by u.id)
      from game.player_vehicles u join game.vehicles v on v.id = u.vehicle_id
      where u.player_id = pid
    ), '[]'::jsonb),
    'targets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'name', v.name, 'description', v.description, 'icon', v.icon,
        'min_level', v.min_level, 'difficulty', v.difficulty,
        'energy', v.steal_energy,
        'locked', p.level < v.min_level,
        'chance', case when p.level < v.min_level then 0
                       else least(90, greatest(12, round((0.72 - v.difficulty * 0.06
                         + least(0.20, p.dex / 2000.0) + least(0.15, p.spd / 2000.0)) * 100))) end
      ) order by v.id)
      from game.vehicles v
    ), '[]'::jsonb)
  );
end $function$;

create or replace function public.steal_car(p_token text, p_vehicle int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  v game.vehicles;
  chance numeric;
  n int;
begin
  perform game.rate_limit(pid, 'steal_car', 20, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  select * into v from game.vehicles where id = p_vehicle;
  if not found then raise exception 'Unknown ride.'; end if;
  if p.level < v.min_level then raise exception 'You are not experienced enough for that ride.'; end if;
  if p.energy < v.steal_energy then raise exception 'Not enough energy.'; end if;
  if p.last_steal_at is not null and p.last_steal_at > now() - interval '8 minutes' then
    raise exception 'You need to let the street cool down before boosting another ride.';
  end if;
  select count(*) into n from game.player_vehicles where player_id = pid;
  if n >= 20 then raise exception 'Your garage is full (20 cars). Chop or export one first.'; end if;
  update game.players set energy = energy - v.steal_energy, last_steal_at = now() where id = pid;
  chance := least(0.90, greatest(0.12, 0.72 - v.difficulty * 0.06
              + least(0.20, p.dex / 2000.0) + least(0.15, p.spd / 2000.0)));
  if random() > chance then
    if random() < 0.35 then
      update game.players set jail_until = now() + interval '12 minutes' where id = pid;
      perform game.add_event(pid, 'boost', 'You got pinched boosting a ' || v.name || ' and landed in jail.');
      return jsonb_build_object('ok', false, 'message', 'You got pinched and thrown in jail.', 'me', game.me_json(pid));
    end if;
    perform game.add_event(pid, 'boost', 'You failed to boost a ' || v.name || '.');
    return jsonb_build_object('ok', false, 'message', 'The ride would not start. You walked away empty.', 'me', game.me_json(pid));
  end if;
  insert into game.player_vehicles (player_id, vehicle_id) values (pid, v.id);
  perform game.add_event(pid, 'boost', 'You boosted a ' || v.name || ' and stashed it in the garage.');
  return jsonb_build_object('ok', true, 'message', 'You boosted a ' || v.name || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.tune_car(p_token text, p_unit bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; u game.player_vehicles; v game.vehicles; cost bigint;
begin
  perform game.rate_limit(pid, 'garage', 30, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  perform game.require_free(p);
  select * into u from game.player_vehicles where id = p_unit and player_id = pid for update;
  if not found then raise exception 'Car not found.'; end if;
  if u.tune_level >= 5 then raise exception 'That ride is already maxed out.'; end if;
  select * into v from game.vehicles where id = u.vehicle_id;
  cost := floor(v.chop_value * 0.40 * (u.tune_level + 1))::bigint;
  perform game.take_dirty(pid, cost);
  update game.player_vehicles set tune_level = tune_level + 1 where id = u.id;
  return jsonb_build_object('message', format('You tuned the %s to stage %s for $%s dirty cash.', v.name, u.tune_level + 1, to_char(cost, 'FM999,999,999')),
                            'me', game.me_json(pid));
end $function$;

create or replace function public.chop_car(p_token text, p_unit bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; u game.player_vehicles; v game.vehicles; pay bigint; mods jsonb;
begin
  perform game.rate_limit(pid, 'garage', 30, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  perform game.require_free(p);
  select * into u from game.player_vehicles where id = p_unit and player_id = pid for update;
  if not found then raise exception 'Car not found.'; end if;
  select * into v from game.vehicles where id = u.vehicle_id;
  mods := game.path_mods(p.specialization);
  pay := floor(v.chop_value * (1 + u.tune_level * 0.10) * coalesce((mods->>'chop')::numeric, 1))::bigint;
  delete from game.player_vehicles where id = u.id and player_id = pid;
  if not found then raise exception 'Car not found.'; end if;
  perform game.add_dirty(pid, pay);
  perform game.add_event(pid, 'chop', format('You chopped a %s for $%s dirty cash.', v.name, to_char(pay, 'FM999,999,999')));
  return jsonb_build_object('message', format('The shop paid $%s dirty cash for the %s.', to_char(pay, 'FM999,999,999'), v.name),
                            'me', game.me_json(pid));
end $function$;

create or replace function public.export_car(p_token text, p_unit bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; u game.player_vehicles; v game.vehicles; pay bigint;
begin
  perform game.rate_limit(pid, 'export', 10, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.last_export_at is not null and p.last_export_at > now() - interval '6 hours' then
    raise exception 'The docks will not take another export yet.';
  end if;
  if p.energy < 15 then raise exception 'Not enough energy.'; end if;
  select * into u from game.player_vehicles where id = p_unit and player_id = pid for update;
  if not found then raise exception 'Car not found.'; end if;
  select * into v from game.vehicles where id = u.vehicle_id;
  pay := floor(v.export_value * (1 + u.tune_level * 0.12))::bigint;
  delete from game.player_vehicles where id = u.id and player_id = pid;
  if not found then raise exception 'Car not found.'; end if;
  update game.players set energy = energy - 15, last_export_at = now() where id = pid;
  perform game.add_dirty(pid, pay);
  perform game.add_event(pid, 'export', format('You exported a %s through the docks for $%s dirty cash.', v.name, to_char(pay, 'FM999,999,999')));
  return jsonb_build_object('message', format('The docks paid $%s dirty cash for the %s.', to_char(pay, 'FM999,999,999'), v.name),
                            'me', game.me_json(pid));
end $function$;

-- ---------- fronts / businesses ----------
create or replace function public.list_businesses(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; mods jsonb;
begin
  p := game.tick(pid);
  perform game.tick_economy(pid);
  mods := game.path_mods(p.specialization);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'name', b.name, 'description', b.description, 'icon', b.icon,
      'price', b.price, 'min_level', b.min_level,
      'launder_per_hour', b.launder_per_hour,
      'fee_bps', round(b.fee_bps * coalesce((mods->>'launder_fee')::numeric, 1)),
      'owned', exists (select 1 from game.player_businesses pb where pb.player_id = pid and pb.business_id = b.id),
      'locked', p.level < b.min_level
    ) order by b.id)
    from game.business_types b
  ), '[]'::jsonb);
end $function$;

create or replace function public.buy_business(p_token text, p_business int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; b game.business_types;
begin
  perform game.rate_limit(pid, 'buy_item', 20, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  perform game.require_free(p);
  select * into b from game.business_types where id = p_business;
  if not found then raise exception 'Unknown front.'; end if;
  if p.level < b.min_level then raise exception 'You are not experienced enough for that front.'; end if;
  if exists (select 1 from game.player_businesses where player_id = pid and business_id = b.id) then
    raise exception 'You already own that front.';
  end if;
  perform game.take_dirty(pid, b.price);
  insert into game.player_businesses (player_id, business_id, last_run_at) values (pid, b.id, now());
  perform game.add_event(pid, 'front', 'You bought ' || b.name || '. Dirty cash will start coming out clean.');
  return jsonb_build_object('message', 'You now own ' || b.name || '.', 'me', game.me_json(pid));
end $function$;

-- ---------- swiss CDs ----------
create or replace function public.swiss_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  perform game.tick(pid);
  return jsonb_build_object(
    'open', (select count(*) from game.swiss_cds where player_id = pid and not collected),
    'max_open', 5,
    'terms', jsonb_build_array(
      jsonb_build_object('id', '24h', 'label', '24 hours', 'interest_bps', 200),
      jsonb_build_object('id', '72h', 'label', '72 hours', 'interest_bps', 500),
      jsonb_build_object('id', '7d',  'label', '7 days',   'interest_bps', 1200)
    ),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'amount', s.amount, 'interest_bps', s.interest_bps,
        'opened_at', s.opened_at, 'matures_at', s.matures_at,
        'ready', s.matures_at <= now(),
        'payout', case when s.matures_at <= now() then floor(s.amount * (1 + s.interest_bps / 10000.0))::bigint else s.amount end
      ) order by s.id)
      from game.swiss_cds s where s.player_id = pid and not s.collected
    ), '[]'::jsonb)
  );
end $function$;

create or replace function public.swiss_open(p_token text, p_amount bigint, p_term text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; bps int; mat interval; n int;
begin
  perform game.rate_limit(pid, 'bank', 20, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  if coalesce(p_amount, 0) < 1000 then raise exception 'Minimum deposit is $1,000 clean cash.'; end if;
  if p_term = '24h' then bps := 200; mat := interval '24 hours';
  elsif p_term = '72h' then bps := 500; mat := interval '72 hours';
  elsif p_term = '7d' then bps := 1200; mat := interval '7 days';
  else raise exception 'Choose a term: 24h, 72h or 7d.'; end if;
  select count(*) into n from game.swiss_cds where player_id = pid and not collected;
  if n >= 5 then raise exception 'You already have 5 open accounts.'; end if;
  perform game.take_clean(pid, p_amount);
  insert into game.swiss_cds (player_id, amount, interest_bps, matures_at)
    values (pid, p_amount, bps, now() + mat);
  return jsonb_build_object('message', format('Opened a Swiss account with $%s clean cash.', to_char(p_amount, 'FM999,999,999')),
                            'me', game.me_json(pid));
end $function$;

create or replace function public.swiss_collect(p_token text, p_account bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); s game.swiss_cds; pay bigint;
begin
  perform game.rate_limit(pid, 'bank', 20, interval '10 minutes', interval '1 second');
  perform game.tick(pid);
  select * into s from game.swiss_cds where id = p_account and player_id = pid and not collected for update;
  if not found then raise exception 'Account not found.'; end if;
  if s.matures_at <= now() then
    pay := floor(s.amount * (1 + s.interest_bps / 10000.0))::bigint;
  else
    pay := s.amount; -- early cash-out, no yield
  end if;
  update game.swiss_cds set collected = true where id = s.id;
  perform game.add_clean(pid, pay);
  return jsonb_build_object(
    'message', case when s.matures_at <= now()
                    then format('The account matured. You collected $%s clean cash.', to_char(pay, 'FM999,999,999'))
                    else format('You closed the account early and recovered $%s clean cash (no yield).', to_char(pay, 'FM999,999,999')) end,
    'me', game.me_json(pid));
end $function$;

-- ---------- bounties ----------
create or replace function public.list_bounties(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  perform game.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'target_id', t.id, 'username', t.username, 'level', t.level,
      'status', game.status_of(t.hospital_until, t.jail_until),
      'total', s.total, 'count', s.cnt
    ) order by s.total desc, t.id)
    from (
      select target_id, sum(amount) as total, count(*) as cnt
        from game.bounties where collected_at is null
       group by target_id
    ) s
    join game.players t on t.id = s.target_id
    where not t.is_admin and not t.banned
  ), '[]'::jsonb);
end $function$;

create or replace function public.place_bounty(p_token text, p_target bigint, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; t game.players;
begin
  perform game.rate_limit(pid, 'bounty', 15, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if coalesce(p_amount, 0) < 1000 then raise exception 'Minimum bounty is $1,000 dirty cash.'; end if;
  if p_target is null or p_target = pid then raise exception 'Player not found.'; end if;
  select * into t from game.players where id = p_target;
  if not found or t.banned or t.is_admin or t.is_npc then raise exception 'Player not found.'; end if;
  perform game.take_dirty(pid, p_amount);
  insert into game.bounties (placer_id, target_id, amount) values (pid, t.id, p_amount);
  perform game.add_event(t.id, 'bounty', format('A $%s bounty was placed on you.', to_char(p_amount, 'FM999,999,999')));
  return jsonb_build_object('message', format('You put $%s dirty cash on %s''s head.', to_char(p_amount, 'FM999,999,999'), t.username),
                            'me', game.me_json(pid));
end $function$;

-- ---------- turf ----------
create or replace function public.list_districts(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  perform game.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', d.id, 'name', d.name, 'description', d.description,
      'wealth', d.wealth, 'difficulty', d.difficulty,
      'holder_id', d.holder_id,
      'holder', (select f.name from game.factions f where f.id = d.holder_id),
      'holder_tag', (select f.tag from game.factions f where f.id = d.holder_id),
      'cooldown', case when d.contested_at is null then 0
                       else greatest(0, 3600 - extract(epoch from (now() - d.contested_at)))::int end,
      'tribute_ready', d.holder_id is not null and (d.last_tribute_at is null or d.last_tribute_at <= now() - interval '20 hours')
    ) order by d.id)
    from game.districts d
  ), '[]'::jsonb);
end $function$;

create or replace function public.contest_district(p_token text, p_district int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  d game.districts;
  att numeric := 0;
  def numeric := 0;
  won boolean;
  msg text;
begin
  perform game.rate_limit(pid, 'turf', 10, interval '10 minutes', interval '3 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.faction_id is null then raise exception 'You need a cartel to contest turf.'; end if;
  if p.energy < 30 then raise exception 'Not enough energy.'; end if;
  select * into d from game.districts where id = p_district for update;
  if not found then raise exception 'District not found.'; end if;
  if d.holder_id = p.faction_id then raise exception 'Your cartel already holds this district.'; end if;
  if d.contested_at is not null and d.contested_at > now() - interval '1 hour' then
    raise exception 'This district was just fought over. Wait before another push.';
  end if;
  update game.players set energy = energy - 30 where id = pid;
  select coalesce(sum((game.army_power(id)->>'power')::numeric), 0) into att
    from game.players where faction_id = p.faction_id and not is_admin and not banned;
  if d.holder_id is null then
    def := d.difficulty * 400;
  else
    select coalesce(sum((game.army_power(id)->>'power')::numeric), 0) into def
      from game.players where faction_id = d.holder_id and not is_admin and not banned;
    def := def + d.difficulty * 200;
  end if;
  att := att * (0.85 + random() * 0.30);
  def := def * (0.85 + random() * 0.30);
  won := att >= def;
  update game.districts set contested_at = now(), holder_id = case when won then p.faction_id else holder_id end where id = d.id;
  if won then
    msg := 'Your cartel took ' || d.name || '.';
    perform game.add_event(pid, 'turf', msg);
  else
    msg := 'Your push on ' || d.name || ' was beaten back.';
    perform game.add_event(pid, 'turf', msg);
  end if;
  return jsonb_build_object('ok', won, 'message', msg, 'me', game.me_json(pid));
end $function$;

create or replace function public.collect_tribute(p_token text, p_district int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; d game.districts; f game.factions;
begin
  perform game.rate_limit(pid, 'turf', 20, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  if p.faction_id is null then raise exception 'You are not in a cartel.'; end if;
  select * into f from game.factions where id = p.faction_id;
  if f.leader_id <> pid then raise exception 'Only the cartel leader can collect tribute.'; end if;
  select * into d from game.districts where id = p_district for update;
  if not found then raise exception 'District not found.'; end if;
  if d.holder_id <> f.id then raise exception 'Your cartel does not hold that district.'; end if;
  if d.last_tribute_at is not null and d.last_tribute_at > now() - interval '20 hours' then
    raise exception 'Tribute from that district is not ready yet.';
  end if;
  update game.districts set last_tribute_at = now() where id = d.id;
  update game.factions set vault_dirty = vault_dirty + d.wealth where id = f.id;
  perform game.add_event(pid, 'turf', format('Tribute of $%s dirty cash from %s went into the vault.', to_char(d.wealth, 'FM999,999,999'), d.name));
  return jsonb_build_object('message', format('Collected $%s dirty cash from %s into the vault.', to_char(d.wealth, 'FM999,999,999'), d.name),
                            'me', game.me_json(pid));
end $function$;


-- ---------- raids ----------
create or replace function public.list_raid_bosses(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'name', b.name, 'description', b.description,
      'min_level', b.min_level, 'min_members', b.min_members,
      'difficulty', b.difficulty, 'chest_min', b.chest_min, 'chest_max', b.chest_max,
      'energy_cost', b.energy_cost
    ) order by b.id)
    from game.raid_bosses b
  ), '[]'::jsonb);
end $function$;

create or replace function public.list_raids(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players;
begin
  p := game.tick(pid);
  if p.faction_id is null then return jsonb_build_object('raids', '[]'::jsonb); end if;
  return jsonb_build_object('raids', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'boss_id', r.boss_id, 'boss', b.name, 'status', r.status,
      'leader_id', r.leader_id,
      'leader', (select username from game.players where id = r.leader_id),
      'chest', case when r.status <> 'open' then r.chest else null end,
      'created_at', r.created_at, 'resolved_at', r.resolved_at,
      'log', case when r.status <> 'open' then r.log else '[]'::jsonb end,
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', m.player_id,
          'username', (select username from game.players where id = m.player_id),
          'role', m.role
        ) order by m.player_id)
        from game.raid_members m where m.raid_id = r.id
      ), '[]'::jsonb)
    ) order by r.id desc)
    from (select * from game.raids where faction_id = p.faction_id order by id desc limit 10) r
    join game.raid_bosses b on b.id = r.boss_id
  ), '[]'::jsonb));
end $function$;

create or replace function public.start_raid(p_token text, p_boss int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; b game.raid_bosses; rid bigint; f game.factions;
begin
  perform game.rate_limit(pid, 'raid', 8, interval '10 minutes', interval '3 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.faction_id is null then raise exception 'You need a cartel to start a raid.'; end if;
  select * into f from game.factions where id = p.faction_id;
  if f.leader_id <> pid then raise exception 'Only the cartel leader can start a raid.'; end if;
  select * into b from game.raid_bosses where id = p_boss;
  if not found then raise exception 'Unknown job.'; end if;
  if p.level < b.min_level then raise exception 'You are not experienced enough to lead that job.'; end if;
  if exists (select 1 from game.raids where faction_id = f.id and status = 'open') then
    raise exception 'Your cartel already has an open job.';
  end if;
  insert into game.raids (faction_id, boss_id, leader_id) values (f.id, b.id, pid) returning id into rid;
  insert into game.raid_members (raid_id, player_id, role) values (rid, pid, 'combat');
  perform game.add_event(pid, 'raid', 'You opened a job on ' || b.name || '.');
  return jsonb_build_object('id', rid, 'message', 'Job opened: ' || b.name || '. Your crew can join with a role.', 'me', game.me_json(pid));
end $function$;

create or replace function public.join_raid(p_token text, p_raid bigint, p_role text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; r game.raids; role text := lower(trim(coalesce(p_role,'')));
begin
  p := game.tick(pid);
  perform game.require_free(p);
  if role not in ('breach','hack','combat') then raise exception 'Choose a role: breach, hack or combat.'; end if;
  if p.faction_id is null then raise exception 'You are not in a cartel.'; end if;
  select * into r from game.raids where id = p_raid for update;
  if not found or r.faction_id <> p.faction_id or r.status <> 'open' then raise exception 'Job not found.'; end if;
  if exists (select 1 from game.raid_members where raid_id = r.id and player_id = pid) then
    update game.raid_members set role = role where raid_id = r.id and player_id = pid;
    return jsonb_build_object('message', 'Role updated to ' || role || '.', 'me', game.me_json(pid));
  end if;
  insert into game.raid_members (raid_id, player_id, role) values (r.id, pid, role);
  return jsonb_build_object('message', 'You joined the job as ' || role || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.commit_raid(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  r game.raids;
  b game.raid_bosses;
  n int;
  n_br int; n_hk int; n_cb int;
  power numeric;
  v_log jsonb := '[]'::jsonb;
  ok_br boolean; ok_hk boolean; ok_cb boolean;
  v_chest bigint := 0;
  rec record;
  ch numeric;
  won boolean;
begin
  perform game.rate_limit(pid, 'raid', 8, interval '10 minutes', interval '3 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.faction_id is null then raise exception 'You are not in a cartel.'; end if;
  select * into r from game.raids where faction_id = p.faction_id and status = 'open' for update;
  if not found then raise exception 'There is no open job.'; end if;
  if r.leader_id <> pid then raise exception 'Only the job leader can commit the raid.'; end if;
  select * into b from game.raid_bosses where id = r.boss_id;
  select count(*),
         count(*) filter (where role = 'breach'),
         count(*) filter (where role = 'hack'),
         count(*) filter (where role = 'combat')
    into n, n_br, n_hk, n_cb
    from game.raid_members where raid_id = r.id;
  if n < b.min_members then raise exception 'You need at least % people on this job.', b.min_members; end if;

  -- Charge energy and require everyone free. Lock members in id order.
  for rec in
    select m.player_id, pl.energy, pl.hospital_until, pl.jail_until, pl.level
      from game.raid_members m
      join game.players pl on pl.id = m.player_id
     where m.raid_id = r.id
     order by m.player_id
     for update of pl
  loop
    perform game.tick(rec.player_id);
    select energy, hospital_until, jail_until into rec.energy, rec.hospital_until, rec.jail_until
      from game.players where id = rec.player_id;
    if rec.hospital_until is not null and rec.hospital_until > now() then
      raise exception 'Someone on the job is in the hospital.';
    end if;
    if rec.jail_until is not null and rec.jail_until > now() then
      raise exception 'Someone on the job is in jail.';
    end if;
    if rec.energy < b.energy_cost then
      raise exception 'Someone on the job does not have enough energy.';
    end if;
    update game.players set energy = energy - b.energy_cost where id = rec.player_id;
  end loop;

  select coalesce(sum((game.army_power(m.player_id)->>'power')::numeric), 0) into power
    from game.raid_members m where m.raid_id = r.id;

  ch := least(0.92, greatest(0.15, 0.50 + n_br * 0.10 - b.difficulty * 0.08 + least(0.15, power / 8000.0)));
  ok_br := random() < ch;
  v_log := v_log || jsonb_build_array(jsonb_build_object('stage','breach','ok', ok_br, 'chance', round(ch*100)));

  ch := least(0.92, greatest(0.15, 0.50 + n_hk * 0.10 - b.difficulty * 0.08 + least(0.15, power / 8000.0)));
  ok_hk := random() < ch;
  v_log := v_log || jsonb_build_array(jsonb_build_object('stage','hack','ok', ok_hk, 'chance', round(ch*100)));

  ch := least(0.92, greatest(0.15, 0.50 + n_cb * 0.10 - b.difficulty * 0.08 + least(0.15, power / 8000.0)));
  ok_cb := random() < ch;
  v_log := v_log || jsonb_build_array(jsonb_build_object('stage','combat','ok', ok_cb, 'chance', round(ch*100)));

  won := ok_br and ok_hk and ok_cb;
  if won then
    v_chest := (b.chest_min + floor(random() * (b.chest_max - b.chest_min + 1)))::bigint;
    update game.factions set vault_dirty = vault_dirty + v_chest where id = r.faction_id;
  end if;
  update game.raids
     set status = case when won then 'won' else 'failed' end,
         resolved_at = now(), chest = v_chest, log = v_log
   where id = r.id;

  insert into game.events (player_id, kind, message)
    select m.player_id, 'raid',
           case when won then format('The job on %s paid $%s dirty cash into the vault.', b.name, to_char(v_chest, 'FM999,999,999'))
                else 'The job on ' || b.name || ' fell apart.' end
      from game.raid_members m where m.raid_id = r.id;

  return jsonb_build_object(
    'ok', won, 'chest', v_chest, 'log', v_log,
    'message', case when won then format('The job succeeded. $%s dirty cash went into the vault.', to_char(v_chest, 'FM999,999,999'))
                    else 'The job failed. The vault is unchanged.' end,
    'me', game.me_json(pid));
end $function$;

-- ---------- hospital hits & jail breaks ----------
create or replace function public.hospital_hit(p_token text, p_target bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  t game.players;
  mods jsonb;
  chance numeric;
  extra int;
  pay bigint := 0;
begin
  perform game.rate_limit(pid, 'hit', 12, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.energy < 20 then raise exception 'Not enough energy.'; end if;
  if p.last_hit_at is not null and p.last_hit_at > now() - interval '15 minutes' then
    raise exception 'You already made a hospital move recently.';
  end if;
  if p_target is null or p_target = pid then raise exception 'Player not found.'; end if;
  if pid < p_target then
    perform 1 from game.players where id = pid for update;
    select * into t from game.players where id = p_target for update;
  else
    select * into t from game.players where id = p_target for update;
    perform 1 from game.players where id = pid for update;
  end if;
  if t is null or t.banned or t.is_admin or t.is_npc then raise exception 'Player not found.'; end if;
  perform game.tick(t.id);
  select * into t from game.players where id = t.id;
  if t.hospital_until is null or t.hospital_until <= now() then raise exception 'That player is not in the hospital.'; end if;
  update game.players set energy = energy - 20, last_hit_at = now() where id = pid;
  mods := game.path_mods(p.specialization);
  chance := least(0.90, greatest(0.12, 0.40 * coalesce((mods->>'hit')::numeric, 1) + least(0.20, p.dex / 2000.0)));
  if random() > chance then
    if random() < 0.4 then
      update game.players set jail_until = now() + interval '20 minutes' where id = pid;
      perform game.add_event(pid, 'hit', 'The hospital hit went wrong. You landed in jail.');
      return jsonb_build_object('ok', false, 'message', 'You were pinched in the ward and thrown in jail.', 'me', game.me_json(pid));
    end if;
    perform game.add_event(pid, 'hit', 'Your hospital hit on ' || t.username || ' missed.');
    return jsonb_build_object('ok', false, 'message', 'You could not get close enough.', 'me', game.me_json(pid));
  end if;
  extra := 20 + floor(random() * 21)::int;
  pay := floor(t.cash * 0.08)::bigint;
  if pay > 0 then
    update game.players set cash = cash - pay, hospital_until = hospital_until + make_interval(mins => extra) where id = t.id;
    perform game.add_dirty(pid, pay);
  else
    update game.players set hospital_until = hospital_until + make_interval(mins => extra) where id = t.id;
  end if;
  perform game.add_event(t.id, 'hit', format('%s hit you in the hospital. You will be there longer.%s', p.username,
    case when pay > 0 then format(' They took $%s.', to_char(pay, 'FM999,999,999')) else '' end));
  perform game.add_event(pid, 'hit', format('You hit %s in the hospital.', t.username));
  return jsonb_build_object('ok', true,
    'message', format('You hit %s. They stay another %s minutes.%s', t.username, extra,
      case when pay > 0 then format(' You took $%s dirty cash.', to_char(pay, 'FM999,999,999')) else '' end),
    'me', game.me_json(pid));
end $function$;

create or replace function public.jail_break(p_token text, p_target bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  t game.players;
  chance numeric;
begin
  perform game.rate_limit(pid, 'break', 12, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.energy < 20 then raise exception 'Not enough energy.'; end if;
  if p.last_break_at is not null and p.last_break_at > now() - interval '15 minutes' then
    raise exception 'You already tried a breakout recently.';
  end if;
  if p_target is null or p_target = pid then raise exception 'Player not found.'; end if;
  if pid < p_target then
    perform 1 from game.players where id = pid for update;
    select * into t from game.players where id = p_target for update;
  else
    select * into t from game.players where id = p_target for update;
    perform 1 from game.players where id = pid for update;
  end if;
  if t is null or t.banned or t.is_admin or t.is_npc then raise exception 'Player not found.'; end if;
  perform game.tick(t.id);
  select * into t from game.players where id = t.id;
  if t.jail_until is null or t.jail_until <= now() then raise exception 'That player is not in jail.'; end if;
  update game.players set energy = energy - 20, last_break_at = now() where id = pid;
  chance := least(0.85, greatest(0.15, 0.45 + least(0.20, p.spd / 2000.0) + case when p.specialization = 'fixer' then 0.10 else 0 end));
  if random() > chance then
    update game.players set jail_until = now() + interval '20 minutes' where id = pid;
    perform game.add_event(pid, 'break', 'The breakout failed. You landed in jail.');
    return jsonb_build_object('ok', false, 'message', 'The breakout failed and you were locked up.', 'me', game.me_json(pid));
  end if;
  update game.players set jail_until = null where id = t.id;
  perform game.add_event(t.id, 'break', p.username || ' broke you out of jail.');
  perform game.add_event(pid, 'break', 'You broke ' || t.username || ' out of jail.');
  return jsonb_build_object('ok', true, 'message', 'You broke ' || t.username || ' out of jail.', 'me', game.me_json(pid));
end $function$;

-- ---------- specialization ----------
create or replace function public.choose_path(p_token text, p_spec text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; s text := lower(trim(coalesce(p_spec,'')));
begin
  p := game.tick(pid);
  if p.level < 15 then raise exception 'You can choose a path at level 15.'; end if;
  if p.specialization is not null then raise exception 'You already chose your path.'; end if;
  if s not in ('enforcer','hustler','fixer','ghost') then raise exception 'Choose Enforcer, Hustler, Fixer or Ghost.'; end if;
  update game.players set specialization = s where id = pid;
  perform game.add_event(pid, 'path', 'You chose the ' || initcap(s) || ' path.');
  return jsonb_build_object('message', 'You are now a ' || initcap(s) || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.path_action(p_token text, p_action text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  act text := lower(trim(coalesce(p_action,'')));
  pay bigint;
  msg text;
begin
  perform game.rate_limit(pid, 'path', 10, interval '10 minutes', interval '2 seconds');
  p := game.tick(pid);
  if p.specialization is null then raise exception 'You have not chosen a path yet.'; end if;
  -- vanish / strings may be used while locked up; others need a free player.
  if act not in ('vanish','strings') then
    perform game.require_free(p);
  end if;
  if p.last_path_at is not null and p.last_path_at > now() - interval '30 minutes' then
    raise exception 'Your path move is still cooling down.';
  end if;

  if p.specialization = 'enforcer' and act = 'stand' then
    if p.energy < 15 then raise exception 'Not enough energy.'; end if;
    update game.players
       set energy = energy - 15, last_path_at = now(),
           path_buff = 'stand', path_buff_until = now() + interval '10 minutes'
     where id = pid;
    msg := 'You plant your feet. The next fight hits you softer.';

  elsif p.specialization = 'enforcer' and act = 'shake' then
    if p.energy < 20 then raise exception 'Not enough energy.'; end if;
    pay := (200 * p.level)::bigint;
    update game.players set energy = energy - 20, last_path_at = now() where id = pid;
    perform game.add_dirty(pid, pay);
    msg := format('You shook the block down for $%s dirty cash.', to_char(pay, 'FM999,999,999'));

  elsif p.specialization = 'hustler' and act = 'hustle' then
    if p.energy < 15 then raise exception 'Not enough energy.'; end if;
    pay := (300 * p.level)::bigint;
    update game.players set energy = energy - 15, last_path_at = now() where id = pid;
    perform game.add_dirty(pid, pay);
    msg := format('A quick hustle paid $%s dirty cash.', to_char(pay, 'FM999,999,999'));

  elsif p.specialization = 'hustler' and act = 'flip' then
    if p.energy < 15 then raise exception 'Not enough energy.'; end if;
    pay := (180 * p.level)::bigint;
    update game.players set energy = energy - 15, last_path_at = now() where id = pid;
    perform game.add_clean(pid, pay);
    msg := format('You flipped a short pile into $%s clean cash.', to_char(pay, 'FM999,999,999'));

  elsif p.specialization = 'fixer' and act = 'strings' then
    if p.jail_until is null or p.jail_until <= now() then raise exception 'You are not in jail.'; end if;
    update game.players set jail_until = null, last_path_at = now() where id = pid;
    msg := 'You pulled strings and walked out of jail.';

  elsif p.specialization = 'fixer' and act = 'grease' then
    if p.energy < 15 then raise exception 'Not enough energy.'; end if;
    update game.players
       set energy = energy - 15, last_path_at = now(),
           path_buff = 'crime_edge', path_buff_until = now() + interval '15 minutes'
     where id = pid;
    msg := 'You greased a few palms. Your next jobs are cleaner.';

  elsif p.specialization = 'ghost' and act = 'mark' then
    if p.energy < 15 then raise exception 'Not enough energy.'; end if;
    update game.players
       set energy = energy - 15, last_path_at = now(),
           path_buff = 'marked', path_buff_until = now() + interval '10 minutes'
     where id = pid;
    msg := 'You mark a target. The next fight hits harder and their armor matters less.';

  elsif p.specialization = 'ghost' and act = 'vanish' then
    if p.hospital_until is null or p.hospital_until <= now() then raise exception 'You are not in the hospital.'; end if;
    update game.players set hospital_until = null, hp = game.max_hp(p.level), hp_at = now(), last_path_at = now() where id = pid;
    msg := 'You slipped out of the ward without paying.';

  else
    raise exception 'That is not a move on your path.';
  end if;

  perform game.add_event(pid, 'path', msg);
  return jsonb_build_object('message', msg, 'me', game.me_json(pid));
end $function$;


create or replace function public.jail_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
begin
  perform game.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'username', p.username, 'level', p.level, 'until', p.jail_until
    ) order by p.jail_until)
    from game.players p
    where p.jail_until > now() and not p.is_admin and not p.banned
  ), '[]'::jsonb);
end $function$;
