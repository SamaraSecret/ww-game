#!/usr/bin/env python3
"""Generate original military stencil SVG icons for Iron Front (no external art)."""
from pathlib import Path

OUT = Path("/workspace/ww-game/assets/icons")
OUT.mkdir(parents=True, exist_ok=True)

# Shared palette
S = "#d7d9c8"      # steel highlight
SD = "#8d9178"     # steel mid
SK = "#3e4334"     # steel shadow
OL = "#8fa34a"     # olive
BR = "#c4b14a"     # brass
NV = "#4a6d82"     # navy
SKY = "#6a9bb8"    # sky
RD = "#c0503a"     # accent red
WD = "#8a6a3a"     # wood
BK = "#1a1c14"


def wrap(name, body, accent="#6a7348"):
    # Unique gradient ids per file so the SVG is self-contained.
    gid, rid = f"p-{name}", f"r-{name}"
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" role="img" aria-label="{name}">
  <defs>
    <linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3a4030"/>
      <stop offset="1" stop-color="#1c2016"/>
    </linearGradient>
    <linearGradient id="{rid}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#9aa378"/>
      <stop offset="1" stop-color="{accent}"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="10" fill="#10120e"/>
  <rect x="2.5" y="2.5" width="59" height="59" rx="8" fill="url(#{gid})" stroke="url(#{rid})" stroke-width="1.6"/>
  <rect x="6" y="6" width="52" height="52" rx="5" fill="none" stroke="#2e3326" stroke-width="0.75" opacity="0.7"/>
  <circle cx="11" cy="11" r="1.5" fill="#7a8068"/>
  <circle cx="53" cy="11" r="1.5" fill="#7a8068"/>
  <circle cx="11" cy="53" r="1.5" fill="#7a8068"/>
  <circle cx="53" cy="53" r="1.5" fill="#7a8068"/>
  {body}
</svg>
'''


def save(slug, body, accent="#6a7348"):
    (OUT / f"{slug}.svg").write_text(wrap(slug, body, accent), encoding="utf-8")


# ---------- helpers ----------
def gun(x, y, length, barrel=18, stock=8, grip=6, thick=3, color=S, barrel_c=SD, stock_c=WD):
    """Side-on firearm pointing right, origin at receiver."""
    by = y - thick / 2
    return f'''
    <rect x="{x}" y="{by}" width="{length}" height="{thick}" rx="0.6" fill="{color}"/>
    <rect x="{x + length}" y="{y - 0.8}" width="{barrel}" height="1.6" fill="{barrel_c}"/>
    <rect x="{x - stock}" y="{by + 0.4}" width="{stock}" height="{thick + 1.2}" rx="0.4" fill="{stock_c}"/>
    <path d="M{x + 2} {y + thick/2} l{grip * 0.3} {grip} h{2.2} l{-grip * 0.3} {-grip} z" fill="{stock_c}"/>
    '''


# ===== PERSONAL WEAPONS =====
save("knife", f'''
  <rect x="30.2" y="14" width="3.6" height="28" rx="0.6" fill="{S}"/>
  <path d="M30.2 14 L32 10 L33.8 14 Z" fill="{S}"/>
  <rect x="25" y="40" width="14" height="3" rx="0.5" fill="{BR}"/>
  <rect x="29.5" y="43" width="5" height="11" rx="1" fill="{WD}"/>
''')

save("pistol", f'''
  <rect x="16" y="28" width="30" height="6.5" rx="1" fill="{S}"/>
  <rect x="46" y="29.4" width="8" height="3.4" fill="{SD}"/>
  <path d="M24 34.5 L21 50 L27 50 L29.5 34.5 Z" fill="{SD}"/>
  <rect x="22" y="25.5" width="6" height="3" fill="{BR}"/>
  <circle cx="20" cy="31" r="1.2" fill="{SK}"/>
''')

save("heavy-pistol", f'''
  <rect x="14" y="26" width="32" height="8" rx="1" fill="{S}"/>
  <rect x="46" y="27.6" width="8" height="4.4" fill="{SD}"/>
  <path d="M24 34 L20 52 L28 52 L31 34 Z" fill="{WD}"/>
  <rect x="18" y="23.5" width="8" height="3" fill="{BR}"/>
  <rect x="36" y="24.5" width="8" height="2.2" fill="{SK}"/>
''')

save("bolt-rifle", f'''
  <rect x="8" y="30" width="28" height="5" rx="0.6" fill="{WD}"/>
  <rect x="36" y="30.6" width="18" height="3.6" fill="{S}"/>
  <rect x="8" y="28" width="10" height="3" fill="{WD}"/>
  <path d="M16 35 L13 46 L19 46 L21 35 Z" fill="{WD}"/>
  <rect x="30" y="27.5" width="5" height="3" fill="{BR}"/>
  <circle cx="54" cy="32.4" r="1.3" fill="{SK}"/>
''')

save("smg", f'''
  <rect x="16" y="26" width="22" height="7" rx="1" fill="{S}"/>
  <rect x="38" y="27.5" width="14" height="4" fill="{SD}"/>
  <rect x="18" y="22" width="8" height="4" rx="0.5" fill="{SK}"/>
  <path d="M22 33 L20 48 L26 48 L28 33 Z" fill="{WD}"/>
  <rect x="32" y="33" width="3" height="8" fill="{SK}"/>
  <rect x="42" y="24" width="2" height="4" fill="{BR}"/>
''')

save("semi-rifle", f'''
  <rect x="8" y="29" width="24" height="6" rx="0.6" fill="{WD}"/>
  <rect x="32" y="29.8" width="20" height="4.2" fill="{S}"/>
  <rect x="18" y="25.5" width="9" height="4" rx="0.4" fill="{SK}"/>
  <path d="M16 35 L13 47 L19 47 L21.5 35 Z" fill="{WD}"/>
  <rect x="34" y="27" width="4" height="3" fill="{BR}"/>
  <rect x="48" y="27.5" width="2" height="3" fill="{SD}"/>
''')

save("lmg", f'''
  <rect x="10" y="26" width="26" height="8" rx="1" fill="{S}"/>
  <rect x="36" y="27.6" width="16" height="4.6" fill="{SD}"/>
  <rect x="14" y="22" width="12" height="5" rx="0.5" fill="{SK}"/>
  <path d="M18 34 L16 50 L23 50 L25 34 Z" fill="{WD}"/>
  <rect x="28" y="34" width="12" height="6" rx="1" fill="{BR}"/>
  <rect x="30" y="36.2" width="8" height="2" fill="{SK}"/>
''')

save("at-launcher", f'''
  <rect x="8" y="27" width="44" height="9" rx="3" fill="{OL}"/>
  <rect x="10" y="28.8" width="40" height="5.4" rx="2" fill="{SD}"/>
  <rect x="6" y="28.5" width="6" height="6" fill="{SK}"/>
  <path d="M24 36 L22 48 L28 48 L29.5 36 Z" fill="{WD}"/>
  <circle cx="50" cy="31.5" r="2.4" fill="{SK}"/>
  <rect x="30" y="24" width="8" height="3" fill="{BR}"/>
''')

save("trench-shotgun", f'''
  <rect x="10" y="29" width="22" height="6.5" rx="0.8" fill="{WD}"/>
  <rect x="32" y="29.6" width="18" height="5.2" rx="1.4" fill="{S}"/>
  <path d="M18 35.5 L15 48 L21 48 L23.5 35.5 Z" fill="{WD}"/>
  <rect x="28" y="27" width="6" height="3" fill="{BR}"/>
  <rect x="34" y="35.5" width="10" height="2" fill="{SD}"/>
''')

save("carbine", f'''
  <rect x="12" y="29" width="20" height="5.5" rx="0.6" fill="{S}"/>
  <rect x="32" y="29.8" width="16" height="3.8" fill="{SD}"/>
  <rect x="10" y="27.5" width="8" height="3" fill="{WD}"/>
  <path d="M18 34.5 L16 46 L22 46 L23.5 34.5 Z" fill="{WD}"/>
  <rect x="24" y="26" width="6" height="3.2" fill="{SK}"/>
''')

save("combat-shotgun", f'''
  <rect x="10" y="27" width="24" height="7" rx="1" fill="{S}"/>
  <rect x="34" y="28.2" width="16" height="5" rx="1.6" fill="{SD}"/>
  <path d="M18 34 L15 50 L22 50 L24.5 34 Z" fill="{WD}"/>
  <rect x="26" y="34" width="8" height="5" rx="0.6" fill="{SK}"/>
  <rect x="22" y="24.5" width="8" height="3" fill="{BR}"/>
''')

save("cluster-grenades", f'''
  <ellipse cx="24" cy="34" rx="8" ry="10" fill="{OL}"/>
  <rect x="21" y="20" width="6" height="6" rx="1" fill="{BR}"/>
  <rect x="22.5" y="17" width="3" height="4" fill="{SD}"/>
  <ellipse cx="42" cy="38" rx="6.5" ry="8" fill="{OL}"/>
  <rect x="39.5" y="27" width="5" height="5" rx="1" fill="{BR}"/>
  <circle cx="24" cy="34" r="2" fill="{SK}"/>
  <circle cx="42" cy="38" r="1.6" fill="{SK}"/>
''')

save("marksman", f'''
  <rect x="8" y="31" width="26" height="5" rx="0.5" fill="{S}"/>
  <rect x="34" y="31.6" width="18" height="3.6" fill="{SD}"/>
  <rect x="22" y="24" width="14" height="6" rx="1" fill="{SK}"/>
  <circle cx="29" cy="27" r="2.3" fill="#0e100c" stroke="{BR}" stroke-width="1"/>
  <path d="M16 36 L13 48 L19 48 L21 36 Z" fill="{WD}"/>
  <rect x="8" y="28.5" width="8" height="3" fill="{WD}"/>
''')

save("grenade-launcher", f'''
  <rect x="12" y="26" width="24" height="9" rx="2" fill="{OL}"/>
  <rect x="36" y="28" width="14" height="6" rx="2" fill="{SD}"/>
  <path d="M20 35 L17 50 L24 50 L26.5 35 Z" fill="{WD}"/>
  <circle cx="24" cy="30.5" r="3" fill="{SK}"/>
  <rect x="16" y="22" width="8" height="4" fill="{BR}"/>
''')

save("assault-rifle", f'''
  <rect x="10" y="28" width="24" height="6.5" rx="0.7" fill="{S}"/>
  <rect x="34" y="29.2" width="16" height="4" fill="{SD}"/>
  <rect x="18" y="23" width="10" height="5.5" rx="0.6" fill="{SK}"/>
  <path d="M18 34.5 L16 48 L22 48 L24 34.5 Z" fill="{WD}"/>
  <rect x="28" y="34.5" width="3.2" height="9" fill="{SK}"/>
  <rect x="36" y="26" width="4" height="3.4" fill="{BR}"/>
  <rect x="12" y="26.5" width="6" height="2.5" fill="{OL}"/>
''')

save("battle-rifle", f'''
  <rect x="8" y="29" width="26" height="6.2" rx="0.6" fill="{S}"/>
  <rect x="34" y="29.8" width="18" height="4.4" fill="{SD}"/>
  <rect x="20" y="23.5" width="11" height="5.8" rx="0.5" fill="{SK}"/>
  <path d="M16 35.2 L13 49 L19.5 49 L22 35.2 Z" fill="{WD}"/>
  <rect x="8" y="26.5" width="9" height="3.2" fill="{WD}"/>
  <rect x="32" y="27" width="5" height="3" fill="{BR}"/>
''')

save("hmg", f'''
  <rect x="12" y="22" width="30" height="10" rx="1" fill="{S}"/>
  <rect x="42" y="24.2" width="12" height="5.5" fill="{SD}"/>
  <rect x="16" y="17" width="14" height="6" rx="0.6" fill="{SK}"/>
  <path d="M20 32 L14 42 L50 42 L46 32 Z" fill="{SK}"/>
  <rect x="22" y="42" width="4" height="8" fill="{SD}"/>
  <rect x="38" y="42" width="4" height="8" fill="{SD}"/>
  <rect x="28" y="32" width="12" height="6" fill="{BR}"/>
''')

save("recoilless", f'''
  <rect x="6" y="26" width="50" height="10" rx="4" fill="{OL}"/>
  <rect x="10" y="28.2" width="42" height="5.6" rx="2.5" fill="{SD}"/>
  <circle cx="10" cy="31" r="5" fill="none" stroke="{BR}" stroke-width="1.6"/>
  <circle cx="54" cy="31" r="5" fill="none" stroke="{BR}" stroke-width="1.6"/>
  <path d="M24 36 L22 48 L28 48 L30 36 Z" fill="{WD}"/>
''')

save("am-rifle", f'''
  <rect x="6" y="30" width="28" height="6.5" rx="0.6" fill="{S}"/>
  <rect x="34" y="30.8" width="20" height="4.6" fill="{SD}"/>
  <rect x="20" y="22" width="16" height="7" rx="1" fill="{SK}"/>
  <circle cx="28" cy="25.5" r="2.6" fill="#0e100c" stroke="{BR}" stroke-width="1.1"/>
  <path d="M14 36.5 L11 50 L18 50 L20.5 36.5 Z" fill="{WD}"/>
  <rect x="36" y="36" width="10" height="3" fill="{OL}"/>
''')

save("rail-rifle", f'''
  <rect x="8" y="28" width="26" height="7" rx="0.8" fill="{S}"/>
  <rect x="34" y="29.5" width="18" height="2.2" fill="{SKY}"/>
  <rect x="34" y="33" width="18" height="2.2" fill="{SKY}"/>
  <rect x="18" y="21.5" width="12" height="6.5" rx="0.6" fill="{SK}"/>
  <path d="M16 35 L14 49 L20 49 L22.5 35 Z" fill="{WD}"/>
  <rect x="28" y="26" width="6" height="3" fill="{BR}"/>
  <circle cx="52" cy="32.2" r="2" fill="{RD}"/>
''')

# ===== ARMOR =====
save("jacket", f'''
  <path d="M20 20 L32 16 L44 20 L46 50 L18 50 Z" fill="{OL}" stroke="{SK}" stroke-width="1"/>
  <path d="M32 16 L32 50" stroke="{BR}" stroke-width="1.2"/>
  <path d="M20 20 L14 30 L20 32" fill="{OL}" stroke="{SK}" stroke-width="1"/>
  <path d="M44 20 L50 30 L44 32" fill="{OL}" stroke="{SK}" stroke-width="1"/>
  <circle cx="27" cy="30" r="1.3" fill="{BR}"/>
  <circle cx="27" cy="36" r="1.3" fill="{BR}"/>
  <circle cx="27" cy="42" r="1.3" fill="{BR}"/>
''')

save("helmet", f'''
  <path d="M14 36 Q14 18 32 18 Q50 18 50 36 L46 38 Q32 42 18 38 Z" fill="{SD}" stroke="{S}" stroke-width="1"/>
  <path d="M18 36 Q32 40 46 36" fill="none" stroke="{SK}" stroke-width="1.4"/>
  <rect x="30" y="22" width="4" height="8" fill="{BR}"/>
  <path d="M16 36 L12 40 L16 40" fill="{SD}"/>
  <path d="M48 36 L52 40 L48 40" fill="{SD}"/>
''')

save("flak", f'''
  <path d="M20 18 L32 15 L44 18 L47 48 L17 48 Z" fill="{OL}"/>
  <rect x="22" y="24" width="20" height="18" rx="1" fill="{SK}"/>
  <rect x="24" y="26" width="16" height="6" fill="{SD}"/>
  <rect x="24" y="34" width="16" height="6" fill="{SD}"/>
  <path d="M20 18 L14 28 L20 30" fill="{OL}"/>
  <path d="M44 18 L50 28 L44 30" fill="{OL}"/>
''')

save("trench-plate", f'''
  <path d="M18 18 L32 14 L46 18 L48 50 L16 50 Z" fill="{SD}" stroke="{S}" stroke-width="1.2"/>
  <path d="M22 26 L42 26 L42 44 L22 44 Z" fill="none" stroke="{BR}" stroke-width="1.2"/>
  <circle cx="24" cy="28" r="1.3" fill="{BR}"/>
  <circle cx="40" cy="28" r="1.3" fill="{BR}"/>
  <circle cx="24" cy="42" r="1.3" fill="{BR}"/>
  <circle cx="40" cy="42" r="1.3" fill="{BR}"/>
  <path d="M32 14 L32 50" stroke="{SK}" stroke-width="1"/>
''')

save("ceramic", f'''
  <path d="M19 17 L32 14 L45 17 L48 49 L16 49 Z" fill="{S}"/>
  <path d="M23 24 L41 24 L41 42 L23 42 Z" fill="{SKY}" opacity="0.55"/>
  <path d="M23 24 L41 24 L41 42 L23 42 Z" fill="none" stroke="{NV}" stroke-width="1.2"/>
  <path d="M19 17 L13 27 L19 29" fill="{S}"/>
  <path d="M45 17 L51 27 L45 29" fill="{S}"/>
  <rect x="30" y="20" width="4" height="6" fill="{BR}"/>
''')

save("assault-suit", f'''
  <path d="M18 16 L32 12 L46 16 L49 52 L15 52 Z" fill="{OL}" stroke="{S}" stroke-width="1"/>
  <rect x="22" y="22" width="20" height="22" rx="2" fill="{SK}"/>
  <rect x="24" y="24" width="16" height="8" fill="{SD}"/>
  <rect x="24" y="34" width="16" height="8" fill="{SD}"/>
  <circle cx="32" cy="20" r="5" fill="{SD}" stroke="{S}" stroke-width="1"/>
  <path d="M18 16 L11 28 L18 31" fill="{SD}"/>
  <path d="M46 16 L53 28 L46 31" fill="{SD}"/>
''')

save("webbing", f'''
  <path d="M22 16 L32 14 L42 16 L44 50 L20 50 Z" fill="#5a4a2e"/>
  <path d="M24 22 H40 M24 30 H40 M24 38 H40" stroke="{BR}" stroke-width="2.4"/>
  <rect x="25" y="23.5" width="6" height="5" fill="{OL}"/>
  <rect x="33" y="23.5" width="6" height="5" fill="{OL}"/>
  <rect x="25" y="31.5" width="14" height="5" fill="{OL}"/>
  <path d="M22 16 L16 24" stroke="{BR}" stroke-width="2"/>
  <path d="M42 16 L48 24" stroke="{BR}" stroke-width="2"/>
''')

save("riot-shield", f'''
  <rect x="18" y="12" width="28" height="40" rx="4" fill="{NV}" stroke="{S}" stroke-width="1.6"/>
  <rect x="21" y="16" width="22" height="12" rx="1" fill="#9ec4d8" opacity="0.7"/>
  <rect x="22" y="32" width="20" height="14" rx="1" fill="{SK}"/>
  <path d="M32 32 V46" stroke="{BR}" stroke-width="1.4"/>
''')

save("comp-helmet", f'''
  <path d="M14 36 Q14 16 32 16 Q50 16 50 36 L46 39 Q32 44 18 39 Z" fill="{S}" stroke="{SKY}" stroke-width="1.3"/>
  <rect x="20" y="28" width="24" height="5" rx="1" fill="{SK}"/>
  <rect x="28" y="20" width="8" height="4" fill="{NV}"/>
  <path d="M16 36 L10 42 L16 41" fill="{SD}"/>
  <path d="M48 36 L54 42 L48 41" fill="{SD}"/>
''')

save("plate-carrier", f'''
  <path d="M20 16 L32 13 L44 16 L47 50 L17 50 Z" fill="{OL}"/>
  <rect x="22" y="24" width="20" height="20" rx="1" fill="{SK}" stroke="{S}" stroke-width="1"/>
  <rect x="24" y="26" width="16" height="7" fill="{SD}"/>
  <rect x="24" y="35" width="16" height="7" fill="{SD}"/>
  <path d="M20 16 L14 22 L20 26" fill="{OL}" stroke="{BR}" stroke-width="1"/>
  <path d="M44 16 L50 22 L44 26" fill="{OL}" stroke="{BR}" stroke-width="1"/>
''')

save("bomb-suit", f'''
  <path d="M16 18 L32 12 L48 18 L52 52 L12 52 Z" fill="{SD}" stroke="{S}" stroke-width="1.3"/>
  <circle cx="32" cy="22" r="8" fill="{SK}" stroke="{S}" stroke-width="1.4"/>
  <circle cx="32" cy="22" r="5" fill="#8fb8c8" opacity="0.6"/>
  <rect x="20" y="32" width="24" height="16" rx="2" fill="{SK}"/>
  <rect x="22" y="34" width="20" height="5" fill="{BR}"/>
  <rect x="22" y="41" width="20" height="5" fill="{BR}"/>
''')

save("exo-plate", f'''
  <path d="M16 16 L32 11 L48 16 L51 52 L13 52 Z" fill="{S}" stroke="{SKY}" stroke-width="1.4"/>
  <path d="M22 24 L42 24 L42 46 L22 46 Z" fill="{NV}"/>
  <path d="M24 26 L40 26 L40 34 L24 34 Z" fill="{SKY}" opacity="0.5"/>
  <circle cx="32" cy="18" r="4.5" fill="{SK}" stroke="{BR}" stroke-width="1"/>
  <rect x="14" y="28" width="6" height="16" rx="1" fill="{SD}"/>
  <rect x="44" y="28" width="6" height="16" rx="1" fill="{SD}"/>
''')

# ===== ARMY WEAPONS =====
save("rifles", f'''
  <g transform="translate(0,-4)">
    <rect x="10" y="28" width="30" height="3.4" fill="{WD}"/>
    <rect x="40" y="28.5" width="14" height="2.4" fill="{S}"/>
  </g>
  <g transform="translate(0,4)">
    <rect x="10" y="28" width="30" height="3.4" fill="{WD}"/>
    <rect x="40" y="28.5" width="14" height="2.4" fill="{S}"/>
  </g>
  <rect x="18" y="20" width="3" height="6" fill="{BR}"/>
''')

save("machine-guns", f'''
  <rect x="12" y="24" width="28" height="8" rx="1" fill="{S}"/>
  <rect x="40" y="26" width="12" height="4" fill="{SD}"/>
  <rect x="16" y="20" width="10" height="5" fill="{SK}"/>
  <path d="M20 32 L16 42 L48 42 L44 32 Z" fill="{SK}"/>
  <rect x="22" y="42" width="3.5" height="6" fill="{SD}"/>
  <rect x="38" y="42" width="3.5" height="6" fill="{SD}"/>
''')

save("mortars", f'''
  <rect x="28" y="14" width="7" height="28" rx="2" transform="rotate(28 31.5 28)" fill="{SD}"/>
  <circle cx="24" cy="42" r="8" fill="none" stroke="{BR}" stroke-width="2.2"/>
  <rect x="16" y="44" width="32" height="4" fill="{SK}"/>
  <circle cx="38" cy="18" r="3" fill="{OL}"/>
''')

save("at-rockets", f'''
  <rect x="10" y="24" width="36" height="8" rx="3" fill="{OL}"/>
  <polygon points="46,22 58,28 46,34" fill="{RD}"/>
  <rect x="14" y="25.8" width="10" height="4.4" fill="{BR}"/>
  <path d="M22 32 L20 44 L26 44 L28 32 Z" fill="{WD}"/>
  <rect x="32" y="20" width="8" height="4" fill="{SK}"/>
''')

save("flamethrowers", f'''
  <rect x="22" y="22" width="10" height="22" rx="2" fill="{OL}"/>
  <rect x="32" y="28" width="16" height="5" rx="1.5" fill="{S}"/>
  <path d="M48 26 Q58 30.5 50 36 Q60 30.5 48 26" fill="{RD}"/>
  <circle cx="27" cy="28" r="2" fill="{BR}"/>
  <path d="M24 44 L22 50 L32 50 L30 44 Z" fill="{SK}"/>
''')

save("grenades", f'''
  <ellipse cx="24" cy="34" rx="8" ry="10" fill="{OL}"/>
  <rect x="21" y="20" width="6" height="6" rx="1" fill="{BR}"/>
  <ellipse cx="42" cy="36" rx="7" ry="9" fill="{OL}"/>
  <rect x="39.4" y="24" width="5.2" height="5" rx="1" fill="{BR}"/>
  <path d="M24 28 l0 12 M20 34 h8" stroke="{SK}" stroke-width="1.2"/>
''')

save("shotguns", f'''
  <rect x="8" y="24" width="24" height="5.5" rx="1" fill="{WD}"/>
  <rect x="32" y="24.6" width="18" height="4.2" rx="1.4" fill="{S}"/>
  <rect x="8" y="36" width="24" height="5.5" rx="1" fill="{WD}"/>
  <rect x="32" y="36.6" width="18" height="4.2" rx="1.4" fill="{S}"/>
''')

save("heavy-mortars", f'''
  <rect x="30" y="12" width="9" height="32" rx="2" transform="rotate(24 34.5 28)" fill="{S}"/>
  <circle cx="22" cy="44" r="9" fill="none" stroke="{BR}" stroke-width="2.4"/>
  <rect x="14" y="46" width="36" height="5" fill="{SK}"/>
  <rect x="18" y="40" width="10" height="6" fill="{OL}"/>
''')

save("recoilless-guns", f'''
  <rect x="6" y="27" width="52" height="9" rx="4" fill="{OL}"/>
  <rect x="12" y="29" width="40" height="5" rx="2" fill="{SD}"/>
  <circle cx="10" cy="31.5" r="5.5" fill="none" stroke="{BR}" stroke-width="1.8"/>
  <circle cx="54" cy="31.5" r="5.5" fill="none" stroke="{BR}" stroke-width="1.8"/>
''')

save("autocannons", f'''
  <rect x="14" y="22" width="16" height="16" rx="1" fill="{SK}"/>
  <rect x="30" y="26" width="22" height="4" fill="{S}"/>
  <rect x="30" y="32" width="18" height="4" fill="{S}"/>
  <path d="M16 38 L14 48 L50 48 L46 38 Z" fill="{OL}"/>
  <rect x="20" y="48" width="4" height="6" fill="{SD}"/>
  <rect x="40" y="48" width="4" height="6" fill="{SD}"/>
''')

save("howitzers", f'''
  <rect x="22" y="16" width="10" height="26" rx="2" transform="rotate(-28 27 29)" fill="{S}"/>
  <path d="M16 36 L12 50 L52 50 L46 36 Z" fill="{OL}"/>
  <circle cx="22" cy="50" r="5" fill="{SK}" stroke="{SD}" stroke-width="1.5"/>
  <circle cx="42" cy="50" r="5" fill="{SK}" stroke="{SD}" stroke-width="1.5"/>
  <rect x="26" y="38" width="12" height="6" fill="{BR}"/>
''')

save("missile-launchers", f'''
  <rect x="14" y="18" width="8" height="28" rx="2" fill="{OL}"/>
  <rect x="25" y="18" width="8" height="28" rx="2" fill="{OL}"/>
  <rect x="36" y="18" width="8" height="28" rx="2" fill="{OL}"/>
  <polygon points="18,14 22,10 22,14" fill="{RD}"/>
  <polygon points="29,14 33,10 33,14" fill="{RD}"/>
  <polygon points="40,14 44,10 44,14" fill="{RD}"/>
  <rect x="16" y="46" width="26" height="5" fill="{SK}"/>
''')

# ===== VEHICLES =====
save("jeep", f'''
  <path d="M12 36 L16 28 L28 28 L32 22 L50 22 L54 36 Z" fill="{OL}"/>
  <rect x="33" y="24" width="14" height="8" fill="#8fb8c8" opacity="0.55"/>
  <circle cx="22" cy="40" r="5.2" fill="{SK}" stroke="{S}" stroke-width="1.3"/>
  <circle cx="46" cy="40" r="5.2" fill="{SK}" stroke="{S}" stroke-width="1.3"/>
  <rect x="14" y="30" width="8" height="5" fill="{SK}"/>
''')

save("armored-car", f'''
  <path d="M10 34 L14 24 L50 24 L54 34 L54 40 L10 40 Z" fill="{SD}"/>
  <rect x="20" y="26" width="16" height="8" fill="{SK}"/>
  <rect x="38" y="20" width="12" height="5" fill="{S}"/>
  <circle cx="20" cy="42" r="5" fill="{SK}" stroke="{S}" stroke-width="1.2"/>
  <circle cx="44" cy="42" r="5" fill="{SK}" stroke="{S}" stroke-width="1.2"/>
''')

save("light-tank", f'''
  <path d="M10 34 L16 28 L48 28 L54 34 L54 42 L10 42 Z" fill="{OL}"/>
  <rect x="22" y="20" width="20" height="10" rx="2" fill="{SD}"/>
  <rect x="40" y="22" width="16" height="4" fill="{S}"/>
  <rect x="12" y="36" width="40" height="4" fill="{SK}"/>
  <rect x="14" y="42" width="8" height="5" fill="{SK}"/>
  <rect x="28" y="42" width="8" height="5" fill="{SK}"/>
  <rect x="42" y="42" width="8" height="5" fill="{SK}"/>
''')

save("artillery", f'''
  <rect x="20" y="14" width="8" height="28" rx="1.5" transform="rotate(-32 24 28)" fill="{S}"/>
  <path d="M14 36 L10 50 L50 50 L46 36 Z" fill="{OL}"/>
  <circle cx="22" cy="50" r="5.5" fill="{SK}" stroke="{SD}" stroke-width="1.5"/>
  <circle cx="42" cy="50" r="5.5" fill="{SK}" stroke="{SD}" stroke-width="1.5"/>
''')

save("heavy-tank", f'''
  <path d="M8 34 L14 26 L50 26 L56 34 L56 44 L8 44 Z" fill="{OL}"/>
  <rect x="20" y="16" width="24" height="12" rx="2" fill="{SD}"/>
  <rect x="42" y="18" width="16" height="5" fill="{S}"/>
  <rect x="10" y="36" width="44" height="5" fill="{SK}"/>
  <rect x="12" y="44" width="10" height="6" fill="{SK}"/>
  <rect x="27" y="44" width="10" height="6" fill="{SK}"/>
  <rect x="42" y="44" width="10" height="6" fill="{SK}"/>
''')

save("fighter", f'''
  <ellipse cx="32" cy="32" rx="22" ry="5" fill="{SKY}"/>
  <path d="M32 20 L54 32 L32 28 Z" fill="{NV}"/>
  <path d="M18 28 L8 22 L10 30 L8 38 L18 32 Z" fill="{NV}"/>
  <path d="M16 30 L6 36 L16 34 Z" fill="{SD}"/>
  <circle cx="40" cy="30" r="2" fill="#9ec4d8"/>
''', accent="#4a6d82")

save("bomber", f'''
  <ellipse cx="32" cy="34" rx="24" ry="6" fill="{NV}"/>
  <path d="M32 22 L58 34 L32 30 Z" fill="{SKY}"/>
  <path d="M20 30 L6 18 L10 32 L6 46 L20 36 Z" fill="{SD}"/>
  <rect x="26" y="36" width="4" height="6" fill="{SK}"/>
  <rect x="34" y="36" width="4" height="6" fill="{SK}"/>
  <circle cx="46" cy="32" r="2" fill="#9ec4d8"/>
''', accent="#4a6d82")

save("destroyer", f'''
  <path d="M6 40 L16 30 L54 30 L60 40 L54 46 L12 46 Z" fill="{NV}"/>
  <rect x="24" y="20" width="8" height="10" fill="{SD}"/>
  <rect x="34" y="24" width="14" height="6" fill="{S}"/>
  <rect x="18" y="26" width="5" height="4" fill="{BR}"/>
  <path d="M8 40 H58" stroke="{SKY}" stroke-width="1.2"/>
''', accent="#4a6d82")

save("motorcycle", f'''
  <circle cx="20" cy="40" r="7" fill="none" stroke="{S}" stroke-width="2.2"/>
  <circle cx="46" cy="40" r="7" fill="none" stroke="{S}" stroke-width="2.2"/>
  <path d="M20 40 L30 26 L44 28 L46 40" fill="none" stroke="{OL}" stroke-width="2.4" stroke-linejoin="round"/>
  <rect x="28" y="22" width="10" height="5" rx="1" fill="{SK}"/>
  <path d="M30 26 L18 22" stroke="{SD}" stroke-width="2"/>
''')

save("truck", f'''
  <rect x="8" y="24" width="24" height="18" fill="{OL}"/>
  <path d="M32 30 L42 30 L46 38 L46 42 L32 42 Z" fill="{SD}"/>
  <rect x="36" y="32" width="7" height="6" fill="#8fb8c8" opacity="0.6"/>
  <circle cx="16" cy="44" r="5" fill="{SK}" stroke="{S}" stroke-width="1.2"/>
  <circle cx="28" cy="44" r="5" fill="{SK}" stroke="{S}" stroke-width="1.2"/>
  <circle cx="42" cy="44" r="5" fill="{SK}" stroke="{S}" stroke-width="1.2"/>
''')

save("halftrack", f'''
  <path d="M10 30 L16 22 L36 22 L40 28 L54 28 L54 40 L10 40 Z" fill="{OL}"/>
  <rect x="18" y="24" width="12" height="8" fill="{SK}"/>
  <circle cx="20" cy="42" r="5" fill="{SK}" stroke="{S}" stroke-width="1.2"/>
  <rect x="32" y="38" width="22" height="8" rx="2" fill="{SK}"/>
  <rect x="34" y="40" width="4" height="5" fill="{SD}"/>
  <rect x="41" y="40" width="4" height="5" fill="{SD}"/>
  <rect x="48" y="40" width="4" height="5" fill="{SD}"/>
''')

save("apc", f'''
  <path d="M10 32 L16 22 L50 22 L56 32 L56 42 L10 42 Z" fill="{OL}"/>
  <rect x="20" y="24" width="10" height="8" fill="{SK}"/>
  <rect x="32" y="24" width="14" height="8" fill="{SK}"/>
  <rect x="12" y="34" width="40" height="5" fill="{SK}"/>
  <rect x="16" y="42" width="8" height="5" fill="{SK}"/>
  <rect x="28" y="42" width="8" height="5" fill="{SK}"/>
  <rect x="40" y="42" width="8" height="5" fill="{SK}"/>
  <rect x="44" y="18" width="8" height="5" fill="{S}"/>
''')

save("scout-plane", f'''
  <ellipse cx="32" cy="34" rx="20" ry="4.2" fill="{S}"/>
  <path d="M30 18 L50 34 L30 30 Z" fill="{OL}"/>
  <path d="M20 30 L10 22 L12 34 L10 42 L20 36 Z" fill="{OL}"/>
  <circle cx="40" cy="32.5" r="2.2" fill="#9ec4d8"/>
  <path d="M18 34 L10 38 L18 36 Z" fill="{SD}"/>
''')

save("medium-tank", f'''
  <path d="M9 34 L15 27 L49 27 L55 34 L55 43 L9 43 Z" fill="{OL}"/>
  <rect x="21" y="18" width="22" height="11" rx="2" fill="{SD}"/>
  <rect x="41" y="20" width="16" height="4.5" fill="{S}"/>
  <rect x="11" y="36" width="42" height="4.5" fill="{SK}"/>
  <rect x="13" y="43" width="9" height="5.5" fill="{SK}"/>
  <rect x="27.5" y="43" width="9" height="5.5" fill="{SK}"/>
  <rect x="42" y="43" width="9" height="5.5" fill="{SK}"/>
''')

save("spg", f'''
  <path d="M10 36 L16 30 L50 30 L56 36 L56 44 L10 44 Z" fill="{OL}"/>
  <rect x="22" y="14" width="8" height="22" rx="1.5" transform="rotate(-18 26 25)" fill="{S}"/>
  <rect x="20" y="22" width="16" height="10" fill="{SD}"/>
  <rect x="12" y="38" width="40" height="4" fill="{SK}"/>
  <rect x="14" y="44" width="8" height="5" fill="{SK}"/>
  <rect x="28" y="44" width="8" height="5" fill="{SK}"/>
  <rect x="42" y="44" width="8" height="5" fill="{SK}"/>
''')

save("transport-heli", f'''
  <rect x="16" y="28" width="30" height="12" rx="3" fill="{OL}"/>
  <rect x="20" y="30" width="16" height="6" fill="#8fb8c8" opacity="0.5"/>
  <rect x="44" y="31" width="14" height="3" fill="{SD}"/>
  <path d="M8 26 H56 M32 20 V26" stroke="{S}" stroke-width="2"/>
  <path d="M16 40 L12 48 L20 44 M42 40 L38 48 L46 44" stroke="{SK}" stroke-width="2"/>
''')

save("attack-heli", f'''
  <path d="M14 30 L44 26 L50 32 L44 38 L14 36 Z" fill="{OL}"/>
  <rect x="18" y="30" width="12" height="5" fill="{SK}"/>
  <rect x="4" y="31" width="12" height="3" fill="{S}"/>
  <rect x="48" y="31" width="12" height="3" fill="{SD}"/>
  <path d="M6 24 H58 M32 18 V26" stroke="{S}" stroke-width="2"/>
  <rect x="24" y="36" width="3" height="8" fill="{RD}"/>
  <rect x="30" y="36" width="3" height="8" fill="{RD}"/>
  <path d="M18 38 L14 46 L22 42" stroke="{SK}" stroke-width="2"/>
''')

save("jet", f'''
  <path d="M8 32 L36 26 L58 32 L36 38 Z" fill="{SKY}"/>
  <path d="M28 20 L50 32 L28 28 Z" fill="{NV}"/>
  <path d="M28 36 L50 32 L28 44 Z" fill="{NV}"/>
  <path d="M12 30 L4 22 L8 32 L4 42 L12 34 Z" fill="{SD}"/>
  <circle cx="40" cy="32" r="2" fill="#cfe4ee"/>
''', accent="#4a6d82")

save("submarine", f'''
  <ellipse cx="32" cy="36" rx="24" ry="8" fill="{NV}"/>
  <rect x="28" y="20" width="8" height="12" fill="{SD}"/>
  <rect x="30" y="14" width="4" height="8" fill="{S}"/>
  <rect x="36" y="24" width="8" height="4" fill="{SK}"/>
  <path d="M8 36 L4 32 L8 36 L4 40 Z" fill="{SD}"/>
  <circle cx="20" cy="36" r="1.6" fill="{SKY}"/>
  <circle cx="26" cy="36" r="1.6" fill="{SKY}"/>
''', accent="#4a6d82")

save("cruiser", f'''
  <path d="M4 40 L14 28 L56 28 L62 40 L54 48 L10 48 Z" fill="{NV}"/>
  <rect x="22" y="16" width="7" height="12" fill="{SD}"/>
  <rect x="30" y="20" width="16" height="8" fill="{S}"/>
  <rect x="18" y="22" width="5" height="6" fill="{BR}"/>
  <rect x="48" y="22" width="6" height="6" fill="{BR}"/>
  <path d="M8 40 H58" stroke="{SKY}" stroke-width="1.2"/>
''', accent="#4a6d82")

save("battleship", f'''
  <path d="M2 40 L14 26 L58 26 L64 40 L54 50 L8 50 Z" fill="{NV}"/>
  <rect x="18" y="14" width="8" height="12" fill="{SD}"/>
  <rect x="28" y="16" width="18" height="10" fill="{S}"/>
  <rect x="14" y="20" width="5" height="6" fill="{BR}"/>
  <rect x="48" y="18" width="6" height="8" fill="{BR}"/>
  <rect x="54" y="20" width="5" height="6" fill="{BR}"/>
  <path d="M6 40 H60" stroke="{SKY}" stroke-width="1.3"/>
  <rect x="22" y="28" width="4" height="4" fill="{SK}"/>
  <rect x="38" y="28" width="4" height="4" fill="{SK}"/>
''', accent="#4a6d82")

save("unknown", f'''
  <circle cx="32" cy="32" r="12" fill="none" stroke="{SD}" stroke-width="2.2"/>
  <text x="32" y="38" text-anchor="middle" font-size="18" font-family="Trebuchet MS,Verdana,sans-serif" fill="{S}">?</text>
''')

save("fists", f'''
  <rect x="14" y="26" width="14" height="16" rx="3" fill="{SD}"/>
  <rect x="36" y="26" width="14" height="16" rx="3" fill="{SD}"/>
  <rect x="16" y="22" width="4" height="8" rx="1.5" fill="{S}"/>
  <rect x="20.5" y="21" width="4" height="8" rx="1.5" fill="{S}"/>
  <rect x="25" y="22" width="4" height="8" rx="1.5" fill="{S}"/>
  <rect x="38" y="22" width="4" height="8" rx="1.5" fill="{S}"/>
  <rect x="42.5" y="21" width="4" height="8" rx="1.5" fill="{S}"/>
  <rect x="47" y="22" width="4" height="8" rx="1.5" fill="{S}"/>
''')

# Preview page
icons = sorted(p.name for p in OUT.glob("*.svg"))
cards = "\n".join(
    f'<figure><img src="file://{OUT / n}" alt="{n}"><figcaption>{n[:-4]}</figcaption></figure>'
    for n in icons
)
preview = Path("/tmp/icon-preview/index.html")
preview.write_text(f'''<!doctype html>
<meta charset="utf-8">
<title>Iron Front icons</title>
<style>
  body{{background:#121410;color:#d9dcc9;font:13px/1.3 Trebuchet MS,Verdana,sans-serif;margin:16px}}
  h1{{color:#b5a142;font-size:18px}}
  .grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:14px}}
  figure{{margin:0;background:#1c1f18;border:1px solid #363b2c;border-radius:8px;padding:10px;text-align:center}}
  img{{width:80px;height:80px;image-rendering:auto}}
  figcaption{{margin-top:6px;color:#8c917c}}
</style>
<h1>Iron Front icon set ({len(icons)})</h1>
<div class="grid">{cards}</div>
''', encoding="utf-8")
print(f"wrote {len(icons)} icons to {OUT}")
print(f"preview {preview}")
