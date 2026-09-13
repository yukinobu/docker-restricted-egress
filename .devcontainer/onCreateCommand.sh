#!/usr/bin/env bash
set -euET -o pipefail
shopt -s inherit_errexit

catch() {
	echo "[ERROR] returned a non-zero exit status $? on $0:$1" "$(\date +'[%F %T %Z]')" >&2
}
trap 'catch ${LINENO[0]}' ERR

( mkdir -p ~/local && cd "$_" && if [[ -d dotfiles ]]; then cd dotfiles && git pull --rebase; else git clone -c core.autocrlf=input --filter=tree:0 https://github.com/yukinobu/dotfiles.git; fi )
grep -qxF '. ~/local/dotfiles/_bashrc' ~/.bashrc || echo '. ~/local/dotfiles/_bashrc' >> ~/.bashrc

ln -fs ~/local/dotfiles/_bashrc_safe ~/.bashrc_safe
ln -fs ~/local/dotfiles/_gitignore ~/.gitignore
ln -fs ~/local/dotfiles/_vimrc ~/.vimrc

# install Codex CLI
curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh

# make devenv as needed
[[ -f Makefile ]] && ( make -f Makefile -q devenv >/dev/null 2>&1; [[ $? -ne 2 ]] && make -f Makefile devenv ) || true

[[ -f .envrc ]] && direnv allow . || true
