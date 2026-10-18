# archived/

Charts e manifests **congelados** — não recebem deploy nem entram na
verificação padrão do `scripts/verify-charts.sh` (use `--archived` para incluí-los).

Conteúdo:

- `explana-app/` — API/front (common-chart 0.2.0) + MongoDB (StatefulSet/PVC).
- `video-extract/` — API/front (common-chart 0.2.0).

Regras:

- Não crie Applications do ArgoCD apontando para cá.
- Mudanças aqui só por necessidade histórica/arqueológica; prefira deixar congelado.
- Se um app for reativado, mova-o para `apps/` e crie `argocd/apps/<nome>.yaml`.
