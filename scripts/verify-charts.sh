#!/usr/bin/env bash
set -euo pipefail

# Refresh vendored deps and verify every common-chart consumer.
# Usage: ./scripts/verify-charts.sh (run from repo root)
#
# Content-aware vendoring: source charts are packaged once per run. A vendored
# tgz is replaced only when its content differs, or when a version change
# requires `helm dependency update` to regenerate Chart.lock; unchanged
# sibling deps keep their existing bytes. Re-running with no source changes
# leaves every vendored tgz byte-identical, so verify runs do not churn git.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONSUMERS=(payroll payroll-front landing-page personal-landing-page copilot-api sistema-estoque archived/explana-app/api archived/explana-app/front archived/video-extract/api archived/video-extract/front)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== helm lint common-chart/ =="
helm lint common-chart/

package_chart() { # $1 chart dir; prints packaged tgz path
  local out f
  out="$(mktemp -d "$TMP/pkg.XXXXXX")"
  helm package "$1" -d "$out" >/dev/null
  for f in "$out"/*.tgz; do [ -e "$f" ] || continue; printf '%s' "$f"; return 0; done
  return 1
}
pkg="$(package_chart common-chart)" || { echo "FAIL: could not package common-chart"; exit 1; }
pkg_name="$(basename "$pkg")"
mysql_pkg="$(package_chart sistema-estoque/charts/mysql-chart)" || { echo "FAIL: could not package mysql-chart"; exit 1; }
mysql_pkg_name="$(basename "$mysql_pkg")"
mkdir -p "$TMP/pkg-content" "$TMP/mysql-content"
tar -xzf "$pkg" -C "$TMP/pkg-content"
tar -xzf "$mysql_pkg" -C "$TMP/mysql-content"

find_tgz() { # $1 charts dir, $2 dep name
  local f
  for f in "$1/$2"-*.tgz; do [ -e "$f" ] || continue; printf '%s' "$f"; return 0; done
}
content_matches() { # $1 tgz, $2 reference content dir
  rm -rf "$TMP/compare"; mkdir -p "$TMP/compare"
  tar -xzf "$1" -C "$TMP/compare" 2>/dev/null || return 1
  diff -rq "$TMP/compare" "$2" >/dev/null 2>&1
}
finalize_dep() { # $1 consumer dir, $2 dep, $3 pkg, $4 pkg_name, $5 content dir, $6 saved pre-update tgz (may be empty)
  local dir="$1" dep="$2" new_pkg="$3" pn="$4" content="$5" old="$6" existing
  existing="$(find_tgz "$dir/charts" "$dep")"
  if [ -n "$existing" ] && [ "$(basename "$existing")" = "$pn" ] && content_matches "$existing" "$content"; then
    if [ -n "$old" ] && [ "$(basename "$old")" = "$pn" ] && content_matches "$old" "$content"; then
      cmp -s "$old" "$existing" || cp -f "$old" "$existing"
    fi
    return 0
  fi
  cp -f "$new_pkg" "$dir/charts/$pn"
}

failures=()
for dir in "${CONSUMERS[@]}"; do
  name="$(basename "$dir")"
  echo "== $dir =="

  common_existing="$(find_tgz "$dir/charts" common-chart)"
  common_need_cp=false
  common_need_update=false
  if [ -n "$common_existing" ] && [ "$(basename "$common_existing")" = "$pkg_name" ]; then
    content_matches "$common_existing" "$TMP/pkg-content" || common_need_cp=true
  else
    common_need_update=true
  fi

  mysql_existing=""
  mysql_need_cp=false
  mysql_need_update=false
  if [ "$dir" = "sistema-estoque" ]; then
    mysql_existing="$(find_tgz "$dir/charts" mysql-chart)"
    if [ -n "$mysql_existing" ] && [ "$(basename "$mysql_existing")" = "$mysql_pkg_name" ]; then
      content_matches "$mysql_existing" "$TMP/mysql-content" || mysql_need_cp=true
    else
      mysql_need_update=true
    fi
  fi

  if [ "$common_need_update" = true ] || [ "$mysql_need_update" = true ]; then
    echo "   regenerating dependencies (version change)"
    mkdir -p "$TMP/old"
    old_common=""; old_mysql=""
    if [ -n "$common_existing" ]; then old_common="$TMP/old/$(basename "$common_existing")"; cp -f "$common_existing" "$old_common"; fi
    if [ -n "$mysql_existing" ]; then old_mysql="$TMP/old/$(basename "$mysql_existing")"; cp -f "$mysql_existing" "$old_mysql"; fi
    if ! helm dependency update "$dir" >/dev/null; then
      echo "FAIL: $dir (dependency update)"
      failures+=("$dir (dependency update)")
      continue
    fi
    finalize_dep "$dir" common-chart "$pkg" "$pkg_name" "$TMP/pkg-content" "$old_common"
    if [ "$dir" = "sistema-estoque" ]; then
      finalize_dep "$dir" mysql-chart "$mysql_pkg" "$mysql_pkg_name" "$TMP/mysql-content" "$old_mysql"
    fi
  else
    if [ "$common_need_cp" = true ]; then
      echo "   updating vendored $pkg_name (content changed)"
      cp -f "$pkg" "$common_existing"
    fi
    if [ "$mysql_need_cp" = true ]; then
      echo "   updating vendored $mysql_pkg_name (content changed)"
      cp -f "$mysql_pkg" "$mysql_existing"
    fi
  fi

  if helm dependency list "$dir" 2>/dev/null | awk 'NR>1' | grep -Eq "missing|wrong version"; then
    echo "FAIL: $dir (dependency list)"
    failures+=("$dir (dependency list)")
    continue
  fi

  if ! helm template "$name" "$dir" > /dev/null; then
    echo "FAIL: $dir (template)"
    failures+=("$dir (template)")
    continue
  fi
  echo "OK: $dir"
done

echo ""
echo "== summary =="
if [ "${#failures[@]}" -eq 0 ]; then
  echo "All ${#CONSUMERS[@]} consumers verified."
else
  echo "Failures (${#failures[@]} of ${#CONSUMERS[@]}):"
  for f in "${failures[@]}"; do echo "  - $f"; done
  exit 1
fi
