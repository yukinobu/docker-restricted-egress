#!/usr/bin/env bash
set -euET -o pipefail
shopt -s inherit_errexit

git config --global --replace-all credential.helper ""
