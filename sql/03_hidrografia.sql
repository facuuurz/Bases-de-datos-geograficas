/* =====================================================================
   PUNTO 7 - Hidrografía y características del departamento La Paz
   Los resultados que se visualizan en QGIS se guardan como tablas r7_*.
   ===================================================================== */
SET search_path = entrerios, public;

/* ---------------------------------------------------------------------
   7.1 Departamentos vecinos
   ST_Touches exige que los límites coincidan exactamente; como los
   polígonos del IGN comparten vértices, funciona, pero se usa además
   ST_Intersects + longitud del límite compartido > 0 para descartar
   contactos en un único punto (departamentos que se "tocan" en una esquina).
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r7_vecinos;
CREATE TABLE entrerios.r7_vecinos AS
SELECT v.id, v.nombre AS vecino,
       ST_Touches(lp.geom, v.geom) AS touches,
       round((ST_Length(ST_Intersection(ST_Boundary(lp.geom_m), ST_Boundary(v.geom_m))) / 1000)::numeric, 1) AS limite_km,
       v.geom
FROM entrerios.departamentos lp
JOIN entrerios.departamentos v ON v.id <> lp.id AND ST_Intersects(lp.geom, v.geom)
WHERE lp.nombre = 'La Paz';

SELECT vecino, touches, limite_km FROM entrerios.r7_vecinos ORDER BY limite_km DESC;

/* ---------------------------------------------------------------------
   7.2 Frontera común
   Intersección de los contornos (ST_Boundary) de La Paz y cada vecino.
   ST_LineMerge une los segmentos en una única línea continua.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r7_frontera;
CREATE TABLE entrerios.r7_frontera AS
SELECT row_number() OVER () AS id,
       'La Paz - ' || v.nombre AS frontera,
       ST_Multi(ST_LineMerge(ST_CollectionExtract(
           ST_Intersection(ST_Boundary(lp.geom), ST_Boundary(v.geom)), 2)))::geometry(MultiLineString, 4326) AS geom
FROM entrerios.departamentos lp
JOIN entrerios.departamentos v ON v.id <> lp.id AND ST_Intersects(lp.geom, v.geom)
WHERE lp.nombre = 'La Paz';

SELECT frontera, ST_GeometryType(geom) AS tipo,
       round((ST_Length(geom::geography) / 1000)::numeric, 1) AS km
FROM entrerios.r7_frontera ORDER BY km DESC;

/* ---------------------------------------------------------------------
   7.3 Ranking provincial de cuerpos de agua
   Cada laguna se asigna a UN solo departamento usando ST_PointOnSurface
   (evita contar dos veces las lagunas cortadas por un límite).
   Se informa cantidad, superficie y densidad (lagunas cada 100 km²).
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r7_ranking_agua;
CREATE TABLE entrerios.r7_ranking_agua AS
SELECT d.id, d.nombre,
       count(l.id)                                                AS cant_lagunas,
       round((COALESCE(sum(ST_Area(l.geom_m)), 0) / 1e6)::numeric, 2) AS sup_lagunas_km2,
       round((ST_Area(d.geom_m) / 1e6)::numeric, 0)               AS sup_depto_km2,
       round((count(l.id) / (ST_Area(d.geom_m) / 1e8))::numeric, 2) AS lagunas_c100km2,
       rank() OVER (ORDER BY count(l.id) DESC)                    AS ranking,
       d.geom
FROM entrerios.departamentos d
LEFT JOIN entrerios.lagunas l ON ST_Within(ST_PointOnSurface(l.geom), d.geom)
GROUP BY d.id;

SELECT ranking, nombre, cant_lagunas, sup_lagunas_km2, sup_depto_km2, lagunas_c100km2
FROM entrerios.r7_ranking_agua ORDER BY ranking, nombre;

-- Composición por tipo OSM en La Paz (insumo para explicar las limitaciones)
SELECT l.tipo, count(*) AS cantidad, round((sum(ST_Area(l.geom_m)) / 1e6)::numeric, 3) AS km2,
       count(*) FILTER (WHERE l.nombre IS NOT NULL) AS con_nombre
FROM entrerios.lagunas l
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Within(ST_PointOnSurface(l.geom), d.geom)
GROUP BY l.tipo ORDER BY cantidad DESC;

/* ---------------------------------------------------------------------
   7.4 Superficie cubierta por agua (La Paz) - km²
   Se recortan los polígonos al departamento (ST_Intersection) y se
   disuelven (ST_Union) para no sumar dos veces superposiciones.
   Se informan dos variantes: solo lagunas, y lagunas + cauces (water=river).
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r7_superficie_agua;
CREATE TABLE entrerios.r7_superficie_agua AS
WITH lp AS (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'),
lag AS (
    SELECT ST_Union(ST_Intersection(l.geom_m, lp.geom_m)) AS g
    FROM entrerios.lagunas l, lp WHERE ST_Intersects(l.geom_m, lp.geom_m)
),
cau AS (
    SELECT ST_Union(ST_Intersection(r.geom_m, lp.geom_m)) AS g
    FROM entrerios.rios_area r, lp WHERE ST_Intersects(r.geom_m, lp.geom_m)
)
SELECT round((ST_Area(lp.geom_m) / 1e6)::numeric, 2)                         AS sup_total_km2,
       round((ST_Area(lag.g) / 1e6)::numeric, 2)                             AS sup_lagunas_km2,
       round(((ST_Area(lp.geom_m) - ST_Area(lag.g)) / 1e6)::numeric, 2)      AS sup_restante_km2,
       round((100 * ST_Area(lag.g) / ST_Area(lp.geom_m))::numeric, 3)        AS pct_lagunas,
       round((ST_Area(ST_Union(lag.g, cau.g)) / 1e6)::numeric, 2)            AS sup_agua_con_cauces_km2,
       round((100 * ST_Area(ST_Union(lag.g, cau.g)) / ST_Area(lp.geom_m))::numeric, 3) AS pct_agua_con_cauces
FROM lp, lag, cau;

SELECT * FROM entrerios.r7_superficie_agua;

/* ---------------------------------------------------------------------
   7.5 Cursos de agua que atraviesan La Paz y longitud dentro del depto (m)
   Se agrupa por nombre: en OSM un mismo arroyo está partido en muchos ways.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r7_cursos_agua;
CREATE TABLE entrerios.r7_cursos_agua AS
SELECT row_number() OVER (ORDER BY sum(ST_Length(ST_Intersection(r.geom_m, d.geom_m))) DESC) AS id,
       COALESCE(r.nombre, '(sin nombre)') AS nombre,
       string_agg(DISTINCT r.tipo, '/')    AS tipo,
       count(*)                            AS tramos,
       round(sum(ST_Length(ST_Intersection(r.geom_m, d.geom_m)))::numeric, 0) AS longitud_m,
       ST_Multi(ST_Union(ST_Intersection(r.geom, d.geom)))::geometry(MultiLineString, 4326) AS geom
FROM entrerios.rios r
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(r.geom, d.geom)
GROUP BY COALESCE(r.nombre, '(sin nombre)');

SELECT nombre, tipo, tramos, longitud_m FROM entrerios.r7_cursos_agua ORDER BY longitud_m DESC LIMIT 25;

SELECT count(*) FILTER (WHERE nombre <> '(sin nombre)') AS cursos_con_nombre,
       sum(longitud_m) FILTER (WHERE tipo LIKE '%river%') AS long_rios_m,
       sum(longitud_m)                                     AS longitud_total_m
FROM entrerios.r7_cursos_agua;
