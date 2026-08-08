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
def zfs():  # layered dataset plates + snapshot branch — the zxplore motif, so the
    # ZFS tiles read as one family with the console that manages them.
    plates="".join(RR(58,y,140,36,10,sw=10) for y in (70,116,162))
    rows="".join(f'<rect x="{78}" y="{y+12}" width="{w}" height="9" rx="4.5" fill="{ACCENT}" opacity="{op}"/>'
                 for y,w,op in ((70,64,"0.95"),(116,50,"0.6"),(162,40,"0.35")))
    branch=P("M186 88 C 216 88, 224 62, 224 46",w=9)+Cf2(186,88,7)+Cf2(224,40,9)
    return plates+rows+branch
def mok_repair():  # shield + keyhole = Secure Boot / MOK recovery
    shield = P("M128 48 L198 76 V136 C198 180 168 210 128 226 "
               "C88 210 58 180 58 136 V76 Z", w=12)
    keyhole = Cf2(128, 122, 15) + P("M128 136 L118 172 H138 Z", True)
    return shield + keyhole
def wgxplore():  # mesh: hub + spokes with a locked link = WireGuard estate
    cx = cy = 128
    o = [C(cx, cy, 20, w=11), Cf2(cx, cy, 9)]
    import math as _m
    pts = []
    for k in range(5):
        a = _m.radians(-90 + k * 72)
        x, y = cx + 74 * _m.cos(a), cy + 74 * _m.sin(a)
        pts.append((x, y))
        o.append(L(cx + 20 * _m.cos(a), cy + 20 * _m.sin(a), x, y, 9))
        o.append(C(x, y, 12, w=9))
    o.append(P("M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z", w=7))
    return "".join(o)
def vmxplore():  # golden VM box forking to two clones, all standing on a
    # dataset plate — the domain↔zvol join that IS the console. Plates+branch
    # keep it in the zxplore family; the amber dot marks the running clone.
    golden=RR(48,58,84,60,10,sw=10)
    gr=(f'<rect x="64" y="76" width="52" height="9" rx="4.5"'
        f' fill="{ACCENT}" opacity="0.95"/>')
    c1=RR(160,44,50,40,8,sw=9)
    c2=RR(160,108,50,40,8,sw=9)
    fork=(P("M132 88 C 148 88, 148 64, 160 64",w=9)
          +P("M132 88 C 148 88, 148 128, 160 128",w=9))
    join=L(90,118,90,172,9)
    plate=RR(48,172,162,36,10,sw=10)
    pr=(f'<rect x="68" y="184" width="72" height="9" rx="4.5"'
        f' fill="{ACCENT}" opacity="0.6"/>')
    led=Cf2(172,120,7)  # amber = the clone that is running
    return golden+gr+c1+c2+fork+join+plate+pr+led
def zfslab(): # dataset plates + a branch forking to two experiment nodes:
    # "clone it, try it" — the lab story, sibling of the zfs plates glyph.
    plates="".join(RR(48,y,132,36,10,sw=10) for y in (96,142))
    rows="".join(f'<rect x="{68}" y="{y+12}" width="{w}" height="9" rx="4.5" fill="{ACCENT}" opacity="{op}"/>'
                 for y,w,op in ((96,58,"0.95"),(142,44,"0.55")))
    fork=P("M180 114 C 204 114, 210 96, 212 82",w=9)+P("M180 114 C 206 118, 216 138, 218 152",w=9)
    nodes=C(180,114,7,True)+Cf2(214,74,9)+Cf2(220,160,9)
    return plates+rows+fork+nodes
def kubernetes():
    cx=cy=128;Rv=74;hub=13;o=[C(cx,cy,hub,w=12),Cf2(cx,cy,hub-5)];pts=[]  # amber hub core inside the ring
    for k in range(7):
        a=math.radians(-90+k*360/7);x,y=cx+Rv*math.cos(a),cy+Rv*math.sin(a);pts.append((x,y))
        o.append(L(cx+hub*math.cos(a),cy+hub*math.sin(a),x,y,11));o.append(C(x,y,9,True))
    o.append(P("M"+" L".join(f"{x:.1f} {y:.1f}" for x,y in pts)+" Z",w=9))
    return "".join(o)
def vms(): # a live screen with a clone budding off its edge — the branch echoes
    # the xplore consoles' snapshot/replica curve, so "VM cloning" reads at a glance.
    scr=RR(44,64,142,100,16,sw=11)
    stand=L(115,164,115,184,10)+L(92,184,138,184,10)
    led=Cf2(66,84,6)  # amber power LED, top-left of the bezel
    branch=P("M186 96 C 214 96, 222 76, 222 66",w=9)+C(186,96,7,True)
    clone=RR(202,34,42,30,9,sw=8)
    return scr+stand+led+branch+clone
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
# Helm + Ansible wear their NATIVE marks (glyph paths from simple-icons,
# CC0) — operators recognize the ship's wheel and the circle-A instantly;
# an invented stand-in just looks wrong next to them. Painted in ACCENT so
# the layered() gunmetal shadow pass works unchanged.
HELM_PATH=("M12.337 0c-.475 0-.861 1.016-.861 2.269 0 .527.069 1.011.183 1.396a8.514 8.514 0 0 0"
 "-3.961 1.22 5.229 5.229 0 0 0-.595-1.093c-.606-.866-1.34-1.436-1.79-1.43a.381.381 0 "
 "0 0-.217.066c-.39.273-.123 1.326.596 2.353.267.381.559.705.84.948a8.683 8.683 0 0 0-"
 "1.528 1.716h1.734a7.179 7.179 0 0 1 5.381-2.421 7.18 7.18 0 0 1 5.382 2.42h1.733a8.6"
 "87 8.687 0 0 0-1.32-1.53c.35-.249.735-.643 1.078-1.133.719-1.027.986-2.08.596-2.353a"
 ".382.382 0 0 0-.217-.065c-.45-.007-1.184.563-1.79 1.43a4.897 4.897 0 0 0-.676 1.325 "
 "8.52 8.52 0 0 0-3.899-1.42c.12-.39.193-.887.193-1.429 0-1.253-.386-2.269-.862-2.269z"
 "M1.624 9.443v5.162h1.358v-1.968h1.64v1.968h1.357V9.443H4.62v1.838H2.98V9.443zm5.912 "
 "0v5.162h3.21v-1.108H8.893v-.95h1.64v-1.142h-1.64v-.84h1.853V9.443zm4.698 0v5.162h3.2"
 "18v-1.362h-1.86v-3.8zm4.706 0v5.162h1.364v-2.643l1.357 1.225 1.35-1.232v2.65h1.365V9"
 ".443h-.614l-2.1 1.914-2.109-1.914zm-11.82 7.28a8.688 8.688 0 0 0 1.412 1.548 5.206 5"
 ".206 0 0 0-.841.948c-.719 1.027-.985 2.08-.596 2.353.39.273 1.289-.338 2.007-1.364a5"
 ".23 5.23 0 0 0 .595-1.092 8.514 8.514 0 0 0 3.961 1.219 5.01 5.01 0 0 0-.183 1.396c0"
 " 1.253.386 2.269.861 2.269.476 0 .862-1.016.862-2.269 0-.542-.072-1.04-.193-1.43a8.5"
 "2 8.52 0 0 0 3.9-1.42c.121.4.352.865.675 1.327.719 1.026 1.617 1.637 2.007 1.364.39-"
 ".273.123-1.326-.596-2.353-.343-.49-.727-.885-1.077-1.135a8.69 8.69 0 0 0 1.202-1.36h"
 "-1.771a7.174 7.174 0 0 1-5.227 2.252 7.174 7.174 0 0 1-5.226-2.252z")
ANSIBLE_PATH=("M10.617 11.473l4.686 3.695-3.102-7.662zM12 0C5.371 0 0 5.371 0 12s5.371 12 12 12 12-"
 "5.371 12-12S18.629 0 12 0zm5.797 17.305c-.011.471-.403.842-.875.83-.236 0-.416-.09-."
 "664-.293l-6.19-5-2.079 5.203H6.191L11.438 5.44c.124-.314.427-.52.764-.506.326-.014.6"
 "3.189.742.506l4.774 11.494c.045.111.08.234.08.348-.001.009-.001.009-.001.023z")
def helm(): # official Helm ship's-wheel wordmark
    return f'<g transform="translate(28,28) scale(8.33)"><path d="{HELM_PATH}" fill="{ACCENT}"/></g>'
def ansible(): # official Ansible circle-A
    return f'<g transform="translate(28,28) scale(8.33)"><path d="{ANSIBLE_PATH}" fill="{ACCENT}"/></g>'
def klab(): # flask / beaker
    fl="M112 60 V104 L72 178 A20 20 0 0 0 90 196 H166 A20 20 0 0 0 184 178 L144 104 V60"
    return P(fl,w=11)+L(102,60,154,60,12)+P("M96 150 H160",w=10)+C(118,168,6,True)+C(140,176,5,True)
def docs(): # open book
    return P("M128 76 C108 64 80 64 60 72 V178 C80 170 108 170 128 182",w=11)+P("M128 76 C148 64 176 64 196 72 V178 C176 170 148 170 128 182",w=11)+L(128,76,128,182,9)
def kst(): # health gauge
    g=P("M64 168 A64 64 0 0 1 192 168",w=13)
    nd=L(128,168,160,118,11)+C(128,168,9,True)
    tk="".join(L(128+50*math.cos(math.radians(a)),168+50*math.sin(math.radians(a)),128+62*math.cos(math.radians(a)),168+62*math.sin(math.radians(a)),6) for a in (180,135,90,45,0))
    return g+tk+nd
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

ICONS = {
 # kldload-console = the unique brand/tray mark (kldload_k is a ready alt).
 # RETIRED 2026-08-04 (operator, FOSSY pass): kldload-webui (tile uses the
 # brand mark), kldload-terminal + kst-dashboard (no .desktop references
 # them), ksnap + kldload-zfs-manager (their jobs moved into zxplore).
 "kldload-console":kldload_hex,
 "kldload-zfs":zfs, "kldload-zfslab":zfslab,
 "kldload-k8s":kubernetes, "kldload-vms":vms,
 "kldload-metrics":metrics, "bob-chat":bob, "bob-gaming":bob_gaming,
 "kldload-helm":helm, "kldload-ansible":ansible, "kldload-klab":klab,
 "kexport":kexport,
 "kldload-k9s":k9s, "kldload-mok-repair":mok_repair, "wgxplore":wgxplore,
 "vmxplore":vmxplore,
}
LABELS = {  # also reused to set Icon= in .desktop later
 "kldload-zfs":"ZFS","kldload-zfslab":"ZFS Lab",
 "kldload-k8s":"Kubernetes","kldload-vms":"VMs",
 "kldload-metrics":"Metrics","bob-chat":"Bob (jinn)","bob-gaming":"Gaming",
 "kldload-helm":"Helm","kldload-ansible":"Ansible","kldload-klab":"klab",
 "kexport":"Export",
 "kldload-k9s":"k9s","kldload-console":"kldload","kldload-mok-repair":"SB Repair",
 "wgxplore":"WG Console",
 "vmxplore":"VM Console",
}

# Colour-coded by FUNCTION GROUP so colour tells you the category at a glance
# (orange = monitoring, coral = compute, green = storage, blue = orchestration,
# violet = AI, teal = web). Soft pastels — not dark/dreary, not flashy — with a
# slight per-icon shade shift so apps in a group stay distinguishable. Each
# glyph also gets a gunmetal/steel offset behind it for quiet depth.
COLORS = {
 # storage — green (true red for VMs swap — see ACCENTS2 for highlight)
 "kldload-zfs":"#4cb98a","kldload-zfslab":"#3fae7e","kexport":"#84d4b0",
 # compute — RED (was coral; user wanted a real saturated red for VMs)
 # vmxplore joins the compute reds, shifted warm so the two stay apart
 "kldload-vms":"#dc4848","vmxplore":"#e2695d",
 # monitoring — orange (mok-repair joins: security/health-of-boot amber)
 "kldload-metrics":"#e6a55f","kst":"#e8b878",
 "kldload-mok-repair":"#dfae64",
 # networking — cyan-teal (wgxplore: the fabric console)
 "wgxplore":"#49c7c0",
 # orchestration — blue; ansible wears its native red (the brand's circle-A
 # is red everywhere operators have seen it — a blue one reads as a fake)
 "kldload-k8s":"#6a9fd8","kldload-k9s":"#82b0e0","kldload-helm":"#5a8fc8","kldload-klab":"#92bce8","kldload-ansible":"#e05a52",
 # ai — violet
 "bob-chat":"#c79be0","bob-gaming":"#d3a8ec",
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
 "kldload-zfs":"#f0c674","kldload-zfslab":"#f0c674","kexport":"#f0c674",
 # compute red → amber highlight (the "powered" LED on a screen)
 "kldload-vms":"#f0c674","vmxplore":"#f0c674",
 # monitoring oranges → bright lime (data callout)
 "kldload-metrics":"#c8e670","kst":"#c8e670",
 # orchestration blues → warm amber (hub / node indicator)
 "kldload-k8s":"#f0c674","kldload-k9s":"#f0c674","kldload-helm":"#f0c674","kldload-klab":"#f0c674","kldload-ansible":"#f0c674",
 # ai violet → pink sparkle
 "bob-chat":"#ffafd2","bob-gaming":"#ffafd2",
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
