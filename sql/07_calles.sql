/* =====================================================================
   PUNTO 11 - Calles, OpenStreetMap y Argenmap
   Tabla entrerios.calles: highway = primary, secondary, tertiary,
   residential, unclassified (cargada en 01_construccion.sql).
   ===================================================================== */
SET search_path = entrerios, public;

/* ---------------------------------------------------------------------
   11.1 Longitud total de calles por departamento y comparación con el
   promedio provincial. Se informa también la densidad (km por km²),
   que es la comparación justa entre departamentos de distinto tamaño.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r11_calles_depto;
CREATE TABLE entrerios.r11_calles_depto AS
SELECT d.id, d.nombre,
       round((sum(ST_Length(CASE WHEN ST_CoveredBy(c.geom_m, d.geom_m) THEN c.geom_m
                                 ELSE ST_Intersection(c.geom_m, d.geom_m) END)) / 1000)::numeric, 1) AS km_calles,
       round((ST_Area(d.geom_m) / 1e6)::numeric, 0) AS sup_km2,
       d.geom
FROM entrerios.departamentos d
JOIN entrerios.calles c ON ST_Intersects(c.geom_m, d.geom_m)
GROUP BY d.id;
ALTER TABLE entrerios.r11_calles_depto ADD COLUMN densidad_km_km2 numeric;
UPDATE entrerios.r11_calles_depto SET densidad_km_km2 = round(km_calles / sup_km2, 3);

SELECT nombre, km_calles, sup_km2, densidad_km_km2,
       rank() OVER (ORDER BY km_calles DESC) AS rank_km,
       rank() OVER (ORDER BY densidad_km_km2 DESC) AS rank_densidad
FROM entrerios.r11_calles_depto ORDER BY km_calles DESC;

SELECT lp.km_calles                                   AS km_la_paz,
       round(avg(t.km_calles), 1)                     AS promedio_provincial_km,
       round(100 * (lp.km_calles / avg(t.km_calles) - 1), 1) AS dif_pct_vs_promedio,
       lp.densidad_km_km2                             AS densidad_la_paz,
       round(avg(t.densidad_km_km2), 3)               AS densidad_promedio,
       round(sum(t.km_calles) / sum(t.sup_km2), 3)    AS densidad_provincial_global
FROM entrerios.r11_calles_depto t, entrerios.r11_calles_depto lp
WHERE lp.nombre = 'La Paz'
GROUP BY lp.km_calles, lp.densidad_km_km2;

-- Composición por categoría en La Paz (explica de dónde vienen los km)
SELECT c.highway,
       round((sum(ST_Length(ST_Intersection(c.geom_m, d.geom_m))) / 1000)::numeric, 1) AS km
FROM entrerios.calles c
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(c.geom_m, d.geom_m)
GROUP BY c.highway ORDER BY km DESC;

/* ---------------------------------------------------------------------
   11.2 Densidad vial por localidad
   Problema: las localidades de OSM son PUNTOS (sin superficie), y los
   límites de ejido (admin_level 7/8) incluyen enormes áreas rurales.
   Decisión: se estima la "mancha urbana" de cada localidad a partir de
   su propia trama de calles:
     1. Calles highway = residential del departamento. (Se probó incluir
        tertiary/unclassified, pero en Entre Ríos los caminos rurales
        están etiquetados unclassified y forman una red continua: DBSCAN
        los encadenaba y la "mancha" de La Paz daba 862 km².)
     2. ST_ClusterDBSCAN (eps = 100 m, minpoints = 5) agrupa las calles
        que forman una trama continua; las calles aisladas quedan como
        ruido (cluster NULL) y se descartan.
     3. Cada cluster se asigna a la localidad más cercana, si está a
        menos de 1,5 km (los clusters lejanos son barrios/loteos rurales).
     4. Superficie = ST_ConcaveHull(cluster, 0.4) con un buffer de 50 m
        (envolvente cóncava: sigue la forma real de la planta urbana).
     5. Densidad = km de calles (todas las categorías) dentro de la
        mancha / km² de la mancha.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r11_mancha_urbana;
CREATE TABLE entrerios.r11_mancha_urbana AS
WITH base AS (
    SELECT c.id, c.geom_m,
           ST_ClusterDBSCAN(c.geom_m, eps := 100, minpoints := 5) OVER () AS cl
    FROM entrerios.calles c
    JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(c.geom_m, d.geom_m)
    WHERE c.highway = 'residential'
), clusters AS (
    SELECT cl, ST_Collect(geom_m) AS g, count(*) AS n
    FROM base WHERE cl IS NOT NULL GROUP BY cl
), asignado AS (
    SELECT c.cl, c.n, loc.id AS id_localidad, loc.nombre, loc.dist,
           ST_Buffer(ST_ConcaveHull(c.g, 0.4), 50) AS mancha
    FROM clusters c
    CROSS JOIN LATERAL (
        SELECT l.id, l.nombre, ST_Distance(l.geom_m, c.g) AS dist
        FROM entrerios.localidades l ORDER BY l.geom_m <-> c.g LIMIT 1
    ) loc
    WHERE loc.dist < 1500
)
SELECT id_localidad, nombre AS localidad, sum(n) AS calles_osm,
       ST_Multi(ST_Union(mancha))::geometry(MultiPolygon, 5347) AS geom_m
FROM asignado GROUP BY id_localidad, nombre;

ALTER TABLE entrerios.r11_mancha_urbana ADD COLUMN geom geometry(MultiPolygon, 4326);
UPDATE entrerios.r11_mancha_urbana SET geom = ST_Multi(ST_Transform(geom_m, 4326));

DROP TABLE IF EXISTS entrerios.r11_densidad_localidad;
CREATE TABLE entrerios.r11_densidad_localidad AS
SELECT m.id_localidad, m.localidad, l.poblacion,
       round((ST_Area(m.geom_m) / 1e6)::numeric, 3) AS sup_km2,
       round((sum(ST_Length(ST_Intersection(c.geom_m, m.geom_m))) / 1000)::numeric, 2) AS km_calles,
       round(((sum(ST_Length(ST_Intersection(c.geom_m, m.geom_m))) / 1000) / (ST_Area(m.geom_m) / 1e6))::numeric, 2) AS densidad_km_km2,
       m.geom
FROM entrerios.r11_mancha_urbana m
JOIN entrerios.localidades l ON l.id = m.id_localidad
JOIN entrerios.calles c ON ST_Intersects(c.geom_m, m.geom_m)
GROUP BY m.id_localidad, m.localidad, l.poblacion, m.geom_m, m.geom;

SELECT rank() OVER (ORDER BY densidad_km_km2 DESC) AS ranking, localidad, poblacion, sup_km2, km_calles, densidad_km_km2
FROM entrerios.r11_densidad_localidad ORDER BY densidad_km_km2 DESC;

/* ---------------------------------------------------------------------
   11.3 Calles primary y secondary en La Paz (km por categoría)
   --------------------------------------------------------------------- */
SELECT c.highway, count(*) AS tramos,
       round((sum(ST_Length(ST_Intersection(c.geom_m, d.geom_m))) / 1000)::numeric, 2) AS km
FROM entrerios.calles c
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(c.geom_m, d.geom_m)
WHERE c.highway IN ('primary', 'secondary')
GROUP BY ROLLUP (c.highway) ORDER BY c.highway;

/* ---------------------------------------------------------------------
   11.4 Insumos cuantitativos para la comparación OSM vs Argenmap
   (la comparación visual se hace en QGIS con el TMS de Argenmap)
   a) superficie declarada de las vías (pavimentadas vs tierra)
   b) puentes registrados en OSM dentro del departamento
   c) km de calles dentro de la Zona de Riesgo Hídrico
   --------------------------------------------------------------------- */
SELECT CASE WHEN c.superficie IN ('asphalt', 'paved', 'concrete', 'paving_stones', 'sett', 'chipseal') THEN 'pavimentada'
            WHEN c.superficie IS NULL THEN 'sin dato'
            ELSE 'no pavimentada (' || c.superficie || ')' END AS superficie,
       round((sum(ST_Length(ST_Intersection(c.geom_m, d.geom_m))) / 1000)::numeric, 1) AS km
FROM entrerios.calles c
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(c.geom_m, d.geom_m)
GROUP BY 1 ORDER BY km DESC;

DROP TABLE IF EXISTS entrerios.r11_puentes;
CREATE TABLE entrerios.r11_puentes AS
SELECT c.id, c.nombre, c.highway, round(ST_Length(c.geom_m)::numeric) AS largo_m,
       (SELECT COALESCE(r.nombre, '(sin nombre)') FROM entrerios.rios r
        ORDER BY r.geom_m <-> c.geom_m LIMIT 1) AS curso_cercano,
       c.geom
FROM entrerios.calles c
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(c.geom_m, d.geom_m)
WHERE c.puente;

SELECT count(*) AS puentes_osm, round(sum(largo_m)) AS metros_totales FROM entrerios.r11_puentes;
SELECT nombre, highway, largo_m, curso_cercano FROM entrerios.r11_puentes ORDER BY largo_m DESC LIMIT 15;

SELECT round((sum(ST_Length(ST_Intersection(c.geom_m, z.geom_m))) / 1000)::numeric, 1) AS km_calles_en_zrh,
       round((100 * sum(ST_Length(ST_Intersection(c.geom_m, z.geom_m))) /
              (SELECT sum(ST_Length(ST_Intersection(c2.geom_m, d.geom_m))) FROM entrerios.calles c2
               JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(c2.geom_m, d.geom_m)))::numeric, 1) AS pct
FROM entrerios.calles c
JOIN entrerios.zona_riesgo_hidrico z ON z.depto = 'La Paz' AND ST_Intersects(c.geom_m, z.geom_m);
