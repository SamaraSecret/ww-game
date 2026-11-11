-- Fixes: equipped flag, change password.

create or replace function public.list_items(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  select * into p from game.players where id = pid;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', i.id, 'name', i.name, 'kind', i.kind, 'power', i.power, 'price', i.price,
      'min_level', i.min_level, 'description', i.description,
      'owned', coalesce(inv.qty, 0),
      'equipped', coalesce(i.id = p.weapon_id, false) or coalesce(i.id = p.armor_id, false)) order by i.kind desc, i.price)
    from game.items i left join game.inventory inv on inv.item_id = i.id and inv.player_id = pid), '[]'::jsonb);
end $$;

create or replace function public.change_password(p_token text, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); h text;
begin
  if p_new is null or length(p_new) < 6 or length(p_new) > 72 then raise exception 'New password must be 6-72 characters.'; end if;
  select pass_hash into h from game.players where id = pid for update;
  if extensions.crypt(coalesce(p_old, ''), h) <> h then raise exception 'Current password is wrong.'; end if;
  update game.players set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 8)) where id = pid;
  -- sign out every other session
  delete from game.sessions where player_id = pid and token_hash <> sha256(convert_to(p_token, 'UTF8'));
  return jsonb_build_object('message', 'Password changed. Other devices were signed out.');
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
