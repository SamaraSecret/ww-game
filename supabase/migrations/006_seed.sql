-- Seed data: game content only (items, missions, NPC training targets). No player data.

insert into game.items (id, name, kind, power, price, min_level, description) values
 (1,  'Combat Knife',        'weapon',  4,    300,  1, 'Standard-issue blade. Better than fists.'),
 (2,  'Service Pistol',      'weapon',  8,   1200,  1, 'Reliable sidearm.'),
 (3,  'Bolt-Action Rifle',   'weapon', 14,   4000,  3, 'Accurate at range, slow to cycle.'),
 (4,  'Submachine Gun',      'weapon', 22,  12000,  6, 'Close-quarters firepower.'),
 (5,  'Semi-Auto Rifle',     'weapon', 30,  30000, 10, 'The backbone of a modern infantry squad.'),
 (6,  'Light Machine Gun',   'weapon', 42,  80000, 15, 'Suppressive fire on demand.'),
 (7,  'Anti-Tank Launcher',  'weapon', 60, 200000, 22, 'Overkill for most targets. Perfect.'),
 (101,'Field Jacket',        'armor',   3,    400,  1, 'Keeps the wind out and a little shrapnel too.'),
 (102,'Steel Helmet',        'armor',   6,   1500,  1, 'Protects the most important part.'),
 (103,'Flak Vest',           'armor',  10,   5000,  4, 'Stops fragments.'),
 (104,'Trench Plate',        'armor',  15,  15000,  8, 'Heavy steel chest plate.'),
 (105,'Ceramic Body Armor',  'armor',  22,  45000, 14, 'Modern protection.'),
 (106,'Heavy Assault Suit',  'armor',  32, 120000, 20, 'Walk through the storm.')
on conflict (id) do nothing;

insert into game.missions (id, name, description, tier, nerve_cost, min_level, base_chance, cash_min, cash_max, xp, success_text, fail_text) values
 (1, 'Recon Patrol',     'Scout enemy positions along the front line.',          1, 1,  1, 0.75,   50,   150,  6,
     'You slipped past the sentries and mapped the trenches.', 'A flare went up over your position.'),
 (2, 'Supply Raid',      'Raid a lightly guarded enemy supply depot.',            2, 2,  2, 0.62,  200,   500, 14,
     'You hauled away crates of rations and ammunition.', 'The depot guards were waiting for you.'),
 (3, 'Radio Intercept',  'Tap into enemy field communications.',                  3, 3,  4, 0.55,  500,  1200, 25,
     'You intercepted coded orders and sold the intel to HQ.', 'A patrol traced your signal.'),
 (4, 'Sabotage',         'Plant charges on an enemy artillery battery.',          4, 4,  6, 0.48, 1200,  2800, 45,
     'The battery went up in a column of smoke.', 'A sentry spotted the charges before they blew.'),
 (5, 'Convoy Ambush',    'Ambush an armored supply convoy on a mountain road.',   5, 5,  9, 0.42, 3000,  6500, 80,
     'The convoy is yours, cargo and all.', 'The convoy escort returned fire.'),
 (6, 'Bridge Demolition','Drop a strategic bridge before the enemy offensive.',   6, 7, 14, 0.36, 7000, 15000, 140,
     'The bridge collapsed into the river. The offensive is stalled.', 'Engineers defused part of your charges.')
on conflict (id) do nothing;

-- NPC targets (cannot log in: pass_hash is NULL).
insert into game.players (username, is_npc, level, cash, str, def, spd, dex, hp) values
 ('Training_Dummy',  true,  1, 0,    3,    3,    2,    2, 100),
 ('Conscript',       true,  3, 0,   25,   25,   20,   20, 140),
 ('Veteran',         true,  8, 0,  120,  110,  100,  100, 240),
 ('Elite_Commando',  true, 15, 0,  450,  400,  420,  380, 380),
 ('Iron_Colonel',    true, 25, 0, 1500, 1400, 1300, 1300, 580)
on conflict do nothing;
