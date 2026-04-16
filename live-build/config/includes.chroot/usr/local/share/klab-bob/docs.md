# kldload.com Documentation — Bob's Reference
# Extracted from 178+ website pages

## arch
  kldload — Arch Linux on ZFS
.hero-arch { max-width: 800px; margin: 0 auto; }
.hero-arch h1 { font-size: 2rem; margin-bottom: 0.5rem; }
.hero-arch .subtitle { font-size: 1.1rem; color: var(--accent); margin-bottom: 2rem; }
.feature-list { list-style: none; padding: 0; margin: 1.5rem 0; }
.feature-list li { font-size: 0.95rem; color: var(--subtle); line-height: 1.85; padding: 0.4rem 0; padding-left: 1.5rem; position: relative; }
.feature-list li::before { content: ""; position: absolute; left: 0; top: 0.85rem; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); }
.money-line { font-size: 1.2rem; color: var(--bright); font-weight: 700; line-height: 1.7; margin: 2rem 0; padding: 1.5rem 2rem; border-left: 3px solid rgba(52,211,153,0.6); background: rgba(52,211,153,0.04); border-radius: 0 8px 8px 0; }
.money-line code { color: var(--accent); background: rgba(0,184,217,0.1); padding: 0.15rem 0.4rem; border-radius: 4px; font-size: 1rem; }
.arch-screenshot { margin: 2rem 0; border-radius: 8px; overflow: hidden; border: 1px solid var(--border); }
.arch-screenshot img { width: 100%; display: block; }
.arch-stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 1rem; margin: 2rem 0; }
.arch-stat { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.2rem; text-align: center; }
.arch-stat .num { font-size: 1.8rem; font-weight: 700; color: var(--accent); font-family: var(--mono); }
.arch-stat .label { font-size: 0.78rem; color: var(--muted); margin-top: 0.3rem; }
.cta-box { text-align: center; margin: 3rem 0 2rem; padding: 2rem; background: var(--bg2); border: 1px solid var(--border); border-radius: 10px; }
.cta-box h3 { margin: 0 0 0.5rem; }
.cta-box p { font-size: 0.88rem; color: var(--subtle); margin-bottom: 1.2rem; }
    &#9776;
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    Arch Linux on ZFS
    The thing Arch never had: a safety net.
    pacman -Syu broke your system? Pick the previous snapshot in ZFSBootMenu, reboot, you're back. Ten seconds.
    229packages
    1.63xcompression
    ZFSon root
    10srollback
  What you get
    ZFS on root — not ext4, not btrfs. Checksummed, compressed, self-healing storage from first boot.
    ZFSBootMenu — boot environment manager. Clone your running system, upgrade the clone, boot into it. If it works, keep it. If not, you still have the original.
    Automatic rolling snapshots — sanoid takes snapshots on schedule. Every update is recoverable without thinking about it.
    Atomic upgrades — kupgrade snapshots your boot environment, runs pacman -Syu, and if the new kernel breaks ZFS compatibility, holds it back and upgrades everything else.
    kpkg — kpkg install nginx = ZFS snapshot + pacman -S nginx. One command, automatic safety net. Still just pacman underneath.
    Kernel pinning — archzfs lags behind the latest Arch kernel. kldload detects the required version and pins it. No manual intervention.
    WireGuard — encrypted networking in every profile. Configured at install time.
    eBPF observability — bcc, bpftrace, perf. execsnoop, tcplife, biolatency work immediately. Kernel-level tracing without agents.
    NVIDIA — checkbox at install. nvidia nvidia-utils nvidia-settings from the Arch extra repo.
    Golden image export — kexport turns your running Arch into a qcow2, VMDK, VHD, or OVA. Stamp it out across a fleet.
    No forced desktop — core and server profiles. You install your own DE if you want one. We don't decide that for you.
    Nothing is patched — stock Arch packages from upstream repos. kldload adds ZFS, the tools, and the safety net. That's it.
  What we don't do
    No custom kernel. Stock Arch kernel, pinned to what archzfs supports.
    No package manager replacement. pacman is still pacman. The k-tools are optional wrappers.
    No desktop opinion. GNOME, KDE, Hyprland, Sway — your call.
    No telemetry. No accounts. No cloud dependency.
  How it works
  # Boot the USB, open the web UI, pick Arch, pick Server, click install.
# Or unattended:
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=arch
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=archbox
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_ENABLE_EBPF=1
EOF

## download
  kldload — build once, deploy anywhere build once, deploy anywhere — for freegt; kldload — infrastructure, your way — for free
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## faq
  kldload — build once, deploy anywhere build once, deploy anywhere — for freegt; kldload — infrastructure, your way — for free
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## features
  kldload — build once, deploy anywhere build once, deploy anywhere — for freegt; kldload — infrastructure, your way — for free
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## index
  kldload — pick your distro, get ZFS on root. One ISO. Nine distros. Offline.
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## index-monolith-backup
  kldload — kernel loader. any distro. any hardware.
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    your Linux re-packerkldloadOS — your platform, your way, anywhere, free
    Source
    START HERE
      The Idea
      Features
      Screenshots
      Why ZFS
      How Things Work
    LEARN
      Kernels & Architecture
      How Services Talk
      The Recipe
      Docs (live) ↗ GitHub
      Docs (PDF) ↓ offline
      FAQ
    THE PLATFORM
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Systems Operators
    BUILD YOUR OWN
      Overview
      Zero to Hero
      IaC Quickstart
      Postinstallers
      Environment Reference
    TUTORIALS
      What is kldloadOS
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      ZFS Zero to Hero
      NFS & iSCSI
      Networking
      WireGuard Basics
      WireGuard Masterclass
      KVM Virtual Machines

## release-notes
  kldload 1.0 Release Notes — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
.rn-table { width: 100%; border-collapse: collapse; font-size: 0.85rem; margin: 1rem 0 1.5rem; }
.rn-table th { text-align: left; padding: 0.6rem 0.8rem; color: var(--accent); border-bottom: 2px solid var(--border); font-weight: 600; font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.04em; }
.rn-table td { padding: 0.5rem 0.8rem; color: var(--subtle); border-bottom: 1px solid var(--border); }
.rn-table tr:hover td { background: rgba(52,211,153,0.04); }
.rn-table code { font-size: 0.8rem; color: var(--accent2); }
    &#9776;
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management

## screenshots
  kldload — build once, deploy anywhere build once, deploy anywhere — for freegt; kldload — infrastructure, your way — for free
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## why-zfs
  kldload — build once, deploy anywhere build once, deploy anywhere — for freegt; kldload — infrastructure, your way — for free
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    build once, deploy anywherekldload — your AI platform, your way, for free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## ai-overview
  kldload — AI
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## beginner-clone
  kldload — Clone Anything — instant copies in milliseconds
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
.compare-row { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin: 1.5rem 0; }
.compare-box { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.2rem; }
.compare-box.slow { border-color: rgba(239,68,68,0.3); }
.compare-box.fast { border-color: rgba(52,211,153,0.3); }
.compare-box h4 { font-size: 0.88rem; margin: 0 0 0.5rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
.compare-box p { font-size: 0.88rem; color: var(--subtle); line-height: 1.7; margin: 0; }
.compare-box code { font-size: 0.82rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles

## beginner-connect
  kldload — Connect Two Machines — your first WireGuard tunnel
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
.step-num { display: inline-flex; align-items: center; justify-content: center; width: 2rem; height: 2rem; border-radius: 50%; background: var(--accent); color: #000; font-weight: 700; font-size: 0.9rem; margin-right: 0.6rem; flex-shrink: 0; }
.step-row { display: flex; align-items: flex-start; margin-bottom: 2rem; }
.step-body { flex: 1; }
.step-body h3 { margin: 0 0 0.6rem; color: var(--bright); font-size: 1rem; display: flex; align-items: center; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install

## beginner-replicate
  kldload — Replicate Your Data — automatic backups to another machine
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## beginner-snapshot
  kldload — Snapshot Before You Break It — the undo button for your OS
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
.callout { background: rgba(52,211,153,0.06); border: 1px solid rgba(52,211,153,0.25); border-radius: 8px; padding: 1.2rem 1.5rem; margin: 1.5rem 0; }
.callout p { font-size: 0.92rem; color: var(--subtle); margin: 0; line-height: 1.75; }
.callout strong { color: var(--bright); }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install

## build-ai-docker
  AI for Docker — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-ebpf
  AI for eBPF — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai
  AI Admin Assistant — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-k8s
  AI for Kubernetes — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-kvm
  AI for KVM — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-train
  Train AI on Your Infrastructure — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-voice
  AI Voice & Vision — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-wireguard
  AI for WireGuard — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ai-zfs
  AI for ZFS — kldload
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-backup
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-ci
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-classroom
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-cluster
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-containers
  kldload — Containers on ZFS
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-database
  kldload — Databases on ZFS — PostgreSQL, MySQL, Redis
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-dr
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-edge
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-grafana
  kldload — Grafana, Prometheus & Alerting on ZFS
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-hypervisor
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-k8s
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-media
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-monitoring
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-security
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-serverless
  kldload — Serverless & MicroVMs — Firecracker on ZFS
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    &#9776;
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-storage
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-vdi
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-windows
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-workstation
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## build-xmpp
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

## disk-labels
  kldload kldload — your Linux re-packer your Linux re-packer — for freegt; kldload — infrastructure, your way — for freemdash; pick your distro, get ZFS on root
.page-view { display: none; padding-top: 1.5rem; }
.page-view.active { display: block; }
.sb-view.active { color: var(--accent2); border-left-color: var(--accent); background: rgba(50,108,229,0.1); font-weight: 600; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 740px; margin-bottom: 1.5rem; }
.prose strong { color: var(--text); }
.prose em { color: var(--accent2); font-style: italic; }
.teach-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 1.6rem; margin-bottom: 1rem; transition: border-color 0.15s; }
.teach-card:hover { border-color: rgba(52,211,153,0.4); }
.teach-card h4 { font-size: 1rem; color: var(--bright); margin: 0 0 0.6rem; }
.teach-card p { font-size: 0.88rem; color: var(--subtle); line-height: 1.75; margin: 0; }
.teach-card .analogy { font-size: 0.82rem; color: var(--orange); font-family: var(--mono); margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--border); }
.manifesto { border-left: 3px solid var(--accent); padding: 1.5rem 2rem; background: rgba(0,184,217,0.04); border-radius: 0 8px 8px 0; margin: 2rem 0; }
.manifesto p { font-size: 1rem; line-height: 1.85; color: var(--subtle); margin-bottom: 1rem; }
.manifesto p:last-child { margin-bottom: 0; }
.manifesto strong { color: var(--bright); }
.concept-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; margin: 1.5rem 0 2rem; }
    ☰
    kldload &gt;
    |
    pick your distro, get ZFS on rootkldload — your platform, your way, free
    Source
    GET STARTED
      The Idea
      Executive Summary
      Features
      Screenshots
      Why ZFS
      Download
      FAQ
    CONCEPTS
      How It Works
      Kernels & Architecture
      Kernel vs Userland
      Secure Boot & the Boot Chain
      How Things Work
      How Services Talk
      The Recipe
      The Bridge
      ZFS Without GRUB
      Build ZFS from Scratch
      The Platform
      Tools & Commands
      Web UI
      Automation
      Storage & ZFS
      Security
      Audit & Trust
      Systems Operators
    TUTORIALS
      Getting Started
      What is kldload
      Editions & Profiles
      CLI Tools Reference
      Package Management
      Unattended Install
      Post-Install
      Troubleshooting
      Image Export Guide
      Upgrade Guide

