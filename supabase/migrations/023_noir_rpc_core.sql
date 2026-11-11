-- Noir Syndicate: rewritten core RPCs (crimes, streets, market, bank, crew, cartels, lists, admin strings).

create or replace function public.get_me(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  perform game.tick(pid);
  perform game.tick_economy(pid);
  return game.me_json(pid) || jsonb_build_object(
    'announcement', (select jsonb_build_object('message', message, 'created_at', created_at)
                       from game.announcements where active order by id desc limit 1),
    'unread', (select count(*) from game.events where player_id = pid and not seen),
    'recent_events', coalesce((select jsonb_agg(e order by e.id desc) from
        (select id, kind, message, created_at, seen from game.events where player_id = pid order by id desc limit 6) e), '[]'::jsonb)
  );
end $function$;

create or replace function game.public_player(p game.players) returns jsonb
language sql stable set search_path = '' as $function$
  select jsonb_build_object(
    'id', p.id,
    'username', case when p.is_admin then 'The Boss' else p.username end,
    'level', p.level,
    'rank', game.rank_title(p.level),
    'status', game.status_of(p.hospital_until, p.jail_until),
    'npc', p.is_npc,
    'staff', false,
    'online', p.last_action > now() - interval '10 minutes',
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag)
                  from game.factions f where f.id = p.faction_id),
    'wins', p.wins,
    'losses', p.losses,
    'joined', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD')
  )
$function$;

-- ---------- crimes ----------
create or replace function public.list_crimes(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; mods jsonb;
begin
  p := game.tick(pid);
  mods := game.path_mods(p.specialization);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'description', c.description, 'tier', c.tier,
      'nerve_cost', c.nerve_cost, 'min_level', c.min_level,
      'cash_min', c.cash_min, 'cash_max', c.cash_max, 'xp', c.xp,
      'locked', p.level < c.min_level,
      'chance', case when p.level < c.min_level then 0
                     else least(95, greatest(8, round((c.base_chance
                       + least(0.20, p.dex / 2000.0)
                       + least(0.10, p.level / 400.0)
                       + coalesce((mods->>'crime_chance')::numeric, 0)) * 100))) end
    ) order by c.id)
    from game.crimes c
  ), '[]'::jsonb);
end $function$;

create or replace function public.do_crime(p_token text, p_crime int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  c game.crimes;
  mods jsonb;
  chance numeric;
  roll numeric;
  pay bigint;
  jail_m int;
begin
  perform game.rate_limit(pid, 'do_crime', 30, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  perform game.require_free(p);
  select * into c from game.crimes where id = p_crime;
  if not found then raise exception 'Unknown crime.'; end if;
  if p.level < c.min_level then raise exception 'You are not experienced enough for that job.'; end if;
  if p.nerve < c.nerve_cost then raise exception 'Not enough nerve.'; end if;
  mods := game.path_mods(p.specialization);
  chance := least(0.95, greatest(0.08, c.base_chance
            + least(0.20, p.dex / 2000.0)
            + least(0.10, p.level / 400.0)
            + coalesce((mods->>'crime_chance')::numeric, 0)));
  if p.path_buff = 'crime_edge' and p.path_buff_until > now() then
    chance := least(0.95, chance + 0.08);
  end if;
  update game.players set nerve = nerve - c.nerve_cost where id = pid;
  roll := random();
  if roll <= chance then
    pay := (c.cash_min + floor(random() * (c.cash_max - c.cash_min + 1)))::bigint;
    pay := ceil(pay * coalesce((mods->>'crime_cash')::numeric, 1))::bigint;
    perform game.add_dirty(pid, pay);
    update game.players set crimes_done = crimes_done + 1, missions_done = missions_done + 1 where id = pid;
    perform game.add_xp(pid, c.xp);
    perform game.add_event(pid, 'crime', c.success_text || format(' You took $%s dirty cash.', to_char(pay, 'FM999,999,999')));
    return jsonb_build_object('result', 'success', 'message', c.success_text || format(' You took $%s dirty cash and %s XP.', to_char(pay, 'FM999,999,999'), c.xp),
                              'cash', pay, 'xp', c.xp, 'me', game.me_json(pid));
  end if;
  -- Failure: wound or jail, shortened for Fixers.
  if random() < 0.45 then
    jail_m := greatest(2, ceil((5 + c.tier * 2) * coalesce((mods->>'jail')::numeric, 1)))::int;
    update game.players set jail_until = now() + make_interval(mins => jail_m) where id = pid;
    perform game.add_event(pid, 'crime', c.fail_text || ' You were picked up.');
    return jsonb_build_object('result', 'fail', 'message', c.fail_text || format(' You were jailed for %s minutes.', jail_m),
                              'me', game.me_json(pid));
  else
    update game.players set hp = greatest(1, hp - (8 + c.tier * 4)),
      hospital_until = case when hp - (8 + c.tier * 4) <= 0
                            then now() + make_interval(mins => greatest(3, c.tier * 2))
                            else hospital_until end
     where id = pid;
    perform game.add_event(pid, 'crime', c.fail_text);
    return jsonb_build_object('result', 'fail', 'message', c.fail_text, 'me', game.me_json(pid));
  end if;
end $function$;

-- ---------- black market ----------
create or replace function public.list_items(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players;
begin
  p := game.tick(pid);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'name', i.name, 'kind', i.kind, 'power', i.power, 'price', i.price,
      'min_level', i.min_level, 'description', i.description, 'icon', i.icon,
      'owned', coalesce(inv.qty, 0),
      'equipped', (i.id = p.weapon_id or i.id = p.armor_id)
    ) order by i.kind, i.min_level, i.id)
    from game.items i
    left join game.inventory inv on inv.player_id = pid and inv.item_id = i.id
  ), '[]'::jsonb);
end $function$;

create or replace function public.buy_item(p_token text, p_item int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; it game.items;
begin
  perform game.rate_limit(pid, 'buy_item', 40, interval '10 minutes', interval '0.4 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  select * into it from game.items where id = p_item;
  if not found then raise exception 'Unknown item.'; end if;
  if p.level < it.min_level then raise exception 'You are not experienced enough for that item.'; end if;
  perform game.take_dirty(pid, it.price);
  insert into game.inventory (player_id, item_id, qty) values (pid, it.id, 1)
    on conflict (player_id, item_id) do update set qty = game.inventory.qty + 1;
  return jsonb_build_object('message', 'Bought ' || it.name || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.sell_item(p_token text, p_item int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; it game.items; q int; refund bigint;
begin
  p := game.tick(pid);
  select * into it from game.items where id = p_item;
  if not found then raise exception 'Unknown item.'; end if;
  select qty into q from game.inventory where player_id = pid and item_id = p_item;
  if q is null then raise exception 'You do not own that.'; end if;
  if p.weapon_id = p_item or p.armor_id = p_item then
    if q <= 1 then raise exception 'Unequip it before selling your last one.'; end if;
  end if;
  refund := ceil(it.price * 0.5)::bigint;
  if q <= 1 then delete from game.inventory where player_id = pid and item_id = p_item;
  else update game.inventory set qty = qty - 1 where player_id = pid and item_id = p_item; end if;
  perform game.add_dirty(pid, refund);
  return jsonb_build_object('message', format('Sold %s for $%s dirty cash.', it.name, to_char(refund, 'FM999,999,999')), 'me', game.me_json(pid));
end $function$;

-- equip / unequip stay valid (signatures unchanged). Recreate to keep search_path tight and messages thematic.
create or replace function public.equip_item(p_token text, p_item int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; it game.items;
begin
  p := game.tick(pid);
  select * into it from game.items where id = p_item;
  if not found then raise exception 'Unknown item.'; end if;
  if not exists (select 1 from game.inventory where player_id = pid and item_id = p_item) then
    raise exception 'You do not own that.'; end if;
  if p.level < it.min_level then raise exception 'You are not experienced enough for that item.'; end if;
  if it.kind = 'weapon' then update game.players set weapon_id = it.id where id = pid;
  else update game.players set armor_id = it.id where id = pid; end if;
  return jsonb_build_object('message', 'Equipped ' || it.name || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.unequip_item(p_token text, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  perform game.tick(pid);
  if p_kind = 'weapon' then update game.players set weapon_id = null where id = pid;
  elsif p_kind = 'armor' then update game.players set armor_id = null where id = pid;
  else raise exception 'Invalid slot.'; end if;
  return jsonb_build_object('message', 'Unequipped.', 'me', game.me_json(pid));
end $function$;


-- ---------- bank (clean money) and teller laundering ----------
create or replace function public.bank_deposit(p_token text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; fee bigint; net bigint;
begin
  perform game.rate_limit(pid, 'bank', 20, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  if coalesce(p_amount, 0) <= 0 then raise exception 'Invalid amount.'; end if;
  perform game.take_clean(pid, p_amount);
  fee := ceil(p_amount * 0.01)::bigint;
  net := p_amount - fee;
  update game.players set bank = bank + net where id = pid;
  return jsonb_build_object('message', format('Deposited $%s clean cash (1%% fee $%s).', to_char(net, 'FM999,999,999'), to_char(fee, 'FM999,999,999')),
                            'me', game.me_json(pid));
end $function$;

create or replace function public.bank_withdraw(p_token text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players;
begin
  perform game.rate_limit(pid, 'bank', 20, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  if coalesce(p_amount, 0) <= 0 then raise exception 'Invalid amount.'; end if;
  if p.bank < p_amount then raise exception 'Not enough money in the bank.'; end if;
  update game.players set bank = bank - p_amount, clean_cash = clean_cash + p_amount where id = pid;
  return jsonb_build_object('message', format('Withdrew $%s clean cash.', to_char(p_amount, 'FM999,999,999')), 'me', game.me_json(pid));
end $function$;

create or replace function public.bank_launder(p_token text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; fee bigint; net bigint; mods jsonb;
begin
  perform game.rate_limit(pid, 'bank', 20, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  if coalesce(p_amount, 0) <= 0 then raise exception 'Invalid amount.'; end if;
  mods := game.path_mods(p.specialization);
  perform game.take_dirty(pid, p_amount);
  fee := ceil(p_amount * 0.30 * coalesce((mods->>'launder_fee')::numeric, 1))::bigint;
  if fee >= p_amount then raise exception 'The teller fee would swallow that amount.'; end if;
  net := p_amount - fee;
  perform game.add_clean(pid, net);
  return jsonb_build_object('message', format('The teller cleaned $%s into $%s clean cash (fee $%s).', to_char(p_amount, 'FM999,999,999'), to_char(net, 'FM999,999,999'), to_char(fee, 'FM999,999,999')),
                            'me', game.me_json(pid));
end $function$;

-- ---------- hospital / jail ----------
create or replace function public.revive(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; left_s numeric; cost bigint;
begin
  p := game.tick(pid);
  if p.hospital_until is null or p.hospital_until <= now() then raise exception 'You are not in the hospital.'; end if;
  left_s := extract(epoch from (p.hospital_until - now()));
  cost := (50 * p.level + ceil(left_s / 60) * 25)::bigint;
  perform game.take_any(pid, cost);
  update game.players set hospital_until = null, hp = game.max_hp(p.level), hp_at = now() where id = pid;
  return jsonb_build_object('message', format('You paid $%s for treatment and walked out.', to_char(cost, 'FM999,999,999')), 'me', game.me_json(pid));
end $function$;

create or replace function public.pay_bail(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; left_s numeric; cost bigint; mods jsonb;
begin
  p := game.tick(pid);
  if p.jail_until is null or p.jail_until <= now() then raise exception 'You are not in jail.'; end if;
  mods := game.path_mods(p.specialization);
  left_s := extract(epoch from (p.jail_until - now()));
  cost := ceil((75 * p.level + ceil(left_s / 60) * 30) * coalesce((mods->>'bail')::numeric, 1))::bigint;
  perform game.take_any(pid, cost);
  update game.players set jail_until = null where id = pid;
  return jsonb_build_object('message', format('You paid $%s and walked out of jail.', to_char(cost, 'FM999,999,999')), 'me', game.me_json(pid));
end $function$;

create or replace function public.hospital_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  perform game.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'username', p.username, 'level', p.level, 'until', p.hospital_until
    ) order by p.hospital_until)
    from game.players p
    where p.hospital_until > now() and not p.is_admin and not p.banned
  ), '[]'::jsonb);
end $function$;

-- ---------- crew (personal soldiers) ----------
create or replace function public.get_crew(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; pw jsonb;
begin
  p := game.tick(pid);
  pw := game.army_power(pid);
  return jsonb_build_object(
    'level', p.level,
    'force_class', pw->>'class',
    'crew_class', pw->>'class',
    'troops', p.troops,
    'max_troops', game.max_troops(p.level),
    'cost10', case when p.troops + 10 <= 1000 then game.recruit_cost(p.troops, 10) end,
    'cost100', case when p.troops + 100 <= 1000 then game.recruit_cost(p.troops, 100) end,
    'power', pw,
    'weapons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', tw.id, 'name', tw.name, 'description', tw.description, 'icon', tw.icon,
        'attack', tw.attack, 'defense', tw.defense, 'price', tw.price, 'min_level', tw.min_level,
        'owned', coalesce(pw2.qty, 0)
      ) order by tw.id)
      from game.troop_weapons tw
      left join game.player_troop_weapons pw2 on pw2.player_id = pid and pw2.weapon_id = tw.id
    ), '[]'::jsonb)
  );
end $function$;

create or replace function public.recruit_crew(p_token text, p_count int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; n int; cost bigint; energy_cost int;
begin
  perform game.rate_limit(pid, 'recruit', 30, interval '10 minutes', interval '0.5 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  n := coalesce(p_count, 0);
  if n < 1 or n > 1000 then raise exception 'Invalid crew size.'; end if;
  if p.troops + n > 1000 then raise exception 'A crew cannot exceed 1,000.'; end if;
  cost := game.recruit_cost(p.troops, n);
  energy_cost := ceil(n / 20.0)::int;
  if p.energy < energy_cost then raise exception 'Not enough energy.'; end if;
  perform game.take_dirty(pid, cost);
  update game.players set troops = troops + n, energy = energy - energy_cost where id = pid;
  return jsonb_build_object('message', format('Hired %s crew for $%s dirty cash.', n, to_char(cost, 'FM999,999,999')), 'me', game.me_json(pid));
end $function$;

create or replace function public.dismiss_crew(p_token text, p_count int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; n int;
begin
  p := game.tick(pid);
  n := coalesce(p_count, 0);
  if n < 1 then raise exception 'Invalid crew size.'; end if;
  if p.troops < n then raise exception 'You do not have that many crew.'; end if;
  update game.players set troops = troops - n where id = pid;
  return jsonb_build_object('message', format('Dismissed %s crew. There is no refund.', n), 'me', game.me_json(pid));
end $function$;

create or replace function public.buy_crew_weapon(p_token text, p_weapon int, p_qty int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; w game.troop_weapons; q int;
begin
  perform game.rate_limit(pid, 'buy_item', 40, interval '10 minutes', interval '0.4 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  q := coalesce(p_qty, 0);
  if q < 1 or q > 1000 then raise exception 'Invalid quantity.'; end if;
  select * into w from game.troop_weapons where id = p_weapon;
  if not found then raise exception 'Unknown weapon.'; end if;
  if p.level < w.min_level then raise exception 'You are not experienced enough for that.'; end if;
  perform game.take_dirty(pid, w.price * q);
  insert into game.player_troop_weapons (player_id, weapon_id, qty) values (pid, w.id, q)
    on conflict (player_id, weapon_id) do update set qty = game.player_troop_weapons.qty + q;
  return jsonb_build_object('message', format('Bought %s × %s.', q, w.name), 'me', game.me_json(pid));
end $function$;

create or replace function public.sell_crew_weapon(p_token text, p_weapon int, p_qty int) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); w game.troop_weapons; have int; q int; refund bigint;
begin
  perform game.tick(pid);
  q := coalesce(p_qty, 0);
  if q < 1 then raise exception 'Invalid quantity.'; end if;
  select * into w from game.troop_weapons where id = p_weapon;
  if not found then raise exception 'Unknown weapon.'; end if;
  select qty into have from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon;
  if coalesce(have, 0) < q then raise exception 'You do not have that many.'; end if;
  refund := ceil(w.price * 0.5)::bigint * q;
  if have = q then delete from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon;
  else update game.player_troop_weapons set qty = qty - q where player_id = pid and weapon_id = p_weapon; end if;
  perform game.add_dirty(pid, refund);
  return jsonb_build_object('message', format('Sold %s × %s for $%s dirty cash.', q, w.name, to_char(refund, 'FM999,999,999')), 'me', game.me_json(pid));
end $function$;


-- ---------- cartels (factions) ----------
create or replace function public.list_cartels(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id, 'name', f.name, 'tag', f.tag,
      'leader', (select case when is_admin then 'The Boss' else username end from game.players where id = f.leader_id),
      'members', (select count(*) from game.players where faction_id = f.id and not is_admin),
      'total_level', (select coalesce(sum(level),0) from game.players where faction_id = f.id and not is_admin),
      'class', game.crew_class(coalesce((select sum((game.army_power(id)->>'power')::numeric) from game.players where faction_id = f.id and not is_admin), 0)),
      'districts', (select count(*) from game.districts where holder_id = f.id)
    ) order by (select count(*) from game.players where faction_id = f.id) desc, f.id)
    from game.factions f
  ), '[]'::jsonb);
end $function$;

create or replace function public.get_cartel(p_token text, p_cartel bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); f game.factions; is_member boolean; is_leader boolean;
begin
  select * into f from game.factions where id = p_cartel;
  if not found then raise exception 'Cartel not found.'; end if;
  is_member := exists (select 1 from game.players where id = pid and faction_id = f.id);
  is_leader := f.leader_id = pid;
  return jsonb_build_object(
    'id', f.id, 'name', f.name, 'tag', f.tag, 'description', f.description,
    'leader_id', case when exists (select 1 from game.players where id = f.leader_id and is_admin) then null else f.leader_id end,
    'leader', (select case when is_admin then 'The Boss' else username end from game.players where id = f.leader_id),
    'is_member', is_member, 'is_leader', is_leader,
    'vault_dirty', case when is_member then f.vault_dirty else null end,
    'vault_clean', case when is_member then f.vault_clean else null end,
    'class', game.crew_class(coalesce((select sum((game.army_power(id)->>'power')::numeric) from game.players where faction_id = f.id and not is_admin), 0)),
    'districts', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'wealth', d.wealth) order by d.id)
      from game.districts d where d.holder_id = f.id
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(game.public_player(p) || jsonb_build_object('is_leader', p.id = f.leader_id) order by p.level desc, p.id)
      from game.players p where p.faction_id = f.id and not p.is_admin
    ), '[]'::jsonb)
  );
end $function$;

create or replace function public.create_cartel(p_token text, p_name text, p_tag text, p_description text default '') returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; fid bigint;
  n text := trim(p_name); t text := upper(trim(p_tag)); d text := left(trim(coalesce(p_description,'')), 300);
begin
  perform game.rate_limit(pid, 'create_faction', 3, interval '1 day', interval '5 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.faction_id is not null then raise exception 'You already belong to a cartel.'; end if;
  if n is null or n !~ '^[A-Za-z0-9][A-Za-z0-9 _''-]{2,23}$' then raise exception 'Cartel name must be 3-24 letters, numbers, spaces or -_.'; end if;
  if t is null or t !~ '^[A-Z0-9]{2,5}$' then raise exception 'Tag must be 2-5 letters or numbers.'; end if;
  perform game.take_dirty(pid, 10000);
  insert into game.factions (name, tag, description, leader_id) values (n, t, d, pid) returning id into fid;
  update game.players set faction_id = fid where id = pid;
  return jsonb_build_object('id', fid, 'message', 'You founded ' || n || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.join_cartel(p_token text, p_cartel bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; f game.factions;
begin
  p := game.tick(pid);
  perform game.require_free(p);
  if p.faction_id is not null then raise exception 'You already belong to a cartel.'; end if;
  select * into f from game.factions where id = p_cartel;
  if not found then raise exception 'Cartel not found.'; end if;
  update game.players set faction_id = f.id where id = pid;
  perform game.add_event(pid, 'cartel', 'You joined ' || f.name || '.');
  return jsonb_build_object('message', 'You joined ' || f.name || '.', 'me', game.me_json(pid));
end $function$;

create or replace function public.leave_cartel(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; f game.factions;
begin
  p := game.tick(pid);
  if p.faction_id is null then raise exception 'You are not in a cartel.'; end if;
  select * into f from game.factions where id = p.faction_id;
  if f.leader_id = pid then
    -- Pass leadership or dissolve if last member.
    if (select count(*) from game.players where faction_id = f.id) > 1 then
      update game.factions set leader_id = (
        select id from game.players where faction_id = f.id and id <> pid order by level desc, id limit 1
      ) where id = f.id;
    else
      update game.districts set holder_id = null where holder_id = f.id;
      update game.players set faction_id = null where id = pid;
      delete from game.raids where faction_id = f.id and status = 'open';
      delete from game.factions where id = f.id;
      return jsonb_build_object('message', 'The cartel was dissolved.', 'me', game.me_json(pid));
    end if;
  end if;
  update game.players set faction_id = null where id = pid;
  return jsonb_build_object('message', 'You left the cartel.', 'me', game.me_json(pid));
end $function$;

create or replace function public.cartel_vault(p_token text, p_kind text, p_amount bigint, p_dir text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; f game.factions; amt bigint := coalesce(p_amount,0);
begin
  perform game.rate_limit(pid, 'bank', 20, interval '10 minutes', interval '1 second');
  p := game.tick(pid);
  if p.faction_id is null then raise exception 'You are not in a cartel.'; end if;
  select * into f from game.factions where id = p.faction_id for update;
  if amt <= 0 then raise exception 'Invalid amount.'; end if;
  if p_kind not in ('dirty','clean') then raise exception 'Choose dirty or clean cash.'; end if;
  if p_dir = 'deposit' then
    if p_kind = 'dirty' then
      perform game.take_dirty(pid, amt);
      update game.factions set vault_dirty = vault_dirty + amt where id = f.id;
    else
      perform game.take_clean(pid, amt);
      update game.factions set vault_clean = vault_clean + amt where id = f.id;
    end if;
    return jsonb_build_object('message', 'Deposited into the cartel vault.', 'me', game.me_json(pid));
  elsif p_dir = 'withdraw' then
    if f.leader_id <> pid then raise exception 'Only the cartel leader can withdraw from the vault.'; end if;
    if p_kind = 'dirty' then
      if f.vault_dirty < amt then raise exception 'The vault does not have that much dirty cash.'; end if;
      update game.factions set vault_dirty = vault_dirty - amt where id = f.id;
      perform game.add_dirty(pid, amt);
    else
      if f.vault_clean < amt then raise exception 'The vault does not have that much clean cash.'; end if;
      update game.factions set vault_clean = vault_clean - amt where id = f.id;
      perform game.add_clean(pid, amt);
    end if;
    return jsonb_build_object('message', 'Withdrew from the cartel vault.', 'me', game.me_json(pid));
  else
    raise exception 'Choose deposit or withdraw.';
  end if;
end $function$;

-- ---------- directory, profile, boards, chat, events ----------
create or replace function public.list_players(p_token text, p_search text default null, p_page int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); q text := lower(trim(coalesce(p_search,''))); pg int := greatest(coalesce(p_page,0), 0);
begin
  return coalesce((
    select jsonb_agg(game.public_player(p) order by p.level desc, p.id)
    from (
      select * from game.players p
       where not p.is_admin and not p.banned
         and (q = '' or lower(p.username) like '%' || q || '%')
       order by p.level desc, p.id
       offset pg * 25 limit 25
    ) p
  ), '[]'::jsonb);
end $function$;

create or replace function public.get_profile(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); t game.players;
begin
  select * into t from game.players where id = p_player and not banned;
  if not found or t.is_admin then raise exception 'Player not found.'; end if;
  return game.public_player(t) || jsonb_build_object(
    'force', game.crew_class((game.army_power(t.id)->>'power')::numeric)
  );
end $function$;

create or replace function public.leaderboard(p_token text, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); k text := coalesce(p_kind, 'level');
begin
  if k not in ('level','wins','stats','army','crew','wealth') then k := 'level'; end if;
  if k = 'army' then k := 'crew'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', x.id, 'username', x.username, 'rank', game.rank_title(x.level),
      'value', x.val
    ) order by x.ord)
    from (
      select p.id, p.username, p.level,
             case k
               when 'level' then p.level::numeric
               when 'wins' then p.wins::numeric
               else null
             end as val,
             row_number() over (
               order by
                 case k
                   when 'level' then p.level
                   when 'wins' then p.wins
                   else 0
                 end desc,
                 case k
                   when 'stats' then p.str + p.def + p.spd + p.dex
                   when 'crew' then (game.army_power(p.id)->>'power')::numeric
                   when 'wealth' then (p.cash + p.clean_cash + p.bank)::numeric
                   else 0
                 end desc,
                 p.id
             ) as ord
        from game.players p
       where not p.is_admin and not p.banned and not p.is_npc
       limit 25
    ) x
  ), '[]'::jsonb);
end $function$;

create or replace function public.get_chat(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'player_id', case when p.is_admin then null else c.player_id end,
      'username', case when p.is_admin then 'The Boss' else p.username end,
      'staff', p.is_admin,
      'message', c.message,
      'created_at', c.created_at
    ) order by c.id)
    from (select * from game.chat_messages order by id desc limit 80) c
    join game.players p on p.id = c.player_id
  ), '[]'::jsonb);
end $function$;


-- ---------- streets / combat ----------
create or replace function public.list_targets(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'username', t.username, 'level', t.level, 'rank', game.rank_title(t.level),
      'status', game.status_of(t.hospital_until, t.jail_until),
      'npc', t.is_npc,
      'faction', (select tag from game.factions where id = t.faction_id),
      'protected', (not t.is_npc and t.level < 3),
      'cooldown', (select greatest(0, 600 - extract(epoch from (now() - a.created_at)))::int
                     from game.attacks a
                    where a.attacker_id = pid and a.defender_id = t.id
                    order by a.created_at desc limit 1)
    ) order by t.is_npc desc, t.level, t.id)
    from game.players t
    where t.id <> pid and not t.is_admin and not t.banned
    limit 40
  ), '[]'::jsonb);
end $function$;

create or replace function public.attack(p_token text, p_target bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  a game.players;
  d game.players;
  aw game.items; aa game.items; dw game.items; da game.items;
  a_mods jsonb; d_mods jsonb;
  a_army jsonb; d_army jsonb;
  a_mult numeric; d_mult numeric;
  a_wp int := 0; a_ar int := 0; d_wp int := 0; d_ar int := 0;
  a_pow numeric; d_pow numeric;
  a_hp int; d_hp int; rounds int; r int;
  a_init numeric; d_init numeric;
  hit boolean; dmg int;
  v_log text[] := array[]::text[];
  outcome text; a_disp text; d_disp text;
  v_cash bigint := 0; v_xp int := 0; bounty_pay bigint := 0;
  a_lp numeric; d_lp numeric; a_lost int := 0; d_lost int := 0;
  msg text; last_at timestamptz;
begin
  perform game.rate_limit(pid, 'attack', 8, interval '5 minutes', interval '3 seconds');
  a := game.tick(pid);
  perform game.require_free(a);
  if a.energy < 25 then raise exception 'Not enough energy.'; end if;

  -- Lock both rows in a stable order to avoid deadlocks.
  if p_target is null or p_target = pid then raise exception 'Player not found.'; end if;
  if pid < p_target then
    perform 1 from game.players where id = pid for update;
    select * into d from game.players where id = p_target for update;
  else
    select * into d from game.players where id = p_target for update;
    perform 1 from game.players where id = pid for update;
  end if;
  -- Refresh attacker after lock
  select * into a from game.players where id = pid;

  -- Generic miss for missing, banned, or admin (no enumeration).
  if d is null or d.banned or d.is_admin then raise exception 'Player not found.'; end if;
  perform game.tick(d.id);
  select * into d from game.players where id = p_target;

  if not d.is_npc and d.level < 3 then raise exception 'That player is still under protection.'; end if;
  if game.status_of(d.hospital_until, d.jail_until) <> 'Okay' then raise exception 'That player is not on the street.'; end if;

  select max(created_at) into last_at from game.attacks where attacker_id = pid and defender_id = d.id;
  if last_at is not null and last_at > now() - interval '10 minutes' then
    raise exception 'You already went after that target recently.';
  end if;

  update game.players set energy = energy - 25 where id = pid;
  select * into a from game.players where id = pid;

  a_disp := case when a.is_admin then 'The Boss' else a.username end;
  d_disp := case when d.is_admin then 'The Boss' else d.username end;

  select * into aw from game.items where id = a.weapon_id;
  select * into aa from game.items where id = a.armor_id;
  select * into dw from game.items where id = d.weapon_id;
  select * into da from game.items where id = d.armor_id;
  a_wp := coalesce(aw.power, 0); a_ar := coalesce(aa.power, 0);
  d_wp := coalesce(dw.power, 0); d_ar := coalesce(da.power, 0);
  a_mods := game.path_mods(a.specialization);
  d_mods := game.path_mods(d.specialization);
  a_army := game.army_power(a.id);
  d_army := game.army_power(d.id);
  -- Crew multiplier between 0.6 and 1.5 vs the other crew.
  a_mult := least(1.5, greatest(0.6, 1.0 + (((a_army->>'power')::numeric) - ((d_army->>'power')::numeric)) / 4000.0));
  d_mult := least(1.5, greatest(0.6, 1.0 + (((d_army->>'power')::numeric) - ((a_army->>'power')::numeric)) / 4000.0));
  if a.path_buff = 'stand' and a.path_buff_until > now() then d_mult := d_mult * 0.85; end if;
  if a.path_buff = 'marked' and a.path_buff_until > now() then a_mult := a_mult * 1.15; d_ar := floor(d_ar * 0.5)::int; end if;

  a_hp := game.max_hp(a.level); -- fight stamina, not wound HP, so hospital is applied after
  d_hp := game.max_hp(d.level);
  a_pow := (a.str + a_wp) * coalesce((a_mods->>'dmg')::numeric, 1) * a_mult;
  d_pow := (d.str + d_wp) * coalesce((d_mods->>'dmg')::numeric, 1) * d_mult;

  v_log := v_log || format('%s steps to %s on the street.', a_disp, d_disp);

  if a.god_strike then
    outcome := 'win';
    v_log := v_log || ARRAY['A single blow ends it.'];
  else
    rounds := 8 + floor(random() * 5)::int;
    for r in 1..rounds loop
      exit when a_hp <= 0 or d_hp <= 0;
      a_init := a.spd * (0.85 + random() * 0.3);
      d_init := d.spd * (0.85 + random() * 0.3);
      -- Attacker swing
      if true then
        hit := random() < least(0.92, greatest(0.25, 0.55 + (a.spd - d.dex) / 800.0));
        if hit then
          dmg := greatest(1, ceil((a_pow * (0.7 + random() * 0.6) - (d.def + d_ar) * 0.45)))::int;
          if a.immortal then dmg := dmg; end if;
          d_hp := d_hp - dmg;
          v_log := v_log || format('%s connects for %s.', a_disp, dmg);
        else
          v_log := v_log || format('%s misses.', a_disp);
        end if;
      end if;
      exit when d_hp <= 0;
      hit := random() < least(0.92, greatest(0.25, 0.55 + (d.spd - a.dex) / 800.0));
      if d.immortal then
        -- still swings, but attacker with immortal ignores incoming later
        null;
      end if;
      if hit then
        dmg := greatest(1, ceil((d_pow * (0.7 + random() * 0.6) - (a.def + a_ar) * 0.45)))::int;
        if a.immortal then dmg := 0; end if;
        a_hp := a_hp - dmg;
        if dmg = 0 then
          v_log := v_log || format('%s''s blow does not land.', d_disp);
        else
          v_log := v_log || format('%s answers for %s.', d_disp, dmg);
        end if;
      else
        v_log := v_log || format('%s misses.', d_disp);
      end if;
    end loop;

    if d_hp <= 0 and a_hp > 0 then outcome := 'win';
    elsif a_hp <= 0 and d_hp > 0 then outcome := 'loss';
    elsif a_hp <= 0 and d_hp <= 0 then
      -- Simultaneous drop: attacker withdrew (stalemate), same as the earlier fix.
      outcome := 'draw';
    else
      outcome := 'draw';
    end if;
  end if;

  if outcome = 'win' then
    if d.is_npc then
      v_cash := (40 * d.level + floor(random() * (80 * d.level + 1)))::bigint;
    else
      v_cash := floor(d.cash * (0.10 + random() * 0.15))::bigint;
      if v_cash > 0 then
        update game.players set cash = cash - v_cash where id = d.id;
      end if;
    end if;
    perform game.add_dirty(pid, v_cash);
    v_xp := 12 + d.level * 3;
    perform game.add_xp(pid, v_xp);
    update game.players set wins = wins + 1 where id = pid;
    if not d.is_npc and not d.immortal then
      update game.players
         set losses = losses + 1,
             hospital_until = now() + make_interval(mins => (8 + a.level / 2)::int),
             hp = 1
       where id = d.id;
      perform game.add_event(d.id, 'battle', format('%s put you in the hospital.', a_disp));
    elsif not d.is_npc and d.immortal then
      perform game.add_event(d.id, 'battle', format('%s came for you, but you walked away.', a_disp));
    end if;
    -- Collect open bounties on a real player kill (hospitalizing counts).
    if not d.is_npc then
      select coalesce(sum(amount), 0) into bounty_pay
        from game.bounties where target_id = d.id and collected_at is null;
      if bounty_pay > 0 then
        update game.bounties
           set collected_at = now(), collected_by = pid
         where target_id = d.id and collected_at is null;
        perform game.add_dirty(pid, bounty_pay);
        perform game.add_event(pid, 'bounty', format('You collected $%s in bounties on %s.', to_char(bounty_pay, 'FM999,999,999'), d_disp));
      end if;
    end if;
    msg := format('You dropped %s.', d_disp);
    if v_cash > 0 then msg := msg || format(' You took $%s dirty cash.', to_char(v_cash, 'FM999,999,999')); end if;
    if bounty_pay > 0 then msg := msg || format(' Bounties paid $%s.', to_char(bounty_pay, 'FM999,999,999')); end if;
    v_log := v_log || ARRAY[a_disp || ' walks away.'];
  elsif outcome = 'loss' then
    update game.players set losses = losses + 1 where id = pid;
    if not a.immortal then
      update game.players
         set hospital_until = now() + make_interval(mins => (8 + d.level / 2)::int),
             hp = 1
       where id = pid;
    end if;
    if not d.is_npc then
      update game.players set wins = wins + 1 where id = d.id;
      perform game.add_event(d.id, 'battle', format('You dropped %s on the street.', a_disp));
    end if;
    msg := format('%s dropped you.', d_disp);
    v_log := v_log || ARRAY[d_disp || ' is still standing.'];
  else
    msg := format('Stalemate. Neither side broke, and you withdrew from %s.', d_disp);
    v_log := v_log || ARRAY['Both sides back off.'];
  end if;

  -- Crew casualties (NPCs always regroup)
  if outcome = 'win' then a_lp := 0.01 + random() * 0.03; d_lp := 0.06 + random() * 0.06;
  elsif outcome = 'loss' then a_lp := 0.06 + random() * 0.06; d_lp := 0.01 + random() * 0.03;
  else a_lp := 0.02 + random() * 0.03; d_lp := 0.02 + random() * 0.03; end if;
  if a.immortal or a.god_strike then a_lp := 0; end if;
  a_lost := floor(a.troops * a_lp);
  update game.players set troops = greatest(0, troops - a_lost) where id = pid;
  if a_lost > 0 then
    v_log := v_log || format('You lost %s crew.', a_lost);
    msg := msg || format(' You lost %s crew.', a_lost);
  end if;
  if not d.is_npc then
    d_lost := floor(d.troops * d_lp);
    update game.players set troops = greatest(0, troops - d_lost) where id = d.id;
    if d_lost > 0 then
      perform game.add_event(d.id, 'battle', format(' You also lost %s crew.', d_lost));
    end if;
  end if;

  -- Clear one-shot buffs after a fight
  if a.path_buff in ('marked','stand') then
    update game.players set path_buff = null, path_buff_until = null where id = pid;
  end if;

  insert into game.attacks (attacker_id, defender_id, result) values (pid, d.id, outcome);
  perform game.add_event(pid, 'battle', msg);
  return jsonb_build_object('result', outcome, 'message', msg, 'log', to_jsonb(v_log),
                            'cash', v_cash, 'xp', v_xp, 'me', game.me_json(pid));
end $function$;


-- ---------- chat, register welcome, admin copy ----------
create or replace function public.send_chat(p_token text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); v_last timestamptz; m text;
begin
  m := trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'));
  if length(m) < 1 then raise exception 'Message is empty.'; end if;
  if length(m) > 200 then raise exception 'Messages are limited to 200 characters.'; end if;
  select last_chat_at into v_last from game.players where id = pid for update;
  if v_last is not null and v_last > now() - interval '4 seconds' then
    raise exception 'Slow down. One message every 4 seconds.';
  end if;
  update game.players set last_chat_at = now() where id = pid;
  insert into game.chat_messages (player_id, message) values (pid, m);
  delete from game.chat_messages where id < (select min(id) from (select id from game.chat_messages order by id desc limit 500) k);
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.register(p_username text, p_password text, p_device text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint; u text := trim(coalesce(p_username, '')); dev text := game.norm_device(p_device);
  k bytea := game.bucket('reg:' || dev); r game.login_throttle;
begin
  if u !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'Username must be 3-16 characters: letters, numbers or underscore.';
  end if;
  perform game.password_ok(p_password, u);
  if game.reserved_name(u) then raise exception 'That username is not allowed. Please pick another.'; end if;
  insert into game.login_throttle (key_hash, kind) values (k, 'reg_d') on conflict (key_hash) do nothing;
  select * into r from game.login_throttle where key_hash = k for update;
  if r.window_start < now() - interval '1 hour' then r.fails := 0; r.window_start := now(); end if;
  if r.fails >= (case when dev = 'no-device' then 10 else 3 end) then
    raise exception 'Too many new accounts from this device. Try again later.';
  end if;
  if (select count(*) from game.players where not is_npc and created_at > now() - interval '10 minutes') >= 300 then
    raise exception 'Too many new players right now. Try again in a few minutes.';
  end if;
  begin
    insert into game.players (username, pass_hash)
    values (u, game.hash_password(p_password))
    returning id into pid;
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
  update game.login_throttle set fails = r.fails + 1, window_start = r.window_start where key_hash = k;
  perform game.add_event(pid, 'system', 'Welcome to Grayhaven. Train in The Yard, work the streets, and keep your name clean — or don''t.');
  return jsonb_build_object('token', game.new_session(pid), 'is_admin', false);
end
$fn$;

create or replace function public.admin_adjust_cash(p_token text, p_player bigint, p_delta bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000000000 then
    raise exception 'Invalid amount.';
  end if;
  t := game.tick(p_player);
  if t is null or t.is_npc then raise exception 'Player not found.'; end if;
  if p_delta > 0 then
    perform game.add_dirty(p_player, p_delta);
    perform game.add_event(p_player, 'system', format('The Boss granted you $%s dirty cash.', to_char(p_delta, 'FM999,999,999,999')));
  else
    -- take dirty first, then clean, then bank; never go below zero overall
    perform game.take_any(p_player, least(abs(p_delta), t.cash + t.clean_cash + t.bank));
    -- also shave bank if take_any didn't cover (take_any is dirty+clean only)
    -- handled below if we need bank; keep simple: take_any already dirty+clean.
    perform game.add_event(p_player, 'system', format('The Boss took $%s from you.', to_char(abs(p_delta), 'FM999,999,999,999')));
  end if;
  perform game.audit(pid, format('cash %s', p_delta), p_player);
  return jsonb_build_object('message', format('Adjusted cash for %s.', t.username));
end $function$;

create or replace function public.admin_adjust_clean(p_token text, p_player bigint, p_delta bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000000000 then
    raise exception 'Invalid amount.';
  end if;
  t := game.tick(p_player);
  if t is null or t.is_npc then raise exception 'Player not found.'; end if;
  if p_delta > 0 then
    perform game.add_clean(p_player, p_delta);
    perform game.add_event(p_player, 'system', format('The Boss granted you $%s clean cash.', to_char(p_delta, 'FM999,999,999,999')));
  else
    perform game.take_clean(p_player, least(abs(p_delta), t.clean_cash));
    perform game.add_event(p_player, 'system', format('The Boss took $%s clean cash from you.', to_char(abs(p_delta), 'FM999,999,999,999')));
  end if;
  perform game.audit(pid, format('clean %s', p_delta), p_player);
  return jsonb_build_object('message', format('Adjusted clean cash for %s.', t.username));
end $function$;

create or replace function public.admin_reset_player(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  t := game.tick(p_player);
  if t.is_npc then raise exception 'NPCs cannot be reset.'; end if;
  if t.is_admin then raise exception 'The Boss cannot be reset this way.'; end if;
  update game.players set level = 1, xp = 0, cash = 1000, clean_cash = 0, bank = 0, hp = 100, energy = 100, nerve = 10,
    hp_at = now(), energy_at = now(), nerve_at = now(), str = 10, def = 10, spd = 10, dex = 10,
    weapon_id = null, armor_id = null, hospital_until = null, jail_until = null,
    wins = 0, losses = 0, missions_done = 0, crimes_done = 0, troops = 0, troops_free_granted = 0,
    immortal = false, god_strike = false, specialization = null, path_buff = null, path_buff_until = null,
    stat_points = 0, stat_points_granted = 0
   where id = p_player;
  delete from game.inventory where player_id = p_player;
  delete from game.player_troop_weapons where player_id = p_player;
  delete from game.player_vehicles where player_id = p_player;
  delete from game.player_businesses where player_id = p_player;
  delete from game.swiss_cds where player_id = p_player;
  delete from game.bounties where placer_id = p_player and collected_at is null;
  perform game.audit(pid, 'reset', p_player);
  perform game.add_event(p_player, 'system', 'The Boss reset your record.');
  return jsonb_build_object('message', format('%s has been reset.', t.username));
end $function$;

create or replace function public.admin_command_order(p_token text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); m text := trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')); n int;
begin
  perform game.require_admin(pid);
  if length(m) < 1 or length(m) > 300 then raise exception 'A word from The Boss must be 1-300 characters.'; end if;
  if exists (select 1 from game.admin_audit_log where admin_id = pid and action = 'command order' and created_at > now() - interval '30 seconds') then
    raise exception 'Wait 30 seconds between broadcasts.';
  end if;
  insert into game.events (player_id, kind, message)
    select id, 'order', 'THE BOSS: ' || m from game.players where not is_npc and not banned;
  get diagnostics n = row_count;
  perform game.audit(pid, 'command order', null, jsonb_build_object('message', m, 'recipients', n));
  return jsonb_build_object('message', format('Word from The Boss sent to %s players.', n));
end $function$;

create or replace function public.admin_set_specialization(p_token text, p_player bigint, p_spec text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); t game.players; s text := nullif(trim(coalesce(p_spec,'')), '');
begin
  perform game.require_admin(pid);
  if s is not null and s not in ('enforcer','hustler','fixer','ghost') then raise exception 'Unknown path.'; end if;
  select * into t from game.players where id = p_player;
  if not found or t.is_npc then raise exception 'Player not found.'; end if;
  update game.players set specialization = s, path_buff = null, path_buff_until = null where id = p_player;
  perform game.audit(pid, 'set specialization', p_player, jsonb_build_object('spec', s));
  perform game.add_event(p_player, 'system', case when s is null then 'The Boss cleared your path.'
                                                  else 'The Boss set your path to ' || initcap(s) || '.' end);
  return jsonb_build_object('message', 'Specialization updated.');
end $function$;

create or replace function public.admin_power_grant(p_token text, p_cash bigint default 0, p_troops int default 0,
  p_weapon int default null, p_weapon_qty int default 0, p_vehicle int default null, p_vehicle_qty int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare pid bigint := game.auth(p_token); p game.players; n int; parts text[] := '{}';
begin
  perform game.require_admin(pid);
  p := game.tick(pid);
  p_cash := coalesce(p_cash, 0); p_troops := coalesce(p_troops, 0); p_weapon_qty := coalesce(p_weapon_qty, 0); p_vehicle_qty := coalesce(p_vehicle_qty, 0);
  if p_cash < 0 or p_cash > 1000000000000 then raise exception 'Cash grant must be 0 to 1,000,000,000,000.'; end if;
  if p_troops < 0 or p.troops + p_troops > 1000 then raise exception 'Crew size is capped at 1,000 (you have %).', p.troops; end if;
  if p_weapon_qty < 0 or p_weapon_qty > 1000 then raise exception 'Weapon quantity must be 0-1,000.'; end if;
  if p_vehicle_qty < 0 or p_vehicle_qty > 20 then raise exception 'Vehicle quantity must be 0-20.'; end if;
  if p_cash > 0 then perform game.add_dirty(pid, p_cash); parts := parts || format('$%s dirty', p_cash); end if;
  if p_troops > 0 then update game.players set troops = troops + p_troops where id = pid; parts := parts || format('%s crew', p_troops); end if;
  if p_weapon_qty > 0 then
    if not exists (select 1 from game.troop_weapons where id = p_weapon) then raise exception 'Unknown crew weapon.'; end if;
    if coalesce((select qty from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon), 0) + p_weapon_qty > 1000 then
      raise exception 'At most 1,000 of each crew weapon.';
    end if;
    insert into game.player_troop_weapons (player_id, weapon_id, qty) values (pid, p_weapon, p_weapon_qty)
      on conflict (player_id, weapon_id) do update set qty = game.player_troop_weapons.qty + excluded.qty;
    parts := parts || format('%s x %s', p_weapon_qty, (select name from game.troop_weapons where id = p_weapon));
  end if;
  if p_vehicle_qty > 0 then
    if not exists (select 1 from game.vehicles where id = p_vehicle) then raise exception 'Unknown vehicle.'; end if;
    select count(*) into n from game.player_vehicles where player_id = pid;
    if n + p_vehicle_qty > 20 then raise exception 'Garage is capped at 20 cars.'; end if;
    insert into game.player_vehicles (player_id, vehicle_id) select pid, p_vehicle from generate_series(1, p_vehicle_qty);
    parts := parts || format('%s x %s', p_vehicle_qty, (select name from game.vehicles where id = p_vehicle));
  end if;
  if cardinality(parts) = 0 then raise exception 'Nothing to grant.'; end if;
  perform game.audit(pid, 'power: grant self', pid, jsonb_build_object('cash', p_cash, 'troops', p_troops,
    'weapon', p_weapon, 'weapon_qty', p_weapon_qty, 'vehicle', p_vehicle, 'vehicle_qty', p_vehicle_qty));
  return jsonb_build_object('message', 'Granted: ' || array_to_string(parts, ', ') || '.', 'me', game.me_json(pid));
end $function$;

revoke all on function game.public_player(game.players) from public, anon, authenticated;


create or replace function public.admin_list_players(p_token text, p_search text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); q text := nullif(regexp_replace(coalesce(p_search, ''), '[^A-Za-z0-9_]', '', 'g'), '');
begin
  perform game.require_admin(pid);
  perform game.rate_limit(pid, 'admin_list', 30, interval '5 minutes', interval '1 second');
  perform game.audit(pid, 'list players', null, jsonb_build_object('search', coalesce(q, '')));
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level,
            'cash', cash, 'clean', clean_cash, 'bank', bank, 'banned', banned, 'is_admin', is_admin,
            'npc', is_npc, 'wins', wins, 'losses', losses, 'specialization', specialization,
            'created_at', created_at, 'last_action', last_action) order by id)
     from (select * from game.players where q is null or username ilike '%' || q || '%' order by id limit 200) x), '[]'::jsonb);
end
$fn$;
