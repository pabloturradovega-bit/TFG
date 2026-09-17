# -*- coding: utf-8 -*-
# =============================================================
# MACRO ECE R66 - GEOMETRIA L CON CARTELA (SOLIDO)
# Material: S-235JR (Yield 235 MPa, Tangent Modulus 1.16 GPa)
# Fixed Support en B_Inferior, Desplazamiento en A_Tope_Arista
# Salida: Energia / Peso
# =============================================================
import os
import math
import traceback

BATCH_MODE = os.environ.get("TFG_BATCH_MODE", "") == "1"
sim_id = os.environ.get("TFG_SIM_ID", "manual")
pipeline_dir = os.environ.get("TFG_PIPELINE_DIR", "")

# Parametro geometrico para malla
param_b_mm = float(os.environ.get("TFG_PARAM_B_MM", "100"))
# Dimension caracteristica de malla: media de las 4 dimensiones de seccion
# char_dim = (a1 + a2 + 2*b) / 4  — reduce la varianza de nodos respecto a usar solo b
# Se pasa desde MATLAB; si no existe se usa b como fallback.
char_dim_mm = float(os.environ.get("TFG_CHAR_DIM_MM", str(param_b_mm)))
c_mm = float(os.environ.get("TFG_C_MM", "80"))
longitud_viga_mm = float(os.environ.get("TFG_LONGITUD_VIGA_MM", "1000"))
angulo_desplazamiento_deg = float(os.environ.get("TFG_ANGULO_DESPLAZAMIENTO_DEG", "30"))

# --- Substeps (configurables desde GUI / T02) ---
substeps_init = int(os.environ.get("TFG_SUBSTEPS_INIT", "50"))
substeps_min  = int(os.environ.get("TFG_SUBSTEPS_MIN",  "20"))
substeps_max  = int(os.environ.get("TFG_SUBSTEPS_MAX",  "250"))

# --- Malla (configurables desde GUI / T02) ---
# Resolucion global ANSYS (1=gruesa … 7=fina)
mesh_resolution = int(os.environ.get("TFG_MESH_RESOLUTION", "4"))
# Divisores de malla: elem_size = clamp(char_dim/div, h_min, h_max)  (char_dim=(a1+a2+2b)/4)
# div=14, h_min=4.5, h_max=7.0 → rango esperado 75-115k nodos para todo el espacio de diseño
_coarse_div     = int(os.environ.get("TFG_MESH_COARSE_DIV", "4"))
_fine_div       = int(os.environ.get("TFG_MESH_FINE_DIV",   "14"))
_fine_min_mm    = float(os.environ.get("TFG_MESH_FINE_MIN_MM", "4.5"))   # suelo: secciones pequeñas
_fine_max_mm    = float(os.environ.get("TFG_MESH_FINE_MAX_MM", "7.0"))   # techo: secciones grandes
mesh_soi_radius = float(os.environ.get("TFG_MESH_SOI_RADIUS", "300"))
dir_x_sign = float(os.environ.get("TFG_DIR_X", "-1"))   # -1 = estandar ECE R66, +1 = invertida
desplazamiento_x_mm = dir_x_sign * longitud_viga_mm * math.sin(math.radians(angulo_desplazamiento_deg))

if not pipeline_dir:
    # Si se ejecuta manualmente desde ANSYS (sin MATLAB), forzamos tu ruta base
    pipeline_dir = r"C:\Users\pablo\Desktop\Matlab\TFG\L\TFG_Pipeline_Definitivo - b"

csv_outfile = os.path.join(pipeline_dir, 'parametrossalida.csv')
log_outfile = os.path.join(pipeline_dir, 'mechanical_run.log')
campaign_name = os.environ.get("TFG_CAMPAIGN_NAME", "")
if campaign_name:
    results_base_dir = os.path.join(pipeline_dir, 'Resultados', campaign_name)
    image_dir = os.path.join(results_base_dir, 'Sim_' + str(sim_id))
else:
    results_base_dir = os.path.join(pipeline_dir, 'Resultados')
    image_dir = os.path.join(results_base_dir, 'Simulacion_Manual_Test')


def reset_log():
    try:
        fh = open(log_outfile, 'w')
        fh.write('=== Mechanical run log ===' + chr(10))
        fh.close()
    except:
        pass


def log(msg):
    print(msg)
    try:
        fh = open(log_outfile, 'a')
        fh.write(str(msg) + chr(10))
        fh.close()
    except:
        pass


import System.IO

def ensure_dir(path):
    try:
        if not System.IO.Directory.Exists(path):
            System.IO.Directory.CreateDirectory(path)
    except:
        pass

def set_clean_deformed_view():
    try:
        Graphics.ViewOptions.ShowLegend = False
    except:
        pass
    try:
        Graphics.ViewOptions.ShowRuler = False
    except:
        pass
    try:
        Graphics.ViewOptions.ShowTriad = False
    except:
        pass
    try:
        Graphics.ViewOptions.ShowMesh = False
    except:
        pass
    try:
        Graphics.ViewOptions.ShowMeshConnection = False
    except:
        pass
    try:
        Graphics.ViewOptions.ModelDisplay = ModelDisplay.ShadedExterior
    except:
        pass
    try:
        Graphics.ViewOptions.ModelColoring = ModelColoring.ByMaterial
    except:
        pass
    try:
        Graphics.ViewOptions.ResultPreference.ExtraModelDisplay = MechanicalEnums.Graphics.ExtraModelDisplay.NoWireframe
    except:
        pass
    try:
        Graphics.ViewOptions.ResultPreference.ShowMaximum = False
    except:
        pass
    try:
        Graphics.ViewOptions.ResultPreference.ShowMinimum = False
    except:
        pass
    try:
        Graphics.ViewOptions.ResultPreference.ScopingDisplay = MechanicalEnums.Graphics.ScopingDisplay.ResultOnly
    except:
        pass
    for contour_name in ['NoContours', 'NoContour']:
        try:
            contour_enum = getattr(MechanicalEnums.Graphics.ContourView, contour_name)
            Graphics.ViewOptions.ResultPreference.ContourView = contour_enum
            break
        except:
            pass


def sequence_count(seq):
    try:
        return len(seq)
    except:
        pass
    for attr in ['Count', 'Length']:
        try:
            return int(getattr(seq, attr))
        except:
            pass
    return 0


def sequence_item(seq, idx):
    try:
        return seq[idx]
    except:
        pass
    try:
        return seq.GetValue(idx)
    except:
        pass
    try:
        return seq.Item[idx]
    except:
        pass
    raise Exception('No se pudo leer el indice ' + str(idx) + ' de PlotData')

def extract_y_max_stress_mm(stress_res, analysis):
    try:
        stress_res.EvaluateAllResults()
    except:
        pass

    try:
        plot_data = stress_res.PlotData
        node_ids = None
        values = None
        for key_name in ['Node', 'Node ID', 'NodeId', 'Node Number']:
            try:
                node_ids = plot_data[key_name]
                log('[PLOTDATA] Columna nodo: ' + key_name)
                break
            except:
                pass
        for key_name in ['Values', 'Value', 'Equivalent Stress']:
            try:
                values = plot_data[key_name]
                log('[PLOTDATA] Columna valor: ' + key_name)
                break
            except:
                pass
        n_nodes = sequence_count(node_ids)
        n_values = sequence_count(values)
        log('[PLOTDATA] n_nodes=' + str(n_nodes) + ', n_values=' + str(n_values))
        n_data = min(n_nodes, n_values)
        if node_ids is not None and values is not None and n_data > 0:
            # Ignorar nodos por debajo de Y_MIN_MM para evitar artefactos
            # de concentración de tensión en el apoyo fijo (B_Inferior).
            Y_MIN_MM = 5.0
            max_idx = -1
            max_val = -1.0
            for ii in range(n_data):
                try:
                    nid = int(sequence_item(node_ids, ii))
                    nd  = analysis.MeshData.NodeById(nid)
                    if nd is None:
                        continue
                    y_nd = nd.Y * 1000.0
                    if y_nd < Y_MIN_MM:
                        continue
                    val = float(sequence_item(values, ii))
                    if val > max_val:
                        max_val = val
                        max_idx = ii
                except:
                    pass
            if max_idx >= 0:
                node_id = int(sequence_item(node_ids, max_idx))
                node = analysis.MeshData.NodeById(node_id)
                if node:
                    y_mm = node.Y * 1000.0
                    log('[OK] Y max stress desde PlotData (filtro Y>=' + str(Y_MIN_MM) + 'mm). Node=' + str(node_id) + ', Y[mm]=' + str(round(y_mm, 4)))
                    return y_mm
    except:
        log('[AVISO] PlotData no devolvio la Y del maximo: ' + traceback.format_exc())

    try:
        max_node_id = stress_res.MaximumNode
    except:
        try:
            max_node_id = stress_res.MaximumNodeId
        except:
            max_node_id = 0

    if max_node_id > 0:
        try:
            node = analysis.MeshData.NodeById(max_node_id)
            if node:
                y_mm = node.Y * 1000.0
                log('[OK] Y max stress desde MaximumNode. Node=' + str(max_node_id) + ', Y[mm]=' + str(round(y_mm, 4)))
                return y_mm
        except:
            pass

    return float('nan')


def export_result_image(result_obj, image_path, label):
    try:
        # 1. Seleccionar y evaluar para asegurar que vemos el final
        result_obj.Activate()
        
        # 2. Encuadrar la camara y forzar vista isometrica (muy importante para batch)
        try:
            import Ansys
            # La ruta correcta del enumerador en Ansys 2025 es DataModel.Enums, no Graphics
            ExtAPI.Graphics.Camera.SetSpecificViewOrientation(Ansys.Mechanical.DataModel.Enums.ViewOrientationType.Iso)
        except:
            pass
        
        ExtAPI.Graphics.Camera.SetFit()
        
        # Ocultar la malla (API nativa extraÃ­da del Macro Recorder de ANSYS 2025)
        try:
            Graphics.ViewOptions.ResultPreference.ExtraModelDisplay = MechanicalEnums.Graphics.ExtraModelDisplay.NoWireframe
        except:
            pass
        
        # 3. Configurar imagen (Fondo blanco, 1080p)
        settings = Ansys.Mechanical.Graphics.GraphicsImageExportSettings()
        settings.CurrentGraphicsDisplay = False
        settings.Width = 1920
        settings.Height = 1080
        
        # Intentos para forzar el fondo blanco (segÃºn documentacion Ansys 2025)
        try:
            settings.Background = GraphicsBackgroundType.White
        except Exception: pass
        except System.Exception: pass
        
        try:
            import Ansys.Mechanical.DataModel.Enums as LocalEnums
            settings.Background = LocalEnums.GraphicsBackgroundType.White
        except Exception: pass
        except System.Exception: pass
            
        # 4. Exportar
        ExtAPI.Graphics.ExportImage(image_path, GraphicsImageExportFormat.PNG, settings)
        log("[OK] Imagen " + label + " guardada en: " + image_path)
        return True
    except:
        log("[AVISO] Fallo exportando imagen " + label + ": " + traceback.format_exc())
        return False


def export_view_image(target_obj, image_path, label, view_vec=None, up_vec=None, zoom_target=None):
    try:
        import Ansys
        import Ansys.Mechanical.DataModel.Enums as Enums
        
        # Intentar importar Vector3D de varias rutas posibles (compatibilidad de versiones)
        Vector3D = None
        try:
            from Ansys.Mechanical.Math import Vector3D
        except:
            try:
                from Ansys.ACT.Math import Vector3D
            except:
                pass
        
        # 1. Activar el resultado que gobierna la deformada mostrada
        target_obj.Activate()
        try:
            target_obj.EvaluateAllResults()
        except:
            pass

        # 1b. Forzar una vista limpia de geometria deformada.
        set_clean_deformed_view()

        # 2. Configurar la cÃ¡mara
        cam = ExtAPI.Graphics.Camera
        if view_vec and up_vec and Vector3D:
            try:
                cam.ViewVector = Vector3D(view_vec[0], view_vec[1], view_vec[2])
                cam.UpVector = Vector3D(up_vec[0], up_vec[1], up_vec[2])
            except:
                # Fallback si falla el vector directo
                cam.SetSpecificViewOrientation(Ansys.Mechanical.DataModel.Enums.ViewOrientationType.Iso)
        else:
            # Fallback a orientaciÃ³n por Enum (compatible con todas las versiones)
            # Intentamos mapear nuestros vectores a orientaciones comunes
            if view_vec == [0, 0, 1]: # Frontal
                cam.SetSpecificViewOrientation(Ansys.Mechanical.DataModel.Enums.ViewOrientationType.Front)
            elif view_vec == [1, 0, 0]: # Lateral
                cam.SetSpecificViewOrientation(Ansys.Mechanical.DataModel.Enums.ViewOrientationType.Right)
            else:
                cam.SetSpecificViewOrientation(Ansys.Mechanical.DataModel.Enums.ViewOrientationType.Iso)
        
        # 3. Zoom / Enfoque
        if zoom_target:
            focus_target = zoom_target
            try:
                if hasattr(zoom_target, "Location") and zoom_target.Location is not None:
                    focus_target = zoom_target.Location
            except:
                pass
            ExtAPI.SelectionManager.ClearSelection()
            ExtAPI.SelectionManager.NewSelection(focus_target)
            try:
                cam.SetFit()
                cam.FocusOn(focus_target)
            except:
                pass
            # 3a. Aplicar factor de zoom solicitado (0.5)
            try:
                # SceneWidth controla el campo de visión: menor valor = más zoom
                cam.SceneWidth = cam.SceneWidth * 0.5
                cam.SceneHeight = cam.SceneHeight * 0.5
            except:
                pass

            # 3b. (Desactivado desplazamiento focal manual por petición del usuario)
        else:
            cam.SetFit()
            
        # Refresco forzado de la escena
        ExtAPI.Graphics.Redraw()
            
        # 4. Configurar imagen
        settings = Ansys.Mechanical.Graphics.GraphicsImageExportSettings()
        settings.CurrentGraphicsDisplay = False
        settings.Width = 1920
        settings.Height = 1080
        try:
            settings.Background = Enums.GraphicsBackgroundType.White
        except: pass
            
        # 5. Exportar
        ExtAPI.Graphics.ExportImage(image_path, GraphicsImageExportFormat.PNG, settings)
        log("[OK] Vista " + label + " guardada en: " + image_path)
        
        # Limpiar seleccion
        ExtAPI.SelectionManager.ClearSelection()
        return True
    except:
        log("[AVISO] Fallo exportando vista " + label + ": " + traceback.format_exc())
        return False



def write_csv(e, f, s, w, epm, y_max, valid_flag):
    if not BATCH_MODE:
        return
    try:
        fh = open(csv_outfile, 'w')
        fh.write('Energy_J,Force_N,Stress_Max_Pa,Mass_kg,Energy_per_Mass_J_kg,Y_Max_Stress_mm,Valid' + chr(10))
        fh.write(
            str(e) + ',' + str(f) + ',' + str(s) + ',' +
            str(w) + ',' + str(epm) + ',' + str(y_max) + ',' + str(valid_flag) + chr(10)
        )
        fh.close()
        log("CSV escrito: " + csv_outfile)
    except:
        log("ERROR escribiendo CSV")


def get_first_object_by_name(name):
    try:
        objs = ExtAPI.DataModel.GetObjectsByName(name)
        if objs and len(objs) > 0:
            return objs[0]
    except:
        pass
    return None


def is_valid_number(val):
    try:
        x = float(val)
        if x != x:
            return False
        if x == float('inf') or x == float('-inf'):
            return False
        return True
    except:
        return False


def count_connection_regions(connections_obj):
    count = 0
    try:
        for conn_group in connections_obj.Children:
            try:
                count += len(conn_group.Children)
            except:
                pass
    except:
        pass
    return count


reset_log()
log("=== INICIO ECE R66 - L + CARTELA ===")
log("BATCH_MODE = " + str(BATCH_MODE))
log("pipeline_dir = " + str(pipeline_dir))
log("sim_id = " + str(sim_id))
log("image_dir = " + str(image_dir))
log("param_b_mm = " + str(param_b_mm))
log("c_mm = " + str(c_mm))
log("longitud_viga_mm = " + str(longitud_viga_mm))
log("angulo_desplazamiento_deg = " + str(angulo_desplazamiento_deg))
log("dir_x_sign = " + str(dir_x_sign) + ("  (-X estandar)" if dir_x_sign < 0 else "  (+X invertida)"))
log("desplazamiento_x_mm = " + str(desplazamiento_x_mm))
log("Material desde Engineering Data:")
log("  Yield Strength [Pa] = " + str(os.environ.get("TFG_YIELD_PA", "no_definido")))
log("  Tangent Modulus [Pa] = " + str(os.environ.get("TFG_TANGENT_MODULUS_PA", "no_definido")))

model = ExtAPI.DataModel.Project.Model
analysis = model.Analyses[0]
solution = analysis.Solution

# ============================================================
# PASO 1: LIMPIAR
# ============================================================
borrar = []
# 1. Limpiar TODAS las cargas, soportes y comandos (excepto los ajustes base)
for obj in analysis.Children:
    if obj.Name not in ["Analysis Settings", "Solution", "Initial Condition"]:
        borrar.append(obj)

# 2. Limpiar TODOS los resultados y sondas (excepto la info del solver)
for obj in solution.Children:
    if obj.Name not in ["Solution Information"]:
        borrar.append(obj)

# 3. Limpiar TODOS los sistemas de coordenadas creados
try:
    for cs_obj in list(model.CoordinateSystems.Children):
        if cs_obj.Name != "Global Coordinate System":
            borrar.append(cs_obj)
except:
    pass

# 4. Limpiar TODOS los controles de malla manuales
try:
    for obj in model.Mesh.Children:
        borrar.append(obj)
except:
    pass

for obj in reversed(borrar):
    try:
        obj.Delete()
    except:
        pass
log("[OK] PASO 1: Limpiado (resultados, cargas, malla, coordenadas)")

# ============================================================
# PASO 2: CONTACTOS (Limpiar todo, usar solo Shared Topology)
# ============================================================
try:
    conns = model.Connections
    n_before = count_connection_regions(conns)
    # Eliminar TODOS los grupos de contacto auto-generados al importar
    for conn_group in list(conns.Children):
        try:
            conn_group.Delete()
        except:
            pass
    log("[OK] PASO 2: Contactos eliminados (" + str(n_before) + " -> 0). Dependiendo 100% de Shared Topology.")
except:
    log("[AVISO] PASO 2: No se pudieron limpiar los contactos.")

# ============================================================
# PASO 3: MATERIAL (definido en Engineering Data)
# ============================================================
n_bodies = 0
for part in model.Geometry.Children:
    for body in part.Children:
        try:
            body.Material = "Structural Steel"
            n_bodies += 1
        except:
            pass
log("[OK] PASO 3: Material Structural Steel asignado a " + str(n_bodies) + " cuerpos")

# ============================================================
# PASO 4: ANALYSIS SETTINGS
# ============================================================
cfg = analysis.AnalysisSettings
cfg.LargeDeflection = True
cfg.NumberOfSteps = 1

cfg.CurrentStepNumber = 1
cfg.StepEndTime = Quantity("1 [s]")
cfg.AutomaticTimeStepping = AutomaticTimeStepping.On
cfg.DefineBy = TimeStepDefineByType.Substeps
cfg.InitialSubsteps = substeps_init
cfg.MinimumSubsteps = substeps_min
cfg.MaximumSubsteps = substeps_max
log("[OK] PASO 4: Analysis Settings — substeps init=" + str(substeps_init) +
    " min=" + str(substeps_min) + " max=" + str(substeps_max))

# ============================================================
# PASO 5: APDL SOLU - Convergencia
# ============================================================
apdl_solu = """
/SOLU
NROPT,FULL
LNSRCH,ON
PRED,OFF
NEQIT,60
AUTOTS,ON
RESCONTROL,DEFINE,NONE
SHPP,OFF
OUTRES,ALL,ALL
"""

cmd2 = analysis.AddCommandSnippet()
cmd2.Name = "Commands (APDL)"
cmd2.StepSelectionMode = SequenceSelectionType.All
cmd2.Input = apdl_solu
log("[OK] PASO 5: APDL SOLU (convergencia)")

# ============================================================
# PASO 6: MALLA
# ============================================================
mesh = model.Mesh
mesh.PhysicsPreference = MeshPhysicsPreferenceType.Mechanical
mesh.Resolution = mesh_resolution

elem_size_coarse = char_dim_mm / float(_coarse_div)
_fine_raw        = char_dim_mm / float(_fine_div)
elem_size_fine   = min(max(_fine_raw, _fine_min_mm), _fine_max_mm)

radius_mm = mesh_soi_radius

log("Resolucion global: " + str(mesh_resolution))
log("Dim. caracteristica malla: char_dim=" + str(round(char_dim_mm, 2)) + " mm  (b=" + str(round(param_b_mm, 2)) + " mm)")
log("Tamano malla gruesa: char_dim/" + str(_coarse_div) + " = " + str(round(elem_size_coarse, 2)) + " mm")
_clamp_note = ""
if elem_size_fine <= _fine_min_mm:
    _clamp_note = " [SUELO " + str(_fine_min_mm) + " mm]"
elif elem_size_fine >= _fine_max_mm:
    _clamp_note = " [TECHO " + str(_fine_max_mm) + " mm]"
log("Tamano malla fina (SOI): char_dim/" + str(_fine_div) + "=" + str(round(_fine_raw, 2)) + " mm -> clamp -> " + str(round(elem_size_fine, 2)) + " mm" + _clamp_note + "  radio=" + str(radius_mm) + " mm")

ns_base = get_first_object_by_name("B_Inferior")
ns_tope = get_first_object_by_name("A_Tope")
ns_arista = get_first_object_by_name("A_Tope_Arista")

if ns_base is None:
    raise Exception("No se encontro la Named Selection obligatoria: B_Inferior")
if ns_arista is None:
    raise Exception("No se encontro la Named Selection obligatoria: A_Tope_Arista")
if ns_tope is None:
    ns_tope = ns_arista
    log("[AVISO] No existe A_Tope. Se usa A_Tope_Arista para el Face Sizing superior.")

log("[OK] Named Selections detectadas:")
log("  - B_Inferior")
if ns_tope is ns_arista:
    log("  - A_Tope (fallback -> A_Tope_Arista)")
else:
    log("  - A_Tope")
log("  - A_Tope_Arista")

ns_viga_a = get_first_object_by_name("Viga_A")
ns_viga_b = get_first_object_by_name("Viga_B")
ns_cartela = get_first_object_by_name("Cartela")

# ============================================================
# MALLADO POR ZONAS (Sphere of Influence)
# ============================================================
# Crear un sistema de coordenadas justo en la cartela para centrar la esfera
cs = None
if ns_cartela is not None:
    try:
        cs = model.CoordinateSystems.AddCoordinateSystem()
        cs.OriginLocation = ns_cartela.Location
        cs.Name = "CS_Centro_Esquina"
    except:
        pass

if ns_viga_a is not None:
    # Malla gruesa general
    sizing_a = mesh.AddSizing()
    sizing_a.Location = ns_viga_a
    sizing_a.ElementSize = Quantity(str(elem_size_coarse) + " [mm]")
    # Malla fina en la esquina (si existe la cartela/cs)
    if cs is not None:
        soi_a = mesh.AddSizing()
        soi_a.Location = ns_viga_a
        soi_a.Type = SizingType.SphereOfInfluence
        soi_a.SphereCenter = cs
        soi_a.SphereRadius = Quantity(str(radius_mm) + " [mm]")
        soi_a.ElementSize = Quantity(str(elem_size_fine) + " [mm]")

if ns_viga_b is not None:
    sizing_b = mesh.AddSizing()
    sizing_b.Location = ns_viga_b
    sizing_b.ElementSize = Quantity(str(elem_size_coarse) + " [mm]")
    if cs is not None:
        soi_b = mesh.AddSizing()
        soi_b.Location = ns_viga_b
        soi_b.Type = SizingType.SphereOfInfluence
        soi_b.SphereCenter = cs
        soi_b.SphereRadius = Quantity(str(radius_mm) + " [mm]")
        soi_b.ElementSize = Quantity(str(elem_size_fine) + " [mm]")

if ns_cartela is not None:
    sizing_c = mesh.AddSizing()
    sizing_c.Location = ns_cartela
    sizing_c.ElementSize = Quantity(str(elem_size_fine) + " [mm]")

mesh.GenerateMesh()
num_nodes = model.Mesh.Nodes
num_elems = model.Mesh.Elements
log("[OK] PASO 6: Malla completada. Nodos: " + str(num_nodes) + ", Elementos: " + str(num_elems))

# ============================================================
# MODO SOLO MALLA — para tests de densidad sin resolver
# ============================================================

# ============================================================
# PASO 7: FIXED SUPPORT en B_Inferior
# ============================================================
fs = analysis.AddFixedSupport()
fs.Location = ns_base
log("[OK] PASO 7: Fixed Support en B_Inferior")

# ============================================================
# PASO 8: DESPLAZAMIENTO en A_Tope_Arista (X calculado para el angulo objetivo)
# ============================================================
disp = analysis.AddDisplacement()
disp.Location = ns_arista
disp.DefineBy = LoadDefineBy.Components

disp.XComponent.Output.DiscreteValues = [
    Quantity(str(desplazamiento_x_mm) + " [mm]")
]
log("[OK] PASO 8: Displacement " + str(desplazamiento_x_mm) + " mm X (A_Tope_Arista), Y y Z libres")

# ============================================================
# PASO 9: RESULTADOS
# ============================================================
deformation_res = solution.AddTotalDeformation()
stress_res = solution.AddEquivalentStress()
energy_res = solution.AddStructuralStrainEnergy()
force_res = solution.AddForceReaction()
force_res.BoundaryConditionSelection = disp

# Sonda de desplazamiento para curva time-history
disp_probe = solution.AddDeformationProbe()
try:
    disp_probe.GeometryLocation = ns_arista
except:
    pass
try:
    disp_probe.ResultSelection = ProbeDisplayFilter.XAxis
except:
    pass
log("[OK] PASO 9: Resultados + Sondas de curvas")

# ============================================================
# PASO 10: SOLVE
# ============================================================
solution.ClearGeneratedData()
log("Iniciando Solve...")
solve_ok = False
try:
    analysis.Solve()
    solve_ok = True
    log("[OK] PASO 10: Solve completado")
except:
    log("[ERROR] PASO 10: " + traceback.format_exc())

# ============================================================
# PASO 10B: EXPORTAR IMAGENES DE RESULTADOS (Estado Final)
if solve_ok:
    try:
        solution.EvaluateAllResults()
    except:
        pass
        
    try:
        ensure_dir(image_dir)
        # Foto de Tensiones
        fname_stress = os.path.join(image_dir, "Tensiones.png")
        export_result_image(stress_res, fname_stress, "Tensiones")
        
        # Vistas adicionales sin colores de la geometria ya deformada
        # Definimos vectores manuales para asegurar que la cÃ¡mara se mueve
        v_iso = [1, 1, 1]
        v_frontal = [0, 0, 1]  # Plano X-Y
        v_lateral = [1, 0, 0]  # Plano Y-Z
        up = [0, 1, 0]
        
        # Vista IsomÃ©trica
        export_view_image(disp_probe, os.path.join(image_dir, "Vista_Iso_Gris.png"), "Iso_Gris", v_iso, up)
        
        # Vista Frontal
        export_view_image(disp_probe, os.path.join(image_dir, "Vista_Frontal_Gris.png"), "Frontal_Gris", v_frontal, up)
        
        # Vista Lateral
        export_view_image(disp_probe, os.path.join(image_dir, "Vista_Lateral_Gris.png"), "Lateral_Gris", v_lateral, up)
        
        if ns_cartela is not None:
            # Zoom a la cartela
            export_view_image(disp_probe, os.path.join(image_dir, "Zoom_Cartela.png"), "Zoom_Cartela", v_iso, up, ns_cartela)
    except:
        log("[AVISO] Error en PASO 10B (imagenes): " + traceback.format_exc())
    
    # PASO 10C: EXPORTAR CURVAS FUERZA-DESPLAZAMIENTO (CSV)
    try:
        fname_curvas = os.path.join(image_dir, "Curvas.csv")
        io_force = force_res.InternalObject
        io_disp = disp_probe.InternalObject
        
        n_force = io_force.numPoints
        n_disp = io_disp.numPoints
        log("[CURVAS] numPoints fuerza: " + str(n_force) + ", desplazamiento: " + str(n_disp))
        
        fh = open(fname_curvas, 'w')
        fh.write("Punto,Time_F,ForceX,ForceY,ForceZ,ForceTotal,Time_D,DispX,DispY,DispZ,DispTotal" + chr(10))
        
        n_max = max(n_force, n_disp)
        for i in range(n_max):
            row = str(i)
            # Datos de fuerza
            if i < n_force:
                try:
                    t_f = str(io_force.XAxisData(i))
                except:
                    t_f = ""
                try:
                    fx = str(io_force.SequenceXVector(i))
                except:
                    fx = ""
                try:
                    fy = str(io_force.SequenceYVector(i))
                except:
                    fy = ""
                try:
                    fz = str(io_force.SequenceZVector(i))
                except:
                    fz = ""
                try:
                    ft = str(io_force.SequenceTotalVector(i))
                except:
                    ft = ""
                row = row + "," + t_f + "," + fx + "," + fy + "," + fz + "," + ft
            else:
                row = row + ",,,,,"
            
            # Datos de desplazamiento
            if i < n_disp:
                try:
                    t_d = str(io_disp.XAxisData(i))
                except:
                    t_d = ""
                try:
                    dx = str(io_disp.SequenceXDeformation(i))
                except:
                    dx = ""
                try:
                    dy = str(io_disp.SequenceYDeformation(i))
                except:
                    dy = ""
                try:
                    dz = str(io_disp.SequenceZDeformation(i))
                except:
                    dz = ""
                try:
                    dt = str(io_disp.SequenceTotalDeformation(i))
                except:
                    dt = ""
                row = row + "," + t_d + "," + dx + "," + dy + "," + dz + "," + dt
            else:
                row = row + ",,,,,"
            
            fh.write(row + chr(10))
        
        fh.close()
        log("[OK] PASO 10C: Curvas exportadas a CSV: " + fname_curvas + " (" + str(n_max) + " puntos)")
    except:
        log("[AVISO] Error en PASO 10C (curvas): " + traceback.format_exc())
e_val, f_val, s_val = float('nan'), float('nan'), float('nan')

try:
    e_val = energy_res.Total.Value
except:
    try:
        energy_res.EvaluateAllResults()
        e_val = energy_res.Total.Value
    except:
        log("AVISO: No se pudo leer energia")

try:
    f_val = force_res.MaximumTotal.Value
except:
    try:
        f_val = force_res.Maximum.Value
    except:
        log("AVISO: No se pudo leer fuerza")

y_max_stress = float('nan')
try:
    stress_res.EvaluateAllResults()
    s_val = stress_res.Maximum.Value
    y_max_stress = extract_y_max_stress_mm(stress_res, analysis)
except:
    log("AVISO: Error extrayendo tension o coordenada Y: " + traceback.format_exc())


w_val = float('nan')
try:
    acum = [0.0, 0]  # [masa_total_kg, n_cuerpos]

    def sumar_masa(obj, acum):
        # Solo contar hojas (Body sin hijos) para evitar doble conteo con el Part padre
        try:
            for child in obj.Children:
                n_child = 0
                try:
                    n_child = sequence_count(child.Children)
                except:
                    pass
                if n_child > 0:
                    sumar_masa(child, acum)
                else:
                    try:
                        m = child.Mass.Value
                        acum[0] += m
                        acum[1] += 1
                        try:
                            log("  Cuerpo '" + str(child.Name) + "': masa=" + str(round(m, 6)) + " kg")
                        except:
                            log("  Cuerpo [sin nombre]: masa=" + str(round(m, 6)) + " kg")
                    except:
                        pass
        except:
            pass
    
    sumar_masa(model.Geometry, acum)
    w_val = acum[0]
    log("[MASA] Total: " + str(acum[1]) + " cuerpos, masa = " + str(round(w_val, 4)) + " kg")
except:
    log("AVISO: No se pudo calcular masa desde Geometry")

if is_valid_number(e_val) and is_valid_number(w_val) and w_val > 0:
    mass_kg = w_val
    epm_val = e_val / mass_kg  # J/kg
else:
    epm_val = float('nan')

valid_result = (
    solve_ok and
    is_valid_number(e_val) and e_val > 0 and
    is_valid_number(w_val) and w_val > 0 and
    is_valid_number(f_val)
)

log("")
log("=== RESULTADOS ===")
log("  Energia: " + str(e_val) + " J")
log("  Fuerza:  " + str(f_val) + " N")
log("  Tension: " + str(s_val) + " Pa")
log("  Masa:    " + str(w_val) + " kg")
log("  Y Max Stress [mm]: " + str(y_max_stress))
log("  Valido:  " + str(valid_result))

if is_valid_number(s_val) and s_val > 5.0e9:
    log("[AVISO] Tension maxima muy alta; posible singularidad local o pico numerico.")

# Nota: parametrossalida.csv se escribe al FINAL del macro (tras la limpieza y
# la copia del log), para que su aparicion signifique "simulacion terminada del
# todo". Asi MATLAB no lanza el siguiente diseno mientras este aun limpia/copia,
# lo que evita dos Mechanical solapados y el cruce de logs entre carpetas.

# ============================================================
# PASO FINAL: LIMPIEZA DE DISCO (Archivos pesados del Solver)
# ============================================================
if BATCH_MODE:
    try:
        log("Limpiando archivos temporales del solver para liberar espacio...")
        solver_dir = analysis.WorkingDir
        for f_name in os.listdir(solver_dir):
            # Borrar .rst (resultados pesados) y .r*** (reinicio)
            if f_name.endswith(".rst") or ".r" in f_name.lower() or f_name.endswith(".err"):
                try:
                    os.remove(os.path.join(solver_dir, f_name))
                except:
                    pass
        log("[OK] Limpieza de disco completada.")
    except:
        pass

log("=== FIN ECE R66 - L + CARTELA ===")

# Copiar el log final a la carpeta de resultados de la simulacion
try:
    ensure_dir(image_dir)
    dest_log = os.path.join(image_dir, "mechanical_run.log")
    import System.IO
    System.IO.File.Copy(log_outfile, dest_log, True)
except:
    pass

# ============================================================
# SENAL DE FIN: escribir parametrossalida.csv como ULTIMA accion.
# Su aparicion indica a MATLAB que la simulacion ha terminado por completo
# (resultados, imagenes, limpieza y log ya en su carpeta), de modo que el
# siguiente diseno no arranca hasta que este ha cerrado. Evita solapar dos
# Mechanical y que el log de una carpeta acabe siendo el del diseno siguiente.
# ============================================================
write_csv(e_val, f_val, s_val, w_val, epm_val, y_max_stress, int(valid_result))

