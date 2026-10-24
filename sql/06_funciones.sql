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
