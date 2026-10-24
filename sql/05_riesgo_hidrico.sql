/* =====================================================================
   PUNTO 9 - Gestión del riesgo hídrico
   Zona de Riesgo Hídrico (ZRH) = buffer de 2 km alrededor de ríos,
   arroyos (líneas), lagunas y cauces (polígonos).
   Simplificación académica: NO es un mapa oficial de riesgo de inundación.
   ===================================================================== */
SET search_path = entrerios, public;

/* ---------------------------------------------------------------------
   9.1 Zona de Riesgo Hídrico, calculada para cada departamento.
   Para cada departamento se toman los elementos hídricos a menos de
   2 km (ST_DWithin, usa índice GiST), se simplifican a 25 m
   (ST_Simplify: con un buffer de 2 km el detalle de vértices es
   irrelevante y el cálculo pasa de >10 min a segundos), se aplica
   ST_Buffer de 2000 m, se disuelven con ST_Union y se recorta al
   departamento con ST_Intersection.

   Se generan DOS variantes:
     - zrh completa   : ríos + arroyos (stream) + lagunas + cauces.
     - zrh principal  : solo ríos (waterway=river) + lagunas + cauces,
                        sin los arroyos menores (stream).
   La segunda permite ver cuánto pesa la red densa de arroyos menores.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.zona_riesgo_hidrico CASCADE;
CREATE TABLE entrerios.zona_riesgo_hidrico (
    id_depto  integer PRIMARY KEY REFERENCES entrerios.departamentos(id),
    depto     varchar(60),
    geom_m    geometry(MultiPolygon, 5347),
    geom      geometry(MultiPolygon, 4326),
    geom_m_principal geometry(MultiPolygon, 5347)
);

INSERT INTO entrerios.zona_riesgo_hidrico (id_depto, depto, geom_m, geom_m_principal)
SELECT d.id, d.nombre,
       ST_Multi(ST_CollectionExtract(ST_Intersection(
           ST_Union(ST_Buffer(ST_Simplify(h.g, 25), 2000, 4)), d.geom_m), 3)),
       ST_Multi(ST_CollectionExtract(ST_Intersection(
           ST_Union(ST_Buffer(ST_Simplify(h.g, 25), 2000, 4)) FILTER (WHERE h.principal), d.geom_m), 3))
FROM entrerios.departamentos d
CROSS JOIN LATERAL (
    SELECT r.geom_m AS g, r.tipo = 'river' AS principal
    FROM entrerios.rios r      WHERE ST_DWithin(r.geom_m, d.geom_m, 2000)
    UNION ALL
    SELECT l.geom_m, true FROM entrerios.lagunas l   WHERE ST_DWithin(l.geom_m, d.geom_m, 2000)
    UNION ALL
    SELECT a.geom_m, true FROM entrerios.rios_area a WHERE ST_DWithin(a.geom_m, d.geom_m, 2000)
) h
GROUP BY d.id;

UPDATE entrerios.zona_riesgo_hidrico SET geom = ST_Multi(ST_Transform(geom_m, 4326));
CREATE INDEX ON entrerios.zona_riesgo_hidrico USING gist (geom_m);
CREATE INDEX ON entrerios.zona_riesgo_hidrico USING gist (geom);

-- Vista de la ZRH de La Paz (para QGIS)
CREATE OR REPLACE VIEW entrerios.v_zrh_lapaz AS
SELECT * FROM entrerios.zona_riesgo_hidrico WHERE depto = 'La Paz';

SELECT z.depto,
       round((ST_Area(z.geom_m) / 1e6)::numeric, 1) AS zrh_km2,
       round((100 * ST_Area(z.geom_m) / ST_Area(d.geom_m))::numeric, 1) AS pct_depto,
       round((ST_Area(z.geom_m_principal) / 1e6)::numeric, 1) AS zrh_principal_km2,
       round((100 * ST_Area(z.geom_m_principal) / ST_Area(d.geom_m))::numeric, 1) AS pct_principal
FROM entrerios.zona_riesgo_hidrico z JOIN entrerios.departamentos d ON d.id = z.id_depto
WHERE z.depto = 'La Paz';

/* ---------------------------------------------------------------------
   9.2 Infraestructura sanitaria expuesta
   Establecimientos de La Paz dentro de la ZRH, con la distancia al
   elemento hídrico más cercano y su nombre.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r9_salud_expuesta;
CREATE TABLE entrerios.r9_salud_expuesta AS
SELECT s.id, s.nombre, s.tipo, h.agua_cercana, round(h.dist::numeric) AS dist_agua_m, s.geom
FROM entrerios.salud s
JOIN entrerios.zona_riesgo_hidrico z ON z.depto = 'La Paz' AND ST_Intersects(z.geom_m, s.geom_m)
CROSS JOIN LATERAL (
    SELECT nombre AS agua_cercana, dist FROM (
        SELECT COALESCE(r.nombre, '(curso sin nombre)') AS nombre, ST_Distance(r.geom_m, s.geom_m) AS dist
        FROM entrerios.rios r ORDER BY r.geom_m <-> s.geom_m LIMIT 1) a
    UNION ALL
    SELECT nombre, dist FROM (
        SELECT COALESCE(l.nombre, '(laguna sin nombre)'), ST_Distance(l.geom_m, s.geom_m)
        FROM entrerios.lagunas l ORDER BY l.geom_m <-> s.geom_m LIMIT 1) b(nombre, dist)
    UNION ALL
    SELECT nombre, dist FROM (
        SELECT COALESCE(c.nombre, '(cauce sin nombre)'), ST_Distance(c.geom_m, s.geom_m)
        FROM entrerios.rios_area c ORDER BY c.geom_m <-> s.geom_m LIMIT 1) c(nombre, dist)
    ORDER BY dist LIMIT 1
) h;

SELECT (SELECT count(*) FROM entrerios.salud s JOIN entrerios.departamentos d ON d.id = s.id_depto
        WHERE d.nombre = 'La Paz') AS total_salud,
       (SELECT count(*) FROM entrerios.r9_salud_expuesta) AS expuestos;
SELECT nombre, tipo, agua_cercana, dist_agua_m FROM entrerios.r9_salud_expuesta ORDER BY dist_agua_m;

/* ---------------------------------------------------------------------
   9.3 Posibles situaciones de aislamiento
   Metodología:
   (a) Para cada localidad se busca el punto más cercano de la red vial
       principal (RN/RP) con ST_ClosestPoint y se construye el "conector"
       localidad -> ruta (ST_MakeLine). Si ese conector cruza un río o
       arroyo (ST_Intersects con rios), el acceso a la red principal
       depende de un cruce de agua (puente o alcantarilla).
   (b) Se calcula qué proporción de la red vial a menos de 5 km de cada
       localidad está dentro de la ZRH (rutas potencialmente anegables).
   (c) Se detectan los puntos de cruce ruta x curso de agua
       (ST_Intersection) y se verifica si OSM registra un puente
       (bridge=yes) a menos de 50 m (ST_DWithin). Un cruce sin puente
       registrado es un punto crítico (alcantarilla/vado o dato faltante).
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r9_conectores;
CREATE TABLE entrerios.r9_conectores AS
SELECT l.id, l.nombre AS localidad, l.poblacion, rt.ref AS ruta_mas_cercana,
       round(ST_Distance(l.geom_m, rt.geom_m)::numeric) AS dist_ruta_m,
       (SELECT count(*) FROM entrerios.rios r
         WHERE ST_Intersects(r.geom_m, ST_MakeLine(l.geom_m, ST_ClosestPoint(rt.geom_m, l.geom_m)))) AS cruces_agua,
       (SELECT string_agg(DISTINCT COALESCE(r.nombre, 's/n'), ', ') FROM entrerios.rios r
         WHERE ST_Intersects(r.geom_m, ST_MakeLine(l.geom_m, ST_ClosestPoint(rt.geom_m, l.geom_m)))) AS cursos_cruzados,
       ST_Intersects(z.geom_m, l.geom_m) AS localidad_en_zrh,
       ST_Transform(ST_MakeLine(l.geom_m, ST_ClosestPoint(rt.geom_m, l.geom_m)), 4326)::geometry(LineString, 4326) AS geom
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz'
JOIN entrerios.zona_riesgo_hidrico z ON z.id_depto = d.id
CROSS JOIN LATERAL (
    SELECT r.ref, r.geom_m FROM entrerios.rutas r
    WHERE r.jurisdiccion IN ('Nacional', 'Provincial')
    ORDER BY r.geom_m <-> l.geom_m LIMIT 1
) rt;

-- (b) proporción de la red vial (rutas + calles) del entorno de 5 km dentro de la ZRH
DROP TABLE IF EXISTS entrerios.r9_aislamiento;
CREATE TABLE entrerios.r9_aislamiento AS
SELECT c.id, c.localidad, c.poblacion, c.ruta_mas_cercana, c.dist_ruta_m, c.cruces_agua,
       c.cursos_cruzados, c.localidad_en_zrh,
       round((100 * v.km_zrh / NULLIF(v.km_total, 0))::numeric, 1) AS pct_vias_entorno_en_zrh,
       CASE
           WHEN c.cruces_agua > 0 AND v.km_zrh / NULLIF(v.km_total, 0) > 0.5 THEN 'ALTO'
           WHEN c.cruces_agua > 0 OR  v.km_zrh / NULLIF(v.km_total, 0) > 0.5 THEN 'MEDIO'
           ELSE 'BAJO'
       END AS riesgo_aislamiento,
       l.geom
FROM entrerios.r9_conectores c
JOIN entrerios.localidades l ON l.id = c.id
JOIN entrerios.zona_riesgo_hidrico z ON z.depto = 'La Paz'
CROSS JOIN LATERAL (
    SELECT sum(ST_Length(v.g))                                AS km_total,
           sum(ST_Length(ST_Intersection(v.g, z.geom_m)))     AS km_zrh
    FROM (SELECT ST_Intersection(x.geom_m, ST_Buffer(l.geom_m, 5000)) AS g
          FROM (SELECT geom_m FROM entrerios.calles UNION ALL SELECT geom_m FROM entrerios.rutas) x
          WHERE ST_DWithin(x.geom_m, l.geom_m, 5000)) v
) v;

SELECT localidad, poblacion, ruta_mas_cercana, dist_ruta_m, cruces_agua, cursos_cruzados,
       localidad_en_zrh, pct_vias_entorno_en_zrh, riesgo_aislamiento
FROM entrerios.r9_aislamiento ORDER BY riesgo_aislamiento, pct_vias_entorno_en_zrh DESC;

-- (c) puntos de cruce de la red vial principal con cursos de agua en La Paz
DROP TABLE IF EXISTS entrerios.r9_cruces_ruta_agua;
CREATE TABLE entrerios.r9_cruces_ruta_agua AS
SELECT row_number() OVER () AS id, ru.ref AS ruta, COALESCE(ri.nombre, '(sin nombre)') AS curso, ri.tipo,
       EXISTS (SELECT 1 FROM entrerios.rutas b
               WHERE b.puente AND ST_DWithin(b.geom_m, p.geom, 50)) AS puente_osm,
       ST_Transform(p.geom, 4326)::geometry(Point, 4326) AS geom
FROM entrerios.rutas ru
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(ru.geom_m, d.geom_m)
JOIN entrerios.rios ri ON ST_Intersects(ru.geom_m, ri.geom_m)
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(ST_Intersection(ru.geom_m, ri.geom_m), 1)) p
WHERE ST_Intersects(p.geom, d.geom_m);

SELECT ruta, count(*) AS cruces, count(*) FILTER (WHERE puente_osm) AS con_puente,
       count(*) FILTER (WHERE NOT puente_osm) AS sin_puente_registrado
FROM entrerios.r9_cruces_ruta_agua GROUP BY ruta ORDER BY cruces DESC;

SELECT ruta, curso, tipo, puente_osm FROM entrerios.r9_cruces_ruta_agua
WHERE curso <> '(sin nombre)' ORDER BY ruta, curso;

/* ---------------------------------------------------------------------
   9.4 Departamentos con mayor exposición (escala provincial)
   Para cada departamento: % de superficie de cuerpos de agua y % de
   superficie dentro de la ZRH. Umbral de referencia: 30 %.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r9_exposicion_deptos;
CREATE TABLE entrerios.r9_exposicion_deptos AS
SELECT d.id, d.nombre,
       round((ST_Area(d.geom_m) / 1e6)::numeric, 0) AS sup_km2,
       round((100 * COALESCE(a.area_agua, 0) / ST_Area(d.geom_m))::numeric, 2) AS pct_agua,
       round((100 * ST_Area(z.geom_m) / ST_Area(d.geom_m))::numeric, 1)        AS pct_zrh,
       round((100 * ST_Area(z.geom_m_principal) / ST_Area(d.geom_m))::numeric, 1) AS pct_zrh_principal,
       ST_Area(z.geom_m) / ST_Area(d.geom_m) >= 0.30                           AS supera_30,
       ST_Area(z.geom_m_principal) / ST_Area(d.geom_m) >= 0.30                 AS supera_30_principal,
       rank() OVER (ORDER BY ST_Area(z.geom_m) / ST_Area(d.geom_m) DESC)        AS ranking,
       d.geom
FROM entrerios.departamentos d
JOIN entrerios.zona_riesgo_hidrico z ON z.id_depto = d.id
LEFT JOIN LATERAL (
    SELECT ST_Area(ST_Union(ST_Intersection(w.geom_m, d.geom_m))) AS area_agua
    FROM (SELECT geom_m FROM entrerios.lagunas UNION ALL SELECT geom_m FROM entrerios.rios_area) w
    WHERE ST_Intersects(w.geom_m, d.geom_m)
) a ON true;

SELECT ranking, nombre, sup_km2, pct_agua, pct_zrh, supera_30, pct_zrh_principal, supera_30_principal
FROM entrerios.r9_exposicion_deptos ORDER BY ranking;
