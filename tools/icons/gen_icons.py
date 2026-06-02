#!/usr/bin/env python3
"""kldload app-icon generator — one cohesive flat set.

Dark slate "squircle" tile + gold (#c9a04a) glyph, one per app. Emits scalable
SVG (GNOME renders crisp at any size) plus a contact-sheet SVG for review.
Run: python3 gen_icons.py <outdir>
"""
import math, os, sys

GOLD = "#c9a04a"
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)

TILE = '''<defs><linearGradient id="slate" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#243049"/><stop offset="1" stop-color="#141a26"/>
</linearGradient></defs>
<rect x="8" y="8" width="240" height="240" rx="58" fill="url(#slate)"/>
<rect x="8.75" y="8.75" width="238.5" height="238.5" rx="57.25" fill="none"
 stroke="%s" stroke-opacity="0.30" stroke-width="1.5"/>''' % GOLD

S = f'stroke="{GOLD}"'           # shorthand
def L(x1,y1,x2,y2,w=11): return f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" {S} stroke-width="{w}" stroke-linecap="round"/>'
def C(cx,cy,r,fill=False,w=11): return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" '+(f'fill="{GOLD}"' if fill else f'fill="none" {S} stroke-width="{w}"')+'/>'
def RR(x,y,w,h,r,fill=False,sw=11): return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" '+(f'fill="{GOLD}"' if fill else f'fill="none" {S} stroke-width="{sw}"')+'/>'
def P(d,fill=False,w=11,cap="round",join="round"): return f'<path d="{d}" '+(f'fill="{GOLD}"' if fill else f'fill="none" {S} stroke-width="{w}"')+f' stroke-linecap="{cap}" stroke-linejoin="{join}"/>'

# ── glyphs (drawn in 0..256 space) ───────────────────────────────────────────
def console():   return P("M86 90 L124 128 L86 166",w=16)+RR(138,150,48,16,8,True)
def terminal():  return RR(56,72,144,112,18,sw=11)+L(56,100,200,100,11)+C(74,86,5,True)+C(92,86,5,True)+C(110,86,5,True)+P("M84 128 L108 146 L84 164",w=12)+RR(120,156,40,12,6,True)
def zfs():
    o=[];cx,rx,ry=128,58,18
    for y in (84,118,152):
        o.append(P(f"M{cx-rx} {y} V{y+34} A{rx} {ry} 0 0 0 {cx+rx} {y+34} V{y}"))
        o.append(f'<ellipse cx="{cx}" cy="{y}" rx="{rx}" ry="{ry}" fill="none" {S} stroke-width="11"/>')
    return "".join(o)
def zfs_manager(): # zfs stack + gear badge
    g=[];cx,rx,ry=118,46,15
    for y in (96,124,152):
        g.append(P(f"M{cx-rx} {y} V{y+26} A{rx} {ry} 0 0 0 {cx+rx} {y+26} V{y}"))
        g.append(f'<ellipse cx="{cx}" cy="{y}" rx="{rx}" ry="{ry}" fill="none" {S} stroke-width="9"/>')
    gx,gy=182,182  # gear
    teeth="".join(L(gx+18*math.cos(math.radians(a)),gy+18*math.sin(math.radians(a)),gx+30*math.cos(math.radians(a)),gy+30*math.sin(math.radians(a)),8) for a in range(0,360,45))
    return "".join(g)+teeth+C(gx,gy,18,w=9)+C(gx,gy,6,True)
def kubernetes():
    cx=cy=128;Rv=74;hub=13;o=[C(cx,cy,hub,w=12)];pts=[]
    for k in range(7):
        a=math.radians(-90+k*360/7);x,y=cx+Rv*math.cos(a),cy+Rv*math.sin(a);pts.append((x,y))
        o.append(L(cx+hub*math.cos(a),cy+hub*math.sin(a),x,y,11));o.append(C(x,y,9,True))
    o.append(P("M"+" L".join(f"{x:.1f} {y:.1f}" for x,y in pts)+" Z",w=9))
    return "".join(o)
def vms(): # two overlapping screens
    return RR(58,64,118,86,12,sw=11)+L(96,150,96,162,11)+L(80,162,112,162,11)+RR(118,108,82,72,12,sw=11)+f'<rect x="124" y="114" width="70" height="48" rx="4" fill="{GOLD}" fill-opacity="0.18"/>'
def metrics(): # bars + trend line
    bars="".join(RR(x,y,26,196-y,5,True) for x,y in ((62,140),(100,108),(138,150),(176,84)))
    return bars+P("M62 96 L114 70 L150 112 L196 58",w=9)+C(62,96,7,True)+C(114,70,7,True)+C(150,112,7,True)+C(196,58,7,True)
def bob(): # genie's lamp (filled silhouette) + rising smoke + sparkle
    body='<ellipse cx="126" cy="166" rx="58" ry="28" fill="%s"/>' % GOLD
    base=RR(102,188,48,10,4,True)
    spout=P("M84 158 L44 132 L80 176 Z",True)             # filled spout, upper-left
    lid='<path d="M108 144 Q126 124 144 144 Z" fill="%s"/>' % GOLD + RR(119,122,14,14,3,True)
    handle=P("M182 158 Q216 156 210 182 Q206 196 186 190",w=12)
    smoke=P("M52 122 Q34 100 54 84 Q74 70 56 50 Q47 38 64 26",w=10)    # rising from spout tip
    spark=P("M150 56 L157 78 L179 85 L157 92 L150 114 L143 92 L121 85 L143 78 Z",True)
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
    btns=C(168,130,7,True)+C(188,150,7,True)
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
def webui(): # browser window
    return RR(52,68,152,120,16,sw=11)+L(52,100,204,100,11)+C(70,84,5,True)+C(88,84,5,True)+C(106,84,5,True)+L(72,128,184,128,9)+L(72,150,150,150,9)
def kst(): # health gauge
    g=P("M64 168 A64 64 0 0 1 192 168",w=13)
    nd=L(128,168,160,118,11)+C(128,168,9,True)
    tk="".join(L(128+50*math.cos(math.radians(a)),168+50*math.sin(math.radians(a)),128+62*math.cos(math.radians(a)),168+62*math.sin(math.radians(a)),6) for a in (180,135,90,45,0))
    return g+tk+nd
def kst_dashboard(): # 2x2 dashboard tiles
    return RR(62,62,60,60,10,sw=10)+RR(134,62,60,60,10,sw=10)+RR(62,134,60,60,10,sw=10)+RR(134,134,60,60,10,sw=10)+L(76,150,108,150,8)+L(148,92,180,92,8)
def ksnap(): # camera (snapshot)
    return RR(48,86,160,108,16,sw=11)+P("M92 86 L104 68 H152 L164 86",w=11)+C(128,140,30,w=11)+C(128,140,12,True)+C(182,108,6,True)
def kexport(): # drive + export arrow
    return RR(56,128,144,56,12,sw=11)+C(80,156,7,True)+L(110,156,184,156,9)+P("M128 112 V56 M104 80 L128 56 L152 80",w=12)
def k9s(): # k8s wheel inside a terminal window = k9s TUI
    win = RR(48,72,160,112,16,sw=10)+L(48,100,208,100,10)+C(66,86,4.5,True)+C(82,86,4.5,True)+C(98,86,4.5,True)
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

def terminal_(): return terminal()

ICONS = {
 "kldload-console":argus, "kldload-terminal":terminal, "kldload-zfs":zfs,
 "kldload-zfs-manager":zfs_manager, "kldload-k8s":kubernetes, "kldload-vms":vms,
 "kldload-metrics":metrics, "bob-chat":bob, "bob-gaming":bob_gaming,
 "kldload-helm":helm, "kldload-ansible":ansible, "kldload-klab":klab,
 "kst":kst, "kst-dashboard":kst_dashboard, "ksnap":ksnap, "kexport":kexport,
 "kldload-k9s":k9s,
}
LABELS = {  # also reused to set Icon= in .desktop later
 "kldload-console":"Argus","kldload-terminal":"Terminal","kldload-zfs":"ZFS",
 "kldload-zfs-manager":"ZFS Mgr","kldload-k8s":"Kubernetes","kldload-vms":"VMs",
 "kldload-metrics":"Metrics","bob-chat":"Bob (jinn)","bob-gaming":"Gaming",
 "kldload-helm":"Helm","kldload-ansible":"Ansible","kldload-klab":"klab",
 "kst":"Health","kst-dashboard":"Dashboard","ksnap":"Snapshot","kexport":"Export",
 "kldload-k9s":"k9s",
}

def svg(inner): return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">{TILE}{inner}</svg>'

for name,fn in ICONS.items():
    open(os.path.join(OUT,name+".svg"),"w").write(svg(fn()))
print("wrote", len(ICONS), "icons")

# contact sheet (inline, no external refs so rsvg renders it directly)
cols=6; cell=150; gap=14; pad=20
names=list(ICONS); rows=(len(names)+cols-1)//cols
W=pad*2+cols*cell+(cols-1)*gap; H=pad*2+rows*(cell+26)
parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
       f'<rect width="{W}" height="{H}" fill="#8a8f98"/>']
for i,name in enumerate(names):
    r,c=divmod(i,cols); x=pad+c*(cell+gap); y=pad+r*(cell+26)
    sc=cell/256.0
    parts.append(f'<g transform="translate({x},{y}) scale({sc})">{TILE}{ICONS[name]()}</g>')
    parts.append(f'<text x="{x+cell/2}" y="{y+cell+18}" font-family="sans-serif" font-size="15" fill="#111" text-anchor="middle">{LABELS[name]}</text>')
parts.append('</svg>')
open(os.path.join(OUT,"sheet.svg"),"w").write("".join(parts))
print("wrote sheet.svg", W,"x",H)
