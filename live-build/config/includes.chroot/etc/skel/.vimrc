syntax on
filetype plugin indent on
set nocompatible
set tabstop=2 shiftwidth=2 expandtab
set autoindent smartindent
set background=dark
set ruler
set showcmd
set cursorline
set wildmenu
set incsearch
set hlsearch
set laststatus=2
set showmatch
set backspace=indent,eol,start
set ignorecase
set smartcase
set scrolloff=5
set wildmode=longest,list,full
set splitbelow
set splitright
set clipboard=unnamedplus
set noshowmode

" ── kldload colorscheme ─────────────────────────────────────────────────────────
if has('termguicolors')
  set termguicolors
endif
colorscheme kldload

" ── Statusline — matches kldload tmux bar ───────────────────────────────────────
set statusline=
set statusline+=%#StatusLineTerm#\ %{toupper(mode())}\
set statusline+=%#StatusLine#\ %f%m%r\
set statusline+=%=%#StatusLineNC#\ %y\ %l:%c\ %p%%\

" ── Cursor shape ─────────────────────────────────────────────────────────────
if &term =~ 'xterm'
  let &t_SI = "\e[6 q"
  let &t_EI = "\e[2 q"
endif
