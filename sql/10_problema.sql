/* =====================================================================
   PUNTO 14 - Problema: ubicación de un
              CENTRO DE ATENCIÓN SANITARIA DE EMERGENCIA (CASE)

   METODOLOGÍA (análisis multicriterio sobre grilla hexagonal)
   1. Se discretiza el departamento en hexágonos de 750 m de lado
      (~1,46 km² c/u) con ST_HexagonGrid. El hexágono es la unidad de
      análisis: todas sus celdas vecinas están a la misma distancia y
      cubre el plano sin huecos.
   2. CRITERIOS EXCLUYENTES (la celda se descarta si no los cumple):
      E1. Fuera de la ZRH "principal" (2 km de ríos, lagunas y cauces).
          Se usa la variante principal porque la ZRH completa cubre el
          61 % del depto e incluye las 15 instalaciones de salud: como
          restricción dura dejaría fuera casi todo el territorio útil.
          La ZRH completa se usa como penalización (P3).
      E2. Sin cuerpos de agua: se resta lagunas y cauces.
      E3. Fuera de los suelos de MAYOR aptitud agrícola (IPC >= 40),
          que son las "determinadas áreas de uso agrícola" a preservar.
      E4. Superficie adecuada: luego de restar E1-E3, la celda debe
          conservar al menos 0,5 km² (50 ha) libres y continuos.
      E5. A no más de 3 km de una ruta nacional o provincial.
   3. CRITERIOS DE PUNTAJE (0 a 1, ponderados):
      Todos los tiempos se calculan con pgRouting sobre la red vial EN
      ESCENARIO DE CRECIDA (tramos cortados del punto 13): un centro de
      emergencia tiene que ser alcanzable justamente cuando hay crecida.
      P1 (45 %) Beneficio sanitario: sum(población × minutos ahorrados)
          para cada localidad, comparando su tiempo actual al HOSPITAL
          más cercano (punto 13, escenario crecida; 180 min si queda
          aislada) con el tiempo hasta la celda. Prioriza a las
          localidades peor servidas.
      P2 (25 %) Cantidad de localidades a <= 45 min por la red vial.
      P3 (15 %) 1 - fracción de la celda dentro de la ZRH completa.
      P4 (15 %) Cercanía a la ruta principal (1 en la ruta, 0 a 3 km).
   4. Se eligen los 3 mejores candidatos separados por >= 10 km
      (para no proponer tres celdas contiguas del mismo lugar).

   FUNCIONES PostGIS / pgRouting investigadas y usadas:
   ST_HexagonGrid, ST_Difference, ST_Union, ST_Intersection, ST_Area,
   ST_Dump, ST_PointOnSurface, ST_DWithin, ST_Distance, operador KNN <->,
   pgr_dijkstraCost (muchos a muchos).
   ===================================================================== */
SET search_path = entrerios, public;

/* ---------------------------------------------------------------------
   14.1 Grilla hexagonal
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r14_grilla CASCADE;
CREATE TABLE entrerios.r14_grilla AS
SELECT row_number() OVER () AS id, h.geom::geometry(Polygon, 5347) AS geom_m
FROM entrerios.departamentos d
CROSS JOIN LATERAL ST_HexagonGrid(750, d.geom_m) h
WHERE d.nombre = 'La Paz' AND ST_Within(h.geom, d.geom_m);
CREATE INDEX ON entrerios.r14_grilla USING gist (geom_m);

/* ---------------------------------------------------------------------
   14.2 Criterios excluyentes E1 - E5
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tmp_restriccion;
CREATE TEMP TABLE tmp_restriccion AS
SELECT ST_Union(g) AS g FROM (
    SELECT geom_m_principal AS g FROM entrerios.zona_riesgo_hidrico WHERE depto = 'La Paz'          -- E1
    UNION ALL
    SELECT ST_Buffer(geom_m, 0) FROM entrerios.lagunas l                                            -- E2
    WHERE ST_Intersects(l.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'))
    UNION ALL
    SELECT geom_m FROM entrerios.rios_area a
    WHERE ST_Intersects(a.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'))
    UNION ALL
    SELECT geom_m FROM entrerios.r12_suelo_lapaz WHERE ipc >= 40                                     -- E3
) x;

DROP TABLE IF EXISTS entrerios.r14_aptas;
CREATE TABLE entrerios.r14_aptas AS
WITH libre AS (
    SELECT g.id, g.geom_m,
           ST_Difference(g.geom_m, COALESCE(ST_Intersection(r.g, g.geom_m), 'POLYGON EMPTY'::geometry)) AS libre
    FROM entrerios.r14_grilla g, tmp_restriccion r
), mayor_parche AS (                                                   -- E4: mayor parche continuo
    SELECT DISTINCT ON (l.id) l.id, l.geom_m, p.geom AS parche, ST_Area(p.geom) AS area_parche
    FROM libre l CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(l.libre, 3)) p
    ORDER BY l.id, ST_Area(p.geom) DESC
)
SELECT m.id, m.geom_m, m.parche, round((m.area_parche / 1e6)::numeric, 3) AS libre_km2,
       ST_PointOnSurface(m.parche) AS sitio_m,
       rt.ref AS ruta, rt.dist AS dist_ruta_m
FROM mayor_parche m
CROSS JOIN LATERAL (
    SELECT r.ref, ST_Distance(r.geom_m, m.parche) AS dist
    FROM entrerios.rutas r WHERE r.jurisdiccion IN ('Nacional', 'Provincial')
    ORDER BY r.geom_m <-> m.parche LIMIT 1
) rt
WHERE m.area_parche >= 500000                                          -- E4: >= 0,5 km²
  AND rt.dist <= 3000;                                                 -- E5

SELECT (SELECT count(*) FROM entrerios.r14_grilla) AS celdas_totales,
       (SELECT count(*) FROM entrerios.r14_aptas)  AS celdas_aptas;

/* ---------------------------------------------------------------------
   14.3 Accesibilidad por red vial (pgRouting): tiempo desde cada sitio
   apto a cada localidad del departamento.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tmp_vsitio, tmp_vloc, tmp_tiempos;
CREATE TEMP TABLE tmp_vsitio AS
SELECT a.id, v.id AS vid
FROM entrerios.r14_aptas a
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> a.sitio_m LIMIT 1) v;

CREATE TEMP TABLE tmp_vloc AS
SELECT i.id, i.localidad, GREATEST(i.poblacion, 100) AS poblacion,     -- sin dato OSM -> 100 hab.
       COALESCE(i.min_crecida, 180) AS min_actual, v.id AS vid
FROM entrerios.r13_impacto_crecida i
JOIN entrerios.localidades l ON l.id = i.id
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> l.geom_m LIMIT 1) v;

CREATE TEMP TABLE tmp_tiempos AS
SELECT * FROM pgr_dijkstraCost(
    'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial WHERE NOT cortado',
    (SELECT array_agg(DISTINCT vid) FROM tmp_vsitio),
    (SELECT array_agg(DISTINCT vid) FROM tmp_vloc));

/* ---------------------------------------------------------------------
   14.4 Puntaje multicriterio
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r14_candidatos;
CREATE TABLE entrerios.r14_candidatos AS
WITH m AS (
    SELECT s.id,
           sum(l.poblacion * GREATEST(0, l.min_actual - t.agg_cost))          AS beneficio,
           count(*) FILTER (WHERE t.agg_cost <= 45)                           AS loc_45min,
           string_agg(l.localidad || ' ' || round(t.agg_cost::numeric) || ' min', ', ' ORDER BY t.agg_cost)
               FILTER (WHERE t.agg_cost <= 45)                                AS localidades_45min
    FROM tmp_vsitio s
    JOIN tmp_tiempos t ON t.start_vid = s.vid
    JOIN tmp_vloc l    ON l.vid = t.end_vid
    GROUP BY s.id
), z AS (
    SELECT a.id, ST_Area(ST_Intersection(a.geom_m, zr.geom_m)) / ST_Area(a.geom_m) AS frac_zrh
    FROM entrerios.r14_aptas a, entrerios.zona_riesgo_hidrico zr WHERE zr.depto = 'La Paz'
)
SELECT a.id, a.libre_km2, a.ruta, round(a.dist_ruta_m::numeric) AS dist_ruta_m,
       round(m.beneficio::numeric) AS beneficio_hab_min, m.loc_45min, m.localidades_45min,
       round((100 * z.frac_zrh)::numeric, 1) AS pct_zrh_completa,
       round((0.45 * m.beneficio / NULLIF(max(m.beneficio) OVER (), 0)
            + 0.25 * m.loc_45min::numeric / NULLIF(max(m.loc_45min) OVER (), 0)
            + 0.15 * (1 - z.frac_zrh)
            + 0.15 * (1 - a.dist_ruta_m / 3000.0))::numeric, 4) AS puntaje,
       ST_Transform(a.geom_m, 4326)::geometry(Polygon, 4326) AS geom,
       a.sitio_m
FROM entrerios.r14_aptas a
JOIN m ON m.id = a.id
JOIN z ON z.id = a.id;

/* ---------------------------------------------------------------------
   14.5 Los 3 mejores candidatos separados por >= 10 km (selección voraz)
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r14_mejores;
CREATE TABLE entrerios.r14_mejores (
    ranking int, id_celda bigint, puntaje numeric, beneficio_hab_min numeric, loc_45min int,
    localidades_45min text, ruta text, dist_ruta_m numeric, libre_km2 numeric, pct_zrh_completa numeric,
    localidad_ref text, dist_localidad_m numeric, lat numeric, lon numeric,
    geom geometry(Point, 4326));

DO $$
DECLARE c record; n int := 0;
BEGIN
    FOR c IN SELECT * FROM entrerios.r14_candidatos ORDER BY puntaje DESC LOOP
        EXIT WHEN n = 3;
        CONTINUE WHEN EXISTS (SELECT 1 FROM entrerios.r14_mejores b
                              WHERE ST_DWithin(ST_Transform(b.geom, 5347), c.sitio_m, 10000));
        n := n + 1;
        INSERT INTO entrerios.r14_mejores
        SELECT n, c.id, c.puntaje, c.beneficio_hab_min, c.loc_45min, c.localidades_45min, c.ruta, c.dist_ruta_m,
               c.libre_km2, c.pct_zrh_completa, l.nombre, round(ST_Distance(l.geom_m, c.sitio_m)::numeric),
               round(ST_Y(ST_Transform(c.sitio_m, 4326))::numeric, 5), round(ST_X(ST_Transform(c.sitio_m, 4326))::numeric, 5),
               ST_Transform(c.sitio_m, 4326)
        FROM entrerios.localidades l ORDER BY l.geom_m <-> c.sitio_m LIMIT 1;
    END LOOP;
END $$;

SELECT ranking, puntaje, lat, lon, localidad_ref, dist_localidad_m, ruta, dist_ruta_m, libre_km2,
       pct_zrh_completa, beneficio_hab_min, loc_45min, localidades_45min
FROM entrerios.r14_mejores ORDER BY ranking;

/* ---------------------------------------------------------------------
   14.6 Validación del candidato #1: qué cambia si se construye
   Tiempo al hospital más cercano en crecida, antes y después (por red vial),
   y verificación con fn_hospital_cercano / fn_riesgo-like de su posición.
   --------------------------------------------------------------------- */
SELECT l.localidad, l.poblacion, round(l.min_actual::numeric, 1) AS min_actual,
       round(t.agg_cost::numeric, 1) AS min_al_case,
       round(LEAST(l.min_actual, t.agg_cost)::numeric, 1) AS min_con_case,
       round(GREATEST(0, l.min_actual - t.agg_cost)::numeric, 1) AS ahorro_min
FROM entrerios.r14_mejores b
JOIN tmp_vsitio s ON s.id = b.id_celda
JOIN tmp_tiempos t ON t.start_vid = s.vid
JOIN tmp_vloc l ON l.vid = t.end_vid
WHERE b.ranking = 1
ORDER BY ahorro_min DESC;

SELECT b.ranking, h.* FROM entrerios.r14_mejores b
CROSS JOIN LATERAL entrerios.fn_hospital_cercano(b.lat::float8, b.lon::float8, true) h
ORDER BY b.ranking;
