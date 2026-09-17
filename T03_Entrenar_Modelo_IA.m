% =========================================================================
% T03_Entrenar_Modelo_IA.m
% =========================================================================
% Prepara el dataset limpio y abre Regression Learner para que el usuario
% entrene y seleccione el modelo sustituto de forma interactiva.
% El surrogate predice energia [J]; la energia especifica [J/kg] se calcula
% dividiendo por la masa analitica en T04/T05/T06.
%
% Flujo:
%   1. Limpia el dataset y detecta predictores activos
%   2. Abre Regression Learner con los datos listos
%   3. El usuario entrena, compara y exporta el mejor modelo al workspace
%      (boton "Export Model" → "Export to Workspace", nombre: trainedModel)
%   4. Este script recoge el modelo exportado y lo guarda en
%      modelo_surrogate.mat con el formato que usan T04/T05/T06/GUI
%
% AUTOR: Pablo Turrado Vega
% FECHA: 2026
% =========================================================================

clear; clc;

% --- Cargar Campaña Activa ---
if ~isfile('active_campaign.txt')
    error('No se encontro active_campaign.txt. Ejecuta primero T01_Generar_DOE_LHS.m');
end
fid = fopen('active_campaign.txt', 'r');
nombre_campana = strtrim(fgetl(fid));
fclose(fid);

carpeta_resultados = fullfile('Resultados', nombre_campana);
archivo_db = fullfile(carpeta_resultados, 'basededatos.csv');
fprintf('Campaña activa: %s\n', nombre_campana);

if ~isfile(archivo_db)
    error('No se encuentra el CSV de la campaña activa.');
end

fprintf('Cargando base de datos...\n');
data = readtable(archivo_db);

% =========================================================================
% 1. Verificar columna de energia
% =========================================================================
if ~ismember('energy', data.Properties.VariableNames) || all(isnan(data.energy))
    error('La columna energy esta vacia. Ejecuta primero T02_Lanzar_Simulaciones_Batch.m.');
end

% =========================================================================
% 2. Limpieza de datos
% =========================================================================
mask_valid = isfinite(data.energy) & data.energy > 0;
if ismember('mass_kg', data.Properties.VariableNames)
    mask_valid = mask_valid & isfinite(data.mass_kg) & data.mass_kg > 0;
end
if ismember('valid_ansys', data.Properties.VariableNames) && any(data.valid_ansys == 1)
    mask_valid = mask_valid & data.valid_ansys == 1;
elseif ismember('Valid', data.Properties.VariableNames) && any(data.Valid == 1)
    mask_valid = mask_valid & data.Valid == 1;
end

data = data(mask_valid, :);
n_validas = height(data);
fprintf('Filas validas tras limpieza: %d\n', n_validas);

if n_validas < 10
    warning('Hay pocas muestras validas (%d). El surrogate puede ser poco fiable.', n_validas);
end

% =========================================================================
% 3. Masa analitica y energia especifica como columnas diagnosticas
% =========================================================================
% Formula compartida con T04/T06/GUI (ver masa_analitica.m)
data.mass = masa_analitica(data.m1, data.a1, data.b1, data.l1, ...
                           data.m2, data.a2, data.b2, data.l2, ...
                           data.c, data.e_cartela);
data.energy_per_mass = data.energy ./ data.mass;

% =========================================================================
% 4. Guardar dataset limpio
% =========================================================================
nombre_archivo = sprintf('dataset_%d_muestras_limpio.csv', n_validas);
ruta_final = fullfile(carpeta_resultados, nombre_archivo);
writetable(data, ruta_final);
fprintf('Dataset limpio guardado en: %s\n', ruta_final);

% =========================================================================
% 5. Detectar predictores activos
% =========================================================================
% Excluye columnas constantes (l1=l2=1000, c=80) y duplicadas (b2=b1).
candidatos = {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'};
varia = cellfun(@(v) std(data.(v)) > 1e-10, candidatos);
predictorNames = candidatos(varia);

% Eliminar columnas linealmente dependientes (ej. b2 == b1) para evitar
% rango deficiente en modelos lineales dentro de Regression Learner.
Xcheck = table2array(data(:, predictorNames));
to_keep = true(1, numel(predictorNames));
for ii = 1:numel(predictorNames)
    if ~to_keep(ii), continue; end
    for jj = ii+1:numel(predictorNames)
        if to_keep(jj) && std(Xcheck(:,ii) - Xcheck(:,jj)) < 1e-10
            to_keep(jj) = false;
        end
    end
end
predictorNames = predictorNames(to_keep);

fprintf('Predictores activos (%d): %s\n', numel(predictorNames), strjoin(predictorNames, ', '));

% =========================================================================
% 6. Abrir Regression Learner
% =========================================================================
% Tabla con predictores + variable respuesta (energy [J])
trainingData = [data(:, predictorNames), table(data.energy, 'VariableNames', {'energy'})];

fprintf('\n=========================================================\n');
fprintf('  Abriendo Regression Learner...\n');
fprintf('=========================================================\n');
fprintf('  Variable respuesta : energy [J]\n');
fprintf('  Predictores (%d)  : %s\n', numel(predictorNames), strjoin(predictorNames, ', '));
fprintf('  Muestras           : %d\n', n_validas);
fprintf('\n  PASOS A SEGUIR:\n');
fprintf('  1. La app abrira con los datos ya cargados.\n');
fprintf('  2. Entrena los modelos que quieras (o usa "Train All").\n');
fprintf('  3. Selecciona el mejor modelo por RMSE de validacion cruzada.\n');
fprintf('  4. Exporta: boton "Export Model" -> "Export to Workspace"\n');
fprintf('     Deja el nombre de variable como: trainedModel\n');
fprintf('  5. Vuelve aqui y pulsa Enter en la Ventana de Comandos.\n');
fprintf('=========================================================\n\n');

regressionLearner(trainingData, 'energy');

input('Cuando hayas exportado el modelo al workspace, pulsa Enter para continuar... ', 's');

% =========================================================================
% 7. Recoger modelo exportado y guardarlo en formato estandar
% =========================================================================
if ~evalin('base', 'exist(''trainedModel'',''var'')')
    error(['No se encontro "trainedModel" en el workspace.\n' ...
           'Exporta el modelo desde Regression Learner antes de pulsar Enter.']);
end

exportedModel = evalin('base', 'trainedModel');

if ~isfield(exportedModel, 'predictFcn')
    error('"trainedModel" no tiene campo predictFcn. Asegurate de exportar desde Regression Learner.');
end

% Construir estructura estandar compatible con T04/T05/T06/GUI
pn = predictorNames;
trainedModel.predictFcn      = @(t) exportedModel.predictFcn(t(:, pn));
trainedModel.RegressionModel = exportedModel;
trainedModel.modelo_tipo     = 'RegressionLearner_Manual';
trainedModel.predictorNames  = predictorNames;
% RMSE CV: intentar leerlo del modelo exportado si lo incluye.
% El struct que exporta Regression Learner normalmente NO trae este campo,
% asi que en ese caso se pide al usuario (lo ve en la app) para no perder
% la trazabilidad del modelo en la memoria.
if isfield(exportedModel, 'RegressionResults') && ...
        isfield(exportedModel.RegressionResults, 'ValidationRMSE')
    trainedModel.rmse_cv = exportedModel.RegressionResults.ValidationRMSE;
else
    txt_rmse = input('Introduce el RMSE de validacion [J] mostrado en Regression Learner (Enter para omitir): ', 's');
    v_rmse = str2double(txt_rmse);
    if isfinite(v_rmse) && v_rmse > 0
        trainedModel.rmse_cv = v_rmse;
    else
        trainedModel.rmse_cv = NaN;
    end
end

ruta_modelo = fullfile(carpeta_resultados, 'modelo_surrogate.mat');
save(ruta_modelo, 'trainedModel');

fprintf('\n=========================================================\n');
fprintf('  Modelo guardado en: %s\n', ruta_modelo);
fprintf('  Tipo              : %s\n', trainedModel.modelo_tipo);
if ~isnan(trainedModel.rmse_cv)
    fprintf('  RMSE CV           : %.2f J\n', trainedModel.rmse_cv);
end
fprintf('  Predictores       : %s\n', strjoin(predictorNames, ', '));
fprintf('=========================================================\n');
fprintf('\nPuedes continuar con T04_Optimizacion_GA.m\n');
