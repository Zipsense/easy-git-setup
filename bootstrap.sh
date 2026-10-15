#!/bin/sh
# easy-git bootstrap: gets a Mac or Linux computer ready to use GitHub through Claude Code.
#
#   - Safe to run any number of times: every step is skipped if it's already done.
#   - Never asks for an admin password (installs the GitHub tool into your home folder).
#   - Never changes git settings you already have (only fills in blanks).
#   - Never sees your GitHub password or token (GitHub's own tool stores the login securely).
#
# Usage:
#   sh bootstrap.sh [--orgs org1,org2] [--host github.com] [--with-claude]
#                   [--plugin owner/plugins-repo] [--dry-run] [--interactive | --non-interactive]
#
#   --orgs         GitHub organizations the person must belong to (checked, never changed)
#   --with-claude  install Claude Code too, if it's missing
#   --plugin       add that plugin repo to Claude Code, install easy-git from it, turn on updates
#                  (for people whose Claude plan doesn't deliver it automatically)
#
# In a Terminal it walks you through the GitHub login itself. When Claude runs it (no
# terminal), it stops at steps that need a person and says so with ACTION_NEEDED=..., so
# Claude can show you the login link and code, then run it again.
#
# Exit: 0 ready, 10 a person needs to do one thing (see ACTION_NEEDED), 1 failed.
# The last line is always EASY_GIT_RESULT=ready | action_needed:<what> | failed:<what>

set -u

orgs=""
plugin_repo=""
plugin_name=easy-git
host=github.com
with_claude=no
dry=no
mode=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --orgs) orgs=${2:-}; shift ;;
    --orgs=*) orgs=${1#--orgs=} ;;
    --host) host=${2:-github.com}; shift ;;
    --host=*) host=${1#--host=} ;;
    --with-claude) with_claude=yes ;;
    --plugin) plugin_repo=${2:-}; shift ;;
    --plugin=*) plugin_repo=${1#--plugin=} ;;
    --dry-run) dry=yes ;;
    --interactive) mode=yes ;;
    --non-interactive) mode=no ;;
    -h|--help) sed -n '2,26p' "$0" 2>/dev/null || echo "see the comments at the top of bootstrap.sh"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$mode" = auto ]; then
  if [ -t 1 ] && ( : < /dev/tty ) 2>/dev/null; then mode=yes; else mode=no; fi
fi
interactive=$mode

ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
would() { printf '   (dry run) would: %s\n' "$1"; }

finish() { # finish <exit code> <result>
  printf 'EASY_GIT_RESULT=%s\n' "$2"
  exit "$1"
}

need_person() { # need_person <what> <message...>
  what=$1; shift
  printf '👉 %s\n' "$*"
  printf 'ACTION_NEEDED=%s\n' "$what"
  finish 10 "action_needed:$what"
}

restart_needed=no

# ---------------------------------------------------------------- 1. computer type
os=${EASY_GIT_UNAME_S:-$(uname -s)}
arch_raw=${EASY_GIT_UNAME_M:-$(uname -m)}
case "$arch_raw" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  armv6l|armv7l) arch=armv6 ;;
  i386|i686) arch=386 ;;
  *) arch=$arch_raw ;;
esac
case "$os" in
  Darwin) ok "Mac ($arch)" ;;
  Linux) ok "Linux ($arch)" ;;
  *) warn "This setup supports Mac and Linux only (found: $os)."; finish 1 failed:unsupported_os ;;
esac

# ---------------------------------------------------------------- 2. git
git_works() { command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; }

if [ "$os" = Darwin ]; then
  gitpath=$(command -v git 2>/dev/null)
  if [ -n "$gitpath" ] && [ "$gitpath" != /usr/bin/git ] && git_works; then
    ok "Git is installed ($(git --version | sed 's/^git version //'))"
  elif xcode-select -p >/dev/null 2>&1; then
    ok "Git is installed ($(git --version 2>/dev/null | sed 's/^git version //'))"
  else
    if [ "$dry" = yes ]; then
      would "run xcode-select --install (Apple's installer for Git)"
    else
      xcode-select --install >/dev/null 2>&1
      if [ "$interactive" = yes ]; then
        printf '👉 A window from Apple should appear: click "Install" and wait for it to finish.\n'
        printf '   Waiting'
        waited=0
        until xcode-select -p >/dev/null 2>&1; do
          sleep 10
          waited=$((waited + 10))
          printf '.'
          if [ "$waited" -ge 3600 ]; then
            printf '\n'
            need_person xcode_install 'The Apple installer has not finished. Run this setup again when it has.'
          fi
        done
        printf '\n'
        ok "Git is installed"
      else
        need_person xcode_install 'A window from Apple should appear: click "Install" and wait until it says the software was installed. Then say "done".'
      fi
    fi
  fi
else
  if git_works; then
    ok "Git is installed ($(git --version | sed 's/^git version //'))"
  else
    if command -v apt-get >/dev/null 2>&1; then cmd='sudo apt-get install -y git'
    elif command -v dnf >/dev/null 2>&1; then cmd='sudo dnf install -y git'
    elif command -v yum >/dev/null 2>&1; then cmd='sudo yum install -y git'
    else cmd='(install "git" with your system'"'"'s package manager)'
    fi
    need_person install_git "Git is missing and needs an administrator password to install. In the Terminal app, run: $cmd   Then run this setup again."
  fi
fi

# ---------------------------------------------------------------- 3. GitHub tool (gh)
find_gh() {
  p=$(command -v gh 2>/dev/null)
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  for c in ${EASY_GIT_GH_SEARCH:-"$HOME/.local/bin/gh" "$HOME/bin/gh" /opt/homebrew/bin/gh /usr/local/bin/gh}; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

on_path() {
  case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1
  fi
}

install_gh_download() {
  # pick a folder on the user's own PATH: where `claude` lives (if it's in the home folder), else ~/.local/bin
  target="$HOME/.local/bin"
  cl=$(command -v claude 2>/dev/null)
  if [ -n "$cl" ]; then
    cdir=$(dirname "$cl")
    case "$cdir" in "$HOME"/*) [ -w "$cdir" ] && target=$cdir ;; esac
  fi
  if [ -n "${EASY_GIT_GH_VERSION:-}" ]; then
    ver=$EASY_GIT_GH_VERSION
  else
    latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest 2>/dev/null)
    ver=${latest##*/v}
  fi
  case "$ver" in
    [0-9]*.[0-9]*) ;;
    *) warn "Couldn't find the latest GitHub tool version (no internet?)."; return 1 ;;
  esac
  if [ "$os" = Darwin ]; then asset="gh_${ver}_macOS_${arch}.zip"; else asset="gh_${ver}_linux_${arch}.tar.gz"; fi
  base="https://github.com/cli/cli/releases/download/v${ver}"
  if [ "$dry" = yes ]; then
    would "download $base/$asset, check it against gh_${ver}_checksums.txt, install gh into $target"
    gh=$target/gh
    return 0
  fi
  tmpd=$(mktemp -d) || return 1
  if ! curl -fsSL -o "$tmpd/$asset" "$base/$asset" || ! curl -fsSL -o "$tmpd/sums.txt" "$base/gh_${ver}_checksums.txt"; then
    warn "Download failed."; rm -rf "$tmpd"; return 1
  fi
  want=$(grep " $asset\$" "$tmpd/sums.txt" | cut -d' ' -f1)
  got=$(sha256_of "$tmpd/$asset")
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    warn "The download didn't match GitHub's published checksum, so it was not installed."; rm -rf "$tmpd"; return 1
  fi
  if [ "$os" = Darwin ]; then (cd "$tmpd" && unzip -q "$asset"); else (cd "$tmpd" && tar -xzf "$asset"); fi
  mkdir -p "$target"
  cp "$tmpd/${asset%.zip}/bin/gh" "$target/gh" 2>/dev/null || cp "$tmpd/${asset%.tar.gz}/bin/gh" "$target/gh" 2>/dev/null || {
    warn "Couldn't unpack the GitHub tool."; rm -rf "$tmpd"; return 1; }
  chmod +x "$target/gh"
  rm -rf "$tmpd"
  gh=$target/gh
  if ! on_path "$target"; then
    line="export PATH=\"$target:\$PATH\""
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
      case "$rc" in
        */.zshrc) [ "$os" = Darwin ] || [ -f "$rc" ] || continue ;;
        */.bashrc) [ "$os" = Linux ] || [ -f "$rc" ] || continue ;;
      esac
      grep -Fqx "$line" "$rc" 2>/dev/null || printf '\n# added by easy-git setup\n%s\n' "$line" >> "$rc"
    done
    PATH="$target:$PATH"
    restart_needed=yes
  fi
  return 0
}

if gh=$(find_gh); then
  ok "GitHub tool is installed ($("$gh" --version 2>/dev/null | head -n 1 | sed -E 's/^gh version ([^ ]+).*/\1/'))"
else
  gh=""
  if command -v brew >/dev/null 2>&1; then
    if [ "$dry" = yes ]; then
      would "brew install gh"
      gh=gh
    elif HOMEBREW_NO_AUTO_UPDATE=1 brew install gh >/dev/null 2>&1 && gh=$(find_gh); then
      ok "GitHub tool installed (Homebrew)"
    else
      gh=""
    fi
  fi
  if [ -z "$gh" ]; then
    if install_gh_download; then
      [ "$dry" = yes ] || ok "GitHub tool installed in $(dirname "$gh")"
    else
      finish 1 failed:install_gh
    fi
  fi
fi
printf 'GH_BIN=%s\n' "$gh"

if [ "$dry" = yes ] && [ ! -x "$gh" ]; then
  would "log in to GitHub, connect git to that login, fill in your name/email, check orgs"
  finish 0 ready
fi

# ---------------------------------------------------------------- 4. GitHub login
if "$gh" auth status --hostname "$host" >/dev/null 2>&1; then
  user=$("$gh" api user --hostname "$host" --jq .login 2>/dev/null)
  ok "Logged in to GitHub as ${user:-you}"
else
  login_cmd="$gh auth login --hostname $host --git-protocol https --web"
  if [ "$dry" = yes ]; then
    would "$login_cmd"
    finish 0 ready
  elif [ "$interactive" = yes ]; then
    printf '👉 Next: log in to GitHub. You will get a short code; press Enter, paste it in the browser, and click Authorize.\n'
    "$gh" auth login --hostname "$host" --git-protocol https --web < /dev/tty
    if "$gh" auth status --hostname "$host" >/dev/null 2>&1; then
      ok "Logged in to GitHub"
    else
      finish 1 failed:github_login
    fi
  else
    printf 'LOGIN_COMMAND=%s\n' "$login_cmd"
    need_person github_login 'GitHub login needed: run LOGIN_COMMAND, show the person the code and link it prints, wait for it to finish, then run this setup again.'
  fi
fi

# git uses the same login (only if not already connected)
helpers=$(git config --global --get-all "credential.https://$host.helper" 2>/dev/null)
case "$helpers" in
  *"auth git-credential"*) ok "Git is connected to your GitHub login" ;;
  *)
    if [ "$dry" = yes ]; then would "$gh auth setup-git --hostname $host"
    elif "$gh" auth setup-git --hostname "$host" >/dev/null 2>&1; then ok "Connected git to your GitHub login"
    else warn "Couldn't connect git to your GitHub login (try: $gh auth setup-git)"
    fi ;;
esac

# ---------------------------------------------------------------- 5. name + email for saves
name=$(git config --global user.name 2>/dev/null)
if [ -n "$name" ]; then
  ok "Your name for saves: $name"
else
  name=$("$gh" api user --hostname "$host" --jq '.name // .login' 2>/dev/null)
  if [ -n "$name" ]; then
    if [ "$dry" = yes ]; then would "git config --global user.name \"$name\""
    else git config --global user.name "$name" && ok "Set your name for saves: $name"
    fi
  else
    warn "Couldn't read your name from GitHub; saves will ask for it."
  fi
fi

email=$(git config --global user.email 2>/dev/null)
if [ -n "$email" ]; then
  ok "Your email for saves: $email"
elif [ "$host" = github.com ]; then
  email=$("$gh" api user --jq '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null)
  if [ -n "$email" ]; then
    if [ "$dry" = yes ]; then would "git config --global user.email \"$email\""
    else git config --global user.email "$email" && ok "Set your email for saves: $email (GitHub's private address)"
    fi
  else
    warn "Couldn't read your GitHub account to set an email."
  fi
else
  warn "No email set for saves. Ask your lead which email to use on $host."
fi

# ---------------------------------------------------------------- 6. org membership
org_problem=no
if [ -n "$orgs" ]; then
  old_ifs=$IFS
  IFS=,
  for org in $orgs; do
    IFS=$old_ifs
    org=$(printf '%s' "$org" | tr -d ' ')
    [ -n "$org" ] || continue
    state=$("$gh" api "user/memberships/orgs/$org" --hostname "$host" --jq .state 2>/dev/null)
    case "$state" in
      active)
        sso=$("$gh" api -i "orgs/$org/repos?per_page=1" --hostname "$host" 2>/dev/null | grep -i '^x-github-sso:' | sed -n -E 's/.*url=([^ ;]+).*/\1/p' | tr -d '\r')
        if [ -n "$sso" ]; then
          warn "$org uses single sign-on. Open this link and click Authorize: $sso"
          org_problem=yes
        else
          ok "Member of $org"
        fi ;;
      pending)
        warn "You have an invitation to $org waiting. Accept it here: https://$host/orgs/$org/invitation"
        org_problem=yes ;;
      *)
        warn "You're not in the $org organization yet. Ask your admin to invite your GitHub account."
        org_problem=yes ;;
    esac
    IFS=,
  done
  IFS=$old_ifs
fi

# ---------------------------------------------------------------- 7. Claude Code (optional)
if [ "$with_claude" = yes ]; then
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code is installed"
  elif [ "$dry" = yes ]; then
    would "install Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  else
    if curl -fsSL https://claude.ai/install.sh | bash; then ok "Installed Claude Code"; restart_needed=yes
    else warn "Couldn't install Claude Code. See https://code.claude.com/docs/en/setup"
    fi
  fi
fi

# ---------------------------------------------------------------- 8. easy-git in Claude Code (optional)
find_claude() {
  p=$(command -v claude 2>/dev/null)
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# turn_on_updates SETTINGS_FILE MARKETPLACE : sets autoUpdate on the marketplace entry that
# `claude plugin marketplace add` wrote (keeps a backup; changes nothing else)
turn_on_updates() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PY'
import json, os, shutil, sys
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
entry = data.get("extraKnownMarketplaces", {}).get(name)
if not isinstance(entry, dict) or "source" not in entry:
    sys.exit(1)
if entry.get("autoUpdate") is True:
    sys.exit(0)
shutil.copy(path, path + ".bak-easy-git")
entry["autoUpdate"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

plugin_problem=no
install_plugin() {
  claude_bin=$(find_claude) || {
    warn "Claude Code isn't installed yet, so easy-git can't be added. Run this setup again with --with-claude, or install it from https://code.claude.com/docs/en/setup"
    plugin_problem=yes; return; }
  if "$claude_bin" plugin list 2>/dev/null | grep -q "$plugin_name@"; then
    ok "easy-git is installed in Claude Code"
    return
  fi
  mkt=$("$gh" api --hostname "$host" -H "Accept: application/vnd.github.raw+json" \
        "repos/$plugin_repo/contents/.claude-plugin/marketplace.json" --jq .name 2>/dev/null)
  if [ -z "$mkt" ]; then
    warn "Couldn't read the plugin list in $plugin_repo. Ask your admin to give your GitHub account access to it."
    plugin_problem=yes; return
  fi
  if [ "$dry" = yes ]; then
    would "claude plugin marketplace add $plugin_repo; claude plugin install $plugin_name@$mkt; turn on automatic updates"
    return
  fi
  "$claude_bin" plugin marketplace add "$plugin_repo" >/dev/null 2>&1
  if "$claude_bin" plugin install "$plugin_name@$mkt" >/dev/null 2>&1 &&
     "$claude_bin" plugin list 2>/dev/null | grep -q "$plugin_name@$mkt"; then
    ok "Installed easy-git in Claude Code"
  else
    warn "Couldn't install easy-git (try in Claude Code: /plugin install $plugin_name@$mkt)."
    plugin_problem=yes; return
  fi
  if turn_on_updates "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$mkt"; then
    ok "easy-git will update itself"
  else
    warn "Turn on updates once in Claude Code: /plugin -> Marketplaces -> $mkt -> Enable auto-update"
  fi
}

[ -n "$plugin_repo" ] && install_plugin

# ---------------------------------------------------------------- done
if [ "$restart_needed" = yes ]; then
  printf 'GH_BIN=%s\n' "$gh"
  need_person restart 'All set. Close and reopen Claude Code (and any Terminal windows) once so they can find the new tools.'
fi
if [ "$plugin_problem" = yes ]; then
  need_person plugin_access 'Almost done: fix the easy-git item marked ⚠️ above, then run this setup again.'
fi
if [ "$org_problem" = yes ]; then
  need_person org_access 'Almost done: fix the organization item(s) marked ⚠️ above, then run this setup again.'
fi
ok "All set. You can now say \"start a new task\" in Claude Code."
finish 0 ready
