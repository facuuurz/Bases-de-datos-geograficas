/* #####################################################################
   TP2 - BASES DE DATOS AVANZADAS 2026 - UADER FCyT
   Bases de Datos Geográficas
   Riesgo Hídrico y Accesibilidad Sanitaria en Entre Ríos
   Departamento: LA PAZ  -  Localidad de referencia: La Paz

   Script único (puntos 6 a 14). Requisitos:
     - PostgreSQL 18 + PostGIS 3.6 + pgRouting 4.0
     - Base tp2_bdg con el esquema "fuentes" cargado con ogr2ogr
       (IGN departamentos, INTA suelos, OSM points/lines/multipolygons).
   Ejecución:  psql -d tp2_bdg -f TP2_LaPaz.sql    (~20 min)
   ##################################################################### */


-- ====================================================================
-- Archivo: 01_construccion.sql
-- ====================================================================
/* =====================================================================
   TP2 - Bases de Datos Avanzadas 2026 - UADER FCyT
   Riesgo Hídrico y Accesibilidad Sanitaria en Entre Ríos
   Departamento de referencia: LA PAZ   |  Localidad de referencia: La Paz
   ---------------------------------------------------------------------
   PUNTO 6 - Construcción de la base de datos espacial
   =====================================================================

   Fuentes cargadas "en crudo" con ogr2ogr en el esquema fuentes:
     fuentes.ign_departamentos  <- IGN, WFS ign:departamento (SHP), EPSG:4326
     fuentes.inta_suelos        <- INTA WFS geo-nodo03, Carta de Suelos 1:100.000
     fuentes.osm_points / osm_lines / osm_multipolygons
                                <- OSM (extracto Geofabrik Argentina, recortado
                                   al rectángulo de Entre Ríos con ogr2ogr -spat)

   Comandos usados (referencia, se ejecutan desde la terminal):
     ogr2ogr -f PostgreSQL "PG:dbname=tp2_bdg user=postgres" departamentoPolygon.shp
             -nln ign_departamentos -lco SCHEMA=fuentes -lco GEOMETRY_NAME=geom
             -oo ENCODING=ISO-8859-1 -nlt PROMOTE_TO_MULTI
     ogr2ogr -f PostgreSQL "PG:..." suelos.geojson -nln inta_suelos ...
     ogr2ogr -f PostgreSQL "PG:..." entrerios_osm.gpkg points|lines|multipolygons
             -nln osm_<capa> ...

   Sistema de referencia:
     - Almacenamiento: EPSG:4326 (WGS84), como sugiere la consigna.
     - Cálculos métricos: EPSG:5347 (POSGAR 2007 / Argentina faja 5, meridiano
       central -60°). La Paz está entre -59.98° y -58.93°, o sea a menos de
       1.1° del meridiano central: la deformación de Gauss-Krüger es mínima.
       El EPSG:5343 citado como ejemplo en la consigna es la FAJA 1 (meridiano
       -72°, cordillera) y a 12° de distancia introduce errores apreciables.
     - Cada tabla tiene una columna generada geom_m (5347) para no repetir
       ST_Transform en cada consulta y poder indexarla.
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS entrerios;
SET search_path = entrerios, public;

DROP TABLE IF EXISTS entrerios.departamentos, entrerios.provincia, entrerios.localidades,
    entrerios.rutas, entrerios.rios, entrerios.rios_area, entrerios.lagunas,
    entrerios.calles, entrerios.salud CASCADE;

/* ---------------------------------------------------------------------
   6.1 Departamentos (IGN)
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.departamentos (
    id      serial PRIMARY KEY,
    codigo  varchar(5) NOT NULL UNIQUE,          -- código INDEC (in1)
    nombre  varchar(60) NOT NULL,
    geom    geometry(MultiPolygon, 4326) NOT NULL,
    geom_m  geometry(MultiPolygon, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

INSERT INTO entrerios.departamentos (codigo, nombre, geom)
SELECT in1, nam, ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
FROM fuentes.ign_departamentos
WHERE in1 LIKE '30%';

-- Contorno provincial (auxiliar): unión de los 17 departamentos
CREATE TABLE entrerios.provincia AS
SELECT 'Entre Ríos'::varchar AS nombre,
       ST_Multi(ST_Union(geom))::geometry(MultiPolygon, 4326) AS geom
FROM entrerios.departamentos;

/* ---------------------------------------------------------------------
   6.2 Localidades (OSM place = city, town, village)
   Se asigna el departamento por inclusión espacial (ST_Within).
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.localidades (
    id          serial PRIMARY KEY,
    osm_id      varchar(20),
    nombre      varchar(120),
    tipo        varchar(20),       -- city / town / village
    poblacion   integer,
    id_depto    integer REFERENCES entrerios.departamentos(id),
    geom        geometry(Point, 4326) NOT NULL,
    geom_m      geometry(Point, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

INSERT INTO entrerios.localidades (osm_id, nombre, tipo, poblacion, id_depto, geom)
SELECT p.osm_id, p.name, p.place,
       CASE WHEN p.population ~ '^\d+$' THEN p.population::int END,
       d.id, p.geom
FROM fuentes.osm_points p
JOIN entrerios.departamentos d ON ST_Within(p.geom, d.geom)
WHERE p.place IN ('city', 'town', 'village');

-- Depuración de duplicados: en OSM aparecen dos nodos "La Paz" en el
-- departamento (osm 198457357 town, 24.716 hab. y osm 5234286373 village,
-- 500 hab., 45 km al norte sobre la RN12). Ambos apuntan al MISMO objeto
-- de Wikidata (Q2440276 = La Paz, Entre Ríos): el segundo es un nodo
-- duplicado y mal ubicado. Regla general: si dos localidades comparten
-- wikidata se conserva la de mayor jerarquía (city > town > village).
ALTER TABLE entrerios.localidades ADD COLUMN wikidata varchar(20);
UPDATE entrerios.localidades l
SET wikidata = substring(p.other_tags from '"wikidata"=>"([^"]+)"')
FROM fuentes.osm_points p WHERE p.osm_id = l.osm_id;

DELETE FROM entrerios.localidades x
USING entrerios.localidades y
WHERE x.wikidata = y.wikidata AND x.id <> y.id
  AND array_position(ARRAY['city', 'town', 'village'], x.tipo)
    > array_position(ARRAY['city', 'town', 'village'], y.tipo);

/* ---------------------------------------------------------------------
   6.3 Rutas principales (OSM highway = motorway, trunk, primary, secondary)
   Se recortan al contorno provincial. Se deriva la jurisdicción desde ref:
   RN = nacional, RP = provincial.
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.rutas (
    id          serial PRIMARY KEY,
    osm_id      varchar(20),
    nombre      varchar(200),
    ref         varchar(60),
    jurisdiccion varchar(12),
    highway     varchar(20),
    puente      boolean,
    geom        geometry(MultiLineString, 4326) NOT NULL,
    geom_m      geometry(MultiLineString, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

INSERT INTO entrerios.rutas (osm_id, nombre, ref, jurisdiccion, highway, puente, geom)
SELECT l.osm_id, l.name, l.ref,
       CASE WHEN l.ref ~* '^\s*(RN|Ruta Nacional)' THEN 'Nacional'
            WHEN l.ref ~* '^\s*(RP|Ruta Provincial)' THEN 'Provincial'
            ELSE 'Sin dato' END,
       l.highway,
       l.bridge IS NOT NULL AND l.bridge <> 'no',
       ST_Multi(CASE WHEN ST_CoveredBy(l.geom, pr.geom) THEN l.geom
                     ELSE ST_CollectionExtract(ST_Intersection(l.geom, pr.geom), 2) END)
FROM fuentes.osm_lines l, entrerios.provincia pr
WHERE l.highway IN ('motorway', 'trunk', 'primary', 'secondary')
  AND ST_Intersects(l.geom, pr.geom);

/* ---------------------------------------------------------------------
   6.4 Ríos y arroyos (OSM waterway = river, stream) - líneas
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.rios (
    id        serial PRIMARY KEY,
    osm_id    varchar(20),
    nombre    varchar(200),
    tipo      varchar(20),            -- river / stream
    geom      geometry(MultiLineString, 4326) NOT NULL,
    geom_m    geometry(MultiLineString, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

INSERT INTO entrerios.rios (osm_id, nombre, tipo, geom)
SELECT l.osm_id, l.name, l.waterway,
       ST_Multi(CASE WHEN ST_CoveredBy(l.geom, pr.geom) THEN l.geom
                     ELSE ST_CollectionExtract(ST_Intersection(l.geom, pr.geom), 2) END)
FROM fuentes.osm_lines l, entrerios.provincia pr
WHERE l.waterway IN ('river', 'stream')
  AND ST_Intersects(l.geom, pr.geom);

/* ---------------------------------------------------------------------
   6.5 Cuerpos de agua (OSM natural = water)
   Decisión: OSM etiqueta también como natural=water el CAUCE de los ríos
   (water=river: Paraná, Guayquiraró, riachos). Esos polígonos NO son lagunas,
   así que se separan en rios_area. En lagunas quedan lake, pond, lagoon,
   oxbow (madrejón), reservoir y los natural=water sin subtipo.
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.lagunas (
    id        serial PRIMARY KEY,
    osm_id    varchar(20),
    nombre    varchar(200),
    tipo      varchar(30),
    geom      geometry(MultiPolygon, 4326) NOT NULL,
    geom_m    geometry(MultiPolygon, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

CREATE TABLE entrerios.rios_area (LIKE entrerios.lagunas INCLUDING ALL);

WITH agua AS (
    SELECT COALESCE(m.osm_id, m.osm_way_id) AS osm_id, m.name, COALESCE(m.water, 'sin_tipo') AS tipo,
           ST_Multi(ST_CollectionExtract(ST_MakeValid(m.geom), 3)) AS geom
    FROM fuentes.osm_multipolygons m, entrerios.provincia pr
    WHERE m.natural = 'water' AND ST_Intersects(m.geom, pr.geom)
), recorte AS (
    SELECT a.osm_id, a.name, a.tipo,
           ST_Multi(CASE WHEN ST_CoveredBy(a.geom, pr.geom) THEN a.geom
                         ELSE ST_CollectionExtract(ST_Intersection(a.geom, pr.geom), 3) END) AS geom
    FROM agua a, entrerios.provincia pr
)
INSERT INTO entrerios.lagunas (osm_id, nombre, tipo, geom)
SELECT osm_id, name, tipo, geom FROM recorte
WHERE tipo NOT IN ('river', 'stream', 'canal', 'ditch', 'drain', 'wastewater', 'stream_pool')
  AND NOT ST_IsEmpty(geom);

INSERT INTO entrerios.rios_area (osm_id, nombre, tipo, geom)
SELECT COALESCE(m.osm_id, m.osm_way_id), m.name, m.water,
       ST_Multi(ST_CollectionExtract(ST_Intersection(ST_MakeValid(m.geom), pr.geom), 3))
FROM fuentes.osm_multipolygons m, entrerios.provincia pr
WHERE m.natural = 'water' AND m.water IN ('river', 'stream', 'canal')
  AND ST_Intersects(m.geom, pr.geom);
DELETE FROM entrerios.rios_area WHERE ST_IsEmpty(geom);

/* ---------------------------------------------------------------------
   6.6 Calles (OSM highway = primary, secondary, tertiary, residential, unclassified)
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.calles (
    id        serial PRIMARY KEY,
    osm_id    varchar(20),
    nombre    varchar(200),
    highway   varchar(20),
    superficie varchar(30),
    puente    boolean,
    geom      geometry(MultiLineString, 4326) NOT NULL,
    geom_m    geometry(MultiLineString, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

INSERT INTO entrerios.calles (osm_id, nombre, highway, superficie, puente, geom)
SELECT l.osm_id, l.name, l.highway, l.surface,
       l.bridge IS NOT NULL AND l.bridge <> 'no',
       ST_Multi(CASE WHEN ST_CoveredBy(l.geom, pr.geom) THEN l.geom
                     ELSE ST_CollectionExtract(ST_Intersection(l.geom, pr.geom), 2) END)
FROM fuentes.osm_lines l, entrerios.provincia pr
WHERE l.highway IN ('primary', 'secondary', 'tertiary', 'residential', 'unclassified')
  AND ST_Intersects(l.geom, pr.geom);

/* ---------------------------------------------------------------------
   6.7 Establecimientos de salud (OSM amenity = hospital, clinic)
   En OSM un hospital puede estar mapeado como punto, como polígono o como
   ambos. Los polígonos se convierten a punto con ST_PointOnSurface (siempre
   cae dentro del edificio, a diferencia del centroide) y se descartan los
   puntos que caen dentro de un polígono de salud (duplicados).
   --------------------------------------------------------------------- */
CREATE TABLE entrerios.salud (
    id        serial PRIMARY KEY,
    osm_id    varchar(20),
    nombre    varchar(200),
    tipo      varchar(20),         -- hospital / clinic
    origen    varchar(10),         -- punto / poligono
    id_depto  integer REFERENCES entrerios.departamentos(id),
    geom      geometry(Point, 4326) NOT NULL,
    geom_m    geometry(Point, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

WITH pol AS (
    SELECT COALESCE(osm_id, osm_way_id) AS osm_id, name, amenity, ST_MakeValid(geom) AS geom
    FROM fuentes.osm_multipolygons
    WHERE amenity IN ('hospital', 'clinic')
), todos AS (
    SELECT osm_id, name, amenity, 'poligono' AS origen, ST_PointOnSurface(geom) AS geom FROM pol
    UNION ALL
    SELECT p.osm_id, p.name, p.amenity, 'punto', p.geom
    FROM fuentes.osm_points p
    WHERE p.amenity IN ('hospital', 'clinic')
      AND NOT EXISTS (SELECT 1 FROM pol WHERE ST_Intersects(pol.geom, p.geom))
)
INSERT INTO entrerios.salud (osm_id, nombre, tipo, origen, id_depto, geom)
SELECT t.osm_id, COALESCE(t.name, '(sin nombre)'), t.amenity, t.origen, d.id, t.geom
FROM todos t
JOIN entrerios.departamentos d ON ST_Within(t.geom, d.geom);

/* ---------------------------------------------------------------------
   Índices espaciales (GiST) sobre ambas columnas geométricas
   --------------------------------------------------------------------- */
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['departamentos','localidades','rutas','rios','rios_area',
                             'lagunas','calles','salud'] LOOP
        EXECUTE format('CREATE INDEX ON entrerios.%I USING gist (geom)', t);
        EXECUTE format('CREATE INDEX ON entrerios.%I USING gist (geom_m)', t);
        EXECUTE format('ANALYZE entrerios.%I', t);
    END LOOP;
END $$;
CREATE INDEX ON entrerios.provincia USING gist (geom);

-- ====================================================================
-- Archivo: 02_validaciones.sql
-- ====================================================================
/* =====================================================================
   PUNTO 6 (cont.) - Controles de calidad de la importación
   Para cada tabla del esquema entrerios se verifica:
     tipo de geometría, SRID, cantidad de registros,
     geometrías nulas, vacías e inválidas.
   ===================================================================== */
SET search_path = entrerios, public;

CREATE OR REPLACE FUNCTION entrerios.fn_control_calidad()
RETURNS TABLE (tabla text, columna text, tipo_declarado text, srid_declarado int,
               tipos_reales text, srids_reales text, registros bigint,
               nulas bigint, vacias bigint, invalidas bigint)
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT f_table_name AS t, f_geometry_column AS c, type, srid
             FROM geometry_columns
             WHERE f_table_schema = 'entrerios' AND f_geometry_column = 'geom'
             ORDER BY 1
    LOOP
        RETURN QUERY EXECUTE format($q$
            SELECT %L::text, %L::text, %L::text, %s,
                   (SELECT string_agg(DISTINCT ST_GeometryType(%2$I), ', ') FROM entrerios.%1$I),
                   (SELECT string_agg(DISTINCT ST_SRID(%2$I)::text, ', ') FROM entrerios.%1$I),
                   count(*),
                   count(*) FILTER (WHERE %2$I IS NULL),
                   count(*) FILTER (WHERE ST_IsEmpty(%2$I)),
                   count(*) FILTER (WHERE NOT ST_IsValid(%2$I))
            FROM entrerios.%1$I $q$, r.t, r.c, r.type, r.srid);
    END LOOP;
END $$;

-- 6.a Resumen de control de calidad
SELECT * FROM entrerios.fn_control_calidad();

-- 6.b Control puntual con ST_GeometryType y ST_SRID (ejemplo pedido por la consigna)
SELECT nombre, ST_GeometryType(geom) AS tipo, ST_SRID(geom) AS srid,
       ST_IsValid(geom) AS valida, ST_NPoints(geom) AS vertices
FROM entrerios.departamentos
ORDER BY nombre;

-- 6.c Geometrías inválidas en la fuente cruda y su motivo.
--     (La carga ya aplicó ST_MakeValid; acá se muestra qué se corrigió.)
SELECT 'ign_departamentos' AS fuente, count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalidas
FROM fuentes.ign_departamentos
UNION ALL
SELECT 'osm_multipolygons (natural=water)', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.osm_multipolygons WHERE "natural" = 'water'
UNION ALL
SELECT 'osm_multipolygons (salud)', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.osm_multipolygons WHERE amenity IN ('hospital', 'clinic')
UNION ALL
SELECT 'inta_suelos', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.inta_suelos;

SELECT osm_id, name, ST_IsValidReason(geom) AS motivo
FROM fuentes.osm_multipolygons
WHERE "natural" = 'water' AND NOT ST_IsValid(geom)
LIMIT 10;

-- 6.d Corrección con ST_MakeValid sobre cualquier geometría que quedara inválida
--     (idempotente: si no hay inválidas no modifica nada).
UPDATE entrerios.lagunas   SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);
UPDATE entrerios.rios_area SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);
UPDATE entrerios.departamentos SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);

-- 6.e Coherencia topológica: la suma de áreas departamentales vs. el área provincial
--     (detecta superposiciones o huecos entre departamentos del IGN).
SELECT round((SELECT sum(ST_Area(geom_m)) FROM entrerios.departamentos)::numeric / 1e6, 1) AS suma_deptos_km2,
       round(ST_Area(ST_Transform(geom, 5347))::numeric / 1e6, 1)                         AS provincia_km2
FROM entrerios.provincia;

-- 6.f Contenido por departamento (verificación de razonabilidad de OSM)
SELECT d.nombre,
       (SELECT count(*) FROM entrerios.localidades l WHERE l.id_depto = d.id) AS localidades,
       (SELECT count(*) FROM entrerios.salud s       WHERE s.id_depto = d.id) AS salud
FROM entrerios.departamentos d
ORDER BY d.nombre;

-- ====================================================================
-- Archivo: 03_hidrografia.sql
-- ====================================================================
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

-- ====================================================================
-- Archivo: 04_accesibilidad.sql
-- ====================================================================
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

-- ====================================================================
-- Archivo: 05_riesgo_hidrico.sql
-- ====================================================================
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

-- ====================================================================
-- Archivo: 06_funciones.sql
-- ====================================================================
/* =====================================================================
   PUNTO 10 - Funciones y automatización mediante SQL
   ===================================================================== */
SET search_path = entrerios, public;

/* ---------------------------------------------------------------------
   10.1 fn_riesgo_localidad(nombre_localidad)
   Distancia mínima (EPSG:5347, metros) desde la localidad al río,
   arroyo, laguna o cauce más cercano. Clasificación:
       Alto  < 1 km  |  Medio 1 - 3 km  |  Bajo > 3 km
   Devuelve una fila por cada localidad con ese nombre: en OSM hay
   homónimos (p. ej. hay dos "La Paz" en el departamento), por eso se
   informa también el departamento y el osm_id. La búsqueda ignora
   mayúsculas y tildes (translate), así 'concepcion del uruguay' funciona.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION entrerios.fn_riesgo_localidad(nombre_localidad text)
RETURNS TABLE (localidad text, departamento text, osm_id text,
               elemento_cercano text, tipo_elemento text, distancia_m numeric, riesgo text)
LANGUAGE sql STABLE AS $$
    WITH loc AS (
        SELECT l.*, d.nombre AS depto
        FROM entrerios.localidades l
        JOIN entrerios.departamentos d ON d.id = l.id_depto
        WHERE translate(lower(l.nombre), 'áéíóúü', 'aeiouu')
            = translate(lower(trim(nombre_localidad)), 'áéíóúü', 'aeiouu')
    )
    SELECT loc.nombre, loc.depto, loc.osm_id, h.nombre, h.tipo, round(h.dist::numeric, 0),
           CASE WHEN h.dist < 1000 THEN 'Alto'
                WHEN h.dist <= 3000 THEN 'Medio'
                ELSE 'Bajo' END
    FROM loc
    CROSS JOIN LATERAL (
        SELECT * FROM (
            (SELECT COALESCE(r.nombre, '(sin nombre)') AS nombre, r.tipo, ST_Distance(r.geom_m, loc.geom_m) AS dist
             FROM entrerios.rios r ORDER BY r.geom_m <-> loc.geom_m LIMIT 1)
            UNION ALL
            (SELECT COALESCE(g.nombre, '(sin nombre)'), 'laguna/' || g.tipo, ST_Distance(g.geom_m, loc.geom_m)
             FROM entrerios.lagunas g ORDER BY g.geom_m <-> loc.geom_m LIMIT 1)
            UNION ALL
            (SELECT COALESCE(a.nombre, '(sin nombre)'), 'cauce/' || a.tipo, ST_Distance(a.geom_m, loc.geom_m)
             FROM entrerios.rios_area a ORDER BY a.geom_m <-> loc.geom_m LIMIT 1)
        ) c ORDER BY dist LIMIT 1
    ) h
    ORDER BY loc.depto;
$$;

-- Pruebas: todas las localidades de La Paz + algunas de otros departamentos
SELECT r.*
FROM (SELECT DISTINCT l.nombre FROM entrerios.localidades l
      JOIN entrerios.departamentos d ON d.id = l.id_depto WHERE d.nombre = 'La Paz') x
CROSS JOIN LATERAL entrerios.fn_riesgo_localidad(x.nombre) r
WHERE r.departamento = 'La Paz'
ORDER BY r.distancia_m;

SELECT * FROM entrerios.fn_riesgo_localidad('Paraná');
SELECT * FROM entrerios.fn_riesgo_localidad('concordia');
SELECT * FROM entrerios.fn_riesgo_localidad('Villaguay');
SELECT * FROM entrerios.fn_riesgo_localidad('Localidad inexistente');   -- 0 filas

-- Distribución provincial de la clasificación
SELECT r.riesgo, count(*) AS localidades
FROM entrerios.localidades l
CROSS JOIN LATERAL entrerios.fn_riesgo_localidad(l.nombre) r
WHERE r.osm_id = l.osm_id
GROUP BY r.riesgo ORDER BY 1;

/* ---------------------------------------------------------------------
   10.2 MBR (Mínimo Rectángulo Delimitador) de Entre Ríos con ST_Envelope
   Se calcula sobre la geometría en 4326 (rectángulo alineado a
   meridianos y paralelos) y se mide con geography (área geodésica real
   sobre el elipsoide). También se muestra el MBR en la proyección 5347.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r10_mbr;
CREATE TABLE entrerios.r10_mbr AS
SELECT 1 AS id, ST_Envelope(geom)::geometry(Polygon, 4326) AS geom FROM entrerios.provincia;

SELECT ST_AsText(m.geom) AS mbr_wkt,
       round((ST_Area(m.geom::geography) / 1e6)::numeric, 0)               AS mbr_km2,
       round((ST_Area(p.geom::geography) / 1e6)::numeric, 0)               AS provincia_km2,
       round((ST_Area(ST_Envelope(ST_Transform(p.geom, 5347))) / 1e6)::numeric, 0) AS mbr_5347_km2,
       round((100 * ST_Area(p.geom::geography) / ST_Area(m.geom::geography))::numeric, 1) AS pct_ocupado,
       round((ST_Area(m.geom::geography) / ST_Area(p.geom::geography))::numeric, 2)       AS relacion
FROM entrerios.r10_mbr m, entrerios.provincia p;

/* ---------------------------------------------------------------------
   10.3 fn_hospital_cercano(lat, lon)
   Simula una persona que pide asistencia dando solo su posición GPS.
   Atención: ST_MakePoint recibe (x = lon, y = lat).
   Se preseleccionan 10 candidatos con KNN (<->, rápido, en grados) y se
   ordenan por distancia geodésica real (geography), que es exacta en
   cualquier lugar de la provincia (no depende de la faja de proyección).
   Parámetro opcional solo_hospitales para excluir clínicas/consultorios.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION entrerios.fn_hospital_cercano(lat double precision, lon double precision,
                                                         solo_hospitales boolean DEFAULT false)
RETURNS TABLE (establecimiento text, tipo text, departamento text, distancia_m numeric, distancia_km numeric)
LANGUAGE sql STABLE AS $$
    WITH p AS (SELECT ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS g),
    cand AS (
        SELECT s.nombre, s.tipo, s.id_depto, s.geom
        FROM entrerios.salud s, p
        WHERE NOT solo_hospitales OR s.tipo = 'hospital'
        ORDER BY s.geom <-> p.g LIMIT 10
    )
    SELECT c.nombre, c.tipo, d.nombre,
           round(ST_Distance(c.geom::geography, p.g::geography)::numeric, 0),
           round((ST_Distance(c.geom::geography, p.g::geography) / 1000)::numeric, 2)
    FROM cand c, p, entrerios.departamentos d
    WHERE d.id = c.id_depto
    ORDER BY ST_Distance(c.geom::geography, p.g::geography)
    LIMIT 1;
$$;

-- Pruebas
SELECT 'Plaza de La Paz'          AS caso, * FROM entrerios.fn_hospital_cercano(-30.7423, -59.6455);
SELECT 'Campo entre Bovril y Alcaraz' AS caso, * FROM entrerios.fn_hospital_cercano(-31.10, -59.30);
SELECT 'Norte del depto (Guayquiraró)' AS caso, * FROM entrerios.fn_hospital_cercano(-30.40, -59.40);
SELECT 'Mismo punto, solo hospitales' AS caso, * FROM entrerios.fn_hospital_cercano(-30.40, -59.40, true);

/* ---------------------------------------------------------------------
   10.4 Agrupamiento de establecimientos con ST_ClusterKMeans (k = 3)
   ST_ClusterKMeans es una función de ventana: asigna a cada fila el
   número de grupo. Se usan coordenadas proyectadas (5347) para que la
   distancia del algoritmo sea en metros.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r10_kmeans_salud, entrerios.r10_kmeans_centroides;
CREATE TABLE entrerios.r10_kmeans_salud AS
SELECT s.id, s.nombre, s.tipo,
       ST_ClusterKMeans(s.geom_m, 3) OVER () + 1 AS grupo,
       s.geom
FROM entrerios.salud s
JOIN entrerios.departamentos d ON d.id = s.id_depto AND d.nombre = 'La Paz';

CREATE TABLE entrerios.r10_kmeans_centroides AS
SELECT k.grupo, count(*) AS establecimientos,
       string_agg(k.nombre, ' | ' ORDER BY k.nombre) AS integrantes,
       ST_Centroid(ST_Collect(k.geom))::geometry(Point, 4326) AS geom
FROM entrerios.r10_kmeans_salud k
GROUP BY k.grupo;

SELECT grupo, nombre, tipo FROM entrerios.r10_kmeans_salud ORDER BY grupo, nombre;

-- Centroides: localidad y ruta más próximas (para evaluar si son ubicaciones útiles)
SELECT c.grupo, c.establecimientos, round(ST_Y(c.geom)::numeric, 5) AS lat, round(ST_X(c.geom)::numeric, 5) AS lon,
       loc.nombre AS localidad_cercana, round(loc.dist::numeric) AS dist_localidad_m,
       rt.ref AS ruta_cercana, round(rt.dist::numeric) AS dist_ruta_m,
       c.integrantes
FROM entrerios.r10_kmeans_centroides c
CROSS JOIN LATERAL (SELECT l.nombre, ST_Distance(l.geom_m, ST_Transform(c.geom, 5347)) AS dist
                    FROM entrerios.localidades l ORDER BY l.geom_m <-> ST_Transform(c.geom, 5347) LIMIT 1) loc
CROSS JOIN LATERAL (SELECT r.ref, ST_Distance(r.geom_m, ST_Transform(c.geom, 5347)) AS dist
                    FROM entrerios.rutas r WHERE r.ref IS NOT NULL
                    ORDER BY r.geom_m <-> ST_Transform(c.geom, 5347) LIMIT 1) rt
ORDER BY c.grupo;

-- ====================================================================
-- Archivo: 07_calles.sql
-- ====================================================================
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

-- ====================================================================
-- Archivo: 08_suelo.sql
-- ====================================================================
/* =====================================================================
   PUNTO 12 - Información del INTA y uso del suelo
   Capa: Carta de Suelos de Entre Ríos 1:100.000 (INTA, WFS geo-nodo03,
   geonode:carta_de_suelos_unocienmil_...). Es la ÚNICA capa publicada por
   el WFS. No describe el uso ACTUAL del suelo sino su APTITUD, a través
   del Índice de Productividad (ipc, 0-100) de cada unidad cartográfica.

   Clasificación adoptada (criterio del grupo, a partir del IPC):
       IPC >= 30  -> Agrícola            (suelos con aptitud para cultivos)
       20 - 29    -> Agrícola-ganadera   (mixta, cultivos con limitaciones)
       1 - 19     -> Ganadera            (limitaciones severas: hidromorfismo,
                                          sodicidad, vertisoles, erosión)
       0          -> según la unidad cartográfica (simb):
                     Ar, AIB, CR, CAg -> Planicie inundable / agua
                                         (arroyos, islas y bañados, cárcavas,
                                          cuerpos de agua)
                     AU               -> Urbana (ejidos urbanos: también
                                         tienen IPC 0 en la carta)
                     X, otros         -> Misceláneas (canteras, barrancas)
   Para 12.2 y 12.3 se consideran "áreas agrícolas" las de IPC >= 30.
   ===================================================================== */
SET search_path = entrerios, public;

DROP TABLE IF EXISTS entrerios.suelo CASCADE;
CREATE TABLE entrerios.suelo (
    id          serial PRIMARY KEY,
    simb        varchar(20),
    unidad      varchar(200),
    suelo_dominante varchar(100),
    limitante   varchar(200),
    ipc         integer,
    clase       varchar(30),
    depto_inta  varchar(60),
    geom        geometry(MultiPolygon, 4326) NOT NULL,
    geom_m      geometry(MultiPolygon, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED
);

INSERT INTO entrerios.suelo (simb, unidad, suelo_dominante, limitante, ipc, clase, depto_inta, geom)
SELECT s.simb, s.nombre, NULLIF(s.t_1, ''), NULLIF(s.l_1, ''), s.ipc,
       CASE WHEN s.ipc >= 30 THEN 'Agrícola'
            WHEN s.ipc >= 20 THEN 'Agrícola-ganadera'
            WHEN s.ipc >= 1  THEN 'Ganadera'
            WHEN s.simb IN ('Ar', 'AIB', 'CR', 'CAg') THEN 'Planicie inundable / agua'
            WHEN s.simb = 'AU' THEN 'Urbana'
            ELSE 'Misceláneas' END,
       s.depart,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(s.geom), 3))
FROM fuentes.inta_suelos s;

DELETE FROM entrerios.suelo WHERE ST_IsEmpty(geom);
CREATE INDEX ON entrerios.suelo USING gist (geom);
CREATE INDEX ON entrerios.suelo USING gist (geom_m);
ANALYZE entrerios.suelo;

-- Control de calidad de la nueva capa (mismo criterio que el punto 6)
SELECT count(*) AS registros, string_agg(DISTINCT ST_GeometryType(geom), ',') AS tipo,
       string_agg(DISTINCT ST_SRID(geom)::text, ',') AS srid,
       count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalidas
FROM entrerios.suelo;

-- Suelo recortado a La Paz (base de 12.1 - 12.3)
DROP TABLE IF EXISTS entrerios.r12_suelo_lapaz CASCADE;
CREATE TABLE entrerios.r12_suelo_lapaz AS
SELECT s.id, s.simb, s.unidad, s.suelo_dominante, s.limitante, s.ipc, s.clase,
       ST_Multi(ST_CollectionExtract(ST_Intersection(s.geom_m, d.geom_m), 3))::geometry(MultiPolygon, 5347) AS geom_m
FROM entrerios.suelo s
JOIN entrerios.departamentos d ON d.nombre = 'La Paz' AND ST_Intersects(s.geom_m, d.geom_m);
DELETE FROM entrerios.r12_suelo_lapaz WHERE ST_IsEmpty(geom_m);
ALTER TABLE entrerios.r12_suelo_lapaz ADD COLUMN geom geometry(MultiPolygon, 4326);
UPDATE entrerios.r12_suelo_lapaz SET geom = ST_Multi(ST_Transform(geom_m, 4326));
CREATE INDEX ON entrerios.r12_suelo_lapaz USING gist (geom_m);

/* ---------------------------------------------------------------------
   12.1 Porcentaje del departamento por clase de aptitud
   El porcentaje se calcula sobre la superficie del DEPARTAMENTO (IGN);
   la diferencia con la suma de clases es superficie sin cobertura INTA
   (bordes sobre el Paraná, donde los límites de ambas fuentes difieren).
   --------------------------------------------------------------------- */
SELECT s.clase,
       round((sum(ST_Area(s.geom_m)) / 1e6)::numeric, 1) AS km2,
       round((100 * sum(ST_Area(s.geom_m)) / (SELECT ST_Area(geom_m) FROM entrerios.departamentos WHERE nombre = 'La Paz'))::numeric, 1) AS pct_depto
FROM entrerios.r12_suelo_lapaz s
GROUP BY ROLLUP (s.clase)
ORDER BY s.clase NULLS LAST;

-- Agrícola vs. otros usos (lo pedido) + sensibilidad al umbral
SELECT round((100 * sum(ST_Area(geom_m)) FILTER (WHERE ipc >= 30) / sum(ST_Area(geom_m)))::numeric, 1) AS pct_agricola_ipc30,
       round((100 * sum(ST_Area(geom_m)) FILTER (WHERE ipc <  30) / sum(ST_Area(geom_m)))::numeric, 1) AS pct_otros_ipc30,
       round((100 * sum(ST_Area(geom_m)) FILTER (WHERE ipc >= 20) / sum(ST_Area(geom_m)))::numeric, 1) AS pct_agricola_si_umbral_20,
       round((100 * sum(ST_Area(geom_m)) FILTER (WHERE ipc >= 40) / sum(ST_Area(geom_m)))::numeric, 1) AS pct_agricola_si_umbral_40
FROM entrerios.r12_suelo_lapaz;

-- Unidades agrícolas principales
SELECT unidad, suelo_dominante, ipc, round((sum(ST_Area(geom_m)) / 1e6)::numeric, 1) AS km2
FROM entrerios.r12_suelo_lapaz WHERE clase = 'Agrícola'
GROUP BY unidad, suelo_dominante, ipc ORDER BY km2 DESC LIMIT 10;

/* ---------------------------------------------------------------------
   12.2 Áreas agrícolas expuestas: intersección agrícola x ZRH
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r12_agricola_expuesta;
CREATE TABLE entrerios.r12_agricola_expuesta AS
SELECT s.id, s.unidad, s.ipc,
       ST_Multi(ST_CollectionExtract(ST_Intersection(s.geom_m, z.geom_m), 3))::geometry(MultiPolygon, 5347) AS geom_m
FROM entrerios.r12_suelo_lapaz s
JOIN entrerios.zona_riesgo_hidrico z ON z.depto = 'La Paz' AND ST_Intersects(s.geom_m, z.geom_m)
WHERE s.clase = 'Agrícola';
DELETE FROM entrerios.r12_agricola_expuesta WHERE ST_IsEmpty(geom_m);
ALTER TABLE entrerios.r12_agricola_expuesta ADD COLUMN geom geometry(MultiPolygon, 4326);
UPDATE entrerios.r12_agricola_expuesta SET geom = ST_Multi(ST_Transform(geom_m, 4326));

SELECT round((sum(ST_Area(e.geom_m)) / 1e6)::numeric, 1) AS agricola_expuesta_km2,
       round((SELECT sum(ST_Area(geom_m)) FROM entrerios.r12_suelo_lapaz WHERE clase = 'Agrícola')::numeric / 1e6, 1) AS agricola_total_km2,
       round((100 * sum(ST_Area(e.geom_m)) /
              (SELECT sum(ST_Area(geom_m)) FROM entrerios.r12_suelo_lapaz WHERE clase = 'Agrícola'))::numeric, 1) AS pct_expuesta
FROM entrerios.r12_agricola_expuesta e;

-- Misma medida con la ZRH "principal" (solo ríos, lagunas y cauces)
SELECT round((100 * sum(ST_Area(ST_Intersection(s.geom_m, z.geom_m_principal))) /
              (SELECT sum(ST_Area(geom_m)) FROM entrerios.r12_suelo_lapaz WHERE clase = 'Agrícola'))::numeric, 1) AS pct_expuesta_zrh_principal
FROM entrerios.r12_suelo_lapaz s
JOIN entrerios.zona_riesgo_hidrico z ON z.depto = 'La Paz' AND ST_Intersects(s.geom_m, z.geom_m_principal)
WHERE s.clase = 'Agrícola';

SELECT unidad, ipc, round((sum(ST_Area(geom_m)) / 1e6)::numeric, 1) AS km2_expuestos
FROM entrerios.r12_agricola_expuesta GROUP BY unidad, ipc ORDER BY km2_expuestos DESC LIMIT 10;

/* ---------------------------------------------------------------------
   12.3 Corredores productivos: rutas principales x áreas agrícolas
   ST_Intersection de cada ruta con el área agrícola disuelta.
   Indicador: % del recorrido de cada ruta que atraviesa suelo agrícola.
   Además se genera el "corredor" (buffer de 2 km alrededor de la ruta
   dentro del área agrícola), que representa la franja de producción con
   salida directa a la red vial.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r12_corredores;
CREATE TABLE entrerios.r12_corredores AS
WITH agri AS (SELECT ST_Union(geom_m) AS g FROM entrerios.r12_suelo_lapaz WHERE clase = 'Agrícola')
SELECT r.ref, r.jurisdiccion, r.km AS km_ruta,
       round((ST_Length(ST_Intersection(ST_Transform(r.geom, 5347), agri.g)) / 1000)::numeric, 1) AS km_en_agricola,
       round((100 * ST_Length(ST_Intersection(ST_Transform(r.geom, 5347), agri.g)) / NULLIF(ST_Length(ST_Transform(r.geom, 5347)), 0))::numeric, 1) AS pct_en_agricola,
       round((ST_Area(ST_Intersection(ST_Buffer(ST_Transform(r.geom, 5347), 2000), agri.g)) / 1e6)::numeric, 1) AS sup_agricola_corredor_2km_km2,
       ST_Multi(ST_CollectionExtract(ST_Transform(ST_Intersection(ST_Transform(r.geom, 5347), agri.g), 4326), 2))::geometry(MultiLineString, 4326) AS geom,
       ST_Multi(ST_CollectionExtract(ST_Transform(ST_Intersection(ST_Buffer(ST_Transform(r.geom, 5347), 2000), agri.g), 4326), 3))::geometry(MultiPolygon, 4326) AS geom_corredor
FROM entrerios.r8_rutas_lapaz r, agri
WHERE r.jurisdiccion IN ('Nacional', 'Provincial');

SELECT ref, jurisdiccion, km_ruta, km_en_agricola, pct_en_agricola, sup_agricola_corredor_2km_km2
FROM entrerios.r12_corredores ORDER BY km_en_agricola DESC;

-- ====================================================================
-- Archivo: 09_consulta_agregada.sql
-- ====================================================================
/* =====================================================================
   PUNTO 13 - Consulta agregada: situación de emergencia real

   PROBLEMA
   Una crecida de los ríos y arroyos principales (Feliciano, Estacas,
   Alcaraz, Guayquiraró, Paraná, etc.) deja intransitables los tramos de
   la red vial que atraviesan las planicies de inundación. ¿Qué
   localidades de La Paz pierden el acceso por ruta a su hospital, cuánto
   se alarga el viaje para las demás, cuál es el hospital alternativo y en
   qué orden deberían asistirse/evacuarse?

   INFORMACIÓN ESPACIAL UTILIZADA (5 tipos, 3 organismos)
     - Red vial OSM (calles + rutas)                 -> grafo ruteable
     - Hidrografía OSM (ríos y lagunas) -> ZRH principal (buffer 2 km)
     - Suelos INTA: unidades con IPC = 0 (arroyos, bañados, islas,
       planicies aluviales) = terreno bajo, el primero en anegarse
     - Departamentos IGN (área de estudio)
     - Establecimientos de salud y localidades OSM (con población)

   CRITERIO DE CORTE
   Un tramo de la red (que NO sea un puente según OSM) se considera cortado si:
     (a) cruza un río o arroyo: sin puente registrado el cruce es un vado
         o una alcantarilla, que una crecida desborda; o
     (b) está dentro de la ZRH principal Y sobre una unidad de suelo INTA
         de planicie inundable (Arroyos, Ambiente de islas y bañados,
         Cárcavas, Cuerpos de agua).
   Nota: las áreas urbanas (AU) también tienen IPC = 0 en la carta del
   INTA; por eso el criterio usa el tipo de unidad y no el IPC.

   HERRAMIENTAS: pgRouting (pgr_extractVertices, pgr_dijkstraCost,
   pgr_dijkstra), ST_DumpSegments, ST_Intersects, ST_DWithin, KNN.
   ===================================================================== */
SET search_path = entrerios, public;
CREATE EXTENSION IF NOT EXISTS pgrouting;

/* ---------------------------------------------------------------------
   13.1 Grafo ruteable
   Área: La Paz + 30 km (para incluir hospitales de deptos vecinos).
   En OSM las vías se conectan compartiendo NODOS (coordenadas idénticas),
   pero un nodo compartido puede estar en el medio de un way. Para que el
   grafo quede bien conectado se parte cada way en sus segmentos
   elementales (ST_DumpSegments): así cada nodo OSM es un vértice.
   Costo = tiempo de viaje en minutos según categoría de la vía.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.red_vial CASCADE;
CREATE TABLE entrerios.red_vial AS
WITH area AS (
    -- Se simplifica el contorno antes del buffer (para 30 km el detalle es irrelevante)
    -- y se lleva a 4326 para que el filtro use el índice GiST de la tabla cruda.
    SELECT ST_Transform(ST_Buffer(ST_Simplify(geom_m, 200), 30000), 4326) AS g
    FROM entrerios.departamentos WHERE nombre = 'La Paz'
), vias AS (
    SELECT l.osm_id, l.name, l.ref, l.highway,
           COALESCE(l.bridge, 'no') <> 'no' AS puente,
           ST_Transform(l.geom, 5347) AS g
    FROM fuentes.osm_lines l, area
    WHERE l.highway IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link',
                        'secondary', 'secondary_link', 'tertiary', 'tertiary_link',
                        'unclassified', 'residential')
      AND l.geom && area.g
      AND ST_Intersects(l.geom, area.g)
)
SELECT row_number() OVER ()::bigint AS id,
       v.osm_id, v.name, v.ref, v.highway, v.puente,
       CASE WHEN v.highway LIKE 'motorway%' OR v.highway LIKE 'trunk%' THEN 90
            WHEN v.highway LIKE 'primary%'   THEN 80
            WHEN v.highway LIKE 'secondary%' THEN 60
            WHEN v.highway LIKE 'tertiary%'  THEN 50
            WHEN v.highway = 'unclassified'  THEN 40
            ELSE 30 END AS vel_kmh,
       s.geom::geometry(LineString, 5347) AS geom_m
FROM vias v
CROSS JOIN LATERAL ST_DumpSegments(v.g) s;

ALTER TABLE entrerios.red_vial
    ADD COLUMN largo_m double precision, ADD COLUMN costo_min double precision,
    ADD COLUMN source bigint, ADD COLUMN target bigint, ADD COLUMN cortado boolean DEFAULT false;
UPDATE entrerios.red_vial SET largo_m = ST_Length(geom_m),
                              costo_min = ST_Length(geom_m) / 1000.0 / vel_kmh * 60;

-- Vértices (pgRouting 4: pgr_extractVertices reemplaza a pgr_createTopology)
DROP TABLE IF EXISTS entrerios.red_vial_vertices;
CREATE TABLE entrerios.red_vial_vertices AS
SELECT * FROM pgr_extractVertices('SELECT id, geom_m AS geom FROM entrerios.red_vial');

-- pgr_extractVertices devuelve, por vértice, las aristas que salen (out_edges)
-- y las que llegan (in_edges): con eso se asignan source y target sin
-- comparar geometrías.
UPDATE entrerios.red_vial e SET source = v.id
FROM (SELECT id, unnest(out_edges) AS eid FROM entrerios.red_vial_vertices) v WHERE v.eid = e.id;
UPDATE entrerios.red_vial e SET target = v.id
FROM (SELECT id, unnest(in_edges) AS eid FROM entrerios.red_vial_vertices) v WHERE v.eid = e.id;

CREATE INDEX ON entrerios.red_vial (source);
CREATE INDEX ON entrerios.red_vial (target);
CREATE INDEX ON entrerios.red_vial USING gist (geom_m);
CREATE INDEX ON entrerios.red_vial_vertices USING gist (geom);
ANALYZE entrerios.red_vial;  ANALYZE entrerios.red_vial_vertices;

SELECT count(*) AS aristas, round((sum(largo_m) / 1000)::numeric) AS km,
       (SELECT count(*) FROM entrerios.red_vial_vertices) AS vertices
FROM entrerios.red_vial;

-- Conectividad: componentes conexas (la principal debería tener casi todo)
SELECT component, count(*) AS vertices
FROM pgr_connectedComponents('SELECT id, source, target, largo_m AS cost, largo_m AS reverse_cost FROM entrerios.red_vial')
GROUP BY component ORDER BY 2 DESC LIMIT 5;

/* ---------------------------------------------------------------------
   13.2 Tramos cortados por la crecida
   --------------------------------------------------------------------- */
UPDATE entrerios.red_vial SET cortado = false;

-- (a) cruces de agua sin puente
UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.puente
  AND EXISTS (SELECT 1 FROM entrerios.rios r WHERE ST_Intersects(r.geom_m, e.geom_m));

-- (b) planicie inundable (INTA) dentro de la ZRH principal.
--     Se materializa la intersección por polígono (sin ST_Union global,
--     que generaría un único polígono gigante y lento de consultar).
DROP TABLE IF EXISTS tmp_planicie;
CREATE TEMP TABLE tmp_planicie AS
SELECT (ST_Dump(ST_Intersection(s.geom_m, z.geom_m_principal))).geom AS g
FROM entrerios.suelo s
JOIN entrerios.zona_riesgo_hidrico z ON ST_Intersects(s.geom_m, z.geom_m_principal)
WHERE s.clase = 'Planicie inundable / agua'
  AND ST_DWithin(s.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'), 30000);
CREATE INDEX ON tmp_planicie USING gist (g);
ANALYZE tmp_planicie;

UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.cortado AND NOT e.puente
  AND EXISTS (SELECT 1 FROM tmp_planicie p WHERE ST_Intersects(p.g, e.geom_m));

SELECT count(*) FILTER (WHERE cortado) AS aristas_cortadas,
       round((sum(largo_m) FILTER (WHERE cortado) / 1000)::numeric, 1) AS km_cortados,
       round((100 * sum(largo_m) FILTER (WHERE cortado) / sum(largo_m))::numeric, 1) AS pct_red
FROM entrerios.red_vial;

DROP TABLE IF EXISTS entrerios.r13_tramos_cortados;
CREATE TABLE entrerios.r13_tramos_cortados AS
SELECT row_number() OVER () AS id, COALESCE(ref, name, highway) AS via,
       ST_Multi(ST_Transform(ST_LineMerge(ST_Collect(geom_m)), 4326))::geometry(MultiLineString, 4326) AS geom,
       round(sum(largo_m)::numeric) AS metros
FROM entrerios.red_vial WHERE cortado
GROUP BY COALESCE(ref, name, highway);

SELECT via, metros FROM entrerios.r13_tramos_cortados ORDER BY metros DESC LIMIT 15;

/* ---------------------------------------------------------------------
   13.3 Acceso a hospitales: situación normal vs. con crecida
   Cada localidad y cada hospital se "enganchan" al vértice más cercano
   del grafo (KNN). Con pgr_dijkstraCost (muchos-a-muchos) se obtiene el
   tiempo mínimo a cada hospital; se toma el menor por localidad.
   Solo se consideran hospitales (no consultorios) porque en una
   emergencia se necesita internación/guardia.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tmp_nodos;
CREATE TEMP TABLE tmp_nodos AS
SELECT 'L' AS clase, l.id, l.nombre, l.poblacion, v.id AS vid
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz'
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> l.geom_m LIMIT 1) v
UNION ALL
SELECT 'H', s.id, s.nombre, NULL, v.id
FROM entrerios.salud s
JOIN entrerios.departamentos lp ON lp.nombre = 'La Paz' AND ST_DWithin(s.geom_m, lp.geom_m, 30000)
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> s.geom_m LIMIT 1) v
WHERE s.tipo = 'hospital';

DROP TABLE IF EXISTS tmp_normal, tmp_crecida;
CREATE TEMP TABLE tmp_normal AS
SELECT * FROM pgr_dijkstraCost(
    'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial',
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'L'),
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'H'));
CREATE TEMP TABLE tmp_crecida AS
SELECT * FROM pgr_dijkstraCost(
    'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial WHERE NOT cortado',
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'L'),
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'H'));

DROP TABLE IF EXISTS entrerios.r13_impacto_crecida;
CREATE TABLE entrerios.r13_impacto_crecida AS
WITH mejor_normal AS (
    SELECT DISTINCT ON (l.id) l.id, l.nombre, l.poblacion, h.nombre AS hospital, n.agg_cost AS min_normal
    FROM tmp_nodos l JOIN tmp_normal n ON n.start_vid = l.vid
    JOIN tmp_nodos h ON h.clase = 'H' AND h.vid = n.end_vid
    WHERE l.clase = 'L' ORDER BY l.id, n.agg_cost
), mejor_crecida AS (
    SELECT DISTINCT ON (l.id) l.id, h.nombre AS hospital, c.agg_cost AS min_crecida
    FROM tmp_nodos l JOIN tmp_crecida c ON c.start_vid = l.vid
    JOIN tmp_nodos h ON h.clase = 'H' AND h.vid = c.end_vid
    WHERE l.clase = 'L' ORDER BY l.id, c.agg_cost
)
SELECT n.id, n.nombre AS localidad, COALESCE(n.poblacion, 0) AS poblacion,
       n.hospital AS hospital_normal, round(n.min_normal::numeric, 1) AS min_normal,
       c.hospital AS hospital_crecida, round(c.min_crecida::numeric, 1) AS min_crecida,
       round((c.min_crecida - n.min_normal)::numeric, 1) AS demora_extra_min,
       CASE WHEN c.id IS NULL THEN 'AISLADA (sin acceso a hospital)'
            WHEN c.hospital <> n.hospital THEN 'Debe derivarse a otro hospital'
            WHEN c.min_crecida > n.min_normal * 1.25 THEN 'Acceso demorado'
            ELSE 'Sin afectación relevante' END AS situacion,
       loc.geom
FROM mejor_normal n
LEFT JOIN mejor_crecida c ON c.id = n.id
JOIN entrerios.localidades loc ON loc.id = n.id;

-- Prioridad de asistencia: aisladas primero, luego por población x demora
SELECT rank() OVER (ORDER BY (situacion LIKE 'AISLADA%') DESC,
                             poblacion * COALESCE(demora_extra_min, 999) DESC) AS prioridad,
       localidad, poblacion, hospital_normal, min_normal, hospital_crecida, min_crecida,
       demora_extra_min, situacion
FROM entrerios.r13_impacto_crecida
ORDER BY prioridad;

/* ---------------------------------------------------------------------
   13.4 Ruta alternativa para la localidad más afectada (pgr_dijkstra)
   Se dibujan la ruta normal y la alternativa para QGIS.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r13_rutas_hospital;
CREATE TABLE entrerios.r13_rutas_hospital (
    localidad text, escenario text, hospital text, minutos numeric, km numeric,
    geom geometry(MultiLineString, 4326));

DO $$
DECLARE r record; lv bigint; hv bigint; esc text; filtro text;
BEGIN
    FOR r IN SELECT * FROM entrerios.r13_impacto_crecida
             WHERE situacion <> 'Sin afectación relevante' LOOP
        SELECT vid INTO lv FROM tmp_nodos WHERE clase = 'L' AND id = r.id;
        FOREACH esc IN ARRAY ARRAY['normal', 'crecida'] LOOP
            filtro := CASE WHEN esc = 'normal' THEN '' ELSE ' WHERE NOT cortado' END;
            SELECT vid INTO hv FROM tmp_nodos
            WHERE clase = 'H' AND nombre = CASE WHEN esc = 'normal' THEN r.hospital_normal ELSE r.hospital_crecida END
            LIMIT 1;
            CONTINUE WHEN hv IS NULL;
            INSERT INTO entrerios.r13_rutas_hospital
            SELECT r.localidad, esc, CASE WHEN esc = 'normal' THEN r.hospital_normal ELSE r.hospital_crecida END,
                   round(max(p.agg_cost)::numeric, 1), round((sum(e.largo_m) / 1000)::numeric, 1),
                   ST_Multi(ST_Transform(ST_Collect(e.geom_m), 4326))
            FROM pgr_dijkstra('SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial' || filtro,
                              lv, hv) p
            JOIN entrerios.red_vial e ON e.id = p.edge;
        END LOOP;
    END LOOP;
END $$;

SELECT localidad, escenario, hospital, minutos, km FROM entrerios.r13_rutas_hospital ORDER BY localidad, escenario DESC;

/* ---------------------------------------------------------------------
   13.5 Derivación al hospital de referencia (Hospital Zonal 9 de Julio)
   La mayoría de las localidades tiene un centro de salud propio, por lo
   que el corte de caminos casi no cambia su acceso al establecimiento
   MÁS CERCANO. Pero los casos graves se derivan al hospital zonal de la
   cabecera (La Paz). Se compara el tiempo de derivación normal vs.
   crecida para cada localidad y se dibujan ambas rutas.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tmp_zonal;
CREATE TEMP TABLE tmp_zonal AS
SELECT l.id, l.nombre, COALESCE(l.poblacion, 0) AS poblacion,
       (SELECT v.id FROM entrerios.red_vial_vertices v ORDER BY v.geom <-> l.geom_m LIMIT 1) AS vid
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz';

DROP TABLE IF EXISTS tmp_zonal_h;
CREATE TEMP TABLE tmp_zonal_h AS
SELECT (SELECT v.id FROM entrerios.red_vial_vertices v ORDER BY v.geom <-> s.geom_m LIMIT 1) AS vid
FROM entrerios.salud s WHERE s.nombre = 'Hospital Zonal 9 de Julio';

DROP TABLE IF EXISTS entrerios.r13_derivacion_zonal;
CREATE TABLE entrerios.r13_derivacion_zonal AS
WITH n AS (
    SELECT * FROM pgr_dijkstraCost(
        'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial',
        (SELECT array_agg(DISTINCT vid) FROM tmp_zonal), (SELECT vid FROM tmp_zonal_h))
), c AS (
    SELECT * FROM pgr_dijkstraCost(
        'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial WHERE NOT cortado',
        (SELECT array_agg(DISTINCT vid) FROM tmp_zonal), (SELECT vid FROM tmp_zonal_h))
)
SELECT z.id, z.nombre AS localidad, z.poblacion,
       round(n.agg_cost::numeric, 1) AS min_normal,
       round(c.agg_cost::numeric, 1) AS min_crecida,
       round((c.agg_cost - n.agg_cost)::numeric, 1) AS demora_extra_min,
       round((100 * (c.agg_cost / NULLIF(n.agg_cost, 0) - 1))::numeric, 0) AS pct_extra,
       CASE WHEN c.agg_cost IS NULL THEN 'AISLADA'
            WHEN c.agg_cost - n.agg_cost >= 15 THEN 'Demora crítica (>= 15 min)'
            WHEN c.agg_cost - n.agg_cost >= 5  THEN 'Demora moderada (5-15 min)'
            ELSE 'Sin afectación relevante' END AS situacion,
       l.geom
FROM tmp_zonal z
JOIN entrerios.localidades l ON l.id = z.id
LEFT JOIN n ON n.start_vid = z.vid
LEFT JOIN c ON c.start_vid = z.vid;

-- Prioridad de asistencia: población afectada x minutos de demora
SELECT rank() OVER (ORDER BY (situacion = 'AISLADA') DESC, poblacion * COALESCE(demora_extra_min, 0) DESC) AS prioridad,
       localidad, poblacion, min_normal, min_crecida, demora_extra_min, pct_extra, situacion
FROM entrerios.r13_derivacion_zonal ORDER BY prioridad;

-- Rutas normal y alternativa de cada localidad afectada hacia el hospital zonal
DELETE FROM entrerios.r13_rutas_hospital WHERE hospital = 'Hospital Zonal 9 de Julio (derivación)';
DO $$
DECLARE r record; esc text; filtro text; hv bigint;
BEGIN
    SELECT vid INTO hv FROM tmp_zonal_h;
    FOR r IN SELECT d.*, z.vid FROM entrerios.r13_derivacion_zonal d JOIN tmp_zonal z ON z.id = d.id
             WHERE d.situacion <> 'Sin afectación relevante' AND d.min_crecida IS NOT NULL LOOP
        FOREACH esc IN ARRAY ARRAY['normal', 'crecida'] LOOP
            filtro := CASE WHEN esc = 'normal' THEN '' ELSE ' WHERE NOT cortado' END;
            INSERT INTO entrerios.r13_rutas_hospital
            SELECT r.localidad, esc, 'Hospital Zonal 9 de Julio (derivación)',
                   round(max(p.agg_cost)::numeric, 1), round((sum(e.largo_m) / 1000)::numeric, 1),
                   ST_Multi(ST_Transform(ST_LineMerge(ST_Collect(e.geom_m)), 4326))
            FROM pgr_dijkstra('SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial' || filtro,
                              r.vid, hv) p
            JOIN entrerios.red_vial e ON e.id = p.edge;
        END LOOP;
    END LOOP;
END $$;

SELECT localidad, escenario, minutos, km FROM entrerios.r13_rutas_hospital
WHERE hospital LIKE '%derivación%' ORDER BY localidad, escenario DESC;

-- Tramos cortados que más pesan: los usados por la ruta normal de derivación
SELECT t.via, t.metros
FROM entrerios.r13_tramos_cortados t
WHERE EXISTS (SELECT 1 FROM entrerios.r13_rutas_hospital h
              WHERE h.escenario = 'normal' AND h.hospital LIKE '%derivación%' AND ST_Intersects(h.geom, t.geom))
ORDER BY t.metros DESC;

-- ====================================================================
-- Archivo: 10_problema.sql
-- ====================================================================
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
