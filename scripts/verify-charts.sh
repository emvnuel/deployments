#!/usr/bin/env bash
set -euo pipefail

# Verifica todos os charts do repo (apps/, charts/, platform/) e valida o YAML
# cru de platform/postgres. Uso: ./scripts/verify-charts.sh [--archived]
#
# A lista de charts é derivada via find (nada hardcoded); archived/ só entra
# com --archived. Para cada chart o script copia para um tmp, remove .tgz
# locais, roda helm dependency build (common-chart via OCI/GHCR, wrappers de
# platform via repo upstream), helm lint e helm template — a árvore de
# trabalho permanece limpa.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_ARCHIVED=0
if [ "${1:-}" = "--archived" ]; then WITH_ARCHIVED=1; fi

charts=()
while IFS= read -r dir; do
  charts+=("$dir")
done < <(find apps charts platform -name Chart.yaml -print | xargs -n1 dirname | sort)
if [ "$WITH_ARCHIVED" -eq 1 ]; then
  while IFS= read -r dir; do
    charts+=("$dir")
  done < <(find archived -name Chart.yaml -print | xargs -n1 dirname | sort)
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=()
for dir in "${charts[@]}"; do
  name="$(basename "$dir")"
  echo "== $dir =="

  work="$TMP/$dir"
  mkdir -p "$(dirname "$work")"
  cp -R "$dir" "$work"
  rm -f "$work"/charts/*.tgz

  if ! helm dependency build "$work" >/dev/null; then
    echo "FAIL: $dir (dependency build)"
    failures+=("$dir (dependency build)")
    continue
  fi

  if ! helm lint "$work" >/dev/null; then
    echo "FAIL: $dir (lint)"
    failures+=("$dir (lint)")
    continue
  fi

  if ! helm template "$name" "$work" >/dev/null; then
    echo "FAIL: $dir (template)"
    failures+=("$dir (template)")
    continue
  fi

  echo "OK: $dir"
done

# Directory app: manifests crus não passam pelo helm; valida a sintaxe YAML.
echo "== platform/postgres (YAML cru) =="
if command -v ruby >/dev/null 2>&1; then
  if ruby -ryaml -e 'Dir.glob("platform/postgres/**/*.y*ml").each { |f| YAML.load_stream(File.read(f)) }'; then
    echo "OK: platform/postgres"
  else
    echo "FAIL: platform/postgres (YAML)"
    failures+=("platform/postgres (YAML)")
  fi
else
  echo "SKIP: ruby não encontrado; validação de YAML cru ignorada"
fi

echo ""
echo "== summary =="
if [ "${#failures[@]}" -eq 0 ]; then
  echo "All ${#charts[@]} charts verified."
else
  echo "Failures (${#failures[@]}):"
  for f in "${failures[@]}"; do echo "  - $f"; done
  exit 1
fi
