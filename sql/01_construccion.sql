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
