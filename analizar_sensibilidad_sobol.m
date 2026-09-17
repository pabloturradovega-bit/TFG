function resultados = analizar_sensibilidad_sobol()
% =========================================================================
% analizar_sensibilidad_sobol
% =========================================================================
% Indices de sensibilidad global de Sobol (primer orden S_i y totales ST_i)
% de la energia especifica [J/kg] respecto a las variables activas del DOE
% (6, o 7 si la campaña incluye el cateto de la cartela como variable),
% evaluados sobre el surrogate de la campana activa.
%
% Metodo: estimadores de Saltelli (2010) / Jansen (1999) con matrices A, B
% y AB_i muestreadas con secuencias de Sobol. Coste: N*(d+2) evaluaciones
% del surrogate (sin ANSYS) -- segundos.
%
% Salidas (en Resultados/<campana>/):
%   figura_sensibilidad_sobol.png  (barras S_i vs ST_i)
%   sensibilidad_sobol.csv         (tabla de indices)
%
% Interpretacion para la memoria:
%   S_i  : fraccion de la varianza de EPM explicada por la variable sola.
%   ST_i : idem incluyendo todas sus interacciones.
%   ST_i - S_i grande => la variable actua sobre todo via interacciones.
%
% Es una funcion (no script) para poder invocarla desde la GUI sin
% contaminar workspaces. Se ejecuta igual desde consola:
%   >> analizar_sensibilidad_sobol
% =========================================================================

rng(0);

N = 8192;   % muestras base (evaluaciones totales = N*(d+2))

% --- Cargar Campana Activa ---
if ~isfile('active_campaign.txt')
    error('No se encontro active_campaign.txt. Ejecuta primero T01.');
end
fid = fopen('active_campaign.txt', 'r');
nombre_campana = strtrim(fgetl(fid));
fclose(fid);

carpeta_resultados = fullfile('Resultados', nombre_campana);
fprintf('Campana activa: %s\n', nombre_campana);

ruta_modelo = fullfile(carpeta_resultados, 'modelo_surrogate.mat');
if ~isfile(ruta_modelo)
    error('No se encontro modelo_surrogate.mat. Entrena el modelo primero (T03 o GUI).');
end
load(ruta_modelo, 'trainedModel');

% --- Rangos de las variables activas y parametros fijos (de meta) ---
lb = [2,  40,  2,  40,  40,  2];   % [m1 a1 m2 a2 b e_cartela]
ub = [4, 100,  4, 100, 100,  4];
c_fijo = 80; l_fijo = 1000;
c_lb = 70; c_ub = 120;             % rango del cateto si es variable (Cvar)
meta_f = fullfile(carpeta_resultados, 'meta_campana.mat');
if isfile(meta_f)
    m_meta = load(meta_f, 'meta'); meta_camp = m_meta.meta;
    if isfield(meta_camp, 'lb'),     lb = reshape(meta_camp.lb(1:6), 1, 6); end
    if isfield(meta_camp, 'ub'),     ub = reshape(meta_camp.ub(1:6), 1, 6); end
    if isfield(meta_camp, 'c_fijo'), c_fijo = meta_camp.c_fijo; end
    if isfield(meta_camp, 'l_fijo'), l_fijo = meta_camp.l_fijo; end
    if isfield(meta_camp,'lb') && numel(meta_camp.lb)>=7, c_lb = meta_camp.lb(7); end
    if isfield(meta_camp,'ub') && numel(meta_camp.ub)>=7, c_ub = meta_camp.ub(7); end
    fprintf('Meta cargada: c=%g mm, l=%g mm.\n', c_fijo, l_fijo);
else
    fprintf('Sin meta_campana.mat: usando rangos por defecto.\n');
end

% El cateto c se incluye como 7a variable solo si el surrogate lo trata como
% predictor (campaña de cateto variable). Asi el mismo analisis vale para
% campañas de 6 y de 7 variables.
c_var = isfield(trainedModel,'predictorNames') && ...
        any(strcmp('c', trainedModel.predictorNames));
if c_var
    lb = [lb, c_lb];  ub = [ub, c_ub];
    nombres = {'m1','a1','m2','a2','b','e_{cartela}','c'};
    d = 7;
    fprintf('Cateto variable: incluyendo c en [%g, %g] mm (7 variables).\n', c_lb, c_ub);
else
    nombres = {'m1','a1','m2','a2','b','e_{cartela}'};
    d = 6;
end

% --- Matrices A y B (Sobol scrambled, 2d columnas) ---
p = sobolset(2*d, 'Skip', 1);
p = scramble(p, 'MatousekAffineOwen');
Z = net(p, N);
A = lb + (ub - lb) .* Z(:, 1:d);
B = lb + (ub - lb) .* Z(:, d+1:2*d);
% Nota: en estos rangos la restriccion m <= min(a,b)/4 nunca se viola
% (m_max=4 <= 40/4), asi que el muestreo en caja es valido.

% --- Funcion objetivo: energia especifica [J/kg] ---
evaluar_epm = @(X6) epm_surrogate(X6, trainedModel, l_fijo, c_fijo);

fprintf('Evaluando %d disenos (%d base x %d matrices)...\n', N*(d+2), N, d+2);
tic;
yA = evaluar_epm(A);
yB = evaluar_epm(B);

S  = zeros(d, 1);   % primer orden (Saltelli 2010)
ST = zeros(d, 1);   % totales (Jansen 1999)
V  = var([yA; yB], 1);

for i = 1:d
    ABi = A;
    ABi(:, i) = B(:, i);
    yABi = evaluar_epm(ABi);

    S(i)  = mean(yB .* (yABi - yA)) / V;
    ST(i) = 0.5 * mean((yA - yABi).^2) / V;
end
t_ev = toc;
fprintf('Hecho en %.1f s.\n\n', t_ev);

% --- Resultados ---
[~, orden] = sort(ST, 'descend');
fprintf('=========================================================\n');
fprintf('  INDICES DE SOBOL  (KPI: energia especifica [J/kg])\n');
fprintf('=========================================================\n');
fprintf('  %-12s %10s %10s %14s\n', 'Variable', 'S_i', 'ST_i', 'Interaccion');
for k = 1:d
    i = orden(k);
    fprintf('  %-12s %10.4f %10.4f %14.4f\n', nombres{i}, S(i), ST(i), ST(i)-S(i));
end
fprintf('---------------------------------------------------------\n');
fprintf('  Suma S_i = %.4f  (1 - suma = peso de interacciones)\n', sum(S));
fprintf('=========================================================\n');

% --- Guardar tabla ---
tabla = table(nombres(:), S, ST, ST - S, ...
    'VariableNames', {'variable','S_primer_orden','ST_total','interaccion'});
ruta_csv = fullfile(carpeta_resultados, 'sensibilidad_sobol.csv');
writetable(tabla, ruta_csv);

% --- Figura ---
fig = figure('Name', 'Sensibilidad de Sobol', 'Position', [100, 100, 800, 450]);
bar([S(orden), ST(orden)], 'grouped');
set(gca, 'XTickLabel', nombres(orden), 'TickLabelInterpreter', 'tex');
ylabel('Indice de Sobol');
legend({'S_i (primer orden)', 'ST_i (total)'}, 'Location', 'northeast');
title(sprintf('Sensibilidad global de la energia especifica (N=%d)', N));
grid on;
ruta_png = fullfile(carpeta_resultados, 'figura_sensibilidad_sobol.png');
saveas(fig, ruta_png);

fprintf('\nGuardado: %s\n', ruta_csv);
fprintf('Guardado: %s\n', ruta_png);

resultados = struct('nombres', {nombres}, 'S', S, 'ST', ST, ...
    'orden', orden, 'N', N, 'ruta_csv', ruta_csv, 'ruta_png', ruta_png);
end

% =========================================================================
% Funciones locales
% =========================================================================
function epm = epm_surrogate(X, trainedModel, l_fijo, c_fijo)
    % X: Nxd con columnas [m1 a1 m2 a2 b e_cartela (c)].
    % Si X tiene 7 columnas, la 7a es el cateto c (campaña Cvar); si tiene 6,
    % c se fija a c_fijo. Devuelve la energia especifica [J/kg].
    n = size(X, 1);
    m1 = X(:,1); a1 = X(:,2); m2 = X(:,3); a2 = X(:,4); b = X(:,5); ec = X(:,6);
    if size(X, 2) >= 7
        c = X(:,7);
    else
        c = c_fijo * ones(n, 1);
    end
    tab = array2table([m1, a1, b, l_fijo*ones(n,1), ...
                       m2, a2, b, l_fijo*ones(n,1), ...
                       c, ec], ...
        'VariableNames', {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
    E = trainedModel.predictFcn(tab);  % [J]
    masa = masa_analitica(m1, a1, b, l_fijo, m2, a2, b, l_fijo, c, ec);
    epm = E ./ masa;
end
