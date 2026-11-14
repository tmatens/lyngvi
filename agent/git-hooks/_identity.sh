# shellcheck shell=bash
# shellcheck disable=SC2034  # IDENT_NAME/IDENT_EMAIL are read by the hooks that source this
# Sourced by the git hooks in this directory; not a hook itself (git runs only
# hook names it knows). The site's identities, read from the files baked into
# the image under /etc/lyngvi/site (root-owned, read-only to the agent): never
# from the environment, where a secrets file loaded after site.conf would win
# silently, and git itself prefers GIT_AUTHOR_*/GIT_COMMITTER_* over its config.
LYNGVI_SITE_DIR=/etc/lyngvi/site

site_conf_value() { # KEY → its value in site.conf (last one wins, quotes stripped)
  sed -n "s/^$1=//p" "$LYNGVI_SITE_DIR/site.conf" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//'
}

allowed_idents() { # one "name<TAB>email" line per identity the site declares
  local n e f
  n=$(site_conf_value GIT_AUTHOR_NAME); e=$(site_conf_value GIT_AUTHOR_EMAIL)
  printf '%s\t%s\n' "${n:-lyngvi}" "${e:-lyngvi@users.noreply.example.org}"
  # Per-path identities: user.* in the site gitconfig fragments (gitconfig, and the
  # files its includeIf sections point at, which live beside it).
  for f in "$LYNGVI_SITE_DIR"/gitconfig*; do
    [ -f "$f" ] || continue
    n=$(git config --file "$f" --get user.name 2>/dev/null)
    e=$(git config --file "$f" --get user.email 2>/dev/null)
    [ -n "$n" ] && [ -n "$e" ] && printf '%s\t%s\n' "$n" "$e"
  done
}

ident_allowed() { # NAME EMAIL → exit 0 when the pair is one of the site's
  allowed_idents | awk -F'\t' -v n="$1" -v e="$2" '$1 == n && $2 == e { f = 1 } END { exit !f }'
}

split_ident() { # "Name <email> [date]" → sets IDENT_NAME, IDENT_EMAIL
  IDENT_NAME=$(printf '%s' "$1" | sed -E 's/^(.*) <[^>]*>.*$/\1/')
  IDENT_EMAIL=$(printf '%s' "$1" | sed -E 's/^.* <([^>]*)>.*$/\1/')
}
