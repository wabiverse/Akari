#!/usr/bin/env zsh
# publish-metapackages.zsh

# releases every Meta package changed since its latest tag, raises every from on them to that release, and commits, tags and with publish pushes each one
# copies of a package in MetaverseKitSplit are fast forwarded to its release, the default workspace is the folder holding this checkout

emulate -L zsh
setopt pipe_fail extended_glob

typeset -r SCRIPT_NAME=${0:t}
typeset -r SCRIPT_DIR=${0:A:h}

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

  # line comments, only the tools version directive stays
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

  # block comments, which swift lets nest
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

  # raw string literals with any number of hashes, multiline ones too
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

  # ordinary string literals, single or multiline
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

# tidies the whitespace comment removal leaves behind
$out =~ s/[ \t]+$//mg;
$out =~ s/\n{3,}/\n\n/g;
$out .= "\n" unless $out =~ /\n\z/;

print $out;
PERL
)

# rewrites one Package.swift from stdin, raising from floors to VERSIONS, turning Meta paths into urls with UNPATH and retiring MetaTurboJPEG
typeset -r REWRITE_PERL=$(cat <<'PERL'
use strict;
use warnings;

local $/;
my $s = <>;
my %ver = map { my ($k, $v) = split /=/, $_, 2; (lc $k, $v) } grep { length } split /;/, ($ENV{VERSIONS} // '');
my $org = $ENV{ORG};

sub newer {
  my @a = split /\./, $_[0];
  my @b = split /\./, $_[1];
  for my $i (0 .. 2) {
    my ($x, $y) = ($a[$i] // 0, $b[$i] // 0);
    return 1 if $x > $y;
    return 0 if $x < $y;
  }
  return 0;
}

# MetaTurboJPEG is retired in favor of stackotter's libjpegturbo
my $jpeg = $ENV{JPEG_VERSION};
my $old_package = qr{\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?(?:url|path):\s*"[^"]*MetaTurboJPEG(?:\.git)?/?"\s*(?:,\s*from:\s*"[^"]*"\s*)?\)};
my $old_product = qr{\.product\(\s*name:\s*"TurboJPEG"\s*,\s*package:\s*"MetaTurboJPEG"\s*\)};
if ($s =~ /libjpegturbo/) {
  $s =~ s{^[ \t]*$old_package,?[ \t]*\n}{}mg;
  $s =~ s{^[ \t]*$old_product,?[ \t]*\n}{}mg;
} else {
  $s =~ s{$old_package}{.package(url: "https://github.com/stackotter/libjpegturbo", from: "$jpeg")}g;
  $s =~ s{$old_product}{.product(name: "JPEGTurbo", package: "libjpegturbo")}g;
}

# local paths to Meta packages become their releases
if ($ENV{UNPATH}) {
  $s =~ s{\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"(?:[^"]*/)?(Meta[A-Za-z0-9_]+)/?"\s*\)}{
    my $n = $1;
    defined $ver{lc $n} ? qq{.package(url: "https://github.com/$org/$n.git", from: "$ver{lc $n}")} : $&
  }ge;
}

# from floors up to the latest release
$s =~ s{(\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"[^"]*/([A-Za-z0-9_.-]+?)(?:\.git)?/?"\s*,\s*from:\s*")([^"]*)(")}{
  my ($pre, $n, $v, $post) = ($1, $2, $3, $4);
  my $t = $ver{lc $n};
  (defined $t && newer($t, $v)) ? "$pre$t$post" : "$pre$v$post"
}ge;

print $s;
PERL
)

# output helpers

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_BOLD=$'\e[1m'
else
  C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

info() { print -r -- "${C_BLUE}==>${C_RESET} $*" }
ok()   { print -r -- "${C_GREEN}  ok${C_RESET} $*" }
note() { print -r -- "  ${C_DIM}$*${C_RESET}" }
warn() { print -ru2 -- "${C_YELLOW}warning:${C_RESET} $*" }
die()  { print -ru2 -- "${C_RED}error:${C_RESET} $*"; exit 1 }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Release every Meta* SwiftPM package that changed since its latest tag, raise
every from: on a Meta* package to its latest release across the workspace,
and release whatever that bump changes in turn.

Options:
      --dry-run            Show what would be released and every manifest
                           change (default)
      --apply              Rewrite manifests, commit and tag each release.
                           Does not push.
      --publish            --apply, then push each release branch and tag and
                           create its GitHub release
      --bump KIND          patch, minor or major (default: patch)
      --only NAME          Release only these packages and what depends on
                           them. May be repeated.
      --skip NAME          Never release this package. May be repeated.
      --no-cascade         Release only the changed packages. Meta* packages
                           depending on them keep their from: as is.
      --unpath             Also turn local path: dependencies on Meta*
                           packages outside the Meta* packages (Akari's
                           ../MetaTIFF and so on) into url + from: releases
      --strip-comments     Strip comments from each released Package.swift
      --workspace DIR      Folder holding the packages (default: ${SCRIPT_DIR:h:h})
      --org ORG            GitHub organization (default: wabiverse)
      --verify             Run 'swift package dump-package' on each release
  -h, --help               Show this help

Meta* packages released here never keep path: dependencies on other Meta*
packages, those always become url + from:.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --apply
  ${SCRIPT_NAME} --publish
  ${SCRIPT_NAME} --publish --only MetaTIFF --bump minor
EOF
}

# options

typeset mode=dry
typeset bump=patch
typeset org=wabiverse
typeset workspace=${SCRIPT_DIR:h:h}
typeset -i cascade=1 unpath=0 do_strip=0 do_verify=0
typeset -a only skip

while (( $# )); do
  case $1 in
    --dry-run) mode=dry; shift ;;
    --apply) mode=apply; shift ;;
    --publish) mode=publish; shift ;;
    --bump)
      (( $# >= 2 )) || die "$1 requires patch, minor or major"
      bump=$2; shift 2 ;;
    --only)
      (( $# >= 2 )) || die "$1 requires a package name"
      only+=("$2"); shift 2 ;;
    --skip)
      (( $# >= 2 )) || die "$1 requires a package name"
      skip+=("$2"); shift 2 ;;
    --no-cascade) cascade=0; shift ;;
    --unpath) unpath=1; shift ;;
    --strip-comments) do_strip=1; shift ;;
    --workspace)
      (( $# >= 2 )) || die "$1 requires a directory"
      workspace=$2; shift 2 ;;
    --org)
      (( $# >= 2 )) || die "$1 requires a value"
      org=$2; shift 2 ;;
    --verify) do_verify=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case $bump in
  patch|minor|major) ;;
  *) die "--bump must be patch, minor or major, got: $bump" ;;
esac

[[ -d $workspace ]] || die "not a directory: $workspace"
workspace=${workspace:A}

command -v perl >/dev/null 2>&1 || die "perl is required"
command -v git >/dev/null 2>&1 || die "git is required"

if [[ $mode == publish ]]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for --publish"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in, run: gh auth login"
fi

if [[ $mode != dry ]]; then
  [[ -n $(git config --get user.name) ]] || die "git user.name is not set"
  [[ -n $(git config --get user.email) ]] || die "git user.email is not set"
fi

# discovery

# MetaverseKit is the old monorepo the split replaced, MetaTurboJPEG gave way to stackotter's libjpegturbo
typeset -r -a RETIRED=(MetaverseKit MetaTurboJPEG)

typeset -A pkg_dir duplicate_dir
typeset -a meta_names manifests

is_retired() { (( ${RETIRED[(Ie)$1]} )) }

for manifest in "$workspace"/Meta*/Package.swift(N) "$workspace"/MetaverseKitSplit/Meta*/Package.swift(N); do
  local dir=${manifest:h} name=${manifest:h:t}
  is_retired $name && continue
  [[ -d $dir/.git ]] || { warn "$name: not a git repository, left alone"; continue }
  if [[ -n ${pkg_dir[$name]} ]]; then
    duplicate_dir[$name]=$dir
    continue
  fi
  pkg_dir[$name]=$dir
  meta_names+=("$name")
done

(( ${#meta_names} )) || die "no Meta* packages found in $workspace"
meta_names=("${(@o)meta_names}")

for o in "${only[@]}"; do [[ -n ${pkg_dir[$o]} ]] || die "--only: no package named $o"; done
for o in "${skip[@]}"; do [[ -n ${pkg_dir[$o]} ]] || die "--skip: no package named $o"; done

# every other manifest that may depend on a Meta package
for manifest in "$workspace"/*/Package.swift(N) "$workspace"/MetaverseKitSplit/*/Package.swift(N); do
  local dir=${manifest:h} name=${manifest:h:t}
  is_retired $name && continue
  [[ ${name:l} == *backup* ]] && continue
  [[ ${duplicate_dir[$name]} == $dir ]] && continue
  manifests+=("$manifest")
done

latest_tag() {
  git -C "$1" tag -l 'v[0-9]*' --sort=-v:refname | head -1
}

next_version() {
  local v=${1#v}
  local -a p=("${(@s:.:)v}")
  local major=${p[1]:-0} minor=${p[2]:-0} patch=${p[3]:-0}
  case $bump in
    major) print -r -- "$(( major + 1 )).0.0" ;;
    minor) print -r -- "${major}.$(( minor + 1 )).0" ;;
    patch) print -r -- "${major}.${minor}.$(( patch + 1 ))" ;;
  esac
}

# the reason a package needs a release, empty when it doesn't
change_reason() {
  local dir=$1 tag=$2 dirty since
  dirty=$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')
  [[ -z $tag ]] && { print -r -- "never tagged"; return }
  since=$(git -C "$dir" rev-list --count "$tag..HEAD" 2>/dev/null || print 0)
  local -a why
  (( dirty )) && why+=("${dirty} changed file(s)")
  (( since )) && why+=("${since} commit(s) since ${tag}")
  print -r -- "${(j:, :)why}"
}

typeset -A tag_of new_version reason
for name in "${meta_names[@]}"; do
  tag_of[$name]=$(latest_tag "${pkg_dir[$name]}")
  reason[$name]=$(change_reason "${pkg_dir[$name]}" "${tag_of[$name]}")
done

typeset jpeg_version
jpeg_version=$(git ls-remote --tags --refs https://github.com/stackotter/libjpegturbo.git 2>/dev/null \
  | sed -E 's#.*refs/tags/v?##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
[[ -n $jpeg_version ]] || { jpeg_version=0.1.4; warn "could not reach stackotter/libjpegturbo, using ${jpeg_version}" }

releasable() {
  local name=$1
  (( ${skip[(Ie)$name]} )) && return 1
  return 0
}

# plans the changed packages and whatever their from bumps change, until nothing more does, the rewritten manifests wait in a scratch folder

typeset scratch
scratch=$(mktemp -d "${TMPDIR:-/tmp}/metapublish.XXXXXX") || die "could not make a scratch folder"
trap 'rm -rf "$scratch"' EXIT

typeset -a releases
for name in "${meta_names[@]}"; do
  [[ -n ${reason[$name]} ]] || continue
  releasable $name || continue
  (( ${#only} )) && ! (( ${only[(Ie)$name]} )) && continue
  releases+=("$name")
done

versions_env() {
  local name out=""
  for name in "${meta_names[@]}"; do
    if (( ${releases[(Ie)$name]} )); then
      out+="${name}=$(next_version "${tag_of[$name]:-v0.0.0}");"
    elif [[ -n ${tag_of[$name]} ]]; then
      out+="${name}=${tag_of[$name]#v};"
    fi
  done
  print -r -- "${out}libjpegturbo=${jpeg_version}"
}

typeset -A owner_of
for name in "${meta_names[@]}"; do owner_of[${pkg_dir[$name]}/Package.swift]=$name; done

typeset -A rewritten
rewrite_all() {
  local versions manifest name out
  versions=$(versions_env)
  rewritten=()
  for manifest in "${manifests[@]}"; do
    name=${owner_of[$manifest]}
    out="$scratch/${#rewritten}.swift"
    local un=$unpath
    [[ -n $name ]] && un=1
    VERSIONS=$versions ORG=$org UNPATH=$un JPEG_VERSION=$jpeg_version \
      perl -0 -e "$REWRITE_PERL" "$manifest" > "$out" || die "could not rewrite $manifest"
    if cmp -s "$manifest" "$out"; then
      rm -f "$out"
    else
      rewritten[$manifest]=$out
    fi
  done
}

while true; do
  rewrite_all
  (( cascade )) || break
  typeset -i grew=0
  for manifest in "${(@k)rewritten}"; do
    name=${owner_of[$manifest]}
    [[ -n $name ]] || continue
    (( ${releases[(Ie)$name]} )) && continue
    releasable $name || continue
    releases+=("$name")
    reason[$name]="depends on a new release"
    grew=1
  done
  (( grew )) || break
done

# without the cascade a Meta package that isn't released keeps its manifest
for manifest in "${(@k)rewritten}"; do
  name=${owner_of[$manifest]}
  [[ -n $name ]] && ! (( ${releases[(Ie)$name]} )) && unset "rewritten[$manifest]"
done

releases=("${(@o)releases}")
for name in "${releases[@]}"; do new_version[$name]=$(next_version "${tag_of[$name]:-v0.0.0}"); done

# releases an earlier apply tagged but never pushed
typeset -a unpushed
for name in "${meta_names[@]}"; do
  (( ${releases[(Ie)$name]} )) && continue
  releasable $name || continue
  local tag=${tag_of[$name]} branch=
  [[ -n $tag ]] || continue
  branch=$(git -C "${pkg_dir[$name]}" symbolic-ref -q --short HEAD) || continue
  git -C "${pkg_dir[$name]}" merge-base --is-ancestor "$tag" "origin/$branch" 2>/dev/null || unpushed+=("$name")
done

# show the plan

case $mode in
  dry)     mode_label="dry run, nothing changes" ;;
  apply)   mode_label="apply, commit and tag locally, nothing is pushed" ;;
  publish) mode_label="publish, commit, tag, push and create GitHub releases" ;;
esac

print -r -- "${C_BOLD}publish-metapackages${C_RESET}"
print -r -- "  mode:         ${mode_label}"
print -r -- "  workspace:    ${workspace}"
print -r -- "  libjpegturbo: ${jpeg_version}"
print -r -- ""

if (( ${#releases} == 0 && ${#rewritten} == 0 && ${#unpushed} == 0 )); then
  info "every Meta* package is released and every from: is current"
  exit 0
fi

info "releases"
for name in "${releases[@]}"; do
  print -r -- "  ${C_BOLD}${name}${C_RESET} ${tag_of[$name]:-untagged} -> v${new_version[$name]}  ${C_DIM}(${reason[$name]})${C_RESET}"
done
for name in "${meta_names[@]}"; do
  [[ -n ${reason[$name]} ]] || continue
  (( ${releases[(Ie)$name]} )) && continue
  note "${name} has changes but is left out (${reason[$name]})"
done
for name in "${RETIRED[@]}"; do
  [[ -d $workspace/$name/.git && -n $(git -C "$workspace/$name" status --porcelain) ]] \
    && note "${name} has changes but is retired, never released"
done
for name in "${unpushed[@]}"; do
  print -r -- "  ${C_BOLD}${name}${C_RESET} ${tag_of[$name]} is tagged but not pushed yet  ${C_DIM}(--publish pushes it)${C_RESET}"
done
print -r -- ""

info "manifest changes"
for manifest in "${(@ok)rewritten}"; do
  local shown=${manifest#$workspace/}
  name=${owner_of[$manifest]}
  if [[ -n $name ]]; then print -r -- "  ${C_BOLD}${shown}${C_RESET}"
  else print -r -- "  ${C_BOLD}${shown}${C_RESET} ${C_DIM}(not a Meta* package, left uncommitted)${C_RESET}"
  fi
  diff -u -L "a/$shown" -L "b/$shown" "$manifest" "${rewritten[$manifest]}" | sed -e '1,2d' -e 's/^/    /'
done
print -r -- ""

if [[ $mode == dry ]]; then
  note "nothing changed, run again with --apply to commit and tag or --publish to also push"
  exit 0
fi

# preflight for every release before anything is written

typeset -A branch_of
for name in "${releases[@]}"; do
  local dir=${pkg_dir[$name]} tag="v${new_version[$name]}"
  branch_of[$name]=$(git -C "$dir" symbolic-ref -q --short HEAD) || die "$name: detached HEAD, check out a branch first"
  git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$name: tag $tag already exists"

  if [[ $mode == publish ]]; then
    git -C "$dir" remote get-url origin >/dev/null 2>&1 || die "$name: has no origin remote"
    git -C "$dir" fetch -q --tags origin || die "$name: could not fetch origin"
    local behind=0
    behind=$(git -C "$dir" rev-list --count "HEAD..origin/${branch_of[$name]}" 2>/dev/null || print 0)
    (( behind == 0 )) || die "$name: ${behind} commit(s) behind origin/${branch_of[$name]}, pull first"
    git -C "$dir" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 \
      && die "$name: tag $tag already exists on origin"
  fi
done

# writes, commits, tags and publishes

typeset backup="${TMPDIR:-/tmp}"
backup="${backup%/}/metapublish-backups-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup" || die "could not make $backup"

info "writing manifests (originals kept in ${backup})"
for manifest in "${(@ok)rewritten}"; do
  local saved="$backup/${manifest#$workspace/}"
  mkdir -p "${saved:h}" && cp "$manifest" "$saved" || die "could not back up $manifest"
  cat "${rewritten[$manifest]}" > "$manifest" || die "could not write $manifest"
  ok "${manifest#$workspace/}"
done
print -r -- ""

strip_comments() {
  local file=$1 tmp="${1}.strip.$$"
  perl -0 -e "$STRIP_COMMENTS_PERL" "$file" > "$tmp" || { rm -f "$tmp"; return 1 }
  cmp -s "$file" "$tmp" || cat "$tmp" > "$file"
  rm -f "$tmp"
}

# pushes a branch and its release tag and creates the github release
publish_release() {
  local name=$1 dir=$2 branch=$3 tag=$4 repo
  git -C "$dir" push -q origin "$branch" "refs/tags/$tag" || { warn "$name: push failed"; return 1 }
  ok "pushed ${branch} and ${tag}"
  repo=$(git -C "$dir" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    note "${repo}@${tag} already has a GitHub release"
  elif gh release create "$tag" --repo "$repo" --title "$tag" --generate-notes --verify-tag >/dev/null; then
    ok "created GitHub release ${repo}@${tag}"
  else
    warn "$name: could not create the GitHub release"
    return 1
  fi
}

typeset -a done_names failed_names
for name in "${releases[@]}"; do
  local dir=${pkg_dir[$name]} tag="v${new_version[$name]}" branch=${branch_of[$name]}
  info "${name} ${tag}"

  if (( do_strip )); then
    strip_comments "$dir/Package.swift" || { warn "$name: could not strip comments"; failed_names+=("$name"); continue }
  fi

  if grep -qE '\.package\(\s*(name:\s*"[^"]*"\s*,\s*)?path:' "$dir/Package.swift"; then
    warn "$name: still has a path: dependency, a release can't resolve it"
  fi

  if (( do_verify )) && ! swift package --package-path "$dir" dump-package >/dev/null; then
    warn "$name: 'swift package dump-package' failed"
    failed_names+=("$name")
    continue
  fi

  git -C "$dir" add -A || { failed_names+=("$name"); continue }
  if git -C "$dir" diff --cached --quiet; then
    note "${name}: nothing to commit, tagging ${branch} as it is"
  else
    git -C "$dir" commit -q -m "${name} ${tag}" || { failed_names+=("$name"); continue }
    ok "committed on ${branch}"
  fi

  git -C "$dir" tag -a "$tag" -m "$tag" || { failed_names+=("$name"); continue }
  ok "tagged ${tag}"

  if [[ $mode == publish ]]; then
    publish_release "$name" "$dir" "$branch" "$tag" || { failed_names+=("$name"); continue }
  fi

  # the copy in MetaverseKitSplit follows the release
  local copy=${duplicate_dir[$name]}
  if [[ -n $copy ]]; then
    if [[ -n $(git -C "$copy" status --porcelain) ]]; then
      warn "$name: ${copy} has its own changes, not brought up to ${tag}"
    elif git -C "$copy" fetch -q "$dir" "refs/tags/${tag}:refs/tags/${tag}" \
         && git -C "$copy" merge -q --ff-only "${tag}^{commit}"; then
      ok "brought ${copy#$workspace/} up to ${tag}"
    else
      warn "$name: ${copy} has diverged, not brought up to ${tag}"
    fi
  fi

  done_names+=("$name")
  print -r -- ""
done

if [[ $mode == publish ]]; then
  for name in "${unpushed[@]}"; do
    local dir=${pkg_dir[$name]} tag=${tag_of[$name]} branch=
    branch=$(git -C "$dir" symbolic-ref -q --short HEAD)
    info "${name} ${tag}, tagged earlier"
    if publish_release "$name" "$dir" "$branch" "$tag"; then
      new_version[$name]=${tag#v}
      done_names+=("$name")
    else
      failed_names+=("$name")
    fi
    print -r -- ""
  done
fi

info "summary"
print -r -- "  released: ${#done_names}"
for name in "${done_names[@]}"; do print -r -- "    ${name} v${new_version[$name]}"; done
local -a others=()
for manifest in "${(@ok)rewritten}"; do [[ -z ${owner_of[$manifest]} ]] && others+=("${manifest#$workspace/}"); done
if (( ${#others} )); then
  print -r -- "  updated, commit these yourself:"
  for m in "${others[@]}"; do print -r -- "    $m"; done
fi
if (( ${#failed_names} )); then
  print -r -- "  ${C_RED}failed:${C_RESET} ${(j:, :)failed_names}"
  exit 1
fi
[[ $mode == apply ]] && note "nothing was pushed, run again with --publish once you're happy"
exit 0
