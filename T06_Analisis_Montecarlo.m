% =========================================================================
% Analisis_Montecarlo_06.m
% =========================================================================
% Analisis de robustez del diseno optimo mediante Monte Carlo.
% KPI principal: energia especifica [J/kg].
% =========================================================================

clear; clc;
rng(0);

% Umbral ECE R66 de energia especifica [J/kg]; 0 = sin comprobar.
% (mismo significado que app.umbral_ecr66 en la GUI)
umbral_ecr66 = 0;

fprintf('=== ANALISIS DE ROBUSTEZ (MONTE CARLO) ===\n\n');

% --- Cargar Campaña Activa ---
if ~isfile('active_campaign.txt')
    error('No se encontro active_campaign.txt. Ejecuta primero T01_Generar_DOE_LHS.m');
end
fid = fopen('active_campaign.txt', 'r');
nombre_campana = strtrim(fgetl(fid));
fclose(fid);

carpeta_resultados = fullfile('Resultados', nombre_campana);
fprintf('Campaña activa: %s\n', nombre_campana);

% =========================================================================
% 1. Cargar optimo y modelo IA
% =========================================================================
ruta_optimo = fullfile(carpeta_resultados, 'optimo_GA.mat');
ruta_modelo = fullfile(carpeta_resultados, 'modelo_surrogate.mat');

if ~isfile(ruta_optimo)
    error('No se encontro optimo_GA.mat en la campaña activa. Ejecuta primero T04_Optimizacion_GA.m');
end
if ~isfile(ruta_modelo)
    error('No se encontro modelo_surrogate.mat en la campaña activa. Entrena primero el modelo.');
end

load(ruta_optimo, 'optimo');
load(ruta_modelo, 'trainedModel');

opt = optimo;
if ~isfield(opt, 'energia_especifica_J_kg')
    error('El optimo no contiene energia_especifica_J_kg. Ejecuta de nuevo T04_Optimizacion_GA.m');
end
epm_nominal = opt.energia_especifica_J_kg;

fprintf('Diseno optimo nominal:\n');
fprintf('  Pilar:   m1=%.2f mm, a1=%.0f mm, b=%.0f mm, l1=%.0f mm\n', opt.m1, opt.a1, opt.b1, opt.l1);
fprintf('  Techo:   m2=%.2f mm, a2=%.0f mm, b=%.0f mm, l2=%.0f mm\n', opt.m2, opt.a2, opt.b1, opt.l2);
fprintf('  Cartela: e_cartela=%.1f mm, c=%.0f mm\n', opt.e_cartela, opt.c);
fprintf('  Energia especifica estimada: %.4f J/kg\n\n', epm_nominal);

% =========================================================================
% 2. Tolerancias de fabricacion
% =========================================================================
% Valores por defecto. Puedes cambiarlos aquí o, si usas la GUI (T06),
% se configuran desde el panel de Monte Carlo sin tocar el código.
tol_espesor   = 0.1;   % mm, desviacion estandar espesores (m, e_cartela)
tol_dimension = 1.0;   % mm, desviacion estandar dimensiones (a, b)

% NOTA: las longitudes l1/l2 NO se perturban. El surrogate se entrena
% excluyendo las columnas constantes de la campana (T03), asi que una
% perturbacion de l solo entraria en la masa analitica y no en la energia
% predicha: seria una variabilidad inconsistente. Solo varian las 6
% variables activas del DOE (m1, a1, m2, a2, b, e_cartela).

fprintf('Tolerancias de fabricacion (1 sigma):\n');
fprintf('  Espesor (m1, m2, e_cartela): %.2f mm\n', tol_espesor);
fprintf('  Seccion (a, b):              %.1f mm\n\n', tol_dimension);

% =========================================================================
% 3. Monte Carlo
% =========================================================================
N = 10000;
fprintf('Generando %d muestras con variabilidad...\n', N);

% Valores nominales: [m1, a1, m2, a2, b, e_cartela] (solo variables activas)
nominal = [opt.m1, opt.a1, opt.m2, opt.a2, opt.b1, opt.e_cartela];
sigma = [tol_espesor, tol_dimension, tol_espesor, tol_dimension, tol_dimension, tol_espesor];

muestras = zeros(N, 6);
for i = 1:6
    muestras(:, i) = nominal(i) + sigma(i) * randn(N, 1);
end

% Limites fisicos coherentes con el espacio de diseno
muestras(:, 1) = max(muestras(:, 1), 0.5);  % m1
muestras(:, 3) = max(muestras(:, 3), 0.5);  % m2
muestras(:, 6) = max(muestras(:, 6), 0.5);  % e_cartela
muestras(:, 2) = max(muestras(:, 2), 10);   % a1
muestras(:, 4) = max(muestras(:, 4), 10);   % a2
muestras(:, 5) = max(muestras(:, 5), 10);   % b

full_muestras = zeros(N, 10);
full_muestras(:, 1) = muestras(:, 1);       % m1
full_muestras(:, 2) = muestras(:, 2);       % a1
full_muestras(:, 3) = muestras(:, 5);       % b1
full_muestras(:, 4) = opt.l1;               % l1 fijo
full_muestras(:, 5) = muestras(:, 3);       % m2
full_muestras(:, 6) = muestras(:, 4);       % a2
full_muestras(:, 7) = muestras(:, 5);       % b2
full_muestras(:, 8) = opt.l2;               % l2 fijo
full_muestras(:, 9) = opt.c;                % c fijo
full_muestras(:, 10) = muestras(:, 6);      % e_cartela

tab = array2table(full_muestras, 'VariableNames', {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});

fprintf('Evaluando %d disenos con modelo IA...\n', N);
tic;
predicted_energy = trainedModel.predictFcn(tab);  % [J]
t_eval = toc;
fprintf('Tiempo de evaluacion: %.2f s (%.0f evaluaciones/segundo)\n\n', t_eval, N/t_eval);

% Masa analitica para cada muestra MC [kg] (formula compartida)
mass_kg = masa_analitica(muestras(:,1), muestras(:,2), muestras(:,5), opt.l1, ...
                         muestras(:,3), muestras(:,4), muestras(:,5), opt.l2, ...
                         opt.c, muestras(:,6));
epm = predicted_energy ./ mass_kg;  % [J/kg]

% =========================================================================
% 4. Estadistica sobre energia especifica [J/kg]
% =========================================================================
epm_media = mean(epm);
epm_std   = std(epm);
epm_min   = min(epm);
epm_max   = max(epm);
epm_p01   = prctile(epm, 1);
epm_p05   = prctile(epm, 5);
epm_p50   = prctile(epm, 50);
cv_pct    = 100 * epm_std / abs(epm_media);

% Criterio de robustez relativo: perdida superior al 5% respecto al nominal.
umbral_robustez = 0.95 * epm_nominal;
n_bajo_umbral   = sum(epm < umbral_robustez);
prob_bajo_umbral = 100 * n_bajo_umbral / N;

% Criterio normativo absoluto: probabilidad de no alcanzar el umbral
% ECE R66 de energia especifica (si esta configurado).
if umbral_ecr66 > 0
    prob_bajo_ecr66 = 100 * sum(epm < umbral_ecr66) / N;
else
    prob_bajo_ecr66 = NaN;
end

fprintf('=========================================================\n');
fprintf('           RESULTADOS DEL ANALISIS\n');
fprintf('=========================================================\n');
fprintf('Estadisticas de energia especifica [J/kg]:\n');
fprintf('  Nominal:        %10.4f J/kg\n', epm_nominal);
fprintf('  Media:          %10.4f J/kg\n', epm_media);
fprintf('  Desv. estandar: %10.4f J/kg\n', epm_std);
fprintf('  CV:             %10.3f %%\n', cv_pct);
fprintf('  Minimo:         %10.4f J/kg\n', epm_min);
fprintf('  Maximo:         %10.4f J/kg\n', epm_max);
fprintf('  Percentil 1%%:   %10.4f J/kg\n', epm_p01);
fprintf('  Percentil 5%%:   %10.4f J/kg\n', epm_p05);
fprintf('  Mediana:        %10.4f J/kg\n', epm_p50);
fprintf('---------------------------------------------------------\n');
fprintf('Robustez relativa:\n');
fprintf('  Umbral 95%% nominal:      %10.4f J/kg\n', umbral_robustez);
fprintf('  Muestras bajo umbral:    %10d / %d\n', n_bajo_umbral, N);
fprintf('  Prob. bajo umbral:       %10.4f %%\n', prob_bajo_umbral);
if umbral_ecr66 > 0
    fprintf('---------------------------------------------------------\n');
    fprintf('Cumplimiento normativo (ECE R66):\n');
    fprintf('  Umbral ECE R66:          %10.4f J/kg\n', umbral_ecr66);
    fprintf('  Prob. de incumplimiento: %10.4f %%\n', prob_bajo_ecr66);
end
fprintf('=========================================================\n\n');

if prob_bajo_umbral < 1 && cv_pct < 5
    robustez = 'ALTA';
elseif prob_bajo_umbral < 5 && cv_pct < 10
    robustez = 'MEDIA';
else
    robustez = 'BAJA';
end
fprintf('Robustez cualitativa del optimo: %s\n', robustez);

% =========================================================================
% 5. Visualizacion
% =========================================================================
figure('Name', 'Monte Carlo - Energia especifica', 'Position', [100, 100, 1000, 400]);

subplot(1, 2, 1);
histogram(epm, 50, 'FaceColor', [0.3, 0.6, 0.9], 'EdgeColor', 'w');
hold on;
xline(epm_nominal, 'g--', 'LineWidth', 1.5);
xline(umbral_robustez, 'r-', 'LineWidth', 2);
if umbral_ecr66 > 0
    xline(umbral_ecr66, 'm-.', 'LineWidth', 2);
    leyenda = {'Muestras', 'Nominal', '95% nominal', 'Umbral ECE R66'};
else
    leyenda = {'Muestras', 'Nominal', '95% nominal'};
end
% Centrar el histograma en la zona de los datos (el umbral ECE R66 suele
% quedar muy a la izquierda y aplastaria la distribucion contra el borde).
xlim([min([epm(:); umbral_robustez])*0.99, max(epm)*1.01]);
xlabel('Energia especifica (J/kg)');
ylabel('Frecuencia');
title(sprintf('Distribucion de energia especifica (N=%d)', N));
legend(leyenda, 'Location', 'best');
hold off;

subplot(1, 2, 2);
boxplot(epm);
ylabel('Energia especifica (J/kg)');
title(sprintf('Robustez: %s | CV %.2f%%', robustez, cv_pct));
grid on;

saveas(gcf, fullfile(carpeta_resultados, 'analisis_montecarlo_epw.png'));

% =========================================================================
% 6. Guardar resultados
% =========================================================================
resultados.N_muestras = N;
resultados.kpi = 'energia_especifica_J_kg';
resultados.epm_nominal = epm_nominal;
resultados.epm_media = epm_media;
resultados.epm_std = epm_std;
resultados.epm_cv_pct = cv_pct;
resultados.epm_min = epm_min;
resultados.epm_max = epm_max;
resultados.epm_p01 = epm_p01;
resultados.epm_p05 = epm_p05;
resultados.epm_p50 = epm_p50;
resultados.umbral_robustez = umbral_robustez;
resultados.prob_bajo_umbral_pct = prob_bajo_umbral;
resultados.umbral_ecr66_J_kg = umbral_ecr66;
resultados.prob_bajo_ecr66_pct = prob_bajo_ecr66;
resultados.robustez = robustez;
resultados.tolerancias.espesor = tol_espesor;
resultados.tolerancias.dimension = tol_dimension;

save(fullfile(carpeta_resultados, 'resultados_montecarlo.mat'), 'resultados');
fprintf('\nResultados guardados en: %s\\resultados_montecarlo.mat\n', carpeta_resultados);
fprintf('Figura guardada en: %s\\analisis_montecarlo_epw.png\n', carpeta_resultados);
