/* =====================================================================
   PUNTO 8 - Rutas y accesibilidad sanitaria (La Paz)
   ===================================================================== */
SET search_path = entrerios, public;

/* ---------------------------------------------------------------------
   8.1 Red vial principal: rutas nacionales y provinciales que atraviesan
   el departamento. La jurisdicción se obtiene del tag ref de OSM
   (RN = nacional, RP = provincial, RPA = provincial de acceso).
   --------------------------------------------------------------------- */
SELECT r.jurisdiccion, r.ref, string_agg(DISTINCT r.highway, ', ') AS categoria_osm,
       string_agg(DISTINCT r.nombre, ' / ') AS nombres
FROM entrerios.rutas r
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(r.geom, d.geom)
WHERE r.ref IS NOT NULL
GROUP BY r.jurisdiccion, r.ref
ORDER BY r.jurisdiccion, r.ref;

/* ---------------------------------------------------------------------
   8.2 Longitud (km) de cada ruta dentro del departamento.
   ST_Intersection recorta cada tramo al polígono; se mide en EPSG:5347.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r8_rutas_lapaz;
CREATE TABLE entrerios.r8_rutas_lapaz AS
SELECT row_number() OVER () AS id,
       COALESCE(r.ref, '(sin ref)') AS ref,
       min(r.jurisdiccion) AS jurisdiccion,
       string_agg(DISTINCT r.highway, ', ') AS categoria_osm,
       round((sum(ST_Length(ST_Intersection(r.geom_m, d.geom_m))) / 1000)::numeric, 2) AS km,
       ST_Multi(ST_Union(ST_Intersection(r.geom, d.geom)))::geometry(MultiLineString, 4326) AS geom
FROM entrerios.rutas r
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(r.geom, d.geom)
GROUP BY COALESCE(r.ref, '(sin ref)');

SELECT ref, jurisdiccion, categoria_osm, km FROM entrerios.r8_rutas_lapaz ORDER BY km DESC;
SELECT jurisdiccion, round(sum(km), 1) AS km FROM entrerios.r8_rutas_lapaz GROUP BY ROLLUP (jurisdiccion) ORDER BY 1;

/* ---------------------------------------------------------------------
   8.3 Establecimientos de salud en La Paz y su distribución espacial
   a) listado, con la localidad más cercana (KNN con el operador <->)
   b) concentración por localidad
   c) distancia al vecino más cercano entre establecimientos
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r8_salud_lapaz;
CREATE TABLE entrerios.r8_salud_lapaz AS
SELECT s.id, s.nombre, s.tipo, s.origen, loc.nombre AS localidad,
       round(loc.dist::numeric) AS dist_localidad_m, s.geom
FROM entrerios.salud s
JOIN entrerios.departamentos d ON d.id = s.id_depto AND d.nombre = 'La Paz'
CROSS JOIN LATERAL (
    SELECT l.nombre, ST_Distance(l.geom_m, s.geom_m) AS dist
    FROM entrerios.localidades l
    ORDER BY l.geom_m <-> s.geom_m LIMIT 1
) loc;

SELECT nombre, tipo, localidad, dist_localidad_m FROM entrerios.r8_salud_lapaz ORDER BY localidad, tipo, nombre;

SELECT localidad, count(*) AS establecimientos,
       count(*) FILTER (WHERE tipo = 'hospital') AS hospitales,
       count(*) FILTER (WHERE tipo = 'clinic')   AS clinicas
FROM entrerios.r8_salud_lapaz GROUP BY localidad ORDER BY 2 DESC;

-- Vecino más cercano: si la mediana es chica, los establecimientos están agrupados.
SELECT round(min(nn)::numeric) AS min_m, round(percentile_cont(0.5) WITHIN GROUP (ORDER BY nn)::numeric) AS mediana_m,
       round(max(nn)::numeric) AS max_m
FROM (
    SELECT (SELECT ST_Distance(a.geom_m, b.geom_m) FROM entrerios.salud b
            WHERE b.id <> a.id ORDER BY a.geom_m <-> b.geom_m LIMIT 1) AS nn
    FROM entrerios.salud a JOIN entrerios.departamentos d ON d.id = a.id_depto AND d.nombre = 'La Paz'
) t;

-- Comparación provincial: establecimientos cada 10.000 km²
SELECT d.nombre, count(s.id) AS establecimientos,
       round((count(s.id) / (ST_Area(d.geom_m) / 1e10))::numeric, 1) AS c10000km2
FROM entrerios.departamentos d LEFT JOIN entrerios.salud s ON s.id_depto = d.id
GROUP BY d.id ORDER BY 3 DESC;

/* ---------------------------------------------------------------------
   8.4 Localidad más alejada de un establecimiento de salud
   Criterio: distancia euclídea (en línea recta, EPSG:5347) desde el
   punto de la localidad al establecimiento MÁS CERCANO, buscándolo en
   toda la provincia (una persona de un borde puede atenderse en el
   departamento vecino). Se usa KNN (<->) con índice GiST.
   Limitación: es distancia en línea recta, no por la red vial.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r8_dist_localidad_salud;
CREATE TABLE entrerios.r8_dist_localidad_salud AS
SELECT l.id, l.osm_id, l.nombre, l.tipo, l.poblacion,
       s.nombre AS salud_mas_cercana, s.tipo AS tipo_salud,
       round(s.dist::numeric) AS distancia_m,
       rank() OVER (ORDER BY s.dist DESC) AS ranking_lejania,
       l.geom,
       ST_MakeLine(l.geom, s.geom)::geometry(LineString, 4326) AS linea
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz'
CROSS JOIN LATERAL (
    SELECT x.nombre, x.tipo, x.geom, ST_Distance(x.geom_m, l.geom_m) AS dist
    FROM entrerios.salud x ORDER BY x.geom_m <-> l.geom_m LIMIT 1
) s;

SELECT ranking_lejania, nombre, tipo, poblacion, salud_mas_cercana, tipo_salud, distancia_m
FROM entrerios.r8_dist_localidad_salud ORDER BY ranking_lejania;

-- Variante: distancia al HOSPITAL más cercano (no clínica/consultorio)
SELECT l.nombre, s.nombre AS hospital_mas_cercano, round(s.dist::numeric) AS distancia_m
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz'
CROSS JOIN LATERAL (
    SELECT x.nombre, ST_Distance(x.geom_m, l.geom_m) AS dist
    FROM entrerios.salud x WHERE x.tipo = 'hospital' ORDER BY x.geom_m <-> l.geom_m LIMIT 1
) s
ORDER BY s.dist DESC;

/* ---------------------------------------------------------------------
   8.5 Área de cobertura sanitaria: buffer de 5 km
   Se generan buffers de 5 km sobre todos los establecimientos que
   puedan alcanzar al departamento (también los de deptos vecinos)
   y se disuelven con ST_Union.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r8_cobertura_5km;
CREATE TABLE entrerios.r8_cobertura_5km AS
SELECT 1 AS id,
       ST_Union(ST_Buffer(s.geom_m, 5000, 32))::geometry(MultiPolygon, 5347) AS geom_m
FROM entrerios.salud s
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_DWithin(s.geom_m, d.geom_m, 5000);
ALTER TABLE entrerios.r8_cobertura_5km ALTER COLUMN geom_m TYPE geometry(MultiPolygon, 5347) USING ST_Multi(geom_m);
ALTER TABLE entrerios.r8_cobertura_5km ADD COLUMN geom geometry(MultiPolygon, 4326);
UPDATE entrerios.r8_cobertura_5km SET geom = ST_Multi(ST_Transform(geom_m, 4326));

DROP TABLE IF EXISTS entrerios.r8_localidades_sin_cobertura;
CREATE TABLE entrerios.r8_localidades_sin_cobertura AS
SELECT l.id, l.nombre, l.tipo, l.poblacion, ds.distancia_m, l.geom
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz'
JOIN entrerios.r8_dist_localidad_salud ds ON ds.id = l.id
WHERE NOT EXISTS (SELECT 1 FROM entrerios.r8_cobertura_5km c WHERE ST_Intersects(c.geom_m, l.geom_m));

SELECT (SELECT count(*) FROM entrerios.r8_dist_localidad_salud)       AS localidades_depto,
       (SELECT count(*) FROM entrerios.r8_localidades_sin_cobertura)  AS fuera_de_cobertura;
SELECT nombre, tipo, poblacion, distancia_m FROM entrerios.r8_localidades_sin_cobertura ORDER BY distancia_m DESC;

-- Porcentaje del territorio departamental cubierto por los 5 km
SELECT round((100 * ST_Area(ST_Intersection(c.geom_m, d.geom_m)) / ST_Area(d.geom_m))::numeric, 1) AS pct_territorio_cubierto
FROM entrerios.r8_cobertura_5km c, entrerios.departamentos d WHERE d.nombre = 'La Paz';
