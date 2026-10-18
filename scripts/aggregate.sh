#!/usr/bin/env bash
# 聚合 CairnPack 各组件的 GitHub Release。
#
#   scripts/aggregate.sh release <CalVer> [--dry-run]
#     读取子模块指针，在每个组件仓库中找到 tag 指向该提交（或提交的树相同）的正式 Release，
#     下载全部附件、生成 SHA256SUMS.txt，创建聚合 Release（tag 为 CalVer，例如 2026.10.18）。
#     找不到对应 Release 时失败，并指出是哪个组件。
#
#   scripts/aggregate.sh nightly [--dry-run]
#     收集各组件滚动预发布 `nightly` 的附件；组件还没有 nightly 时回退到它的 latest 正式版。
#     生成 nightly-manifest.json（记录每个组件的 tag 与提交 sha），只有当它与上一次聚合 nightly
#     的 manifest 不同才发布滚动预发布 `nightly`（--latest=false）。
#
# --dry-run：只收集、校验并生成正文，不创建 tag 或 Release。
#
# 环境变量：
#   GH_TOKEN  gh 使用的令牌（workflow 中为 GITHUB_TOKEN）。组件仓库都是公开的，只读即可。
#   REPO      聚合仓库，默认 $GITHUB_REPOSITORY 或 CairnPack/Codei18n-All。
#   TARGET    读取子模块指针、打 tag 的提交，默认 HEAD。
#   OUT_DIR   附件输出目录，默认 dist。
#   GITHUB_OUTPUT / GITHUB_STEP_SUMMARY  在 Actions 中运行时写入输出与摘要。
set -euo pipefail

# 名称|仓库|子模块路径
COMPONENTS=(
  "core|CairnPack/Codei18n|Codei18n"
  "IDEA 插件|CairnPack/Codei18n-IDEA|Codei18n-IDEA"
  "Desktop|CairnPack/Codei18nDesktop|Codei18nDesktop"
)
# 有子模块但不在聚合范围内的组件。
EXCLUDED=(
  "VS Code 扩展|CairnPack/Codei18n-VSC|Codei18n-VSC"
)
# 聚合 Release 自己生成的文件名，组件附件与之重名时加仓库名前缀。
RESERVED=(SHA256SUMS.txt nightly-manifest.json)

REPO=${REPO:-${GITHUB_REPOSITORY:-CairnPack/Codei18n-All}}
TARGET=$(git rev-parse "${TARGET:-HEAD}")
OUT=${OUT_DIR:-dist}
WORK="${OUT}.work"
SERVER=https://github.com

die() { echo "::error::$*" >&2; exit 1; }
output() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$1" >> "$GITHUB_STEP_SUMMARY"; fi; }

# retry <命令...>：网络偶发错误时最多重试 3 次。
retry() {
  local i
  for i in 1 2 3; do
    if "$@"; then return 0; fi
    [[ $i -lt 3 ]] && sleep $((i * 5))
  done
  return 1
}

pointer() {
  local sha
  sha=$(git ls-tree "$TARGET" -- "$1" | awk '$2 == "commit" { print $3 }')
  [[ -n "$sha" ]] || die "在 ${TARGET:0:7} 中找不到子模块 $1"
  echo "$sha"
}

# commit_of <仓库> <ref>：输出 "<提交 sha> <树 sha>"
commit_of() {
  local out
  out=$(retry gh api "repos/$1/commits/$2" --jq '"\(.sha) \(.commit.tree.sha)"') || die "无法读取 $1 的提交 $2"
  [[ "$out" =~ ^[0-9a-f]{40}\ [0-9a-f]{40}$ ]] || die "无法解析 $1 的提交 $2：$out"
  echo "$out"
}

prepare_dirs() {
  rm -rf "$OUT" "$WORK"
  mkdir -p "$OUT" "$WORK"
}

# collect <仓库> <tag>：下载 Release 的全部附件，用组件自带的校验文件核对，再平铺到 $OUT。
# 重名的附件加 "<仓库名>-" 前缀；改名记录追加到 $WORK/renames。
collect() {
  local repo=$1 tag=$2 short=${1#*/} dir file name sums
  dir="$WORK/$short"
  mkdir -p "$dir"
  retry gh release download "$tag" -R "$repo" -D "$dir" --clobber > /dev/null
  shopt -s nullglob
  local files=("$dir"/*)
  [[ ${#files[@]} -gt 0 ]] || die "$repo 的 Release $tag 没有附件"
  for sums in "$dir"/*.sha256 "$dir"/SHA256SUMS.txt; do
    [[ -f "$sums" ]] || continue
    (cd "$dir" && sha256sum --check --quiet "$(basename "$sums")") \
      || die "$repo 的 Release $tag：附件与 $(basename "$sums") 不符"
  done
  for file in "${files[@]}"; do
    name=$(basename "$file")
    if [[ -e "$OUT/$name" ]] || printf '%s\n' "${RESERVED[@]}" | grep -qxF "$name"; then
      echo "$repo|$name|$short-$name" >> "$WORK/renames"
      name="$short-$name"
    fi
    [[ ! -e "$OUT/$name" ]] || die "附件重名：$name"
    cp "$file" "$OUT/$name"
    echo "$repo|$tag|$name" >> "$WORK/assets"
  done
  shopt -u nullglob
}

write_sums() {
  (cd "$OUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS.txt -printf '%f\n' | LC_ALL=C sort \
    | while IFS= read -r f; do sha256sum -- "$f"; done | sed 's/ \*/  /' > SHA256SUMS.txt)
}

# 附件清单（Markdown 表格）
assets_table() {
  echo "| 附件 | 来源 |"
  echo "| --- | --- |"
  local repo tag name
  while IFS='|' read -r repo tag name; do
    echo "| \`$name\` | [${repo#*/} $tag]($SERVER/$repo/releases/tag/$tag) |"
  done < "$WORK/assets"
  echo "| \`SHA256SUMS.txt\` | 以上全部附件的 SHA-256（聚合时生成） |"
  if [[ -s "$WORK/renames" ]]; then
    echo
    local from to
    while IFS='|' read -r repo from to; do
      echo "- \`$to\`：文件名与聚合 Release 中的其他文件冲突，由 ${repo#*/} 的 \`$from\` 改名而来，内容未改动。"
    done < "$WORK/renames"
  fi
}

publish_assets() {
  local tag=$1
  gh release view "$tag" -R "$REPO" --json assets --jq '.assets[].name' | while IFS= read -r name; do
    gh release delete-asset "$tag" "$name" -R "$REPO" --yes
  done
  gh release upload "$tag" "$OUT"/* -R "$REPO" --clobber
}

cmd_release() {
  local version=${1:-} dry=${2:-}
  [[ "$version" =~ ^[0-9]{4}\.(0?[1-9]|1[0-2])\.(0?[1-9]|[12][0-9]|3[01])(\.[0-9]+)?$ ]] \
    || die "版本号应为日期 CalVer，例如 2026.10.18（同一天再次发布用 2026.10.18.1），实际为：$version"
  prepare_dirs
  : > "$WORK/assets"; : > "$WORK/renames"
  local cv rows="" notes="" entry name repo path ptr ptree tags tag c t exact found match_note

  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name repo path <<< "$entry"
    ptr=$(pointer "$path")
    ptree=$(commit_of "$repo" "$ptr" | cut -d' ' -f2)
    tags=$(retry gh api "repos/$repo/releases?per_page=100" --paginate \
      --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')
    exact="" found="" match_note=""
    for tag in $tags; do
      cv=$(commit_of "$repo" "$tag"); read -r c t <<< "$cv"
      if [[ "$c" == "$ptr" ]]; then exact=$tag; found=$tag; break; fi
      if [[ -z "$found" && "$t" == "$ptree" ]]; then
        found=$tag
        match_note="${name}：子模块指针 \`${ptr:0:7}\` 与 Release tag \`$tag\` 指向的提交 \`${c:0:7}\` 不同，但两者的树相同（\`${t:0:7}\`），内容一致"
        if gh api "repos/$repo/commits/$c" --jq '.parents[].sha' | grep -qxF "$ptr"; then
          match_note+="；\`${c:0:7}\` 是以 \`${ptr:0:7}\` 为父提交的合并提交"
        fi
        match_note+="。"
      fi
    done
    [[ -n "$found" ]] || die "组件 ${name}（$repo）：找不到 tag 指向子模块指针 ${ptr:0:7}（或树相同）的正式 Release"
    [[ -n "$exact" ]] && match_note=""
    echo "${name}：$repo $found（指针 ${ptr:0:7}）"
    collect "$repo" "$found"
    rows+="| ${name}（[${repo#*/}]($SERVER/$repo)） | ${found} | [\`${ptr:0:7}\`]($SERVER/$repo/commit/$ptr) | [${found}]($SERVER/$repo/releases/tag/$found) |"$'\n'
    [[ -z "$match_note" ]] || notes+="- ${match_note}"$'\n'
  done
  for entry in "${EXCLUDED[@]}"; do
    IFS='|' read -r name repo path <<< "$entry"
    ptr=$(pointer "$path")
    rows+="| ${name}（[${repo#*/}]($SERVER/$repo)） | 未包含 | [\`${ptr:0:7}\`]($SERVER/$repo/commit/$ptr) | — |"$'\n'
  done
  write_sums

  {
    echo "CodeI18n 聚合发行版 **${version}**：[${REPO#*/}]($SERVER/$REPO) 在提交 [\`${TARGET:0:7}\`]($SERVER/$REPO/commit/$TARGET) 上的一组子模块指针快照。"
    echo
    echo "各组件用 semver 独立发版；聚合版用日期 CalVer 命名，只表示这一组子模块指针，不跟随任何组件的版本号。附件原样取自各组件的正式 Release。"
    echo
    echo "## 组件"
    echo
    echo "| 组件 | 版本 | 子模块指针提交 | 组件 Release |"
    echo "| --- | --- | --- | --- |"
    printf '%s' "$rows"
    echo
    echo "VS Code 扩展不在本次聚合范围内，未包含。"
    if [[ -n "$notes" ]]; then
      echo
      echo "## 指针核对"
      echo
      printf '%s' "$notes"
    fi
    echo
    echo "## 附件"
    echo
    assets_table
    echo
    echo "校验：\`sha256sum -c SHA256SUMS.txt\`；PowerShell 中用 \`Get-FileHash <文件> -Algorithm SHA256\` 与 SHA256SUMS.txt 对照。"
  } > "$WORK/notes.md"
  summary "$WORK/notes.md"

  if [[ "$dry" == --dry-run ]]; then
    echo "dry-run：不创建 Release。附件：" && ls "$OUT"
    return
  fi
  if gh api "repos/$REPO/git/ref/tags/$version" > /dev/null 2>&1; then
    die "tag $version 已存在，请换一个版本号（同一天再次发布用 ${version}.1）"
  fi
  gh release create "$version" "$OUT"/* -R "$REPO" --target "$TARGET" \
    --title "$version" --notes-file "$WORK/notes.md" --latest
}

cmd_nightly() {
  local dry=${1:-}
  prepare_dirs
  : > "$WORK/assets"; : > "$WORK/renames"
  local cv entry name repo path source tag c t comma="" rows="" fallback=""
  local manifest="$OUT/nightly-manifest.json"

  # 1. 先只用 API 生成 manifest，便于在下载附件前判断是否需要发布。
  {
    echo '{'
    echo '  "components": ['
    for entry in "${COMPONENTS[@]}"; do
      IFS='|' read -r name repo path <<< "$entry"
      if gh release view nightly -R "$repo" > /dev/null 2>&1; then
        source=nightly; tag=nightly
      else
        source=latest
        tag=$(gh api "repos/$repo/releases/latest" --jq .tag_name 2> /dev/null) \
          || die "组件 ${name}（$repo）既没有 nightly 预发布，也没有正式 Release"
      fi
      cv=$(commit_of "$repo" "$tag"); read -r c t <<< "$cv"
      printf '%s    {"repo": "%s", "source": "%s", "tag": "%s", "commit": "%s"}' "$comma" "$repo" "$source" "$tag" "$c"
      comma=$',\n'
      echo "$name|$repo|$source|$tag|$c" >> "$WORK/components"
    done
    echo
    echo '  ]'
    echo '}'
  } > "$manifest"
  cat "$manifest"

  local changed=true
  mkdir -p "$WORK/previous"
  if gh release download nightly -R "$REPO" -p nightly-manifest.json -D "$WORK/previous" > /dev/null 2>&1 \
    && cmp -s "$manifest" "$WORK/previous/nightly-manifest.json"; then
    changed=false
  fi
  output changed "$changed"
  if [[ "$changed" == false && "$dry" != --dry-run ]]; then
    echo "各组件的 tag 与提交和上一次聚合 nightly 相同，跳过发布。" | tee "$WORK/notes.md"
    summary "$WORK/notes.md"
    return
  fi

  # 2. 下载附件并生成正文。
  while IFS='|' read -r name repo source tag c; do
    collect "$repo" "$tag"
    rows+="| ${name}（[${repo#*/}]($SERVER/$repo)） | ${source} | [${tag}]($SERVER/$repo/releases/tag/$tag) | [\`${c:0:7}\`]($SERVER/$repo/commit/$c) |"$'\n'
    [[ "$source" == nightly ]] || fallback+="- ${name} 还没有 nightly 预发布，回退到它的 latest 正式版 ${tag}。"$'\n'
  done < "$WORK/components"
  write_sums

  {
    echo "CodeI18n 聚合 nightly：收集各组件滚动预发布 \`nightly\` 的附件，自动生成，不是正式版。"
    echo
    echo "| 组件 | 来源 | tag | 提交 |"
    echo "| --- | --- | --- | --- |"
    printf '%s' "$rows"
    if [[ -n "$fallback" ]]; then
      echo
      printf '%s' "$fallback"
    fi
    echo
    echo "VS Code 扩展不在聚合范围内，未包含。"
    echo
    echo "## 附件"
    echo
    assets_table
    echo "| \`nightly-manifest.json\` | 各组件的 tag 与提交 sha；下次聚合时与之比较，相同则跳过发布 |"
  } > "$WORK/notes.md"
  summary "$WORK/notes.md"

  if [[ "$dry" == --dry-run ]]; then
    echo "dry-run：不发布（manifest 与上次相比 changed=$changed）。附件：" && ls "$OUT"
    return
  fi

  local title
  title="Nightly $(TZ=Asia/Taipei date +%Y-%m-%d) (${TARGET:0:7})"
  # 用 API 创建或强制移动 nightly tag 到 TARGET。
  if gh api "repos/$REPO/git/ref/tags/nightly" > /dev/null 2>&1; then
    gh api -X PATCH "repos/$REPO/git/refs/tags/nightly" -f sha="$TARGET" -F force=true > /dev/null
  else
    gh api -X POST "repos/$REPO/git/refs" -f ref=refs/tags/nightly -f sha="$TARGET" > /dev/null
  fi
  if gh release view nightly -R "$REPO" > /dev/null 2>&1; then
    gh release edit nightly -R "$REPO" --title "$title" --notes-file "$WORK/notes.md" --prerelease --latest=false
    publish_assets nightly
  else
    gh release create nightly "$OUT"/* -R "$REPO" --verify-tag --title "$title" \
      --notes-file "$WORK/notes.md" --prerelease --latest=false
  fi
}

case "${1:-}" in
  release) shift; cmd_release "$@" ;;
  nightly) shift; cmd_nightly "$@" ;;
  *) die "用法：$0 release <CalVer> [--dry-run] | nightly [--dry-run]" ;;
esac
