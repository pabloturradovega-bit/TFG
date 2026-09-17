% =========================================================================
% T01_Generar_DOE_LHS.m
% =========================================================================
% TFG: Optimización de secciones de arco de seguridad de autobús (ECE R66)
%      mediante modelo sustituto (Gaussian Process Regression) y AG
%
% Genera un DOE con Latin Hypercube Sampling sobre 6 variables geométricas:
%   Variables activas: m1, a1, m2, a2, b(=b1=b2), e_cartela
%   Parametros fijos:  l1=l2=longitud_vigas_mm, c=80 mm (catetos cartela)
%
% Material: S-235JR
%
% AUTOR: Pablo Turrado Vega
% FECHA: 2026
% =========================================================================

clear; clc;

%% 1. Reproducibilidad
rng(0);

%% 2. Parámetros de la Campaña
numSamples = 64;
material   = 'S235JR';
prefijo_campana = 'DOE';

% --- Parámetros del ensayo (se guardan en meta_campana.mat para T02/T05) ---
angulo_desplazamiento_deg = 30;   % Ángulo de giro del pilar [°]
dir_x_sign                = -1;   % Dirección del desplazamiento: -1 = -X (ECE R66), +1 = +X
yield_strength_pa         = 235500000;    % Tensión de fluencia S235JR [Pa]
tangent_modulus_pa        = 1160000000;   % Módulo tangente bilineal [Pa]
% Loeppky et al. (2009): mínimo 10×d = 60 para d=6 variables activas.

%% 3. Rangos de diseño [mm]
% =========================================================================
% 6 Variables ACTIVAS del DOE
% =========================================================================
m1_min = 2;   m1_max = 4;           % Espesor de pared Viga A [mm] (continuo DOE)
a1_min = 40;  a1_max = 100;         % Altura de seccion Viga A [mm] (continuo DOE)
m2_min = 2;   m2_max = 4;           % Espesor de pared Viga B [mm] (continuo DOE)
a2_min = 40;  a2_max = 100;         % Altura de seccion Viga B [mm] (continuo DOE)
b_min  = 40;  b_max  = 100;         % Anchura COMÚN (b1=b2) [mm]
ec_min = 2;   ec_max = 4;           % Espesor cartela [mm] (continuo DOE)

% =========================================================================
% Parámetros FIJOS del DOE geométrico.
% Estas magnitudes sí forman parte de cada muestra guardada en basededatos.csv,
% aunque no varíen dentro del LHS actual. Si cambia la longitud, debe cambiar aquí
% para que geometría, dataset y postproceso queden coherentes entre sí.
% =========================================================================
longitud_vigas_mm = 1000;  % Longitud comun de las vigas [mm]
l1_fijo = longitud_vigas_mm;   % Longitud Viga A [mm]
l2_fijo = longitud_vigas_mm;   % Longitud Viga B [mm]
c_fijo  = 80;                  % Catetos cartela [mm]

%% 4. Validación de restricciones ANTES de generar
limite1 = min(a1_min, b_min) / 4;
margen1 = limite1 - m1_max;

limite2 = min(a2_min, b_min) / 4;
margen2 = limite2 - m2_max;

fprintf('=== VALIDACIÓN PRE-GENERACIÓN ===\n');
fprintf('  Restricción: m_max ≤ min(a_min, b_min) / 4\n\n');
fprintf('  Viga A: m1_max=%.1f, límite=%.1f, margen=%.1f mm\n', m1_max, limite1, margen1);
fprintf('  Viga B: m2_max=%.1f, límite=%.1f, margen=%.1f mm\n', m2_max, limite2, margen2);

assert(margen1 >= 0, 'FALLO Viga A: ajusta rangos.');
assert(margen2 >= 0, 'FALLO Viga B: ajusta rangos.');
fprintf('  Estado: OK\n\n');

%% 5. Latin Hypercube Sampling (6 variables activas)
% Columnas: [m1, a1, m2, a2, b, e_cartela]
X = lhsdesign(numSamples, 6);

%% 6. Escalado a dimensiones físicas
m1        = m1_min + (m1_max - m1_min) * X(:,1);
a1        = a1_min + (a1_max - a1_min) * X(:,2);
m2        = m2_min + (m2_max - m2_min) * X(:,3);
a2        = a2_min + (a2_max - a2_min) * X(:,4);
b         = b_min  + (b_max  - b_min)  * X(:,5);
e_cartela = ec_min + (ec_max - ec_min) * X(:,6);

% Variables derivadas / fijas
b1 = b;
b2 = b;
l1 = ones(numSamples, 1) * l1_fijo;
l2 = ones(numSamples, 1) * l2_fijo;
c  = ones(numSamples, 1) * c_fijo;

%% 7. Verificación post-generación
violaciones = sum((m1 > min(a1,b1)/4) | (m2 > min(a2,b2)/4));
if violaciones == 0
    fprintf('Post-generación: %d/%d muestras válidas\n', numSamples, numSamples);
else
    warning('%d muestras violan restricción.', violaciones);
end

energy          = NaN(numSamples, 1);
stress          = NaN(numSamples, 1);
force           = NaN(numSamples, 1);
mass_kg         = NaN(numSamples, 1);
energy_per_mass = NaN(numSamples, 1);
sim_time_s      = NaN(numSamples, 1);
y_max_stress_mm = NaN(numSamples, 1);
valid_ansys     = NaN(numSamples, 1);
pivot_height_mm = NaN(numSamples, 1);
lever_arm_mm    = NaN(numSamples, 1);
modo_fallo      = repmat({'N/A'}, numSamples, 1);

data = table(m1, a1, b1, l1, m2, a2, b2, l2, c, e_cartela, ...
    energy, stress, force, mass_kg, energy_per_mass, sim_time_s, ...
    y_max_stress_mm, valid_ansys, pivot_height_mm, lever_arm_mm, modo_fallo);

% --- Generacion Inteligente de Nombre de Campana ---
if all(l1 == l1(1)), str_l1 = sprintf('L%d', l1(1)); else, str_l1 = 'Lvar'; end
if all(c == c(1)), str_c = sprintf('C%d', c(1)); else, str_c = 'Cvar'; end

nombre_campana = sprintf('%s_%d_%s_%s_%s', prefijo_campana, numSamples, str_l1, str_c, material);
carpeta_resultados = fullfile('Resultados', nombre_campana);

if ~exist(carpeta_resultados, 'dir')
    mkdir(carpeta_resultados);
end

archivo_db = fullfile(carpeta_resultados, 'basededatos.csv');
writetable(data, archivo_db);

% --- Guardar meta_campana.mat (necesario para T02, T05 y la GUI) ---
% lb/ub: [m1, a1, m2, a2, b, e_cartela, c] — misma convencion que la GUI
meta.material  = material;
meta.l_fijo    = l1_fijo;
meta.c_fijo    = c_fijo;
meta.angulo    = angulo_desplazamiento_deg;
meta.dir_x     = dir_x_sign;
meta.fy_pa     = yield_strength_pa;
meta.Et_pa     = tangent_modulus_pa;
meta.lb        = [m1_min, a1_min, m2_min, a2_min, b_min,  ec_min, c_fijo];
meta.ub        = [m1_max, a1_max, m2_max, a2_max, b_max,  ec_max, c_fijo];
save(fullfile(carpeta_resultados, 'meta_campana.mat'), 'meta');

% --- Guardar chivato para el resto de scripts ---
fid = fopen('active_campaign.txt', 'w');
fprintf(fid, '%s', nombre_campana);
fclose(fid);

fprintf('\n=== DOE GENERADO ===\n');
fprintf('  Campaña           : %s\n', nombre_campana);
fprintf('  Directorio        : %s\n', carpeta_resultados);
fprintf('  Muestras          : %d\n', numSamples);
fprintf('  Variables activas : 6 (m1, a1, m2, a2, b, e_cartela)\n');
fprintf('  Restricción       : b1 = b2 = b (ancho común) \n');
fprintf('  DOE continuo      : a1,a2=[40,100], m1,m2,e_cartela=[2,4] mm\n');
fprintf('  Material          : %s\n', material);


% 9. Visualizacion de cobertura LHS
% Muestra solo las 6 variables activas del DOE actual.

vars_act = table(m1, a1, m2, a2, b, e_cartela);
nombres_vars = {'m1','a1','m2','a2','b','e_c'};

figure('Name', 'Verificacion DOE - Variables activas', 'Position', [100 100 1200 700]);
tiledlayout(2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
scatter(m1, a1, 28, 'filled', 'MarkerFaceColor', [0.20 0.45 0.85], 'MarkerFaceAlpha', 0.55);
xlabel('m1 [mm]'); ylabel('a1 [mm]');
title('Viga A'); grid on; box on;

nexttile;
scatter(m2, a2, 28, 'filled', 'MarkerFaceColor', [0.85 0.35 0.20], 'MarkerFaceAlpha', 0.55);
xlabel('m2 [mm]'); ylabel('a2 [mm]');
title('Viga B'); grid on; box on;

nexttile;
scatter(b, e_cartela, 28, 'filled', 'MarkerFaceColor', [0.25 0.65 0.35], 'MarkerFaceAlpha', 0.55);
xlabel('b [mm]'); ylabel('e_{cartela} [mm]');
title('Ancho comun vs cartela'); grid on; box on;

nexttile;
histogram(a1, 'BinEdges', 40:10:100, 'FaceColor', [0.20 0.45 0.85], 'EdgeColor', 'w');
xlabel('a1 [mm]'); ylabel('Frecuencia');
title('Distribucion a1'); grid on; box on; xlim([40 100]);

nexttile;
histogram(a2, 'BinEdges', 40:10:100, 'FaceColor', [0.85 0.35 0.20], 'EdgeColor', 'w');
xlabel('a2 [mm]'); ylabel('Frecuencia');
title('Distribucion a2'); grid on; box on; xlim([40 100]);

nexttile;
histogram(e_cartela, 'BinEdges', 2:0.2:4, 'FaceColor', [0.25 0.65 0.35], 'EdgeColor', 'w');
xlabel('e_{cartela} [mm]'); ylabel('Frecuencia');
title('Distribucion cartela'); grid on; box on; xlim([2 4]);

sgtitle(sprintf('DOE LHS - %d muestras continuas para ANSYS', numSamples));

% Matriz de correlacion de las variables activas
figure('Name', 'Ortogonalidad del DOE - LHS');
heatmap(nombres_vars, nombres_vars, round(corrcoef(vars_act{:,:}), 2));
title('Matriz de correlacion de Pearson (LHS)');