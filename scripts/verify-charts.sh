#!/usr/bin/env bash
set -euo pipefail

# Verifica todos os consumers do common-chart contra a versão publicada no GHCR.
# Uso: ./scripts/verify-charts.sh (a partir da raiz do repo)
#
# O common-chart é publicado como artefato OCI pelo workflow
# .github/workflows/publish-common-chart.yml (ver charts/common-chart/README.md).
# Cada consumer pina a versão no Chart.lock; este script resolve as
# dependências (helm dependency build) e renderiza (helm template) dentro de
# uma cópia temporária, então a árvore de trabalho permanece limpa.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONSUMERS=(apps/payroll apps/payroll-front apps/landing-page apps/personal-landing-page apps/copilot-api apps/sistema-estoque apps/hermes-agent archived/explana-app/api archived/explana-app/front archived/video-extract/api archived/video-extract/front)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== helm lint charts/common-chart/ =="
helm lint charts/common-chart/

failures=()
for dir in "${CONSUMERS[@]}"; do
  name="$(basename "$dir")"
  echo "== $dir =="

  work="$TMP/$dir"
  mkdir -p "$(dirname "$work")"
  cp -R "$dir" "$work"

  if ! helm dependency build "$work" >/dev/null; then
    echo "FAIL: $dir (dependency build)"
    failures+=("$dir (dependency build)")
    continue
  fi

  if ! helm template "$name" "$work" > /dev/null; then
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
