-- Army Command content (catalogues + NPC forces). Game content only, no player data.

insert into game.troop_weapons (id, name, attack, defense, price, min_level, description) values
 (1, 'Rifles',             1, 1,   30,  1, 'Standard rifles for your infantry.'),
 (2, 'Machine Guns',       3, 2,  150,  3, 'Suppressive fire for a squad.'),
 (3, 'Mortars',            5, 1,  400,  6, 'Indirect fire support.'),
 (4, 'Anti-tank Rockets',  8, 3,  900, 10, 'Stops armor in its tracks.'),
 (5, 'Flamethrowers',     12, 1, 2000, 15, 'Clears fortified positions.')
on conflict (id) do nothing;

insert into game.vehicles (id, name, attack, defense, price, min_level, description) values
 (1, 'Jeep',            20,  10,   5000,  1, 'Fast scout and supply runner.'),
 (2, 'Armored Car',     40,  40,  15000,  4, 'Light armor, mounted gun.'),
 (3, 'Light Tank',      90,  70,  40000,  8, 'Mobile armored support.'),
 (4, 'Artillery',      150,  20,  70000, 12, 'Long-range bombardment.'),
 (5, 'Heavy Tank',     200, 180, 150000, 16, 'The backbone of an armored assault.'),
 (6, 'Fighter Plane',  260,  80, 250000, 20, 'Air superiority.'),
 (7, 'Bomber',         420,  60, 450000, 25, 'Strategic strikes from above.'),
 (8, 'Destroyer',      500, 450, 900000, 32, 'Naval firepower and escort.')
on conflict (id) do nothing;

-- NPC forces
update game.players set troops = 0   where is_npc and username = 'Training_Dummy';
update game.players set troops = 60  where is_npc and username = 'Conscript';
update game.players set troops = 350 where is_npc and username = 'Veteran';
update game.players set troops = 900 where is_npc and username = 'Elite_Commando';
update game.players set troops = 1600 where is_npc and username = 'Iron_Colonel';

insert into game.player_troop_weapons (player_id, weapon_id, qty)
select p.id, w.weapon_id, w.qty from game.players p
join (values ('Conscript', 1, 60), ('Veteran', 1, 250), ('Veteran', 2, 100),
             ('Elite_Commando', 2, 500), ('Elite_Commando', 3, 300),
             ('Iron_Colonel', 3, 800), ('Iron_Colonel', 4, 600), ('Iron_Colonel', 5, 200)) as w(name, weapon_id, qty)
  on p.username = w.name and p.is_npc
on conflict (player_id, weapon_id) do nothing;

insert into game.player_vehicles (player_id, vehicle_id)
select p.id, v.vehicle_id from game.players p
join (values ('Veteran', 1), ('Veteran', 1), ('Elite_Commando', 2), ('Elite_Commando', 3), ('Elite_Commando', 3),
             ('Iron_Colonel', 5), ('Iron_Colonel', 5), ('Iron_Colonel', 4), ('Iron_Colonel', 4), ('Iron_Colonel', 6)) as v(name, vehicle_id)
  on p.username = v.name and p.is_npc
where not exists (select 1 from game.player_vehicles pv where pv.player_id = p.id);
