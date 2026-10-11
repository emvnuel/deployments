# mysql-chart

MySQL StatefulSet with PVC for sistema-estoque. Standalone chart (not derived from
`common-chart`) because `common-chart` only renders a `Deployment` workload and this
dependency needs stable identity plus persistent storage (`kind: StatefulSet` with
`serviceName`, a `data` volume at `/var/lib/mysql`, and a companion
PersistentVolumeClaim).

> Forked from common-chart — see below; keep in sync manually.
> (Also noted in the header comments of `templates/_helpers.tpl` and
> `templates/statefulset.yaml`.)

## What is forked from common-chart (keep in sync by hand)

`templates/_helpers.tpl` is a line-for-line fork of
`common-chart/templates/_helpers.tpl`, with only the `common-chart.` prefix renamed
to `mysql-chart.` (plus minor comment-wording differences):

| mysql-chart template | common-chart counterpart | Status |
|---|---|---|
| `mysql-chart.name` | `common-chart.name` | Identical logic (`default .Chart.Name .Values.nameOverride \| trunc 63 \| trimSuffix "-"`) |
| `mysql-chart.fullname` | `common-chart.fullname` | Identical logic (common-chart has two extra comment lines about the 63-char DNS limit) |
| `mysql-chart.chart` | `common-chart.chart` | Identical logic (one-line comment wording differs) |
| `mysql-chart.labels` | `common-chart.labels` | Identical logic (`helm.sh/chart`, selector labels, version, managed-by) |
| `mysql-chart.selectorLabels` | `common-chart.selectorLabels` | Identical logic (`app.kubernetes.io/name`, `app.kubernetes.io/instance`) |

Not forked: `common-chart.serviceAccountName` and `common-chart.serviceName` have no
counterpart here — `statefulset.yaml` sets neither a `serviceAccountName` nor a
parameterized service name.

`templates/statefulset.yaml` copies these `common-chart/templates/deployment.yaml`
idioms (same shape, mysql-specific values):

1. `metadata.name: {{ include "<chart>.fullname" . }}` and
   `labels: {{- include "<chart>.labels" . | nindent 4 }}`.
2. `selector.matchLabels: {{- include "<chart>.selectorLabels" . | nindent 6 }}` and
   pod-template `labels: {{- include "<chart>.selectorLabels" . | nindent 8 }}`.
3. Container `name: {{ include "<chart>.name" . }}`.
4. `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"` plus
   `imagePullPolicy: {{ .Values.image.pullPolicy }}`.
5. Probe guards `{{- if and .Values.probes.enabled .Values.probes.livenessProbe }}`
   / `readinessProbe` with `{{- toYaml ... | nindent 12 }}` (values differ:
   `tcpSocket` on port `mysql` here vs `httpGet` in common-chart).
6. `resources: {{- toYaml .Values.resources | nindent 12 }}`.
7. `volumeMounts` / `volumes` in the same position and shape: here hardcoded to a
   `data` volume (`mountPath: /var/lib/mysql`, `persistentVolumeClaim: <fullname>-data`
   when `persistence.enabled`, else `emptyDir: {}`), where common-chart renders generic
   `{{- toYaml .Values.volumeMounts }}` / `{{- toYaml .Values.volumes }}`.

Deliberate divergences (not drift — do not "sync" these away): `kind: StatefulSet`
with `spec.serviceName`, no `serviceAccountName` / `securityContext` / `env` /
`envFrom`, hardcoded `mysql:3306` port, and the PVC-or-`emptyDir` `data` volume.

## Consolidation trigger

Do NOT refactor yet (candidate C6 was rated SPECULATIVE — one stateful workload does
not justify the abstraction). Consolidate on this trigger:

**A second stateful dependency, or the first divergence bug between the two charts —
whichever comes first.**

A "divergence bug" means a fix applied to the naming/label/probe/resource/volume
idioms in one chart that was also needed in the other (e.g. a label-selector,
truncation, or probe-guard fix).

## Consolidation options (when the trigger fires)

1. **Extract a library chart.** Move the shared named templates
   (`name`/`fullname`/`chart`/`labels`/`selectorLabels`, and optionally shared
   probe/resource/volume snippets) into a library chart that both `common-chart` and
   `mysql-chart` declare as a dependency — removes the hand-sync requirement without
   forcing stateful workloads into the `Deployment`-shaped common chart.
2. **Add a stateful workload kind to common-chart.** Parameterize the workload
   (`kind: Deployment|StatefulSet`, plus `serviceName`, per-workload volume/probe
   shapes) so `mysql-chart` becomes a values-only instance of `common-chart` —
   simpler dependency graph, but widens `common-chart`'s surface for every consumer.

## Precedent

`archived/explana-app/mongo/` (`mongo-statefulset.yaml`, `mongo-pvc.yaml`,
`mongo-service.yaml`, `mongo-configmap.yaml`) — the previous time this need was met
with raw manifests outside any chart: a Mongo `StatefulSet` with its own PVC and
service, hand-written naming/labels instead of shared helpers. This chart follows that
precedent (stateful dependency ships its own workload manifests) but upgrades it to a
proper chart with `common-chart`-compatible helpers.
