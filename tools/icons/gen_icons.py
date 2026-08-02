#!/usr/bin/env python3
"""kldload app-icon generator — one cohesive flat set.

Transparent background, NO tile: each icon is just the object drawn as line
art in solid light-blue (#7cc0ff) with a crisp BLACK lining hugging every
stroke, so the glyph pops and stays legible on dark and light shells alike.
Emits scalable SVG (GNOME renders crisp at any size) plus a contact-sheet SVG
for review (the sheet has a mid background so both the blue and the black
outline are visible; the shipped icons themselves are transparent).
Run: python3 gen_icons.py <outdir>
"""
import math, os, sys

# STYLE (env): pick the aesthetic — 'outline' (blue + black lining, pops/sticker),
# 'clean' (single-weight blue stroke, no outline — sleek/modern Lucide-ish),
# or 'mono' (near-white single stroke — GNOME-native, very sleek).
STYLE = os.environ.get("STYLE", "clean")
ALPHA = "1"             # fully opaque — translucency made it hard to read
if STYLE == "clean":
    ACCENT = "#5ab0ff"; USE_LINING = False
elif STYLE == "mono":
    ACCENT = "#e9eef7"; USE_LINING = False
else:  # outline
    ACCENT = "#7cc0ff"; USE_LINING = True
LINING = "#000000"      # crisp BLACK lining behind every stroke (outline style)
LINE_R = "2.6"          # lining thickness (feMorphology dilate radius, 256-space)
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)

# Darker-blue lining: dilate the glyph's alpha, flood it darker-blue, drop the
# original line art back on top. Generic — works no matter how a glyph is drawn.
FILTER = (f'<filter id="ln" x="-20%" y="-20%" width="140%" height="140%">'
          f'<feMorphology in="SourceAlpha" operator="dilate" radius="{LINE_R}" result="d"/>'
          f'<feFlood flood-color="{LINING}" result="f"/>'
          f'<feComposite in="f" in2="d" operator="in" result="o"/>'
          f'<feMerge><feMergeNode in="o"/><feMergeNode in="SourceGraphic"/></feMerge>'
          f'</filter>')

S = f'stroke="{ACCENT}"'           # shorthand
def L(x1,y1,x2,y2,w=11): return f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" {S} stroke-width="{w}" stroke-linecap="round"/>'
def C(cx,cy,r,fill=False,w=11): return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" '+(f'fill="{ACCENT}"' if fill else f'fill="none" {S} stroke-width="{w}"')+'/>'
def RR(x,y,w,h,r,fill=False,sw=11): return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" '+(f'fill="{ACCENT}"' if fill else f'fill="none" {S} stroke-width="{sw}"')+'/>'
def P(d,fill=False,w=11,cap="round",join="round"): return f'<path d="{d}" '+(f'fill="{ACCENT}"' if fill else f'fill="none" {S} stroke-width="{w}"')+f' stroke-linecap="{cap}" stroke-linejoin="{join}"/>'

# ── glyphs (drawn in 0..256 space) ───────────────────────────────────────────
# Highlight philosophy: each glyph gets at most ONE element painted in ACCENT2
# (via the Cf2/RRf2/Pf2 helpers) to keep the set cohesive — one warm accent
# against the cool primary so the icon reads as crafted instead of monochrome.
def console():   return P("M86 90 L124 128 L86 166",w=16)+RRf2(138,150,48,16,8)  # amber prompt = cursor
def terminal():  return RR(56,72,144,112,18,sw=11)+L(56,100,200,100,11)+Cf2(74,86,5)+C(92,86,5,True)+C(110,86,5,True)+P("M84 128 L108 146 L84 164",w=12)+RR(120,156,40,12,6,True)  # one traffic-light dot amber
def zfs():
    o=[];cx,rx,ry=128,58,18
    for y in (84,118,152):
        o.append(P(f"M{cx-rx} {y} V{y+34} A{rx} {ry} 0 0 0 {cx+rx} {y+34} V{y}"))
        o.append(f'<ellipse cx="{cx}" cy="{y}" rx="{rx}" ry="{ry}" fill="none" {S} stroke-width="11"/>')
    return "".join(o)
def zxplore():  # dataset stack + magnifier = explore the ZFS you already run
    o = []
    cx, rx, ry = 112, 44, 14
    for y in (86, 116, 146):
        o.append(P(f"M{cx-rx} {y} V{y+24} A{rx} {ry} 0 0 0 {cx+rx} {y+24} V{y}"))
        o.append(
            f'<ellipse cx="{cx}" cy="{y}" rx="{rx}" ry="{ry}" '
            f'fill="none" {S} stroke-width="9"/>')
    mx, my = 176, 164  # magnifier over the stack; amber glint = the F2 accent
    lens = C(mx, my, 26, w=10) + L(mx + 20, my + 20, mx + 42, my + 42, 13)
    return "".join(o) + lens + Cf2(mx - 9, my - 9, 5)
def zfs_manager(): # zfs stack + gear badge
    g=[];cx,rx,ry=118,46,15
    for y in (96,124,152):
        g.append(P(f"M{cx-rx} {y} V{y+26} A{rx} {ry} 0 0 0 {cx+rx} {y+26} V{y}"))
        g.append(f'<ellipse cx="{cx}" cy="{y}" rx="{rx}" ry="{ry}" fill="none" {S} stroke-width="9"/>')
    gx,gy=182,182  # gear
    teeth="".join(L(gx+18*math.cos(math.radians(a)),gy+18*math.sin(math.radians(a)),gx+30*math.cos(math.radians(a)),gy+30*math.sin(math.radians(a)),8) for a in range(0,360,45))
    return "".join(g)+teeth+C(gx,gy,18,w=9)+C(gx,gy,6,True)
def kubernetes():
    cx=cy=128;Rv=74;hub=13;o=[C(cx,cy,hub,w=12),Cf2(cx,cy,hub-5)];pts=[]  # amber hub core inside the ring
    for k in range(7):
        a=math.radians(-90+k*360/7);x,y=cx+Rv*math.cos(a),cy+Rv*math.sin(a);pts.append((x,y))
        o.append(L(cx+hub*math.cos(a),cy+hub*math.sin(a),x,y,11));o.append(C(x,y,9,True))
    o.append(P("M"+" L".join(f"{x:.1f} {y:.1f}" for x,y in pts)+" Z",w=9))
    return "".join(o)
def vms(): # two overlapping screens + power LED
    return RR(58,64,118,86,12,sw=11)+L(96,150,96,162,11)+L(80,162,112,162,11)+RR(118,108,82,72,12,sw=11)+f'<rect x="124" y="114" width="70" height="48" rx="4" fill="{ACCENT}" fill-opacity="0.18"/>'+Cf2(190,116,5)  # amber power-on LED, top-right of front monitor
def metrics(): # bars + trend line — peak bar gets the amber callout
    bars="".join((RRf2(x,y,26,196-y,5) if y==84 else RR(x,y,26,196-y,5,True)) for x,y in ((62,140),(100,108),(138,150),(176,84)))
    return bars+P("M62 96 L114 70 L150 112 L196 58",w=9)+C(62,96,7,True)+C(114,70,7,True)+C(150,112,7,True)+C(196,58,7,True)
def bob(): # genie's lamp (filled silhouette) + rising smoke + sparkle
    body='<ellipse cx="126" cy="166" rx="58" ry="28" fill="%s"/>' % ACCENT
    base=RR(102,188,48,10,4,True)
    spout=P("M84 158 L44 132 L80 176 Z",True)             # filled spout, upper-left
    lid='<path d="M108 144 Q126 124 144 144 Z" fill="%s"/>' % ACCENT + RR(119,122,14,14,3,True)
    handle=P("M182 158 Q216 156 210 182 Q206 196 186 190",w=12)
    smoke=P("M52 122 Q34 100 54 84 Q74 70 56 50 Q47 38 64 26",w=10)    # rising from spout tip
    spark=Pf2("M150 56 L157 78 L179 85 L157 92 L150 114 L143 92 L121 85 L143 78 Z")  # pink sparkle accent
    return body+base+spout+lid+handle+smoke+spark

def argus(): # all-seeing eye in a triangle + rays = divine kernel observability
    tri=P("M128 56 L196 184 L60 184 Z",w=10)
    lens=P("M94 146 Q128 118 162 146 Q128 174 94 146 Z",w=10)
    iris=C(128,146,15,w=8)+C(128,146,6,True)
    rays="".join(L(128+d*8,46,128+d*22,30,7) for d in (-1,0,1)) \
        + L(110,40,98,26,7)+L(146,40,158,26,7)
    return tri+lens+iris+rays
def bob_gaming(): # gamepad
    body="M92 104 H164 A52 52 0 0 1 210 172 A26 26 0 0 1 168 184 L150 164 H106 L88 184 A26 26 0 0 1 46 172 A52 52 0 0 1 92 104 Z"
    dpad=L(80,142,108,142,10)+L(94,128,94,156,10)
    btns=Cf2(168,130,7)+C(188,150,7,True)  # one pink button (Y on a SNES pad), one primary
    return P(body,w=11)+dpad+btns
def helm(): # isometric package/cube (charts)
    top="M128 60 L196 96 L128 132 L60 96 Z"
    left="M60 96 L128 132 V204 L60 168 Z";right="M196 96 L128 132 V204 L196 168 Z"
    return P(top,w=10)+P(left,w=10)+P(right,w=10)+L(128,132,128,204,10)
def ansible(): # bold A
    return P("M128 64 L92 192 M128 64 L164 192 M106 150 H150",w=15)
def klab(): # flask / beaker
    fl="M112 60 V104 L72 178 A20 20 0 0 0 90 196 H166 A20 20 0 0 0 184 178 L144 104 V60"
    return P(fl,w=11)+L(102,60,154,60,12)+P("M96 150 H160",w=10)+C(118,168,6,True)+C(140,176,5,True)
def docs(): # open book
    return P("M128 76 C108 64 80 64 60 72 V178 C80 170 108 170 128 182",w=11)+P("M128 76 C148 64 176 64 196 72 V178 C176 170 148 170 128 182",w=11)+L(128,76,128,182,9)
def webui(): # browser window — one amber traffic light (the "close" red→amber dot)
    return RR(52,68,152,120,16,sw=11)+L(52,100,204,100,11)+Cf2(70,84,5)+C(88,84,5,True)+C(106,84,5,True)+L(72,128,184,128,9)+L(72,150,150,150,9)
def kst(): # health gauge
    g=P("M64 168 A64 64 0 0 1 192 168",w=13)
    nd=L(128,168,160,118,11)+C(128,168,9,True)
    tk="".join(L(128+50*math.cos(math.radians(a)),168+50*math.sin(math.radians(a)),128+62*math.cos(math.radians(a)),168+62*math.sin(math.radians(a)),6) for a in (180,135,90,45,0))
    return g+tk+nd
def kst_dashboard(): # 2x2 dashboard tiles — one filled tile = the "active" pane
    return RR(62,62,60,60,10,sw=10)+RR(134,62,60,60,10,sw=10)+RR(62,134,60,60,10,sw=10)+RR(134,134,60,60,10,sw=10)+L(76,150,108,150,8)+L(148,92,180,92,8)+RRf2(146,146,36,36,6)  # amber inset on bottom-right tile
def ksnap(): # camera (snapshot)
    return RR(48,86,160,108,16,sw=11)+P("M92 86 L104 68 H152 L164 86",w=11)+C(128,140,30,w=11)+C(128,140,12,True)+C(182,108,6,True)
def kexport(): # drive + export arrow
    return RR(56,128,144,56,12,sw=11)+C(80,156,7,True)+L(110,156,184,156,9)+P("M128 112 V56 M104 80 L128 56 L152 80",w=12)
def k9s(): # k8s wheel inside a terminal window = k9s TUI — first traffic light amber
    win = RR(48,72,160,112,16,sw=10)+L(48,100,208,100,10)+Cf2(66,86,4.5)+C(82,86,4.5,True)+C(98,86,4.5,True)
    cx,cy,Rv,hub=128,144,30,6; o=[C(cx,cy,hub,w=6)];pts=[]
    for k in range(7):
        a=math.radians(-90+k*360/7);x,y=cx+Rv*math.cos(a),cy+Rv*math.sin(a);pts.append((x,y))
        o.append(L(cx+hub*math.cos(a),cy+hub*math.sin(a),x,y,6));o.append(C(x,y,4.5,True))
    o.append(P("M"+" L".join(f"{x:.1f} {y:.1f}" for x,y in pts)+" Z",w=5))
    return win+"".join(o)

def shell(): # full dashboard: window with a left nav sidebar (the "UI shell")
    return RR(48,64,160,128,16,sw=11)+L(48,96,208,96,11)+C(66,80,5,True)+C(84,80,5,True) \
        +L(96,96,96,192,11)+L(70,118,80,118,8)+L(70,138,80,138,8)+L(70,158,80,158,8) \
        +L(118,124,188,124,8)+L(118,146,188,146,8)+L(118,168,166,168,8)

def kldload_hex():  # brand mark A: hexagon "kernel" + downward load chevron
    cx, cy, r = 128, 122, 82
    pts = [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in range(-90, 270, 60)]
    hexp = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"
    shaft = L(cx, cy - 40, cx, cy + 18, 15)
    head = P(f"M{cx-28} {cy-8} L{cx} {cy+26} L{cx+28} {cy-8}", w=15)
    base = L(cx - 32, cy + 46, cx + 32, cy + 46, 13)  # the "load target" baseline
    return P(hexp, w=12) + shaft + head + base + Cf2(cx, cy + 46, 0.1)

def kldload_k():  # brand mark B: bold geometric "k" monogram + amber load dot
    stem = L(94, 60, 94, 196, 20)
    arm_up = L(94, 132, 156, 70, 17)
    arm_dn = L(94, 132, 162, 196, 17)
    return stem + arm_up + arm_dn + Cf2(156, 70, 11)  # amber tip = "loaded"

def terminal_(): return terminal()

ICONS = {
 # kldload-console = the unique brand/tray mark (kldload_k is a ready alt).
 "kldload-console":kldload_hex,
 "kldload-webui":webui, "kldload-terminal":terminal, "kldload-zfs":zfs,
 "kldload-zfs-manager":zfs_manager, "kldload-k8s":kubernetes, "kldload-vms":vms,
 "kldload-metrics":metrics, "bob-chat":bob, "bob-gaming":bob_gaming,
 "kldload-helm":helm, "kldload-ansible":ansible, "kldload-klab":klab,
 # kst (System Health) launcher was removed — see commit dropping kst.desktop.
 # Generator no longer ships its icon.
 "kst-dashboard":kst_dashboard, "ksnap":ksnap, "kexport":kexport,
 "kldload-k9s":k9s,
 # zxplore ships from its own repo but wears the kldload icon language on
 # kldload installs — the branded SVG wins over upstream's (build-iso.sh).
 "zxplore":zxplore,
}
LABELS = {  # also reused to set Icon= in .desktop later
 "kldload-webui":"Web UI","kldload-terminal":"Terminal","kldload-zfs":"ZFS",
 "kldload-zfs-manager":"ZFS Mgr","kldload-k8s":"Kubernetes","kldload-vms":"VMs",
 "kldload-metrics":"Metrics","bob-chat":"Bob (jinn)","bob-gaming":"Gaming",
 "kldload-helm":"Helm","kldload-ansible":"Ansible","kldload-klab":"klab",
 "kst":"Health","kst-dashboard":"Dashboard","ksnap":"Snapshot","kexport":"Export",
 "kldload-k9s":"k9s","kldload-console":"kldload","zxplore":"ZFS Console",
}

# Colour-coded by FUNCTION GROUP so colour tells you the category at a glance
# (orange = monitoring, coral = compute, green = storage, blue = orchestration,
# violet = AI, teal = web). Soft pastels — not dark/dreary, not flashy — with a
# slight per-icon shade shift so apps in a group stay distinguishable. Each
# glyph also gets a gunmetal/steel offset behind it for quiet depth.
COLORS = {
 # storage — green (true red for VMs swap — see ACCENTS2 for highlight)
 "kldload-zfs":"#4cb98a","kldload-zfs-manager":"#3fae7e","ksnap":"#6cc9a2","kexport":"#84d4b0",
 "zxplore":"#57c295",
 # compute — RED (was coral; user wanted a real saturated red for VMs)
 "kldload-vms":"#dc4848",
 # monitoring — orange
 "kldload-metrics":"#e6a55f","kst":"#e8b878","kst-dashboard":"#edc28a",
 # orchestration — blue
 "kldload-k8s":"#6a9fd8","kldload-k9s":"#82b0e0","kldload-helm":"#5a8fc8","kldload-klab":"#92bce8","kldload-ansible":"#7aa6d6",
 # ai — violet
 "bob-chat":"#c79be0","bob-gaming":"#d3a8ec",
 # web / console — teal
 "kldload-webui":"#5fc4bc","kldload-terminal":"#7cd0c9",
 # kldload brand mark — a distinct bright kldload blue (no tool uses it)
 "kldload-console":"#5ab0ff",
}
# Secondary accent — one warm complementary highlight per icon family.
# Glyphs that opt in (via the F2 / Cf2 / RRf2 helpers below) get a single
# attention-grabbing dot/bar/spark in this colour so the set reads as
# multi-tone instead of "pile of monochrome glyphs". One element per icon,
# not a re-skin — refinement, not noise.
ACCENTS2 = {
 # storage greens → warm amber highlight (think disk activity LED)
 "kldload-zfs":"#f0c674","kldload-zfs-manager":"#f0c674","ksnap":"#f0c674","kexport":"#f0c674",
 # compute red → amber highlight (the "powered" LED on a screen)
 "kldload-vms":"#f0c674",
 # monitoring oranges → bright lime (data callout)
 "kldload-metrics":"#c8e670","kst":"#c8e670","kst-dashboard":"#c8e670",
 # orchestration blues → warm amber (hub / node indicator)
 "kldload-k8s":"#f0c674","kldload-k9s":"#f0c674","kldload-helm":"#f0c674","kldload-klab":"#f0c674","kldload-ansible":"#f0c674",
 # ai violet → pink sparkle
 "bob-chat":"#ffafd2","bob-gaming":"#ffafd2",
 # web / console teal → amber highlight (cursor / active dot)
 "kldload-webui":"#f0c674","kldload-terminal":"#f0c674",
 # brand mark → amber "loaded" accent (matches the set's warm highlight)
 "kldload-console":"#f0c674",
}
DEFAULT_COLOR = "#7aa6d6"
DEFAULT_COLOR2 = "#f0c674"
GUNMETAL = "#3f4855"          # steel offset behind each glyph
OFFX, OFFY, OFF_OP = 3.0, 4.0, "0.55"

# ACCENT2 — secondary paint, set in lockstep with ACCENT by layered().
# Glyphs use it via the F2 helpers below (Cf2 = filled circle, RRf2 = filled
# rounded-rect, Pf2 = filled path). The shadow pass uses the same gunmetal
# for both, so accents disappear into the shadow cleanly.
ACCENT2 = DEFAULT_COLOR2
def _paint(color):  # primary colour: lines/strokes via S and the stroke helpers
    global ACCENT, S
    ACCENT = color; S = f'stroke="{color}"'
def _paint2(color):  # secondary colour: used by Cf2/RRf2/Pf2 fills
    global ACCENT2
    ACCENT2 = color
# Filled-in-secondary helpers — use sparingly, one element per glyph max.
def Cf2(cx,cy,r): return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{ACCENT2}"/>'
def RRf2(x,y,w,h,r): return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{ACCENT2}"/>'
def Pf2(d): return f'<path d="{d}" fill="{ACCENT2}"/>'

def layered(name, fn):  # gunmetal steel offset behind + pastel group colour on top
    if STYLE != "clean":
        return fn()
    pastel = COLORS.get(name, DEFAULT_COLOR)
    accent2 = ACCENTS2.get(name, DEFAULT_COLOR2)
    # Shadow pass: both ACCENT and ACCENT2 → gunmetal, so the secondary
    # highlights drop cleanly into the shadow without colour bleed.
    _paint(GUNMETAL); _paint2(GUNMETAL); shadow = fn()
    _paint(pastel);   _paint2(accent2);  main = fn()
    return f'<g transform="translate({OFFX},{OFFY})" opacity="{OFF_OP}">{shadow}</g>{main}'

def _grp(inner):  # wrap the glyph per style: black-lining filter, or plain
    if USE_LINING:
        return f'<g filter="url(#ln)" opacity="{ALPHA}">{inner}</g>'
    return f'<g opacity="{ALPHA}">{inner}</g>'

def svg(inner):
    defs = f'<defs>{FILTER}</defs>' if USE_LINING else ''
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">'
            f'{defs}{_grp(inner)}</svg>')

for name,fn in ICONS.items():
    open(os.path.join(OUT,name+".svg"),"w").write(svg(layered(name, fn)))
print("wrote", len(ICONS), "icons")

# contact sheet (dark bg so the translucent blue line art is visible; the
# shipped icons are transparent). One filter def, referenced by every cell.
cols=6; cell=150; gap=14; pad=20
names=list(ICONS); rows=(len(names)+cols-1)//cols
W=pad*2+cols*cell+(cols-1)*gap; H=pad*2+rows*(cell+26)
parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
       (f'<defs>{FILTER}</defs>' if USE_LINING else ''),
       f'<rect width="{W}" height="{H}" fill="#2e3436"/>']
for i,name in enumerate(names):
    r,c=divmod(i,cols); x=pad+c*(cell+gap); y=pad+r*(cell+26)
    sc=cell/256.0
    parts.append(f'<g transform="translate({x},{y}) scale({sc})">{_grp(layered(name, ICONS[name]))}</g>')
    parts.append(f'<text x="{x+cell/2}" y="{y+cell+18}" font-family="sans-serif" font-size="15" fill="#cbd5e1" text-anchor="middle">{LABELS[name]}</text>')
parts.append('</svg>')
open(os.path.join(OUT,"sheet.svg"),"w").write("".join(parts))
print("wrote sheet.svg", W,"x",H)
