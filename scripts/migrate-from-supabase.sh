#!/usr/bin/env bash
# Migra os schemas de aplicação (public=TaskMe, minhaincorp=corretor) do
# Supabase para o Postgres local (container hermes-postgres). Idempotente o
# bastante para rodar de novo: o restore é num banco limpo recém-criado.
#
# Uso:
#   SUPABASE_URL='postgresql://postgres:SENHA@db.xxx.supabase.co:5432/postgres' \
#   ./scripts/migrate-from-supabase.sh
#
# Lê o destino do ./.env (POSTGRES_*). Não toca nos .env dos produtos — o
# repoint do DATABASE_URL é um passo manual do runbook (ver README).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERRO: .env não encontrado (copie de .env.example)"; exit 1; }
set -a; . ./.env; set +a
: "${SUPABASE_URL:?defina SUPABASE_URL (origem) no ambiente}"

PGV=postgres:17
DUMP_DIR=dumps
mkdir -p "$DUMP_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
DUMP="$DUMP_DIR/supabase_$STAMP.sql"

echo ">> 1/3 Dump do Supabase (schemas public + minhaincorp)…"
docker run --rm --network host -e PGPASSWORD_UNUSED=1 "$PGV" \
  pg_dump "$SUPABASE_URL" \
    --no-owner --no-acl \
    --schema=public --schema=minhaincorp \
  > "$DUMP"
echo "   dump salvo em $DUMP ($(wc -l < "$DUMP") linhas)"

echo ">> 2/3 Restore no Postgres local (db=$POSTGRES_DB)…"
# Banco de destino é descartável: zera os schemas de aplicação antes do
# restore para o CREATE SCHEMA do dump não colidir (idempotente em re-runs).
docker exec -i hermes-postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "DROP SCHEMA IF EXISTS minhaincorp CASCADE; DROP SCHEMA IF EXISTS public CASCADE;"
docker exec -i hermes-postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$DUMP"

echo ">> 3/3 Conferência de contagem de linhas…"
docker exec -i hermes-postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    SELECT schemaname, relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname IN ('public','minhaincorp')
    ORDER BY 1,2;"

echo ">> OK. Próximo passo: repointar o DATABASE_URL dos produtos (ver README)."
