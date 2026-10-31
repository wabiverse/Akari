#!/usr/bin/env zsh
#
# publish-metapackages.zsh
#
# Take every split <root>/Meta*/Package.swift package out
# of local edit mode by rewriting sibling dependencies.
#
# Default root: ~/wabi/MetaverseKitSplit

emulate -L zsh
setopt pipe_fail

typeset -r SCRIPT_NAME=${0:t}

typeset -r STRIP_COMMENTS_PERL=$(cat <<'PERL'
use strict;
use warnings;

local $/;
my $s = <>;
my $n = length $s;
my $out = '';
my $i = 0;

while ($i < $n) {
  my $c = substr($s, $i, 1);

  # Line comments. Keep only the tools-version directive.
  if ($c eq '/' && substr($s, $i, 2) eq '//') {
    my $line_start = rindex($s, "\n", $i) + 1;
    my $prefix = substr($s, $line_start, $i - $line_start);
    my $eol = index($s, "\n", $i);
    $eol = $n if $eol < 0;
    my $text = substr($s, $i, $eol - $i);
    my $line_only = $prefix =~ /^\s*$/;

    if ($line_only && $text =~ m{^//\s*swift-tools-version:}) {
      $out .= $text;
      $i = $eol;
    } elsif ($line_only) {
      $out =~ s/[ \t]+$//;
      $i = $eol < $n ? $eol + 1 : $n;
    } else {
      $i = $eol;
    }
    next;
  }

  # Block comments. Swift permits nesting.
  if ($c eq '/' && substr($s, $i, 2) eq '/*') {
    my $comment_start = $i;
    my $line_start = rindex($s, "\n", $comment_start) + 1;
    my $prefix = substr($s, $line_start, $comment_start - $line_start);
    my $depth = 1;
    $i += 2;
    while ($i < $n && $depth > 0) {
      if (substr($s, $i, 2) eq '/*') {
        $depth++;
        $i += 2;
      } elsif (substr($s, $i, 2) eq '*/') {
        $depth--;
        $i += 2;
      } else {
        $i++;
      }
    }

    my $eol = index($s, "\n", $i);
    $eol = $n if $eol < 0;
    my $suffix = substr($s, $i, $eol - $i);

    if ($prefix =~ /^\s*$/ && $suffix =~ /^\s*$/) {
      $out =~ s/[ \t]+$//;
      $i = $eol < $n ? $eol + 1 : $n;
    } else {
      my $prev = length($out) ? substr($out, -1, 1) : '';
      my $next = $i < $n ? substr($s, $i, 1) : '';
      if ($prev =~ /[ \t]/ && $next =~ /[ \t]/) {
        $out =~ s/[ \t]+$//;
      } elsif ($prev !~ /\s/ && $next !~ /\s/) {
        $out .= ' ';
      }
    }
    next;
  }

  # Raw string literal: #"..."# or ##"..."##, including multiline forms.
  if ($c eq '#') {
    my $j = $i;
    $j++ while $j < $n && substr($s, $j, 1) eq '#';
    if ($j < $n && substr($s, $j, 1) eq '"') {
      my $hashes = $j - $i;
      my $multiline = substr($s, $j, 3) eq '"""';
      my $open_len = $multiline ? 3 : 1;
      my $delim = ($multiline ? '"""' : '"') . ('#' x $hashes);
      my $start = $j + $open_len;
      my $end = index($s, $delim, $start);
      $end = $n if $end < 0;
      $end += length($delim) if $end < $n;
      $out .= substr($s, $i, $end - $i);
      $i = $end;
      next;
    }
  }

  # Ordinary string literal, single-line or multiline.
  if ($c eq '"') {
    my $multiline = substr($s, $i, 3) eq '"""';
    my $delim = $multiline ? '"""' : '"';
    my $j = $i + length($delim);
    while ($j < $n) {
      if (substr($s, $j, 1) eq '\\') {
        $j += 2;
        next;
      }
      if (substr($s, $j, length($delim)) eq $delim) {
        $j += length($delim);
        last;
      }
      $j++;
    }
    $j = $n if $j > $n;
    $out .= substr($s, $i, $j - $i);
    $i = $j;
    next;
  }

  $out .= $c;
  $i++;
}

# Tidy up whitespace that comment removal leaves behind.
$out =~ s/[ \t]+$//mg;
$out =~ s/\n{3,}/\n\n/g;
$out .= "\n" unless $out =~ /\n\z/;

print $out;
PERL
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m'
  C_DIM=$'\e[2m'
  C_RED=$'\e[31m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'
  C_BOLD=$'\e[1m'
else
  C_RESET=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_BOLD=''
fi

info() { print -r -- "${C_BLUE}==>${C_RESET} $*" }
ok()   { print -r -- "${C_GREEN}  ok${C_RESET} $*" }
warn() { print -ru2 -- "${C_YELLOW}warning:${C_RESET} $*" }
die()  { print -ru2 -- "${C_RED}error:${C_RESET} $*"; exit 1 }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options] [root ...]

Rewrite every Meta* SwiftPM package under the given roots out of local edit
mode, strip Package.swift comments, and optionally publish each one to GitHub.

Options:
  -r, --root DIR              Root to scan. May be repeated.
                              Default: ~/wabi/MetaverseKitSplit
      --dry-run               Print manifest diffs only (default)
      --apply                 Rewrite manifests, strip comments, then create
                              the local git history (init, commit, tag).
                              Does not push.
      --publish               --apply plus create/push the GitHub repository
      --comments-only         Strip comments only. No dependency rewrite,
                              .gitignore, git, or publish.
      --retag                 Replace local legacy 1.0.0 tags with v1.0.0.
                              Does not push or alter manifests.
      --keep-comments         Do not strip comments during --apply/--publish
      --no-git                Rewrite manifests only, even with --apply/--publish
      --org ORG               GitHub organization/user (default: wabiverse)
      --visibility MODE       public or private (default: public)
      --release-version VER   Version to depend on (default: 1.0.0).
                              Git tag and GitHub release are vVER.
      --branch NAME           Initial branch name (default: main)
      --verify                Run 'swift package dump-package' after each rewrite
  -h, --help                  Show this help

Modes are mutually exclusive; the last mode flag on the command line wins.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --comments-only --verify
  ${SCRIPT_NAME} --apply --verify
  ${SCRIPT_NAME} --publish
  ${SCRIPT_NAME} --root ~/wabi/MetaverseKitSplit/MetaOpenVDB --publish
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

typeset -a roots
typeset mode=dry
typeset do_git=1
typeset org=wabiverse
typeset visibility=public
typeset release_version=1.0.0
typeset branch=main
typeset do_verify=0
typeset do_strip=1

while (( $# )); do
  case $1 in
    -r|--root)
      (( $# >= 2 )) || die "$1 requires a directory"
      roots+=("$2")
      shift 2
      ;;
    --dry-run)
      mode=dry
      shift
      ;;
    --apply)
      mode=apply
      shift
      ;;
    --publish)
      mode=publish
      shift
      ;;
    --comments-only)
      mode=comments
      shift
      ;;
    --retag)
      mode=retag
      shift
      ;;
    --keep-comments)
      do_strip=0
      shift
      ;;
    --no-git)
      do_git=0
      shift
      ;;
    --org)
      (( $# >= 2 )) || die "$1 requires a value"
      org=$2
      shift 2
      ;;
    --visibility)
      (( $# >= 2 )) || die "$1 requires a value"
      visibility=$2
      shift 2
      ;;
    --release-version)
      (( $# >= 2 )) || die "$1 requires a value"
      release_version=$2
      shift 2
      ;;
    --branch)
      (( $# >= 2 )) || die "$1 requires a value"
      branch=$2
      shift 2
      ;;
    --verify)
      do_verify=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      roots+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      roots+=("$1")
      shift
      ;;
  esac
done

case $visibility in
  public|private) ;;
  *) die "--visibility must be 'public' or 'private', got: $visibility" ;;
esac

# Dependency spec stays 1.0.0; git tags/releases use the v-prefixed form.
release_version=${release_version#v}
[[ -n $release_version ]] || die "--release-version must not be empty"
typeset -r release_tag="v${release_version}"

if [[ $mode == publish && $do_git == 0 ]]; then
  die "--publish requires git; remove --no-git or use --dry-run"
fi

if [[ $mode == comments && $do_strip == 0 ]]; then
  die "--comments-only conflicts with --keep-comments"
fi

if [[ $mode == retag && $do_git == 0 ]]; then
  die "--retag requires git; remove --no-git"
fi

(( ${#roots} )) || roots=("$HOME/wabi/MetaverseKitSplit")

case $mode in
  dry)      mode_label="dry run (no changes)" ;;
  apply)    mode_label="apply (manifests + local git commit/tag, no push)" ;;
  publish)  mode_label="publish (manifests + local git + GitHub push)" ;;
  comments) mode_label="comments only (strip comments, no deps or git)" ;;
  retag)    mode_label="retag (replace legacy ${release_version} with ${release_tag})" ;;
esac

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

command -v perl >/dev/null 2>&1 || die "perl is required for manifest rewrites"

if [[ $mode == apply || $mode == publish || $mode == retag ]]; then
  command -v git >/dev/null 2>&1 || die "git is required for --apply/--publish/--retag"
fi

if [[ $mode == publish ]]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for --publish"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
fi

if (( do_git )) && [[ $mode == apply || $mode == publish || $mode == retag ]]; then
  [[ -n $(git config --get user.name) ]] \
    || die "git user.name is not configured; run: git config --global user.name 'Your Name'"
  [[ -n $(git config --get user.email) ]] \
    || die "git user.email is not configured; run: git config --global user.email 'you@example.com'"
fi

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

typeset -a packages

for root in "${roots[@]}"; do
  [[ -d $root ]] || die "not a directory: $root"
  root=${root:A}

  # Allow passing a package directory directly.
  if [[ -f $root/Package.swift && ${root:t} == Meta* && ${root:t} != MetaverseKit ]]; then
    packages+=("$root")
  fi

  for manifest in "$root"/Meta*/Package.swift(N) "$root"/*/Meta*/Package.swift(N); do
    [[ -f $manifest ]] || continue
    pkg=${manifest:h}
    [[ $pkg == */.build/* ]] && continue
    [[ ${pkg:t} == MetaverseKit ]] && continue
    packages+=("$pkg")
  done
done

packages=("${(@u)packages}")
packages=("${(@o)packages}")

(( ${#packages} )) || die "no Meta* SwiftPM packages found under: ${roots[*]}"

# ---------------------------------------------------------------------------
# Manifest rewriting
# ---------------------------------------------------------------------------

typeset last_count=0
typeset comments_changed=0

# Rewrites .package(path: "../MetaFoo") -> .package(url: "...", from: "...").
# Also handles .package(name: "...", path: "../MetaFoo"). Returns 0 always;
# the number of converted path dependencies is left in $last_count.
rewrite_manifest() {
  local manifest=$1
  local before after

  last_count=$(grep -c 'path: "\.\./Meta' "$manifest" 2>/dev/null || true)
  before=$(cksum < "$manifest")

  ORG=$org RELEASE_VERSION=$release_version perl -0pi -e '
    s{
      \.package\(\s*
      (?:name:\s*"[^"]*"\s*,\s*)?
      path:\s*"\.\./(Meta[^"/]+)/?"\s*
      \)
    }{
      qq{.package(url: "https://github.com/$ENV{ORG}/$1.git", from: "$ENV{RELEASE_VERSION}")}
    }gex
  ' "$manifest"

  after=$(cksum < "$manifest")
  [[ $before == $after ]] && last_count=0
  return 0
}

# Strips comments in place. Sets $comments_changed to 1 when the file changed.
strip_comments() {
  local file=$1
  local tmp="${file}.strip-comments.$$"

  if ! perl -0 -e "$STRIP_COMMENTS_PERL" "$file" > "$tmp"; then
    rm -f "$tmp"
    warn "could not strip comments from $file"
    return 1
  fi

  if cmp -s "$file" "$tmp"; then
    comments_changed=0
    rm -f "$tmp"
  else
    if ! cat "$tmp" > "$file"; then
      rm -f "$tmp"
      warn "could not write $file"
      return 1
    fi
    comments_changed=1
    rm -f "$tmp"
  fi

  return 0
}

backup_manifest() {
  local dir=$1
  local name=${dir:t}
  local backup="$backup_dir/$name"

  mkdir -p "$backup" || {
    warn "$name: could not create backup directory $backup"
    return 1
  }
  cp "$dir/Package.swift" "$backup/Package.swift" || {
    warn "$name: could not back up Package.swift"
    return 1
  }
  return 0
}

verify_package() {
  local dir=$1
  local name=${dir:t}

  (( do_verify )) || return 0

  if ! command -v swift >/dev/null 2>&1; then
    warn "$name: swift not found; skipping --verify"
    return 0
  fi

  if ! swift package --package-path "$dir" dump-package >/dev/null; then
    warn "$name: 'swift package dump-package' failed"
    return 1
  fi

  ok "$name: manifest validates"
  return 0
}

ensure_gitignore() {
  local dir=$1
  local file="$dir/.gitignore"
  local entry
  local -a entries=(
    '.build/'
    '.swiftpm/'
    '.index-build/'
    'DerivedData/'
    '.DS_Store'
    'Package.resolved'
    '*.xcuserstate'
  )

  if [[ ! -f $file ]]; then
    print -r -- "# Generated by ${SCRIPT_NAME}" > "$file"
  fi

  for entry in "${entries[@]}"; do
    grep -qxF -- "$entry" "$file" || print -r -- "$entry" >> "$file"
  done
}

# ---------------------------------------------------------------------------
# Per-package phases
# ---------------------------------------------------------------------------

plan_package() {
  local dir=$1
  local name=${dir:t}
  local manifest="$dir/Package.swift"
  local tmp dep_count stripped
  tmp=$(mktemp "${TMPDIR:-/tmp}/metapublish.XXXXXX") || {
    warn "$name: could not create temporary file"
    return 1
  }

  cp "$manifest" "$tmp"
  rewrite_manifest "$tmp"
  dep_count=$last_count

  stripped=0
  if (( do_strip )); then
    strip_comments "$tmp" || {
      rm -f "$tmp"
      return 1
    }
    stripped=$comments_changed
  fi

  if (( dep_count == 0 && stripped == 0 )); then
    print -r -- "  ${C_DIM}${name}: no local-path Meta dependencies or comments${C_RESET}"
    rm -f "$tmp"
    return 0
  fi

  local description="$name:"
  (( dep_count > 0 )) && description+=" would rewrite ${dep_count} path dependency/ies"
  (( dep_count > 0 && stripped )) && description+=" and"
  (( stripped )) && description+=" strip comments"
  print -r -- "  ${C_BOLD}${description}${C_RESET}"

  diff -u -L "a/${name}/Package.swift" -L "b/${name}/Package.swift" "$manifest" "$tmp" \
    | sed -e '1,2d' -e 's/^/    /'
  rm -f "$tmp"
  return 0
}

apply_package() {
  local dir=$1
  local name=${dir:t}
  local manifest="$dir/Package.swift"

  backup_manifest "$dir" || return 1

  rewrite_manifest "$manifest"
  if (( last_count > 0 )); then
    ok "$name: rewrote ${last_count} local-path dependency/ies"
  else
    print -r -- "  ${C_DIM}${name}: no local-path Meta dependencies${C_RESET}"
  fi

  if (( do_strip )); then
    strip_comments "$manifest" || return 1
    if (( comments_changed )); then
      ok "$name: stripped comments"
    else
      print -r -- "  ${C_DIM}${name}: no comments to strip${C_RESET}"
    fi
  fi

  ensure_gitignore "$dir"

  if grep -q '\.package(path:' "$manifest"; then
    warn "$name: still has non-Meta path dependencies (left untouched)"
  fi

  verify_package "$dir" || return 1
  return 0
}

comments_package() {
  local dir=$1
  local name=${dir:t}
  local manifest="$dir/Package.swift"

  backup_manifest "$dir" || return 1

  strip_comments "$manifest" || return 1
  if (( comments_changed )); then
    ok "$name: stripped comments"
  else
    print -r -- "  ${C_DIM}${name}: no comments to strip${C_RESET}"
  fi

  verify_package "$dir" || return 1
  return 0
}

typeset current_branch=$branch

commit_package() {
  local dir=$1
  local name=${dir:t}
  local current

  if [[ ! -d $dir/.git ]]; then
    if ! git -C "$dir" init -q -b "$branch" 2>/dev/null; then
      git -C "$dir" init -q || return 1
      git -C "$dir" symbolic-ref HEAD "refs/heads/$branch" || return 1
    fi
    ok "$name: initialized git repository"
  fi

  if git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    current=$(git -C "$dir" symbolic-ref -q --short HEAD) || {
      warn "$name: repository is in detached HEAD state"
      return 1
    }
  else
    current=$branch
    git -C "$dir" symbolic-ref HEAD "refs/heads/$branch" || return 1
  fi

  git -C "$dir" add -A || return 1

  if git -C "$dir" diff --cached --quiet; then
    print -r -- "  ${C_DIM}${name}: nothing new to commit${C_RESET}"
  else
    git -C "$dir" commit -q -m "Initial commit (${name} ${release_tag})" || return 1
    ok "$name: committed on ${current}"
  fi

  if git -C "$dir" rev-parse -q --verify "refs/tags/${release_tag}" >/dev/null 2>&1; then
    print -r -- "  ${C_DIM}${name}: tag ${release_tag} already exists${C_RESET}"
  else
    git -C "$dir" tag -a "$release_tag" -m "${release_tag}" || return 1
    ok "$name: tagged ${release_tag}"
  fi

  current_branch=$current
  return 0
}

publish_package() {
  local dir=$1
  local name=${dir:t}
  local push_branch=$2
  local url="https://github.com/${org}/${name}.git"

  if gh repo view "${org}/${name}" >/dev/null 2>&1; then
    print -r -- "  ${C_DIM}${name}: GitHub repo exists, pushing${C_RESET}"
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      git -C "$dir" remote set-url origin "$url" || return 1
    else
      git -C "$dir" remote add origin "$url" || return 1
    fi
    git -C "$dir" push -q -u origin "$push_branch" || return 1
  else
    gh repo create "${org}/${name}" "--${visibility}" \
      --source "$dir" --remote origin --push >/dev/null || return 1
  fi

  git -C "$dir" push -q origin "$release_tag" || return 1

  if gh release view "$release_tag" --repo "${org}/${name}" >/dev/null 2>&1; then
    print -r -- "  ${C_DIM}${name}: GitHub release ${release_tag} already exists${C_RESET}"
  else
    gh release create "$release_tag" \
      --repo "${org}/${name}" \
      --title "$release_tag" \
      --notes "Initial release of ${name}." \
      --verify-tag >/dev/null || return 1
    ok "$name: created GitHub release ${release_tag}"
  fi

  ok "$name: published ${org}/${name} (${push_branch} + ${release_tag})"
  return 0
}

retag_package() {
  local dir=$1
  local name=${dir:t}
  local legacy=$release_version
  local legacy_commit v_commit

  if [[ ! -d $dir/.git ]]; then
    warn "$name: not a git repository"
    return 1
  fi

  if git -C "$dir" rev-parse -q --verify "refs/tags/${legacy}" >/dev/null 2>&1; then
    legacy_commit=$(git -C "$dir" rev-list -n 1 "refs/tags/${legacy}") || return 1

    if git -C "$dir" rev-parse -q --verify "refs/tags/${release_tag}" >/dev/null 2>&1; then
      v_commit=$(git -C "$dir" rev-list -n 1 "refs/tags/${release_tag}") || return 1
      if [[ $v_commit != $legacy_commit ]]; then
        warn "$name: ${release_tag} already exists at ${v_commit}, not ${legacy_commit}; leaving tags alone"
        return 1
      fi
      print -r -- "  ${C_DIM}${name}: ${release_tag} already exists${C_RESET}"
    else
      git -C "$dir" tag -a "$release_tag" "$legacy_commit" -m "$release_tag" || return 1
      ok "$name: tagged ${release_tag} at ${legacy_commit}"
    fi

    git -C "$dir" tag -d "$legacy" >/dev/null || return 1
    ok "$name: deleted legacy tag ${legacy}"
  else
    if git -C "$dir" rev-parse -q --verify "refs/tags/${release_tag}" >/dev/null 2>&1; then
      print -r -- "  ${C_DIM}${name}: ${release_tag} already exists; no legacy ${legacy} tag${C_RESET}"
    else
      git -C "$dir" tag -a "$release_tag" -m "$release_tag" || return 1
      ok "$name: tagged ${release_tag}"
    fi
  fi

  return 0
}

process_package() {
  local dir=$1
  local push_branch=$branch

  case $mode in
    dry)
      plan_package "$dir"
      return $?
      ;;
    comments)
      comments_package "$dir"
      return $?
      ;;
    retag)
      retag_package "$dir"
      return $?
      ;;
  esac

  apply_package "$dir" || return 1

  if (( do_git )); then
    commit_package "$dir" || return 1
    push_branch=$current_branch
  fi

  if [[ $mode == publish ]]; then
    publish_package "$dir" "$push_branch" || return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

typeset backup_dir=''
if [[ $mode != dry && $mode != retag ]]; then
  typeset tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  backup_dir="${tmp_base}/metapublish-backups-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir" || die "could not create backup directory: $backup_dir"
fi

print -r -- "${C_BOLD}publish-metapackages${C_RESET}"
print -r -- "  mode:    ${mode_label}"
print -r -- "  root(s): ${(j:, :)roots}"
print -r -- "  found:   ${#packages} package(s)"
[[ -n $backup_dir ]] && print -r -- "  backup:  ${backup_dir}"
print -r -- ""

typeset -a succeeded failed
for dir in "${packages[@]}"; do
  print -r -- "${C_DIM}--- ${dir}${C_RESET}"
  if process_package "$dir"; then
    succeeded+=("${dir:t}")
  else
    warn "${dir:t}: failed"
    failed+=("${dir:t}")
  fi
  print -r -- ""
done

info "summary"
print -r -- "  mode:      ${mode_label}"
print -r -- "  succeeded: ${#succeeded}"
if (( ${#failed} )); then
  print -r -- "  ${C_RED}failed:${C_RESET}    ${(j:, :)failed}"
  exit 1
fi

if [[ $mode == dry ]]; then
  print -r -- "  ${C_DIM}no changes made; re-run with --apply or --publish${C_RESET}"
fi

exit 0
