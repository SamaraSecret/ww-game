-- Fix attack combat log: bare string || text[] is parsed as an array literal.

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
