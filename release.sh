#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.2.0" >&2
}

die() {
  echo "release.sh: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || {
  usage
  exit 2
}

version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "version must use the X.Y.Z format"

for command in curl file gh git grep install makepkg mktemp ruby sed sha256sum tar zig; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aur_dir=$(cd -- "$repo_dir/../../aur/flamez" 2>/dev/null && pwd) ||
  die "AUR repository not found at $repo_dir/../../aur/flamez"
tap_dir=$(cd -- "$repo_dir/../homebrew-tap" 2>/dev/null && pwd) ||
  die "Homebrew tap not found at $repo_dir/../homebrew-tap"
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
gh auth status --hostname github.com >/dev/null 2>&1 ||
  die "GitHub CLI is not authenticated; run 'gh auth login'"
github_repo=$(cd -- "$repo_dir" && gh repo view --json nameWithOwner --jq .nameWithOwner) ||
  die "could not resolve the GitHub repository from origin"

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

release_dir=$(mktemp --directory --suffix="-flamez-$version")
trap 'rm -rf -- "$release_dir"' EXIT

previous_tag=$(git -C "$repo_dir" describe --tags --abbrev=0 \
  --match '[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)
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

echo "Running tests..."
(
  cd -- "$repo_dir"
  zig build test
)

target=aarch64-macos
zig_target=aarch64-macos.13.0
prefix=$release_dir/prefix-$target
package_name=flamez-$version-$target
package_dir=$release_dir/$package_name
archive_name=$package_name.tar.gz
archive=$release_dir/$archive_name

echo "Building $target..."
(
  cd -- "$repo_dir"
  zig build \
    --prefix "$prefix" \
    -Dtarget="$zig_target" \
    -Doptimize=ReleaseSafe \
    -Dversion="$version"
)

install -d "$package_dir/bin" "$package_dir/share/flamez"
install -m 0755 "$prefix/bin/flamez" "$package_dir/bin/flamez"
install -m 0644 \
  "$prefix/share/flamez/flamez-analysis-v1.md" \
  "$prefix/share/flamez/flamez-analysis-v1.schema.json" \
  "$package_dir/share/flamez/"
install -m 0644 "$repo_dir/README.md" "$repo_dir/LICENSE" "$package_dir/"
tar -C "$release_dir" -czf "$archive" "$package_name"

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
source_archive=$release_dir/flamez-$version-source.tar.gz
echo "Downloading the tagged source archive..."
curl --fail --location --silent --show-error \
  --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$source_archive" "$source_url"
source_sha256=$(sha256sum "$source_archive")
source_sha256=${source_sha256%% *}

echo "Updating the AUR package..."
sed -Ei "s/^pkgver=.*/pkgver=$version/" "$pkgbuild"
sed -Ei 's/^pkgrel=.*/pkgrel=1/' "$pkgbuild"
sed -Ei "s/^sha256sums=.*/sha256sums=(\"$source_sha256\")/" "$pkgbuild"

(
  cd -- "$aur_dir"
  makepkg --printsrcinfo >.SRCINFO
  makepkg
  git add -- PKGBUILD .SRCINFO
  git commit -m "Publish version $version"
  git push
)

echo "Updating the Homebrew tap..."
download_url=https://github.com/$github_repo/releases/download/$version
sed -Ei "s|^  version \".*\"|  version \"$version\"|" "$formula"
sed -Ei "s|^  url \".*\"|  url \"$download_url/$archive_name\"|" "$formula"
sed -Ei "s|^  sha256 \".*\"|  sha256 \"$macos_sha256\"|" "$formula"
sed -Ei \
  '/^  disable! date: "[0-9-]+", because: "the first Homebrew release has not been published"$/d' \
  "$formula"
ruby -c "$formula" >/dev/null

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
