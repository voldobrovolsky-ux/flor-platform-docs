#!/usr/bin/env bash
# check-docs.sh — валидатор документации Flōr Group.
#
# Реализует исполняемую сторону гейтов FLOR-ADS §9 в объёме, объявленном
# в guides/gates.md (карта гейтов). Валидатор реализует ДЕЙСТВУЮЩИЙ текст
# стандарта; поправки decisions/ADR-0001 вступают в силу только после принятия.
#
# Режимы:
#   --project    репозиторий продукта (структура §3/§4, каталог, контракты…)
#   --ecosystem  репозиторий flor-platform-docs (заголовки, самодостаточность,
#                парность ru/en при наличии --base)
#   --base REF   база диффа для проверок «в том же изменении» (контракт↔журнал,
#                парность ru/en); без неё дифф-проверки пропускаются с пометкой
#
# Выход: 0 — все блокирующие проверки зелёные; 1 — есть блокирующие нарушения.
# Предупреждения (§9: «предупреждение») на код выхода не влияют.
set -uo pipefail

MODE=""
BASE=""
ROOT="."
FAILS=0
WARNS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   MODE="project" ;;
    --ecosystem) MODE="ecosystem" ;;
    --base)      shift; BASE="${1:-}" ;;
    --root)      shift; ROOT="${1:-.}" ;;
    *) echo "неизвестный аргумент: $1"; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "укажи режим: --project | --ecosystem"; exit 2; }
cd "$ROOT"

fail() { echo "БЛОК: $*"; FAILS=$((FAILS+1)); }
warn() { echo "ПРЕДУПРЕЖДЕНИЕ: $*"; WARNS=$((WARNS+1)); }
skip() { echo "ПРОПУСК: $*"; }

# Шаблоны golden-path не проверяются: это заготовки с плейсхолдерами.
is_excluded() {
  case "$1" in
    */golden-path/skeleton/*|golden-path/skeleton/*) return 0 ;;
    */node_modules/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- заголовки
# Гейт §9: «заголовок документа валиден, status не Draft для файлов „О"».
# README.md и CLAUDE.md — точки входа, не разделы: шапка не требуется.
check_headers() {
  local scope=("$@") f front statuses
  for f in $(git ls-files "${scope[@]}" 2>/dev/null | grep '\.md$'); do
    is_excluded "$f" && continue
    case "$f" in README.md|CLAUDE.md|*/README.md) continue ;; esac
    if [ "$(head -1 "$f")" != "---" ]; then
      fail "$f: нет YAML-шапки (FLOR-ADS §7.1)"
      continue
    fi
    # статус читается только из фронт-маттера: упоминания статусов в теле
    # и код-блоках (шаблоны) — не статус файла
    front=$(awk '/^---$/{c++; next} c==1{print} c>=2{exit}' "$f")
    # у решений свой словарь статусов (FLOR-ADS §5.7), у документов — §7.2
    case "$f" in
      decisions/*|*/decisions/*) statuses='Proposed|Accepted|Superseded by ADR-[0-9]{4}|Deprecated' ;;
      *) statuses='Draft|Accepted|Superseded|Deprecated' ;;
    esac
    echo "$front" | grep -qE "^status: ($statuses)" \
      || fail "$f: нет валидного поля status (FLOR-ADS §7.2/§5.7)"
    if echo "$front" | grep -qE '^status: Draft' && [ "$MODE" = ecosystem ]; then
      warn "$f: Draft на экосистемном уровне — не является основанием ни для чего (П-2)"
    fi
  done
}

# ------------------------------------------------- структура проекта (§3/§4)
tier_of() {
  grep -oE 'flor\.group/tier: *"?[0-2]' catalog-info.yaml 2>/dev/null \
    | grep -oE '[0-2]$' || true
}

check_structure() {
  local tier; tier="$(tier_of)"
  # §2.2: нет аннотации — система читает как Tier 1 (строже), гейт каталога
  # отдельно потребует явную аннотацию.
  [ -n "$tier" ] || tier=1
  local required=(README.md CHANGELOG.md catalog-info.yaml mkdocs.yml
    docs/index.md docs/01-context.md docs/decisions)
  if [ "$tier" != 2 ]; then
    required+=(docs/02-containers.md docs/03-runtime.md docs/glossary.md
      docs/04-quality.md docs/risks.md docs/contracts/openapi.yaml
      docs/05-data.md docs/06-security.md docs/07-reliability.md
      docs/runbooks docs/08-change.md docs/09-testing.md
      docs/10-operations.md docs/11-onboarding.md)
  fi
  if [ "$tier" = 0 ]; then
    required+=(docs/contracts/asyncapi.yaml docs/contracts/pacts)
  fi
  local p
  for p in "${required[@]}"; do
    [ -e "$p" ] || fail "отсутствует обязательный для Tier $tier артефакт: $p (FLOR-ADS §4)"
    # Правило нуля: пустой файл = отсутствующий (§4)
    [ -f "$p" ] && [ ! -s "$p" ] && fail "пустой файл: $p (правило нуля, §4)"
  done
  # status не Draft для существующих «О»-файлов (статус — из фронт-маттера)
  for p in "${required[@]}"; do
    [ -f "$p" ] || continue
    case "$p" in *.md)
      awk '/^---$/{c++; next} c==1{print} c>=2{exit}' "$p" \
        | grep -qE '^status: Draft' \
        && fail "$p: обязательный артефакт в статусе Draft (§9)"
    ;; esac
  done
  return 0
}

check_catalog() {
  [ -f catalog-info.yaml ] || { fail "нет catalog-info.yaml"; return; }
  grep -q 'apiVersion: *backstage.io' catalog-info.yaml \
    || fail "catalog-info.yaml: нет apiVersion backstage.io (§5.2)"
  grep -qE '^ *owner:' catalog-info.yaml \
    || fail "catalog-info.yaml: не заполнен owner (§9)"
  grep -q 'flor.group/tier' catalog-info.yaml \
    || fail "catalog-info.yaml: нет аннотации flor.group/tier (§9)"
  # действующий §9 читается как «ключ присутствует»; явная пустота [] законна
  grep -qE '^ *dependsOn:' catalog-info.yaml \
    || fail "catalog-info.yaml: нет ключа dependsOn (§9; пустота объявляется явно: dependsOn: [])"
}

# --------------------------------------------------------------- контракты
# Гейт §9 «openapi/asyncapi валидны по схеме» — здесь структурная валидность
# (парсится как YAML, есть версионный корневой ключ). Полная схемная валидация
# — недостающая проверка, guides/gates.md раздел 5.
check_contracts() {
  local f
  for f in docs/contracts/openapi.yaml docs/contracts/asyncapi.yaml; do
    [ -f "$f" ] || continue
    python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" 2>/dev/null \
      || { fail "$f: не парсится как YAML"; continue; }
    case "$f" in
      *openapi*)  grep -qE '^openapi: *["'\'']?3\.' "$f" \
        || fail "$f: нет корневого ключа openapi: 3.x (§5.11)";;
      *asyncapi*) grep -qE '^asyncapi: *["'\'']?[23]\.' "$f" \
        || fail "$f: нет корневого ключа asyncapi (§5.12)";;
    esac
  done
}

# --------------------------------------------- «в том же изменении» (дифф)
check_increment() {
  [ -n "$BASE" ] || { skip "дифф-проверки: база не задана (--base REF)"; return; }
  local files
  files=$(git diff --name-only "$BASE"...HEAD 2>/dev/null) \
    || { skip "дифф-проверки: git diff $BASE...HEAD не выполнился"; return; }
  if echo "$files" | grep -q 'docs/contracts/' \
     && ! echo "$files" | grep -qx 'CHANGELOG.md'; then
    fail "контракт изменён без записи в CHANGELOG.md (§9, §5.22)"
  fi
}

check_pair() {
  [ -n "$BASE" ] || { skip "парность ru/en: база не задана (--base REF)"; return; }
  local files ru en
  files=$(git diff --name-only "$BASE"...HEAD 2>/dev/null) || return 0
  ru=$(echo "$files" | grep -c 'standards/ARCHITECTURE-STANDARD.ru.md' || true)
  en=$(echo "$files" | grep -c 'standards/ARCHITECTURE-STANDARD.en.md' || true)
  [ "$ru" = "$en" ] \
    || fail "языковые версии стандарта изменены не парой (§11; проверка валидатора, гейтом станет по ADR-0001)"
}

# ---------------------------------------------------------------- свежесть
check_freshness() {
  local tier limit f d age
  tier="$(tier_of)"; [ -n "$tier" ] || tier=1
  case "$tier" in 0) limit=90;; 1) limit=180;; *) limit=365;; esac
  for f in $(git ls-files 'docs/*.md' 'docs/**/*.md' 2>/dev/null); do
    is_excluded "$f" && continue
    d=$(grep -oE '^last_reviewed: *[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" \
        | grep -oE '[0-9-]{10}$' || true)
    [ -n "$d" ] || continue
    age=$(( ( $(date +%s) - $(date -d "$d" +%s 2>/dev/null || echo 0) ) / 86400 ))
    [ "$age" -le "$limit" ] \
      || warn "$f: last_reviewed $d старше лимита Tier $tier ($limit дн., §7.3)"
  done
}

# ------------------------------------------------------ самодостаточность
check_selfcontained() {
  local hits n f
  hits=$(grep -rnE 'как (сказано|описано) выше|см\. выше' --include='*.md' . \
    | grep -v '«[^»]*выше[^»]*»' | grep -v 'golden-path/skeleton' || true)
  [ -z "$hits" ] || { echo "$hits"; fail "отсылка к контексту, которого у читателя нет (guides/decompose.md)"; }
  while read -r n f; do
    case "$f" in *standards/*|*golden-path/skeleton/*|итого|total|'') continue;; esac
    [ "$n" -le 400 ] || fail "раздел разросся: $f ($n строк; норма ≤400, guides/decompose.md)"
  done < <(git ls-files '*.md' | grep -v node_modules | xargs wc -l 2>/dev/null | sed '$d')
}

# ------------------------------------------------------- уровни (двойники)
check_doclevels() {
  local FORBIDDEN='ARCHITECTURE-STANDARD|observability\.md|versioning\.md|landscape\.md|context-map\.md|sso-architecture\.md|pii-map\.md'
  local f
  for f in $(git ls-files 'docs/**' 'docs/*' 2>/dev/null | grep -Ei "$FORBIDDEN" || true); do
    grep -q 'POINTER' "$f" \
      || fail "дубль экосистемного артефакта в проектных docs/: $f (guides/doc-levels.md)"
  done
}

# --------------------------------------------------------- матрицы и узлы
check_speclint() {
  local f t p body
  for f in $(git ls-files '*.md' 2>/dev/null); do
    is_excluded "$f" && continue
    # код-блоки и упоминания в бэктиках — не содержание документа
    body=$(sed '/^```/,/^```/d' "$f")
    t=$(echo "$body" | grep -c 'Матрица переходов' || true)
    p=$(echo "$body" | grep -c 'Матрица полноты' || true)
    [ "$t" -le "$p" ] \
      || fail "$f: матриц переходов $t, матриц полноты $p (FLOR-ADS §5.6)"
    if grep -qE '^status: Accepted' "$f" \
       && echo "$body" | grep -E '\[узел\]' | grep -qv '`\[узел\]`'; then
      fail "$f: status Accepted при открытых [узел] (П-1, П-2)"
    fi
  done
}

# ------------------------------------------------------------ два контура
check_builddebug() {
  [ -f .devcontainer/devcontainer.json ] || [ -f .devcontainer.json ] \
    || fail "нет devcontainer.json — контур отладки не описан (guides/build-and-debug.md)"
  grep -rqs 'devcontainers/ci' .github/workflows/ \
    || fail "конвейер собирает вне dev-контейнера (guides/build-and-debug.md)"
}

# ------------------------------------------------------------------- запуск
if [ "$MODE" = project ]; then
  check_structure
  check_catalog
  check_headers 'docs'
  check_contracts
  check_increment
  check_freshness
  check_selfcontained
  check_doclevels
  check_speclint
  check_builddebug
else
  check_headers '*.md' 'guides' 'standards' 'decisions'
  check_selfcontained
  check_speclint
  check_pair
  check_increment
fi

echo "---"
echo "блокирующих: $FAILS, предупреждений: $WARNS"
[ "$FAILS" -eq 0 ]
