"""
TP2 BDG 2026 - Genera el proyecto QGIS (TP2_LaPaz.qgz) y exporta los mapas
del informe a PNG.

Ejecutar con el Python de QGIS:
  "C:\\Program Files\\QGIS 3.44.15\\bin\\python-qgis-ltr.bat" generar_proyecto.py
"""
import os
import sys

from qgis.core import (
    QgsApplication, QgsProject, QgsVectorLayer, QgsRasterLayer, QgsDataSourceUri,
    QgsCoordinateReferenceSystem, QgsLayerTreeGroup, QgsSymbol, QgsSingleSymbolRenderer,
    QgsCategorizedSymbolRenderer, QgsRendererCategory, QgsGraduatedSymbolRenderer,
    QgsPalLayerSettings, QgsVectorLayerSimpleLabeling, QgsTextFormat, QgsTextBufferSettings,
    QgsMapSettings, QgsMapRendererParallelJob, QgsRectangle, QgsCoordinateTransform,
    QgsPrintLayout, QgsLayoutItemMap, QgsLayoutItemLabel, QgsLayoutItemLegend,
    QgsLayoutItemScaleBar, QgsLayoutPoint, QgsLayoutSize, QgsUnitTypes, QgsLayoutExporter,
    QgsLegendStyle, QgsLayoutItemPicture, QgsFillSymbol, QgsLineSymbol, QgsMarkerSymbol,
    QgsClassificationRange, QgsRendererRange, QgsSimpleLineCallout, Qgis,
)
from qgis.PyQt.QtGui import QColor, QFont
from qgis.PyQt.QtCore import QSize

BASE = os.path.dirname(os.path.abspath(__file__))
MAPAS = os.path.join(os.path.dirname(BASE), "informe", "mapas")
os.makedirs(MAPAS, exist_ok=True)

DB = dict(host="localhost", port="5432", dbname="tp2_bdg", user="postgres", password="1234")
ARGENMAP = ("type=xyz&zmin=0&zmax=19&url=https://wms.ign.gob.ar/geoserver/gwc/service/tms/1.0.0/"
            "capabaseargenmap@EPSG%3A3857@png/%7Bz%7D/%7Bx%7D/%7B-y%7D.png")

qgs = QgsApplication([], False)
qgs.initQgis()
project = QgsProject.instance()
project.setCrs(QgsCoordinateReferenceSystem("EPSG:5347"))
project.setTitle("TP2 BDG 2026 - Riesgo hídrico y accesibilidad sanitaria - Depto. La Paz")
root = project.layerTreeRoot()


# ---------------------------------------------------------------- helpers
def pg(tabla, nombre, geom="geom", esquema="entrerios", where="", key="id"):
    uri = QgsDataSourceUri()
    uri.setConnection(DB["host"], DB["port"], DB["dbname"], DB["user"], DB["password"])
    uri.setDataSource(esquema, tabla, geom, where, key)
    lyr = QgsVectorLayer(uri.uri(False), nombre, "postgres")
    if not lyr.isValid():
        print(f"  !! capa inválida: {esquema}.{tabla}.{geom}", file=sys.stderr)
    return lyr


def add(lyr, grupo, visible=True):
    project.addMapLayer(lyr, False)
    node = grupo.addLayer(lyr)
    node.setItemVisibilityChecked(visible)
    node.setExpanded(False)
    return lyr


def fill(lyr, color, borde="#333333", alpha=1.0, ancho=0.3, estilo="solid"):
    s = QgsFillSymbol.createSimple({"color": color, "outline_color": borde,
                                    "outline_width": str(ancho), "style": estilo})
    s.setOpacity(alpha)
    lyr.setRenderer(QgsSingleSymbolRenderer(s))


def line(lyr, color, ancho=0.5, estilo="solid"):
    lyr.setRenderer(QgsSingleSymbolRenderer(QgsLineSymbol.createSimple(
        {"line_color": color, "line_width": str(ancho), "line_style": estilo})))


def mark(lyr, color, size=2.5, forma="circle", borde="#000000"):
    lyr.setRenderer(QgsSingleSymbolRenderer(QgsMarkerSymbol.createSimple(
        {"color": color, "size": str(size), "name": forma, "outline_color": borde})))


def categ(lyr, campo, colores, geom="fill", extra=None, rotulos=None):
    """rotulos: dict valor -> texto de la leyenda (si falta, se usa str(valor))."""
    cats = []
    for valor, color in colores.items():
        if geom == "fill":
            s = QgsFillSymbol.createSimple({"color": color, "outline_color": "#555555", "outline_width": "0.1"})
        elif geom == "line":
            s = QgsLineSymbol.createSimple({"line_color": color, "line_width": (extra or "0.8")})
        else:
            s = QgsMarkerSymbol.createSimple({"color": color, "size": (extra or "3"), "outline_color": "#000"})
        cats.append(QgsRendererCategory(valor, s, (rotulos or {}).get(valor, str(valor))))
    lyr.setRenderer(QgsCategorizedSymbolRenderer(campo, cats))


def formato_texto(size, color):
    fmt = QgsTextFormat()
    fmt.setFont(QFont("Arial"))
    fmt.setSize(size)
    fmt.setColor(QColor(color))
    buf = QgsTextBufferSettings()
    buf.setEnabled(True)
    buf.setSize(0.8)
    buf.setColor(QColor("white"))
    fmt.setBuffer(buf)
    return fmt


def etiquetas(lyr, campo, size=8, color="#000000"):
    p = QgsPalLayerSettings()
    p.fieldName = campo
    p.setFormat(formato_texto(size, color))
    p.obstacleSettings().setIsObstacle(True)      # las etiquetas de otras capas no tapan estos puntos
    lyr.setLabeling(QgsVectorLayerSimpleLabeling(p))
    lyr.setLabelsEnabled(True)


def etiquetas_callout(lyr, expresion, size=7, color="#000000"):
    """Etiquetas para puntos muy juntos: posiciones ordenadas alrededor del punto,
    sin superposición (el motor PAL descarta las que colisionan) y con una línea
    guía (callout) que une el texto con el punto cuando queda desplazado."""
    p = QgsPalLayerSettings()
    p.fieldName = expresion
    p.isExpression = True
    p.placement = Qgis.LabelPlacement.OrderedPositionsAroundPoint
    p.dist = 2.5
    p.priority = 8
    p.placementSettings().setOverlapHandling(Qgis.LabelOverlapHandling.PreventOverlap)
    p.placementSettings().setAllowDegradedPlacement(False)
    p.obstacleSettings().setIsObstacle(True)
    p.setFormat(formato_texto(size, color))
    c = QgsSimpleLineCallout()
    c.setEnabled(True)
    c.setMinimumLength(1.5)
    c.setMinimumLengthUnit(Qgis.RenderUnit.Millimeters)
    c.setLineSymbol(QgsLineSymbol.createSimple({"line_color": color, "line_width": "0.25"}))
    p.setCallout(c)
    lyr.setLabeling(QgsVectorLayerSimpleLabeling(p))
    lyr.setLabelsEnabled(True)


def grupo(nombre):
    g = root.addGroup(nombre)
    g.setExpanded(False)
    return g


# ---------------------------------------------------------------- capas base
g_base = root.addGroup("00 Base")
argenmap = QgsRasterLayer(ARGENMAP, "Argenmap (IGN)", "wms")
project.addMapLayer(argenmap, False)

deptos = add(pg("departamentos", "Departamentos (IGN)"), g_base)
fill(deptos, "#ffffff", "#555555", alpha=0.0, ancho=0.4)
etiquetas(deptos, "nombre", 9, "#444444")
lapaz = add(pg("departamentos", "Depto. La Paz", where="nombre = 'La Paz'"), g_base)
fill(lapaz, "#ffffff", "#c0392b", alpha=1.0, ancho=0.9, estilo="no")
locs = add(pg("localidades", "Localidades (OSM)"), g_base)
mark(locs, "#ffffff", 2.4, "circle", "#000000")
etiquetas(locs, "nombre", 8)
g_base.addLayer(argenmap)

# ---------------------------------------------------------------- 6 datos
g6 = grupo("06 Datos cargados (OSM)")
rios = add(pg("rios", "Ríos y arroyos"), g6)
line(rios, "#2e86c1", 0.35)
lag = add(pg("lagunas", "Lagunas"), g6)
fill(lag, "#85c1e9", "#2e86c1", ancho=0.1)
cau = add(pg("rios_area", "Cauces (water=river)"), g6)
fill(cau, "#5dade2", "#2e86c1", ancho=0.1)
rutas = add(pg("rutas", "Rutas principales"), g6)
categ(rutas, "jurisdiccion", {"Nacional": "#c0392b", "Provincial": "#e67e22", "Sin dato": "#999999"}, "line", "0.9")
calles = add(pg("calles", "Calles"), g6, visible=False)
line(calles, "#7f8c8d", 0.15)
salud = add(pg("salud", "Establecimientos de salud"), g6)
categ(salud, "tipo", {"hospital": "#e74c3c", "clinic": "#f5b7b1"}, "point", "3")

# ---------------------------------------------------------------- 7
g7 = grupo("07 Hidrografía")
vec = add(pg("r7_vecinos", "7.1 Departamentos vecinos"), g7)
fill(vec, "#f9e79f", "#b7950b", alpha=0.6)
etiquetas(vec, "vecino", 9)
fro = add(pg("r7_frontera", "7.2 Fronteras comunes"), g7)
categ(fro, "frontera", {"La Paz - Federal": "#8e44ad", "La Paz - Paraná": "#27ae60",
                        "La Paz - Feliciano": "#d35400", "La Paz - Villaguay": "#2980b9"}, "line", "1.6")
rank = add(pg("r7_ranking_agua", "7.3 Ranking de lagunas por depto"), g7, visible=False)
rr = QgsGraduatedSymbolRenderer("cant_lagunas")
rr.setSourceColorRamp(QgsGraduatedSymbolRenderer().sourceColorRamp())
from qgis.core import QgsStyle
rr = QgsGraduatedSymbolRenderer.createRenderer(rank, "cant_lagunas", 5, QgsGraduatedSymbolRenderer.Jenks,
                                               QgsFillSymbol.createSimple({}), QgsStyle().defaultStyle().colorRamp("Blues"))
rr.classificationMethod().setLabelPrecision(0)
rr.updateRangeLabels()
rank.setRenderer(rr)
etiquetas(rank, "nombre || '\n' || cant_lagunas", 8)
rank.labeling().settings().isExpression = True
cur = add(pg("r7_cursos_agua", "7.5 Cursos de agua en La Paz"), g7, visible=False)
line(cur, "#1f618d", 0.5)

# ---------------------------------------------------------------- 8
g8 = grupo("08 Accesibilidad sanitaria")
rl = add(pg("r8_rutas_lapaz", "8.2 Rutas en La Paz (km)"), g8)
categ(rl, "jurisdiccion", {"Nacional": "#c0392b", "Provincial": "#e67e22", "Sin dato": "#999999"}, "line", "1.2")
etiquetas(rl, "ref", 8, "#7b241c")
cob = add(pg("r8_cobertura_5km", "8.5 Cobertura 5 km"), g8)
fill(cob, "#58d68d", "#1e8449", alpha=0.35, ancho=0.4)
sc = add(pg("r8_localidades_sin_cobertura", "8.5 Localidades sin cobertura"), g8)
mark(sc, "#000000", 4.0, "cross_fill", "#000000")
dl = add(pg("r8_dist_localidad_salud", "8.4 Línea localidad - salud más cercana", geom="linea"), g8, visible=False)
line(dl, "#7d3c98", 0.6, "dash")

# ---------------------------------------------------------------- 9
g9 = grupo("09 Riesgo hídrico")
zrh = add(pg("zona_riesgo_hidrico", "9.1 ZRH (2 km) La Paz", where="depto = 'La Paz'", key="id_depto"), g9)
fill(zrh, "#5dade2", "#1b4f72", alpha=0.35, ancho=0.2)
zrhp = add(pg("zona_riesgo_hidrico", "9.1 ZRH principal (sin arroyos menores)", geom="geom_m_principal",
              where="depto = 'La Paz'", key="id_depto"), g9, visible=False)
fill(zrhp, "#2874a6", "#1b4f72", alpha=0.35, ancho=0.2)
se = add(pg("r9_salud_expuesta", "9.2 Salud dentro de la ZRH"), g9)
mark(se, "#e74c3c", 4.0, "triangle", "#000000")
# Solo se rotulan los hospitales: las clínicas y consultorios se pisaban entre sí
# en La Paz, Santa Elena y Bovril; el detalle completo está en la tabla 9.2.
etiquetas_callout(se, "CASE WHEN tipo = 'hospital' THEN nombre END", 7, "#922b21")
ais = add(pg("r9_aislamiento", "9.3 Riesgo de aislamiento"), g9)
categ(ais, "riesgo_aislamiento", {"ALTO": "#c0392b", "MEDIO": "#f39c12", "BAJO": "#27ae60"}, "point", "4.5")
con = add(pg("r9_conectores", "9.3 Conector localidad - ruta"), g9)
line(con, "#000000", 0.6, "dot")
cru = add(pg("r9_cruces_ruta_agua", "9.3 Cruces ruta x curso de agua"), g9)
categ(cru, "puente_osm", {True: "#1e8449", False: "#c0392b"}, "point", "2.2",
      rotulos={True: "Con puente registrado", False: "Sin puente registrado"})
expo = add(pg("r9_exposicion_deptos", "9.4 % de ZRH por departamento"), g9, visible=False)
er = QgsGraduatedSymbolRenderer.createRenderer(expo, "pct_zrh", 5, QgsGraduatedSymbolRenderer.Jenks,
                                               QgsFillSymbol.createSimple({}), QgsStyle().defaultStyle().colorRamp("Reds"))
er.classificationMethod().setLabelPrecision(1)
er.updateRangeLabels()
expo.setRenderer(er)

# ---------------------------------------------------------------- 10
g10 = grupo("10 Funciones")
mbr = add(pg("r10_mbr", "10.2 MBR Entre Ríos"), g10, visible=False)
fill(mbr, "#ffffff", "#c0392b", ancho=0.8, estilo="no")
prov = add(pg("provincia", "Provincia (contorno)", key="nombre"), g10, visible=False)
fill(prov, "#f5cba7", "#a04000", alpha=0.6)
km = add(pg("r10_kmeans_salud", "10.4 K-means salud (3 grupos)"), g10)
categ(km, "grupo", {1: "#e74c3c", 2: "#3498db", 3: "#2ecc71"}, "point", "3.5")
kc = add(pg("r10_kmeans_centroides", "10.4 Centroides", key="grupo"), g10)
mark(kc, "#000000", 5.5, "star", "#ffffff")

# ---------------------------------------------------------------- 11
g11 = grupo("11 Calles OSM vs Argenmap")
mu = add(pg("r11_densidad_localidad", "11.2 Mancha urbana y densidad vial", key="id_localidad"), g11)
fill(mu, "#f8c471", "#b9770e", alpha=0.6)
etiquetas(mu, "localidad", 8)
pu = add(pg("r11_puentes", "11.4 Puentes OSM"), g11)
line(pu, "#000000", 1.5)
cd = add(pg("r11_calles_depto", "11.1 Densidad vial por depto"), g11, visible=False)
cr = QgsGraduatedSymbolRenderer.createRenderer(cd, "densidad_km_km2", 5, QgsGraduatedSymbolRenderer.Jenks,
                                               QgsFillSymbol.createSimple({}), QgsStyle().defaultStyle().colorRamp("Greys"))
cr.classificationMethod().setLabelPrecision(2)
cr.updateRangeLabels()
cd.setRenderer(cr)

# ---------------------------------------------------------------- 12
g12 = grupo("12 Suelo INTA")
su = add(pg("r12_suelo_lapaz", "12.1 Aptitud del suelo (IPC)"), g12)
categ(su, "clase", {"Agrícola": "#1e8449", "Agrícola-ganadera": "#82e0aa",
                    "Ganadera": "#f9e79f", "Planicie inundable / agua": "#aed6f1",
                    "Urbana": "#b2babb", "Misceláneas": "#d7bde2"}, "fill")
ae = add(pg("r12_agricola_expuesta", "12.2 Agrícola dentro de la ZRH"), g12)
fill(ae, "#c0392b", "#7b241c", alpha=0.7, ancho=0.1)
co = add(pg("r12_corredores", "12.3 Corredor productivo (2 km)", geom="geom_corredor", key="ref"), g12)
fill(co, "#f4d03f", "#9a7d0a", alpha=0.5, ancho=0.2)
cl = add(pg("r12_corredores", "12.3 Rutas sobre suelo agrícola", key="ref"), g12)
line(cl, "#6e2c00", 1.4)

# ---------------------------------------------------------------- 13
g13 = grupo("13 Consulta agregada - crecida")
tc = add(pg("r13_tramos_cortados", "13 Tramos cortados por crecida"), g13)
line(tc, "#000000", 1.1)
dz = add(pg("r13_derivacion_zonal", "13 Derivación al Hospital Zonal"), g13)
categ(dz, "situacion", {"AISLADA": "#000000", "Demora crítica (>= 15 min)": "#c0392b",
                        "Demora moderada (5-15 min)": "#f39c12", "Sin afectación relevante": "#27ae60"}, "point", "5")
etiquetas(dz, "localidad", 8)
ic = add(pg("r13_impacto_crecida", "13 Impacto en localidades"), g13)
categ(ic, "situacion", {"AISLADA (sin acceso a hospital)": "#000000", "Debe derivarse a otro hospital": "#c0392b",
                        "Acceso demorado": "#f39c12", "Sin afectación relevante": "#27ae60"}, "point", "4.5")
etiquetas(ic, "localidad", 8)
rh = add(pg("r13_rutas_hospital", "13 Ruta normal / alternativa", key="localidad"), g13)
categ(rh, "escenario", {"normal": "#2e86c1", "crecida": "#8e44ad"}, "line", "1.6")

# ---------------------------------------------------------------- 14
g14 = grupo("14 Centro de Atención Sanitaria de Emergencia")
ca = add(pg("r14_candidatos", "14 Celdas aptas (puntaje)"), g14)
cr14 = QgsGraduatedSymbolRenderer.createRenderer(ca, "puntaje", 5, QgsGraduatedSymbolRenderer.Jenks,
                                                 QgsFillSymbol.createSimple({}), QgsStyle().defaultStyle().colorRamp("YlOrRd"))
cr14.classificationMethod().setLabelPrecision(2)
cr14.updateRangeLabels()
ca.setRenderer(cr14)
mj = add(pg("r14_mejores", "14 Ubicaciones propuestas"), g14)
mark(mj, "#8e44ad", 7, "star", "#ffffff")
etiquetas(mj, "'#' || ranking || ' ' || localidad_ref", 9, "#4a235a")
mj.labeling().settings().isExpression = True

project.write(os.path.join(BASE, "TP2_LaPaz.qgz"))
print("Proyecto guardado:", os.path.join(BASE, "TP2_LaPaz.qgz"))


# ---------------------------------------------------------------- mapas PNG
def extent_de(lyr, margen=0.06):
    ext = QgsCoordinateTransform(lyr.crs(), project.crs(), project).transformBoundingBox(lyr.extent())
    ext.scale(1 + margen)
    return ext


def exportar(nombre, titulo, capas, extent, base=True, tam=(1800, 1500)):
    """Compone un layout A4 con mapa, título, leyenda y escala, y lo exporta a PNG."""
    lay = QgsPrintLayout(project)
    lay.initializeDefaults()
    lay.setName(nombre)
    page = lay.pageCollection().page(0)
    page.setPageSize("A4", page.Landscape)
    mapa = QgsLayoutItemMap(lay)
    mapa.attemptMove(QgsLayoutPoint(8, 18, QgsUnitTypes.LayoutMillimeters))
    mapa.attemptResize(QgsLayoutSize(200, 184, QgsUnitTypes.LayoutMillimeters))
    capas_mapa = list(capas) + ([argenmap] if base else [])
    mapa.setLayers(capas_mapa)
    mapa.setKeepLayerSet(True)
    mapa.setCrs(project.crs())
    mapa.zoomToExtent(extent)          # mantiene el tamaño del marco (setExtent lo redimensiona)
    mapa.setFrameEnabled(True)
    lay.addLayoutItem(mapa)

    t = QgsLayoutItemLabel(lay)
    t.setText(titulo)
    t.setFont(QFont("Arial", 15, QFont.Bold))
    t.attemptMove(QgsLayoutPoint(8, 5, QgsUnitTypes.LayoutMillimeters))
    t.attemptResize(QgsLayoutSize(280, 10, QgsUnitTypes.LayoutMillimeters))
    lay.addLayoutItem(t)

    leg = QgsLayoutItemLegend(lay)
    leg.setTitle("Referencias")
    leg.setLinkedMap(mapa)
    leg.setAutoUpdateModel(False)
    model = leg.model()
    model.rootGroup().clear()
    for c in capas:
        model.rootGroup().addLayer(c)
    leg.attemptMove(QgsLayoutPoint(212, 18, QgsUnitTypes.LayoutMillimeters))
    leg.setStyleFont(QgsLegendStyle.Title, QFont("Arial", 11, QFont.Bold))
    leg.setStyleFont(QgsLegendStyle.SymbolLabel, QFont("Arial", 8))
    lay.addLayoutItem(leg)

    sb = QgsLayoutItemScaleBar(lay)
    sb.setStyle("Single Box")
    sb.setLinkedMap(mapa)
    sb.setUnits(QgsUnitTypes.DistanceMeters)       # segmentos en metros, rotulados en km
    sb.setMapUnitsPerScaleBarUnit(1000)
    sb.setUnitLabel("km")
    # La columna lateral mide 85 mm (x = 212..297). Se elige el segmento "redondo"
    # más grande con el que la barra (2 segmentos) no pase de 50 mm, así el último
    # rótulo y la unidad "km" quedan dentro de la hoja.
    mm_por_km = 200.0 / (mapa.extent().width() / 1000.0)
    seg = max(x for x in (0.5, 1, 2, 5, 10, 20, 25, 50, 100) if 2 * x * mm_por_km <= 50)
    sb.setUnitsPerSegment(seg * 1000)   # en unidades del mapa (metros)
    sb.setNumberOfSegments(2)
    sb.setNumberOfSegmentsLeft(0)
    sb.setHeight(2.5)
    sb.setTextFormat(formato_texto(9, "#000000"))
    sb.update()
    sb.attemptMove(QgsLayoutPoint(212, 182, QgsUnitTypes.LayoutMillimeters))
    lay.addLayoutItem(sb)

    pie = QgsLayoutItemLabel(lay)
    pie.setText("Fuentes: IGN, OpenStreetMap, INTA. Proyección POSGAR 2007 / Argentina 5 (EPSG:5347). TP2 BDA 2026 - UADER")
    pie.setFont(QFont("Arial", 7))
    pie.attemptMove(QgsLayoutPoint(8, 203, QgsUnitTypes.LayoutMillimeters))
    pie.attemptResize(QgsLayoutSize(280, 5, QgsUnitTypes.LayoutMillimeters))
    lay.addLayoutItem(pie)

    project.layoutManager().addLayout(lay)
    exp = QgsLayoutExporter(lay)
    s = QgsLayoutExporter.ImageExportSettings()
    s.dpi = 150
    r = exp.exportToImage(os.path.join(MAPAS, nombre + ".png"), s)
    print(f"  mapa {nombre}: {'OK' if r == QgsLayoutExporter.Success else 'ERROR ' + str(r)}")


E_LP = extent_de(lapaz)
E_ER = extent_de(deptos, 0.03)

exportar("m06_datos", "Datos cargados - Departamento La Paz", [lapaz, locs, salud, rutas, rios, lag, cau, deptos], E_LP)
exportar("m07_vecinos_frontera", "7.1 / 7.2 Departamentos vecinos y fronteras comunes", [lapaz, fro, vec, deptos], extent_de(vec, 0.05))
exportar("m07_ranking_lagunas", "7.3 Cantidad de lagunas por departamento (OSM)", [rank], E_ER, base=False)
exportar("m07_cursos_agua", "7.4 / 7.5 Cuerpos y cursos de agua en La Paz", [lapaz, cur, lag, cau, locs], E_LP)
exportar("m08_rutas", "8.1 / 8.2 Red vial principal de La Paz", [lapaz, rl, locs], E_LP)
exportar("m08_cobertura", "8.3 - 8.5 Establecimientos de salud y cobertura de 5 km", [lapaz, sc, salud, dl, cob, locs], E_LP)
exportar("m09_zrh", "9.1 / 9.2 Zona de Riesgo Hídrico (2 km) e infraestructura expuesta", [lapaz, se, salud, zrh, locs], E_LP)
exportar("m09_aislamiento", "9.3 Posibles situaciones de aislamiento", [lapaz, ais, con, cru, rl, rios], E_LP)
exportar("m09_exposicion", "9.4 Porcentaje de superficie en ZRH por departamento", [expo, deptos], E_ER, base=False)
exportar("m10_mbr", "10.2 MBR (ST_Envelope) de Entre Ríos", [mbr, prov], extent_de(mbr, 0.05), base=False)
exportar("m10_kmeans", "10.4 Agrupamiento K-means (k=3) de establecimientos", [lapaz, kc, km, rl, locs], E_LP)
exportar("m11_densidad", "11.2 Mancha urbana estimada - La Paz (ciudad)", [mu, pu, calles],
         extent_de(pg("r11_densidad_localidad", "tmp", where="localidad = 'La Paz'", key="id_localidad"), 0.3))
exportar("m11_osm_argenmap", "11.4 Calles OSM sobre Argenmap - La Paz y puente", [calles, pu, rios],
         extent_de(pg("r11_densidad_localidad", "tmp", where="localidad = 'La Paz'", key="id_localidad"), 0.6))
exportar("m12_suelo", "12.1 Aptitud del suelo según IPC (INTA)", [lapaz, su, locs], E_LP, base=False)
exportar("m12_expuesta_corredores", "12.2 / 12.3 Áreas agrícolas expuestas y corredores productivos", [lapaz, cl, co, ae, su], E_LP, base=False)
exportar("m13_crecida", "13 Escenario de crecida: tramos cortados y rutas alternativas", [lapaz, dz, rh, tc], E_LP)
exportar("m14_centro", "14 Ubicación del Centro de Atención Sanitaria de Emergencia", [lapaz, mj, ca, sc, salud, rl, zrhp, locs], E_LP)

project.write(os.path.join(BASE, "TP2_LaPaz.qgz"))
qgs.exitQgis()
