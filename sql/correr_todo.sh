#!/bin/bash
# Ejecuta todo el TP en orden y guarda la salida de cada script en salidas/
export PGPASSWORD=1234 PATH="/c/Program Files/PostgreSQL/18/bin:$PATH"
cd "$(dirname "$0")"
for f in 01_construccion 02_validaciones 03_hidrografia 04_accesibilidad 05_riesgo_hidrico 06_funciones 07_calles 08_suelo 09_consulta_agregada 10_problema; do
  s=$(date +%s)
  psql -U postgres -h localhost -d tp2_bdg -v ON_ERROR_STOP=1 -f $f.sql > salidas/$f.txt 2>&1
  rc=$?
  echo "$f rc=$rc $(( $(date +%s) - s ))s"
  [ $rc -ne 0 ] && { tail -5 salidas/$f.txt; exit 1; }
done
echo FIN
