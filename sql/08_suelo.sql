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
