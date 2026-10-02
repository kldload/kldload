#!/usr/bin/sh
# kldload-livenet-stall.sh — make a stalled root-image download fail, so it is
# retried, instead of hanging the netboot forever.
#
# Installed by 95kldload-show/module-setup.sh as cmdline hook 28, one step
# before livenet's own parser (29-parse-livenet.sh). It writes curl options
# into the config file that dracut's url-lib already points curl at:
# url-lib.sh exports CURL_HOME=/run/initramfs/url-lib, and its own
# set_http_header() appends to $CURL_HOME/.curlrc. curl reads that file on
# every invocation, so the options reach the image fetch without touching
# dracut's files.
#
# WHY: livenetroot retries a failed download up to 100 times and curl carries
# --retry 3, but both act only when curl RETURNS. curl has no stall timeout by
# default: a transfer whose bytes stop with the connection still up waits
# forever. fiend, build 173 (2026-10-02): the 20.9 GB squashfs stopped at
# 765 MB, nginx gave up after its 300 s send_timeout, and fiend never asked
# again -- it sat in the initramfs until a human power-cycled it, and the
# 5-desktop edition never installed. The same stall hit on 2026-10-01 at
# 890 MB. A full fetch runs at ~1 GB/s on the 10G link and ~110 MB/s on a
# 1G one, so 1 MB/s for 60 s is a dead transfer, never a slow one.
#
#   speed-limit/speed-time  under 1 MB/s for 60 s is an error (28), which
#                           curl's --retry and livenetroot's loop both retry
#   remove-on-error         drop the partial file: livenetroot fetches each
#                           attempt into a new /tmp dir, and the image is
#                           held in RAM, so a stalled 765 MB would otherwise
#                           stay resident for every failed attempt
#
# Verified with the initrd's exact curl arguments against a server that sends
# 2 MB and stalls (onyx, 2026-10-02), speed-time cut to 10 s for the test:
# each attempt failed with error 28 after ~12 s, curl retried three times
# (four requests served) and left no partial file; without this file it was
# still hung on the first request when killed at 40 s.
#
# Sourced by dracut's sh, not run: POSIX sh only, no exit, no set options.

_kld_curlhome=/run/initramfs/url-lib
mkdir -p "$_kld_curlhome"
if ! grep -qs '^speed-time' "$_kld_curlhome/.curlrc"; then
    {
        echo 'speed-limit = 1048576'
        echo 'speed-time = 60'
        echo 'remove-on-error'
    } >>"$_kld_curlhome/.curlrc"
fi
unset _kld_curlhome
