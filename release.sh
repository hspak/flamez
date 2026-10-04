#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 <version> [--check] [--macos-host HOST] [--macos-archive PATH]" >&2
  echo "  [--minimum-macos MAJOR.0] (default: the Mac's current major release)" >&2
  echo "  FLAMEZ_MACOS_HOST selects the SSH builder; FLAMEZ_MACOS_ARCHIVE reuses an archive." >&2
  echo "  FLAMEZ_MACOS_REPO defaults to code/flamez; an existing checkout is optional." >&2
  echo "  --check prepares and builds both packages without publishing." >&2
}

die() {
  echo "release.sh: $*" >&2
  exit 1
}

if [[ ${1:-} == --help ]]; then
  usage
  exit 0
fi
[[ $# -ge 1 ]] || {
  usage
  exit 2
}

version=$1
shift
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "version must use the X.Y.Z format"
check_only=false
macos_host=${FLAMEZ_MACOS_HOST:-}
macos_repo=${FLAMEZ_MACOS_REPO:-code/flamez}
macos_archive=${FLAMEZ_MACOS_ARCHIVE:-}
macos_minimum=${FLAMEZ_MINIMUM_MACOS:-}
while [[ $# -gt 0 ]]; do
  case $1 in
    --check) check_only=true; shift ;;
    --macos-host|--macos-archive|--minimum-macos)
      [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
      case $1 in
        --macos-host) macos_host=$2 ;;
        --macos-archive) macos_archive=$2 ;;
        --minimum-macos) macos_minimum=$2 ;;
      esac
      shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -z $macos_minimum || $macos_minimum =~ ^[0-9]+\.0$ ]] ||
  die "minimum macOS must use MAJOR.0"
if [[ -n $macos_archive ]]; then
  [[ -f $macos_archive ]] || die "macOS archive not found: $macos_archive"
else
  [[ -n $macos_host && $macos_host != -* ]] ||
    die "set FLAMEZ_MACOS_HOST or pass --macos-host HOST (or supply --macos-archive PATH)"
  command -v ssh >/dev/null || die "required command not found: ssh"
fi

for command in curl file git grep install makepkg mktemp python3 ruby sed sha256sum tar zig; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done
[[ $(zig version) == 0.16.0 ]] || die "Zig 0.16.0 is required on the release host"

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
revision=$(git -C "$repo_dir" rev-parse HEAD)
source_origin=$(git -C "$repo_dir" remote get-url origin)
case $source_origin in
  git@github.com:*) source_origin=https://github.com/${source_origin#git@github.com:} ;;
  https://github.com/*) ;;
  *) die "the source origin must be a GitHub HTTPS or SSH URL" ;;
esac
source_origin=${source_origin%.git}
aur_dir=$(cd -- "${FLAMEZ_AUR_DIR:-$repo_dir/../../aur/flamez}" 2>/dev/null && pwd) ||
  die "AUR repository not found; set FLAMEZ_AUR_DIR to override ../../aur/flamez"
tap_dir=$(cd -- "${FLAMEZ_TAP_DIR:-$repo_dir/../homebrew-tap}" 2>/dev/null && pwd) ||
  die "Homebrew tap not found; set FLAMEZ_TAP_DIR to override ../homebrew-tap"
pkgbuild=$aur_dir/PKGBUILD
formula_path=Formula/flamez.rb
formula=$tap_dir/$formula_path

[[ -f $pkgbuild ]] || die "PKGBUILD not found at $pkgbuild"
[[ -f $formula ]] || die "Homebrew formula not found at $formula"
git -C "$repo_dir" remote get-url origin >/dev/null 2>&1 ||
  die "the source repository has no origin remote"
git -C "$aur_dir" remote get-url origin >/dev/null 2>&1 ||
  die "the AUR repository has no origin remote"
git -C "$tap_dir" remote get-url origin >/dev/null 2>&1 ||
  die "the Homebrew tap has no origin remote"
git -C "$repo_dir" symbolic-ref --quiet HEAD >/dev/null ||
  die "the source repository is in detached HEAD state"
git -C "$aur_dir" symbolic-ref --quiet HEAD >/dev/null ||
  die "the AUR repository is in detached HEAD state"
git -C "$tap_dir" symbolic-ref --quiet HEAD >/dev/null ||
  die "the Homebrew tap is in detached HEAD state"
git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
  die "the current source branch has no upstream"
git -C "$aur_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
  die "the current AUR branch has no upstream"
git -C "$tap_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
  die "the current Homebrew tap branch has no upstream"
git -C "$aur_dir" var GIT_AUTHOR_IDENT >/dev/null 2>&1 ||
  die "git author information is not configured for the AUR repository"
git -C "$tap_dir" var GIT_AUTHOR_IDENT >/dev/null 2>&1 ||
  die "git author information is not configured for the Homebrew tap"
if ! $check_only; then
  command -v gh >/dev/null || die "required command not found: gh"
  gh auth status --hostname github.com >/dev/null 2>&1 ||
    die "GitHub CLI is not authenticated; run 'gh auth login'"
  github_repo=$(cd -- "$repo_dir" && gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die "could not resolve the GitHub repository from origin"
fi

git -C "$repo_dir" diff --quiet --ignore-submodules -- ||
  die "the source repository has uncommitted tracked changes"
git -C "$repo_dir" diff --cached --quiet --ignore-submodules -- ||
  die "the source repository has staged changes"
# Untracked makepkg output in the AUR repository is intentionally ignored.
git -C "$aur_dir" diff --quiet --ignore-submodules -- ||
  die "the AUR repository has uncommitted tracked changes"
git -C "$aur_dir" diff --cached --quiet --ignore-submodules -- ||
  die "the AUR repository has staged changes"
git -C "$tap_dir" diff --quiet --ignore-submodules -- ||
  die "the Homebrew tap has uncommitted tracked changes"
git -C "$tap_dir" diff --cached --quiet --ignore-submodules -- ||
  die "the Homebrew tap has staged changes"
git -C "$tap_dir" ls-files --error-unmatch "$formula_path" >/dev/null 2>&1 ||
  die "the Homebrew formula is not tracked"
git -C "$aur_dir" ls-files --error-unmatch PKGBUILD .SRCINFO >/dev/null 2>&1 ||
  die "PKGBUILD and .SRCINFO must be tracked in the AUR repository"
[[ $(git -C "$repo_dir" rev-parse HEAD) == $(git -C "$repo_dir" rev-parse '@{upstream}') ]] ||
  die "the source branch is not synchronized with its upstream; push or pull it first"
[[ $(git -C "$aur_dir" rev-parse HEAD) == $(git -C "$aur_dir" rev-parse '@{upstream}') ]] ||
  die "the AUR branch is not synchronized with its upstream; push or pull it first"
[[ $(git -C "$tap_dir" rev-parse HEAD) == $(git -C "$tap_dir" rev-parse '@{upstream}') ]] ||
  die "the Homebrew tap branch is not synchronized with its upstream; push or pull it first"

grep -Fq ".version = \"$version\"" "$repo_dir/build.zig.zon" ||
  die "build.zig.zon does not declare version $version"
[[ $(grep -Ec '^pkgver=' "$pkgbuild") -eq 1 ]] ||
  die "expected exactly one pkgver entry in PKGBUILD"
[[ $(grep -Ec '^pkgrel=' "$pkgbuild") -eq 1 ]] ||
  die "expected exactly one pkgrel entry in PKGBUILD"
[[ $(grep -Ec '^sha256sums=' "$pkgbuild") -eq 1 ]] ||
  die "expected exactly one sha256sums entry in PKGBUILD"
[[ $(grep -Ec '^  version "[0-9]+\.[0-9]+\.[0-9]+"$' "$formula") -eq 1 ]] ||
  die "expected exactly one version entry in the Homebrew formula"
[[ $(grep -Ec '^  url ".*"$' "$formula") -eq 1 ]] ||
  die "expected exactly one URL entry in the Homebrew formula"
[[ $(grep -Ec '^  sha256 "[^"]*"$' "$formula") -eq 1 ]] ||
  die "expected exactly one SHA-256 entry in the Homebrew formula"

if ! $check_only; then
  git -C "$repo_dir" rev-parse --verify --quiet "refs/tags/$version" >/dev/null &&
    die "tag $version already exists locally"
  if git -C "$repo_dir" ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null; then
    die "tag $version already exists on origin"
  else
    status=$?
    [[ $status -eq 2 ]] || die "could not query tags on origin"
  fi
  git -C "$aur_dir" ls-remote origin HEAD >/dev/null ||
    die "could not connect to the AUR origin"
  git -C "$tap_dir" ls-remote origin HEAD >/dev/null ||
    die "could not connect to the Homebrew tap origin"
fi

release_dir=$(mktemp --directory --suffix="-flamez-$version")
cleanup() {
  if [[ $? -eq 0 ]]; then
    rm -rf -- "$release_dir"
  else
    echo "Release stopped; inspection files remain at $release_dir" >&2
  fi
}
trap cleanup EXIT

previous_tag=$(git -C "$repo_dir" describe --tags --abbrev=0 \
  --match '[0-9]*.[0-9]*.[0-9]*' --exclude "$version" HEAD 2>/dev/null || true)
notes=$release_dir/release-notes.md
if [[ -n $previous_tag ]]; then
  echo "Generating release notes from commits after $previous_tag..."
  git -C "$repo_dir" log --no-decorate --pretty=oneline "$previous_tag..HEAD" |
    sed 's/$/  /' >"$notes"
else
  echo "Generating release notes from all commits..."
  git -C "$repo_dir" log --no-decorate --pretty=oneline HEAD |
    sed 's/$/  /' >"$notes"
fi
[[ -s $notes ]] || die "there are no commits to include in the release notes"

target=aarch64-macos
package_name=flamez-$version-$target
package_dir=$release_dir/$package_name
archive_name=$package_name.tar.gz
archive=$release_dir/$archive_name

if [[ -n $macos_archive ]]; then
  echo "Using supplied $target archive..."
  install -m 0644 "$macos_archive" "$archive"
else
  echo "Preparing and building $target at $revision on $macos_host..."
  remote_command=$(python3 - "$macos_repo" "$source_origin" \
    "$version" "$revision" "$macos_minimum" <<'PY'
import shlex
import sys
print(shlex.join(['/usr/bin/python3', '-', *sys.argv[1:]]))
PY
  )
  ssh -o BatchMode=yes -- "$macos_host" "$remote_command" \
    <"$repo_dir/tools/release_macos.py" >"$archive"
fi
python3 "$repo_dir/tools/package_macos.py" --verify "$archive" --version "$version" \
  --release-commit "$revision" >/dev/null || die "macOS archive failed validation"
tar -C "$release_dir" -xzf "$archive"
requested_minimum=$macos_minimum
macos_minimum=$(ruby -rjson -e \
  'puts JSON.parse(File.read(ARGV[0])).fetch("minimum_macos")' \
  "$package_dir/share/flamez/macos-package.json")
[[ -z $requested_minimum || $requested_minimum == "$macos_minimum" ]] ||
  die "macOS archive minimum does not match --minimum-macos"
case "$macos_minimum" in
  13.0) macos_formula=ventura ;;
  14.0) macos_formula=sonoma ;;
  15.0) macos_formula=sequoia ;;
  26.0) macos_formula=tahoe ;;
  27.0) macos_formula=golden_gate ;;
  *) die "add an exact Homebrew minimum-version mapping for macOS $macos_minimum" ;;
esac

file "$package_dir/bin/flamez" | grep -Fq 'Mach-O 64-bit arm64 executable' ||
  die "release binary is not an arm64 macOS executable"
grep -aFq "$version" "$package_dir/bin/flamez" ||
  die "release binary does not contain version $version"

(
  cd -- "$release_dir"
  sha256sum -- "$archive_name" >SHA256SUMS
)
macos_sha256=$(sha256sum "$archive")
macos_sha256=${macos_sha256%% *}

# Prepare the legacy AUR recipe in isolation, retaining its package-specific hooks.
stage=$release_dir/aur
mkdir -p "$stage"
stage_recipe() {
  python3 - "$pkgbuild" "$stage/PKGBUILD" "$version" "$1" <<'PYTHON'
import hashlib
from pathlib import Path
import re
import sys
source, destination, version, archive = sys.argv[1:]
text = Path(source).read_text()
checksum = hashlib.sha256(Path(archive).read_bytes()).hexdigest()
for field, value in (("pkgver", version), ("pkgrel", "1"), ("sha256sums", f'("{checksum}")')):
    text, count = re.subn(rf"^{field}=.*$", f"{field}={value}", text, flags=re.M)
    if count != 1:
        sys.exit(f"release.sh: expected one {field} entry in PKGBUILD")
for field, dependencies in (("depends", ("sdl3>=3.4.0", "freetype2", "libpng", "vulkan-icd-loader")),
                            ("makedepends", ("clang", "git", "libcap", "pkgconf", "zig"))):
    pattern = rf"^{field}=\((.*?)\)"
    match = re.search(pattern, text, re.M | re.S)
    if match is None:
        sys.exit(f"release.sh: expected a literal {field} array in PKGBUILD")
    body = match[1]
    # SDL must meet the renderer API minimum, even in an already migrated recipe.
    if field == "depends":
        body = re.sub(r"(?<![\w-])sdl3(?:[<>=]+[\d.]+)?(?![\w-])", "sdl3>=3.4.0", body)
    for dependency in dependencies:
        if not re.search(rf"(?<![\w-]){re.escape(dependency)}(?![\w-])", body):
            body += f'\n  "{dependency}"'
    text = text[:match.start(1)] + body.rstrip() + "\n" + text[match.end(1):]
text = re.sub(r"[ \t]+-Dmsaa=\S+", "", text)
text = re.sub(r"[ \t]+-Dversion=\S+", "", text)
text = re.sub(r"\bzig build\b", 'zig build -Dversion="$pkgver"', text)
# The SDL/font migration added license notices that older recipes omit.
if '"zig-out/share/flamez/licenses"' not in text:
    text, count = re.subn(r"^(package\(\) \{\n  cd [^\n]+\n)", r'\1'
        '  install -d "${pkgdir}/usr/share/flamez"\n'
        '  cp -R "zig-out/share/flamez/licenses" "${pkgdir}/usr/share/flamez/"\n', text, flags=re.M)
    if count != 1:
        sys.exit("release.sh: cannot add license installation to PKGBUILD's package()")
Path(destination).write_text(text)
PYTHON
}

# A local archive lets makepkg install missing dependencies and run build/check
# before a release tag or package repository is changed.
source_archive=$stage/$version.tar.gz
git -C "$repo_dir" archive --format=tar.gz --prefix="flamez-$version/" "$revision" >"$source_archive"
stage_recipe "$source_archive"
echo "Installing missing Linux build dependencies and checking the AUR package..."
(
  cd -- "$stage"
  export PKGDEST="$stage" SRCDEST="$stage" BUILDDIR="$stage" LOGDEST="$stage"
  makepkg --syncdeps --force --cleanbuild --check --noconfirm
  makepkg --printsrcinfo >.SRCINFO
)
python3 -B -m unittest discover -s "$repo_dir/tests" -p 'test_*.py'

staged_formula=$release_dir/flamez.rb
install -m 0644 "$formula" "$staged_formula"
ruby - "$staged_formula" "$macos_formula" <<'RUBY'
path, minimum = ARGV
text = File.read(path)
text = text.gsub(/^  depends_on macos:.*$/, "  depends_on macos: :#{minimum}")
abort "Homebrew formula has no macOS requirement" unless text.include?("  depends_on macos: :#{minimum}")
%w[sdl3 freetype libpng].each do |name|
  text.sub!("  def install", "  depends_on \"#{name}\"\n\n  def install") unless
    text.match?(/^  depends_on "#{name}"/)
end
File.write(path, text)
RUBY
download_url=https://github.com/${source_origin#https://github.com/}/releases/download/$version
sed -Ei "s|^  version \".*\"|  version \"$version\"|" "$staged_formula"
sed -Ei "s|^  url \".*\"|  url \"$download_url/$archive_name\"|" "$staged_formula"
sed -Ei "s|^  sha256 \".*\"|  sha256 \"$macos_sha256\"|" "$staged_formula"
sed -Ei \
  '/^  disable! date: "[0-9-]+", because: "the first Homebrew release has not been published"$/d' \
  "$staged_formula"
ruby -c "$staged_formula" >/dev/null

if $check_only; then
  output=$repo_dir/zig-out/release
  mkdir -p "$output"
  install -m 0644 "$archive" "$release_dir/SHA256SUMS" "$staged_formula" "$output/"
  install -m 0644 "$stage/PKGBUILD" "$stage/.SRCINFO" "$output/"
  package_list=$(cd -- "$stage" && PKGDEST="$stage" makepkg --packagelist)
  [[ -n $package_list ]] || die "makepkg did not report any package artifacts"
  while IFS= read -r package; do
    install -m 0644 "$package" "$output/"
  done <<<"$package_list"
  echo "Release checks passed; packages and recipes are in $output. Nothing was published."
  exit 0
fi

echo "Tagging $version and pushing it to GitHub..."
git -C "$repo_dir" tag "$version"
git -C "$repo_dir" push origin "refs/tags/$version"

echo "Creating a draft GitHub release..."
gh release create "$version" "$archive" "$release_dir/SHA256SUMS" \
  --repo "$github_repo" \
  --draft \
  --verify-tag \
  --title "Flamez $version" \
  --notes-file "$notes"

source_url=https://github.com/$github_repo/archive/refs/tags/$version.tar.gz
echo "Downloading the tagged source archive..."
curl --fail --location --silent --show-error \
  --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$source_archive" "$source_url"
stage_recipe "$source_archive"
(
  cd -- "$stage"
  SRCDEST="$stage" makepkg --verifysource
  makepkg --printsrcinfo >.SRCINFO
)

echo "Updating the AUR package..."
install -m 0644 "$stage/PKGBUILD" "$pkgbuild"
install -m 0644 "$stage/.SRCINFO" "$aur_dir/.SRCINFO"

(
  cd -- "$aur_dir"
  git diff --check
  git add -- PKGBUILD .SRCINFO
  git commit -m "Publish version $version"
  git push
)

echo "Updating the Homebrew tap..."
install -m 0644 "$staged_formula" "$formula"

(
  cd -- "$tap_dir"
  git diff --check
  git add -- "$formula_path"
  git commit -m "Publish Flamez version $version"
  git push
)

echo "Publishing the GitHub release..."
gh release edit "$version" --repo "$github_repo" --draft=false

echo "Published Flamez $version to GitHub, the AUR, and Homebrew."
