-- Public RPCs: auth, home, training, missions, hospital/stockade, bank, armory.

create or replace function public.register(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint; u text := trim(coalesce(p_username, ''));
begin
  if u !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'Username must be 3-16 characters: letters, numbers or underscore.';
  end if;
  if p_password is null or length(p_password) < 6 or length(p_password) > 72 then
    raise exception 'Password must be 6-72 characters.';
  end if;
  if lower(u) in ('admin','administrator','system','command','staff','moderator','root') then
    raise exception 'That username is reserved.';
  end if;
  if (select count(*) from game.players where not is_npc and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Too many new recruits right now. Try again in a few minutes.';
  end if;
  begin
    insert into game.players (username, pass_hash)
    values (u, extensions.crypt(p_password, extensions.gen_salt('bf', 8)))
    returning id into pid;
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
  perform game.add_event(pid, 'system', 'Welcome to the front, recruit! Train at the camp, run missions and climb the ranks.');
  return jsonb_build_object('token', game.new_session(pid));
end $$;

-- Returns {token} or {error}. Never raises on a bad password, so the failed-attempt counter is kept.
create or replace function public.login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p game.players; mins int;
begin
  select * into p from game.players
   where lower(username) = lower(trim(coalesce(p_username, ''))) and not is_npc for update;
  if not found or p.pass_hash is null then
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 8)); -- similar timing
    return jsonb_build_object('error', 'Wrong username or password.');
  end if;
  if p.locked_until is not null and p.locked_until > now() then
    mins := ceil(extract(epoch from (p.locked_until - now())) / 60);
    return jsonb_build_object('error', format('Too many failed attempts. Try again in %s minute(s).', mins));
  end if;
  if extensions.crypt(coalesce(p_password, ''), p.pass_hash) <> p.pass_hash then
    if p.failed_logins + 1 >= 5 then
      update game.players set failed_logins = 0, locked_until = now() + interval '5 minutes' where id = p.id;
      return jsonb_build_object('error', 'Too many failed attempts. Account locked for 5 minutes.');
    end if;
    update game.players set failed_logins = failed_logins + 1 where id = p.id;
    return jsonb_build_object('error', 'Wrong username or password.');
  end if;
  if p.banned then
    return jsonb_build_object('error', 'This account has been banned.');
  end if;
  update game.players set failed_logins = 0, locked_until = null, last_action = now() where id = p.id;
  return jsonb_build_object('token', game.new_session(p.id));
end $$;

create or replace function public.logout(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_token ~ '^[0-9a-f]{64}$' then
    delete from game.sessions where token_hash = sha256(convert_to(p_token, 'UTF8'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_me(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.tick(pid);
  return game.me_json(pid) || jsonb_build_object(
    'announcement', (select jsonb_build_object('message', message, 'created_at', created_at)
                       from game.announcements where active order by id desc limit 1),
    'unread', (select count(*) from game.events where player_id = pid and not seen),
    'recent_events', coalesce((select jsonb_agg(e order by e.id desc) from
        (select id, kind, message, created_at, seen from game.events where player_id = pid order by id desc limit 6) e), '[]'::jsonb)
  );
end $$;

create or replace function public.train(p_token text, p_stat text, p_times int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  v numeric; start_v numeric; g numeric; i int;
  cost int;
  names jsonb := '{"str":"Strength","def":"Defense","spd":"Speed","dex":"Dexterity"}';
begin
  if p_stat not in ('str','def','spd','dex') then raise exception 'Unknown stat.'; end if;
  if p_times is null or p_times < 1 or p_times > 20 then raise exception 'You can train 1 to 20 times at once.'; end if;
  p := game.tick(pid);
  perform game.require_free(p);
  cost := p_times * 5;
  if p.energy < cost then raise exception 'Not enough energy (need %, have %).', cost, p.energy; end if;
  v := case p_stat when 'str' then p.str when 'def' then p.def when 'spd' then p.spd else p.dex end;
  start_v := v;
  for i in 1..p_times loop
    g := (1.0 + random()) * 2.5 / sqrt(1 + v / 100.0);  -- diminishing returns
    v := v + g;
  end loop;
  v := round(v, 2);
  update game.players set
    energy = energy - cost,
    energy_at = case when energy >= 100 then now() else energy_at end,
    str = case when p_stat = 'str' then v else str end,
    def = case when p_stat = 'def' then v else def end,
    spd = case when p_stat = 'spd' then v else spd end,
    dex = case when p_stat = 'dex' then v else dex end
  where id = pid;
  perform game.add_xp(pid, p_times);
  return jsonb_build_object('stat', names ->> p_stat, 'gained', round(v - start_v, 2), 'value', v,
    'message', format('You drilled %s time(s) and gained %s %s.', p_times, round(v - start_v, 2), names ->> p_stat),
    'me', game.me_json(pid));
end $$;

create or replace function public.list_missions(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  p := game.tick(pid);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', m.id, 'name', m.name, 'description', m.description, 'tier', m.tier,
      'nerve_cost', m.nerve_cost, 'min_level', m.min_level, 'cash_min', m.cash_min, 'cash_max', m.cash_max, 'xp', m.xp,
      'chance', round(least(0.95, m.base_chance + (p.level - 1) * 0.01 + p.dex / (p.dex + 1000) * 0.25) * 100),
      'locked', p.level < m.min_level) order by m.tier) from game.missions m), '[]'::jsonb);
end $$;

create or replace function public.do_mission(p_token text, p_mission int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  pid bigint := game.auth(p_token);
  p game.players; m game.missions;
  chance numeric; v_cash bigint; dmg int; mins int; msg text; res text; lv int;
begin
  select * into m from game.missions where id = p_mission;
  if not found then raise exception 'Unknown mission.'; end if;
  p := game.tick(pid);
  perform game.require_free(p);
  if p.level < m.min_level then raise exception 'You need level % for this mission.', m.min_level; end if;
  if p.nerve < m.nerve_cost then raise exception 'Not enough nerve (need %, have %).', m.nerve_cost, p.nerve; end if;
  chance := least(0.95, m.base_chance + (p.level - 1) * 0.01 + p.dex / (p.dex + 1000) * 0.25);
  update game.players set nerve = nerve - m.nerve_cost,
    nerve_at = case when nerve >= 10 then now() else nerve_at end where id = pid;
  if random() < chance then
    v_cash := m.cash_min + floor(random() * (m.cash_max - m.cash_min + 1))::bigint;
    update game.players set cash = cash + v_cash, missions_done = missions_done + 1 where id = pid;
    lv := game.add_xp(pid, m.xp);
    res := 'success';
    msg := format('%s Mission "%s" succeeded: +$%s, +%s XP.', m.success_text, m.name, v_cash, m.xp);
  elsif random() < 0.5 then
    dmg := ceil(game.max_hp(p.level) * (0.15 + random() * 0.25));
    if p.hp - dmg <= 0 then
      mins := 4 + m.tier * 2;
      update game.players set hp = 0, hospital_until = now() + make_interval(mins => mins) where id = pid;
      res := 'hospital';
      msg := format('%s You were badly wounded on "%s" and evacuated to the field hospital for %s minutes.', m.fail_text, m.name, mins);
    else
      update game.players set hp = hp - dmg, hp_at = case when hp >= game.max_hp(level) then now() else hp_at end where id = pid;
      res := 'wounded';
      msg := format('%s You were wounded on "%s" and lost %s HP.', m.fail_text, m.name, dmg);
    end if;
    perform game.add_xp(pid, 1);
  else
    mins := 2 + m.tier * 2;
    update game.players set jail_until = now() + make_interval(mins => mins) where id = pid;
    res := 'stockade';
    msg := format('%s You were captured during "%s" and held in the stockade for %s minutes.', m.fail_text, m.name, mins);
    perform game.add_xp(pid, 1);
  end if;
  perform game.add_event(pid, 'mission', msg);
  return jsonb_build_object('result', res, 'message', msg, 'me', game.me_json(pid));
end $$;

-- Pay to leave the hospital early.
create or replace function public.revive(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; cost bigint; mins int;
begin
  p := game.tick(pid);
  if p.hospital_until is null then raise exception 'You are not in the hospital.'; end if;
  mins := ceil(extract(epoch from (p.hospital_until - now())) / 60);
  cost := 50 * p.level + mins * 25;
  if p.cash < cost then raise exception 'Treatment costs $% and you only have $% in cash.', cost, p.cash; end if;
  update game.players set cash = cash - cost, hospital_until = null, hp = game.max_hp(level), hp_at = now() where id = pid;
  perform game.add_event(pid, 'hospital', format('You paid $%s for emergency treatment and are back on duty.', cost));
  return jsonb_build_object('message', format('Treatment paid ($%s). You are back on duty at full health.', cost), 'me', game.me_json(pid));
end $$;

create or replace function public.pay_bail(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; cost bigint; mins int;
begin
  p := game.tick(pid);
  if p.jail_until is null then raise exception 'You are not in the stockade.'; end if;
  mins := ceil(extract(epoch from (p.jail_until - now())) / 60);
  cost := 75 * p.level + mins * 30;
  if p.cash < cost then raise exception 'Release costs $% and you only have $% in cash.', cost, p.cash; end if;
  update game.players set cash = cash - cost, jail_until = null where id = pid;
  perform game.add_event(pid, 'stockade', format('You paid $%s to be released from the stockade.', cost));
  return jsonb_build_object('message', format('Released for $%s.', cost), 'me', game.me_json(pid));
end $$;

create or replace function public.hospital_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level,
            'until', hospital_until) order by hospital_until)
     from (select id, username, level, hospital_until from game.players
            where hospital_until > now() and not is_npc and not banned order by hospital_until limit 50) x), '[]'::jsonb);
end $$;

create or replace function public.bank_deposit(p_token text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; fee bigint;
begin
  if p_amount is null or p_amount < 1 then raise exception 'Enter a positive amount.'; end if;
  p := game.tick(pid);
  if p.cash < p_amount then raise exception 'You only have $% in cash.', p.cash; end if;
  fee := ceil(p_amount * 0.01);
  update game.players set cash = cash - p_amount, bank = bank + (p_amount - fee) where id = pid;
  return jsonb_build_object('message', format('Deposited $%s (fee $%s).', p_amount - fee, fee), 'me', game.me_json(pid));
end $$;

create or replace function public.bank_withdraw(p_token text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  if p_amount is null or p_amount < 1 then raise exception 'Enter a positive amount.'; end if;
  p := game.tick(pid);
  if p.bank < p_amount then raise exception 'You only have $% in the bank.', p.bank; end if;
  update game.players set cash = cash + p_amount, bank = bank - p_amount where id = pid;
  return jsonb_build_object('message', format('Withdrew $%s.', p_amount), 'me', game.me_json(pid));
end $$;

create or replace function public.list_items(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  select * into p from game.players where id = pid;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', i.id, 'name', i.name, 'kind', i.kind, 'power', i.power, 'price', i.price,
      'min_level', i.min_level, 'description', i.description,
      'owned', coalesce(inv.qty, 0),
      'equipped', (i.id = p.weapon_id or i.id = p.armor_id)) order by i.kind desc, i.price)
    from game.items i left join game.inventory inv on inv.item_id = i.id and inv.player_id = pid), '[]'::jsonb);
end $$;

create or replace function public.buy_item(p_token text, p_item int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; it game.items;
begin
  select * into it from game.items where id = p_item;
  if not found then raise exception 'Unknown item.'; end if;
  p := game.tick(pid);
  if p.level < it.min_level then raise exception 'You need level % to requisition this.', it.min_level; end if;
  if p.cash < it.price then raise exception 'Not enough cash ($% needed).', it.price; end if;
  if coalesce((select qty from game.inventory where player_id = pid and item_id = p_item), 0) >= 10 then
    raise exception 'You can hold at most 10 of each item.';
  end if;
  update game.players set cash = cash - it.price where id = pid;
  insert into game.inventory (player_id, item_id, qty) values (pid, p_item, 1)
    on conflict (player_id, item_id) do update set qty = game.inventory.qty + 1;
  return jsonb_build_object('message', format('Purchased %s for $%s.', it.name, it.price), 'me', game.me_json(pid));
end $$;

create or replace function public.sell_item(p_token text, p_item int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; it game.items; q int; val bigint;
begin
  select * into it from game.items where id = p_item;
  if not found then raise exception 'Unknown item.'; end if;
  p := game.tick(pid);
  select qty into q from game.inventory where player_id = pid and item_id = p_item for update;
  if q is null then raise exception 'You do not own that item.'; end if;
  val := it.price / 2;
  if q <= 1 then
    delete from game.inventory where player_id = pid and item_id = p_item;
    update game.players set
      weapon_id = case when weapon_id = p_item then null else weapon_id end,
      armor_id = case when armor_id = p_item then null else armor_id end where id = pid;
  else
    update game.inventory set qty = qty - 1 where player_id = pid and item_id = p_item;
  end if;
  update game.players set cash = cash + val where id = pid;
  return jsonb_build_object('message', format('Sold %s for $%s.', it.name, val), 'me', game.me_json(pid));
end $$;

create or replace function public.equip_item(p_token text, p_item int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; it game.items;
begin
  select * into it from game.items where id = p_item;
  if not found then raise exception 'Unknown item.'; end if;
  p := game.tick(pid);
  if not exists (select 1 from game.inventory where player_id = pid and item_id = p_item) then
    raise exception 'You do not own that item.';
  end if;
  if it.kind = 'weapon' then update game.players set weapon_id = p_item where id = pid;
  else update game.players set armor_id = p_item where id = pid; end if;
  return jsonb_build_object('message', format('Equipped %s.', it.name), 'me', game.me_json(pid));
end $$;

create or replace function public.unequip_item(p_token text, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  if p_kind not in ('weapon','armor') then raise exception 'Unknown slot.'; end if;
  p := game.tick(pid);
  update game.players set
    weapon_id = case when p_kind = 'weapon' then null else weapon_id end,
    armor_id = case when p_kind = 'armor' then null else armor_id end where id = pid;
  return jsonb_build_object('message', 'Unequipped.', 'me', game.me_json(pid));
end $$;
