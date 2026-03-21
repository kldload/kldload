" kldload.vim — vim colorscheme matching the kldload tmux/website palette
" bg #0f1117  surface #161b25  border #1e2533
" green #34d399  blue #60a5fa  muted #64748b  text #e2e8f0

set background=dark
hi clear
if exists("syntax_on")
  syntax reset
endif
let g:colors_name = "kldload"

" ── Core ─────────────────────────────────────────────────────────────────────
hi Normal          guifg=#e2e8f0 guibg=#0f1117   ctermfg=254 ctermbg=233
hi NonText         guifg=#1e2533 guibg=NONE       ctermfg=236 ctermbg=NONE
hi EndOfBuffer     guifg=#1e2533 guibg=NONE       ctermfg=236 ctermbg=NONE
hi LineNr          guifg=#64748b guibg=NONE       ctermfg=60  ctermbg=NONE
hi CursorLine      guibg=#161b25 guifg=NONE       ctermbg=235 ctermfg=NONE  cterm=NONE gui=NONE
hi CursorLineNr    guifg=#34d399 guibg=NONE       ctermfg=79  ctermbg=NONE  cterm=bold gui=bold
hi SignColumn      guibg=#0f1117                  ctermbg=233
hi ColorColumn     guibg=#161b25                  ctermbg=235
hi VertSplit       guifg=#1e2533 guibg=#0f1117    ctermfg=236 ctermbg=233   cterm=NONE gui=NONE
hi FoldColumn      guifg=#64748b guibg=#0f1117    ctermfg=60  ctermbg=233
hi Folded          guifg=#64748b guibg=#161b25    ctermfg=60  ctermbg=235

" ── Syntax ───────────────────────────────────────────────────────────────────
hi Comment         guifg=#64748b guibg=NONE       ctermfg=60  cterm=italic   gui=italic
hi Constant        guifg=#34d399 guibg=NONE       ctermfg=79
hi String          guifg=#34d399 guibg=NONE       ctermfg=79
hi Character       guifg=#34d399 guibg=NONE       ctermfg=79
hi Number          guifg=#60a5fa guibg=NONE       ctermfg=75
hi Boolean         guifg=#60a5fa guibg=NONE       ctermfg=75
hi Float           guifg=#60a5fa guibg=NONE       ctermfg=75
hi Identifier      guifg=#e2e8f0 guibg=NONE       ctermfg=254
hi Function        guifg=#60a5fa guibg=NONE       ctermfg=75
hi Statement       guifg=#60a5fa guibg=NONE       ctermfg=75  cterm=NONE     gui=NONE
hi Keyword         guifg=#60a5fa guibg=NONE       ctermfg=75
hi Conditional     guifg=#60a5fa guibg=NONE       ctermfg=75
hi Repeat          guifg=#60a5fa guibg=NONE       ctermfg=75
hi Operator        guifg=#e2e8f0 guibg=NONE       ctermfg=254
hi Exception       guifg=#ef5350 guibg=NONE       ctermfg=203
hi PreProc         guifg=#ab47bc guibg=NONE       ctermfg=134
hi Include         guifg=#ab47bc guibg=NONE       ctermfg=134
hi Define          guifg=#ab47bc guibg=NONE       ctermfg=134
hi Macro           guifg=#ab47bc guibg=NONE       ctermfg=134
hi Type            guifg=#34d399 guibg=NONE       ctermfg=79  cterm=NONE     gui=NONE
hi StorageClass    guifg=#60a5fa guibg=NONE       ctermfg=75
hi Structure       guifg=#34d399 guibg=NONE       ctermfg=79
hi Typedef         guifg=#34d399 guibg=NONE       ctermfg=79
hi Special         guifg=#26c6da guibg=NONE       ctermfg=45
hi SpecialChar     guifg=#26c6da guibg=NONE       ctermfg=45
hi Delimiter       guifg=#64748b guibg=NONE       ctermfg=60
hi SpecialComment  guifg=#64748b guibg=NONE       ctermfg=60  cterm=italic   gui=italic
hi Underlined      guifg=#60a5fa guibg=NONE       ctermfg=75  cterm=underline gui=underline
hi Error           guifg=#ef5350 guibg=NONE       ctermfg=203
hi Todo            guifg=#ffca28 guibg=#1e2533    ctermfg=220 ctermbg=236   cterm=bold gui=bold

" ── Search ───────────────────────────────────────────────────────────────────
hi Search          guifg=#0f1117 guibg=#34d399    ctermfg=233 ctermbg=79
hi IncSearch       guifg=#0f1117 guibg=#60a5fa    ctermfg=233 ctermbg=75
hi MatchParen      guifg=#34d399 guibg=#1e2533    ctermfg=79  ctermbg=236   cterm=bold gui=bold

" ── Visual / selection ────────────────────────────────────────────────────────
hi Visual          guibg=#1e2533 guifg=NONE       ctermbg=236 ctermfg=NONE
hi VisualNOS       guibg=#1e2533 guifg=NONE       ctermbg=236 ctermfg=NONE

" ── Statusline — matches tmux bar ─────────────────────────────────────────────
hi StatusLine      guifg=#e2e8f0 guibg=#161b25    ctermfg=254 ctermbg=235   cterm=NONE gui=NONE
hi StatusLineNC    guifg=#64748b guibg=#161b25    ctermfg=60  ctermbg=235   cterm=NONE gui=NONE
hi StatusLineTerm  guifg=#0f1117 guibg=#34d399    ctermfg=233 ctermbg=79    cterm=bold gui=bold
hi StatusLineTermNC guifg=#64748b guibg=#161b25   ctermfg=60  ctermbg=235

" ── Popup / completion menu ────────────────────────────────────────────────────
hi Pmenu           guifg=#e2e8f0 guibg=#1e2533    ctermfg=254 ctermbg=236
hi PmenuSel        guifg=#0f1117 guibg=#34d399    ctermfg=233 ctermbg=79
hi PmenuSbar       guibg=#1e2533                  ctermbg=236
hi PmenuThumb      guibg=#64748b                  ctermbg=60

" ── Messages ─────────────────────────────────────────────────────────────────
hi ModeMsg         guifg=#34d399 guibg=NONE       ctermfg=79  cterm=bold gui=bold
hi MoreMsg         guifg=#34d399 guibg=NONE       ctermfg=79
hi WarningMsg      guifg=#ffca28 guibg=NONE       ctermfg=220
hi ErrorMsg        guifg=#ef5350 guibg=NONE       ctermfg=203
hi Question        guifg=#34d399 guibg=NONE       ctermfg=79

" ── Diff ─────────────────────────────────────────────────────────────────────
hi DiffAdd         guifg=#34d399 guibg=#0d2420    ctermfg=79  ctermbg=22
hi DiffChange      guifg=#ffca28 guibg=#1e1a0e    ctermfg=220 ctermbg=234
hi DiffDelete      guifg=#ef5350 guibg=#1e0e0e    ctermfg=203 ctermbg=52
hi DiffText        guifg=#0f1117 guibg=#ffca28    ctermfg=233 ctermbg=220   cterm=bold gui=bold

" ── Spell ────────────────────────────────────────────────────────────────────
hi SpellBad        guisp=#ef5350 cterm=underline  gui=undercurl
hi SpellCap        guisp=#60a5fa cterm=underline  gui=undercurl
hi SpellRare       guisp=#ab47bc cterm=underline  gui=undercurl

" ── Misc ─────────────────────────────────────────────────────────────────────
hi Directory       guifg=#60a5fa guibg=NONE       ctermfg=75
hi Title           guifg=#34d399 guibg=NONE       ctermfg=79  cterm=bold gui=bold
hi Conceal         guifg=#64748b guibg=NONE       ctermfg=60
hi WildMenu        guifg=#0f1117 guibg=#34d399    ctermfg=233 ctermbg=79
hi TabLine         guifg=#64748b guibg=#161b25    ctermfg=60  ctermbg=235   cterm=NONE gui=NONE
hi TabLineSel      guifg=#34d399 guibg=#0f1117    ctermfg=79  ctermbg=233   cterm=bold gui=bold
hi TabLineFill     guibg=#161b25                  ctermbg=235
