# Python Script, API Version = V252
# =============================================================================
# PLANTILLA SPACECLAIM - GEOMETRIA L CON CARTELA (ECE R66)
# Pilar vertical + Base horizontal + Cartela (chapa triangular en esquina)
# Material: S-235JR
# =============================================================================
ClearAll()

# --- PARAMETROS inyectados desde MATLAB ---
# (Si estás probando en SpaceClaim directamente, sustituye PAR_... por los números)
a1 = PAR_A1
b1 = PAR_B1
m1 = PAR_M1
l1 = PAR_L1

a2 = PAR_A2
b2 = PAR_B2
m2 = PAR_M2
l2 = PAR_L2

c         = PAR_C          # Catetos de la cartela [mm] 
e_cartela = PAR_E_CARTELA  # Espesor de la chapa de la cartela [mm]

# =============================================================================
# FUNCIONES
# =============================================================================
def ajustar_vista():
    """Centra la camara con un margen de 50mm alrededor de la L."""
    ViewHelper.ActivateNamedView(u"Trim\xe9trico")
    try:
        p1 = DatumPointCreator.Create(Point.Create(MM(-50), MM(-50), MM(-50)))
        p2 = DatumPointCreator.Create(Point.Create(MM(l2+50), MM(l1+50), MM(b1+50)))
        ViewHelper.ZoomToEntity(Selection.Create(p1.CreatedPoint, p2.CreatedPoint))
        p1.CreatedPoint.Delete()
        p2.CreatedPoint.Delete()
    except:
        pass

def buscar_cara_Y(body):
    """Devuelve la cara con normal en Y para extruir."""
    for f in body.Faces:
        try:
            n = f.GetFaceNormal(0.5, 0.5)
            if abs(n.Y) > 0.9:
                return f
        except:
            pass
    return body.Faces[0]

# =============================================================================
# INICIO
# =============================================================================
ajustar_vista()

# =============================================================================
# 1. PILAR VIGA A (vertical)
#    Sketch en PlaneZX, extrusion en +Y por l1
# =============================================================================
ViewHelper.SetSketchPlane(Plane.PlaneZX)
SketchRectangle.Create(
    Point2D.Create(MM(0), MM(0)),
    Point2D.Create(MM(b1), MM(0)),
    Point2D.Create(MM(b1), MM(a1)))
SketchRectangle.Create(
    Point2D.Create(MM(m1), MM(m1)),
    Point2D.Create(MM(b1-m1), MM(m1)),
    Point2D.Create(MM(b1-m1), MM(a1-m1)))
ViewHelper.SetViewMode(InteractionMode.Solid, None)
body_a = GetRootPart().Bodies[0]
cara_a = buscar_cara_Y(body_a)
ExtrudeFaces.Execute(FaceSelection.Create(cara_a), MM(l1), ExtrudeFaceOptions())
viga_a = GetRootPart().Bodies[0]
print("Pilar A OK")

# =============================================================================
# 2. BASE VIGA B (horizontal)
#    Sketch en PlaneZX en Componente, extrusion en +Y por l2
# =============================================================================
ComponentHelper.CreateNewComponent(PartSelection.Create(GetRootPart()), None)
ViewHelper.SetSketchPlane(Plane.PlaneZX, None)
SketchRectangle.Create(
    Point2D.Create(MM(0), MM(0)),
    Point2D.Create(MM(b2), MM(0)),
    Point2D.Create(MM(b2), MM(a2)))
SketchRectangle.Create(
    Point2D.Create(MM(m2), MM(m2)),
    Point2D.Create(MM(b2-m2), MM(m2)),
    Point2D.Create(MM(b2-m2), MM(a2-m2)))
ViewHelper.SetViewMode(InteractionMode.Solid, None)
viga_b_part = GetRootPart().Components[0].Content
cara_b = buscar_cara_Y(viga_b_part.Bodies[0])
ExtrudeFaces.Execute(FaceSelection.Create(cara_b), MM(l2), ExtrudeFaceOptions())
viga_b = viga_b_part.Bodies[0]
print("Base B OK")

# =============================================================================
# 3. ENSAMBLAJE (Conexion "L" normal - base horizontal abajo)
# =============================================================================
sel_b = ComponentSelection.Create(GetRootPart().Components[0])
opts = MoveOptions()
Move.Rotate(sel_b, Line.Create(Point.Origin, Direction.DirZ), DEG(-90), opts)
Move.Translate(sel_b, Direction.DirX, MM(a1), opts)
Move.Translate(sel_b, Direction.DirY, MM(a2), opts)
Move.Translate(sel_b, Direction.DirZ, MM(b1-b2), opts)
print("Ensamblaje L OK")

# =============================================================================
# 4. CARTELA (protector de esquina)
# =============================================================================
cartela_front     = None
cartela_back      = None
cartela_inclinada = None

if c > 0 and e_cartela > 0:
    e = e_cartela
    
    z_start = max(0.0, b1 - b2)
    z_end   = b1
    ancho   = z_end - z_start
    
    # ==== PIEZA A: TRIÁNGULO FRONTAL ====
    ComponentHelper.CreateNewComponent(PartSelection.Create(GetRootPart()), None)
    
    origin_F = Point.Create(MM(0), MM(0), MM(z_end - e))
    frame_F = Frame.Create(origin_F, Direction.DirX, Direction.DirY)
    plane_F = Plane.Create(frame_F)
    ViewHelper.SetSketchPlane(plane_F, None)
    
    # Triángulo puro: esquina, cateto horizontal, cateto vertical
    pF1 = Point2D.Create(MM(a1),     MM(a2))
    pF2 = Point2D.Create(MM(a1 + c), MM(a2))
    pF3 = Point2D.Create(MM(a1),     MM(a2 + c))
    
    SketchLine.Create(pF1, pF2)
    SketchLine.Create(pF2, pF3)
    SketchLine.Create(pF3, pF1)
    
    ViewHelper.SetViewMode(InteractionMode.Solid, None)
    
    cartela_F_part = GetRootPart().Components[1].Content
    cartela_F_body = cartela_F_part.Bodies[0]
    cara_Fz = None
    for f in cartela_F_body.Faces:
        try:
            n = f.GetFaceNormal(0.5, 0.5)
            if n.Z > 0.9:
                cara_Fz = f
                break
        except:
            pass
    if cara_Fz is None:
        cara_Fz = cartela_F_body.Faces[0]
    
    ExtrudeFaces.Execute(FaceSelection.Create(cara_Fz), MM(e), ExtrudeFaceOptions())
    cartela_front = cartela_F_part.Bodies[0]
    print("Triangulo frontal OK (z={} a {})".format(z_end - e, z_end))
    
    # ==== PIEZA B: TRIÁNGULO TRASERO ====
    ComponentHelper.CreateNewComponent(PartSelection.Create(GetRootPart()), None)
    
    origin_B = Point.Create(MM(0), MM(0), MM(z_start))
    frame_B = Frame.Create(origin_B, Direction.DirX, Direction.DirY)
    plane_B = Plane.Create(frame_B)
    ViewHelper.SetSketchPlane(plane_B, None)
    
    # Triángulo puro: esquina, cateto horizontal, cateto vertical
    pB1 = Point2D.Create(MM(a1),     MM(a2))
    pB2 = Point2D.Create(MM(a1 + c), MM(a2))
    pB3 = Point2D.Create(MM(a1),     MM(a2 + c))
    
    SketchLine.Create(pB1, pB2)
    SketchLine.Create(pB2, pB3)
    SketchLine.Create(pB3, pB1)
    
    ViewHelper.SetViewMode(InteractionMode.Solid, None)
    
    cartela_B_part = GetRootPart().Components[2].Content
    cartela_B_body = cartela_B_part.Bodies[0]
    cara_Bz = None
    for f in cartela_B_body.Faces:
        try:
            n = f.GetFaceNormal(0.5, 0.5)
            if n.Z > 0.9:
                cara_Bz = f
                break
        except:
            pass
    if cara_Bz is None:
        cara_Bz = cartela_B_body.Faces[0]
    
    ExtrudeFaces.Execute(FaceSelection.Create(cara_Bz), MM(e), ExtrudeFaceOptions())
    cartela_back = cartela_B_part.Bodies[0]
    print("Triangulo trasero OK (z={} a {})".format(z_start, z_start + e))
    
    # ==== PIEZA C: TAPA INCLINADA (hipotenusa) ====
    # Conecta los dos triángulos cerrando la cartela por la diagonal
    ComponentHelper.CreateNewComponent(PartSelection.Create(GetRootPart()), None)
    
    # Sketch en el plano Z = z_start (cara trasera del triángulo trasero)
    origin_I = Point.Create(MM(0), MM(0), MM(z_start))
    frame_I = Frame.Create(origin_I, Direction.DirX, Direction.DirY)
    plane_I = Plane.Create(frame_I)
    ViewHelper.SetSketchPlane(plane_I, None)
    
    # Rectángulo inclinado de espesor e a lo largo de la hipotenusa
    # Hipotenusa: de (a1+c, a2) a (a1, a2+c)
    # Dirección normal a la hipotenusa (hacia la esquina): (1/sqrt2, 1/sqrt2)
    import math
    hip_len = math.sqrt(c*c + c*c)  # longitud de la hipotenusa
    nx_hip = c / hip_len   # componente X de la normal (apunta hacia esquina)
    ny_hip = c / hip_len   # componente Y de la normal
    # Desplazar e en la dirección de la normal hacia afuera (lejos de la esquina)
    dx = e * nx_hip
    dy = e * ny_hip
    
    pI1 = Point2D.Create(MM(a1 + c),      MM(a2))
    pI2 = Point2D.Create(MM(a1),          MM(a2 + c))
    pI3 = Point2D.Create(MM(a1 + dx),     MM(a2 + c + dy))
    pI4 = Point2D.Create(MM(a1 + c + dx), MM(a2 + dy))
    
    SketchLine.Create(pI1, pI4)
    SketchLine.Create(pI4, pI3)
    SketchLine.Create(pI3, pI2)
    SketchLine.Create(pI2, pI1)
    
    ViewHelper.SetViewMode(InteractionMode.Solid, None)
    
    cartela_I_part = GetRootPart().Components[3].Content
    cartela_I_body = cartela_I_part.Bodies[0]
    cara_Iz = None
    for f in cartela_I_body.Faces:
        try:
            n = f.GetFaceNormal(0.5, 0.5)
            if n.Z > 0.9:
                cara_Iz = f
                break
        except:
            pass
    if cara_Iz is None:
        cara_Iz = cartela_I_body.Faces[0]
    
    ExtrudeFaces.Execute(FaceSelection.Create(cara_Iz), MM(ancho), ExtrudeFaceOptions())
    cartela_inclinada = cartela_I_part.Bodies[0]
    print("Tapa inclinada OK (z={} a {})".format(z_start, z_end))

else:
    print("Sin cartela (c=0 o e_cartela=0)")

# =============================================================================
# 5. NAMED SELECTIONS
# =============================================================================
tol = max(a1, a2, b1, b2) * 0.6

caras_A_base     = []
caras_A_tope     = []
caras_A_derecha  = []
caras_A_izquierda = []
caras_A_frontal  = []
caras_A_trasera  = []

caras_B_conexion = []
caras_B_extremo  = []
caras_B_superior = []
caras_B_inferior = []
caras_B_frontal  = []
caras_B_trasera  = []

for f in viga_a.Faces:
    try:
        pt     = f.GetFacePoint(0.5, 0.5)
        normal = f.GetFaceNormal(0.5, 0.5)
        cx = pt.X * 1000.0
        cy = pt.Y * 1000.0
        cz = pt.Z * 1000.0
        nx = normal.X
        ny = normal.Y
        nz = normal.Z
        
        if ny < -0.9: caras_A_base.append(f)
        elif ny > 0.9: caras_A_tope.append(f)
        elif nx > 0.9 and cx > (a1 - m1): caras_A_derecha.append(f)
        elif nx < -0.9 and cx < m1: caras_A_izquierda.append(f)
        elif nz > 0.9 and cz > (b1 - m1): caras_A_frontal.append(f)
        elif nz < -0.9 and cz < m1: caras_A_trasera.append(f)
    except:
        pass

for f in viga_b.Faces:
    try:
        pt     = f.GetFacePoint(0.5, 0.5)
        normal = f.GetFaceNormal(0.5, 0.5)
        cx = pt.X * 1000.0
        cy = pt.Y * 1000.0
        cz = pt.Z * 1000.0
        nx = normal.X
        ny = normal.Y
        nz = normal.Z
        
        if nx < -0.9: caras_B_conexion.append(f)
        elif nx > 0.9: caras_B_extremo.append(f)
        elif ny > 0.9 and cy > (a2 - m2): caras_B_superior.append(f)
        elif ny < -0.9 and cy < m2: caras_B_inferior.append(f)
        elif nz > 0.9 and cz > (b1 - m2): caras_B_frontal.append(f)
        elif nz < -0.9 and cz < (b1 - b2 + m2): caras_B_trasera.append(f)
    except:
        pass

print("=== NAMED SELECTIONS ===")

if caras_A_base: NamedSelection.Create(FaceSelection.Create(caras_A_base), Selection.Empty(), "A_Base")
if caras_A_tope: NamedSelection.Create(FaceSelection.Create(caras_A_tope), Selection.Empty(), "A_Tope")
if caras_A_derecha: NamedSelection.Create(FaceSelection.Create(caras_A_derecha), Selection.Empty(), "A_Derecha")
if caras_A_izquierda: NamedSelection.Create(FaceSelection.Create(caras_A_izquierda), Selection.Empty(), "A_Izquierda")
if caras_A_frontal: NamedSelection.Create(FaceSelection.Create(caras_A_frontal), Selection.Empty(), "A_Frontal")
if caras_A_trasera: NamedSelection.Create(FaceSelection.Create(caras_A_trasera), Selection.Empty(), "A_Trasera")

if caras_B_conexion: NamedSelection.Create(FaceSelection.Create(caras_B_conexion), Selection.Empty(), "B_Conexion")
if caras_B_extremo: NamedSelection.Create(FaceSelection.Create(caras_B_extremo), Selection.Empty(), "B_Extremo")
if caras_B_superior: NamedSelection.Create(FaceSelection.Create(caras_B_superior), Selection.Empty(), "B_Superior")
if caras_B_inferior: NamedSelection.Create(FaceSelection.Create(caras_B_inferior), Selection.Empty(), "B_Inferior")
if caras_B_frontal: NamedSelection.Create(FaceSelection.Create(caras_B_frontal), Selection.Empty(), "B_Frontal")
if caras_B_trasera: NamedSelection.Create(FaceSelection.Create(caras_B_trasera), Selection.Empty(), "B_Trasera")

NamedSelection.Create(BodySelection.Create(viga_a), Selection.Empty(), "Viga_A")
NamedSelection.Create(BodySelection.Create(viga_b), Selection.Empty(), "Viga_B")
print("  Viga_A, Viga_B : cuerpos OK")

# --- Arista superior exterior de Viga A (X=a1, Y=l1, recorre Z) ---
arista_tope = []
for edge in viga_a.Edges:
    try:
        mid = edge.EvalMid()
        mx = mid.Point.X * 1000.0
        my = mid.Point.Y * 1000.0
        # Arista en el tope (Y≈l1) y en la cara exterior (X≈a1)
        if abs(my - l1) < 0.5 and abs(mx - a1) < 0.5:
            arista_tope.append(edge)
    except:
        pass

if arista_tope:
    NamedSelection.Create(EdgeSelection.Create(arista_tope), Selection.Empty(), "A_Tope_Arista")
    print("  A_Tope_Arista  : {} arista(s) OK".format(len(arista_tope)))
else:
    print("  AVISO: No se encontro arista tope exterior")

cartela_bodies = []
if cartela_front is not None: cartela_bodies.append(cartela_front)
if cartela_back is not None: cartela_bodies.append(cartela_back)
if cartela_inclinada is not None: cartela_bodies.append(cartela_inclinada)

if cartela_bodies:
    NamedSelection.Create(BodySelection.Create(cartela_bodies), Selection.Empty(), "Cartela")
    print("  Cartela        : {} cuerpo(s) OK".format(len(cartela_bodies)))

# =============================================================================
# 6. SHARE TOPOLOGY (malla conforme sin contactos)
# =============================================================================
# 1. Forzar la unión geométrica con tolerancia (lo que tú encontraste)
options = ShareTopologyOptions()
options.Tolerance = MM(0.5)
result = ShareTopology.Create(options)

# 2. Activar la "bandera" de Share para que Mechanical lo sepa al importar
root = GetRootPart()
root.ShareTopology = root.ShareTopology.Share
for comp in root.Components:
    try:
        comp.Content.ShareTopology = comp.Content.ShareTopology.Share
    except:
        pass

print("=== SPACECLAIM L + CARTELA OK ===")