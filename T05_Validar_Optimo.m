% =========================================================================
% T05_Validar_Optimo.m
% =========================================================================
% Valida en ANSYS los mejores disenos segun el surrogate (top-K del
% ranking_top guardado por T04) y compara la energia especifica real con
% la predicha. Validar varios disenos -- no solo el ganador -- acota el
% sesgo optimista del optimizador ("winner's curse": el optimizador
% explota los errores del modelo, por lo que la prediccion en el optimo
% tiende a ser optimista).
% KPI principal: energia especifica [J/kg].
% =========================================================================

clear; clc;
tic;

% Numero de disenos a validar (1 = solo el optimo, comportamiento clasico).
% Cada diseno lanza una simulacion ANSYS completa (~minutos por diseno).
num_validar = 3;

% Valores por defecto (se sobreescriben desde meta_campana.mat si existe)
yield_strength_pa         = 235500000;
tangent_modulus_pa        = 1160000000;
angulo_desplazamiento_deg = 30;
dir_x_sign                = -1;   % -1 = -X (ECE R66 estandar), +1 = +X invertida

% --- Cargar Campana Activa ---
if ~isfile('active_campaign.txt')
    error('No se encontro active_campaign.txt. Ejecuta primero T01_Generar_DOE_LHS.m');
end
fid = fopen('active_campaign.txt', 'r');
nombre_campana = strtrim(fgetl(fid));
fclose(fid);

carpeta_resultados = fullfile('Resultados', nombre_campana);
fprintf('Campana activa: %s\n', nombre_campana);

% Leer parametros de la campana desde meta_campana.mat
meta_f = fullfile(carpeta_resultados, 'meta_campana.mat');
if isfile(meta_f)
    m_meta = load(meta_f, 'meta'); meta_camp = m_meta.meta;
    if isfield(meta_camp, 'fy_pa'),  yield_strength_pa         = meta_camp.fy_pa;  end
    if isfield(meta_camp, 'Et_pa'),  tangent_modulus_pa        = meta_camp.Et_pa;  end
    if isfield(meta_camp, 'angulo'), angulo_desplazamiento_deg = meta_camp.angulo; end
    if isfield(meta_camp, 'dir_x'),  dir_x_sign                = meta_camp.dir_x;  end
    fprintf('  Meta: angulo=%.0f  dir_x=%+d  fy=%.0f MPa\n', ...
        angulo_desplazamiento_deg, dir_x_sign, yield_strength_pa/1e6);
end

% =========================================================================
% 1. Cargar optimo y ranking de candidatos
% =========================================================================
ruta_optimo = fullfile(carpeta_resultados, 'optimo_GA.mat');
if ~isfile(ruta_optimo)
    error('No se encontro optimo_GA.mat en la carpeta de la campana activa. Ejecuta primero T04_Optimizacion_GA.m');
end
S_opt = load(ruta_optimo);
opt = S_opt.optimo;
fprintf('Optimo cargado desde %s\n\n', ruta_optimo);

if ~isfield(opt, 'energia_especifica_J_kg')
    error('El optimo no contiene energia_especifica_J_kg. Ejecuta de nuevo T04_Optimizacion_GA.m');
end

% Construir la lista de disenos a validar a partir de ranking_top (T04).
% Si el .mat es antiguo y no lo tiene, se valida solo el optimo.
if isfield(S_opt, 'ranking_top') && istable(S_opt.ranking_top)
    rk = S_opt.ranking_top;
    K = min(num_validar, height(rk));
    disenos = struct('m1',{},'a1',{},'b1',{},'l1',{},'m2',{},'a2',{},'b2',{}, ...
                     'l2',{},'c',{},'e_cartela',{},'epm_pred',{});
    for k = 1:K
        disenos(k).m1 = rk.m1(k);  disenos(k).a1 = rk.a1(k);  disenos(k).b1 = rk.b1(k);
        disenos(k).l1 = rk.l1(k);  disenos(k).m2 = rk.m2(k);  disenos(k).a2 = rk.a2(k);
        disenos(k).b2 = rk.b2(k);  disenos(k).l2 = rk.l2(k);  disenos(k).c  = rk.c(k);
        disenos(k).e_cartela = rk.e_cartela(k);
        disenos(k).epm_pred  = rk.epm_J_kg(k);
    end
else
    if num_validar > 1
        warning('optimo_GA.mat no contiene ranking_top (re-ejecuta T04 para validar top-K). Se valida solo el optimo.');
    end
    K = 1;
    disenos = struct('m1',opt.m1,'a1',opt.a1,'b1',opt.b1,'l1',opt.l1, ...
                     'm2',opt.m2,'a2',opt.a2,'b2',opt.b2,'l2',opt.l2, ...
                     'c',opt.c,'e_cartela',opt.e_cartela, ...
                     'epm_pred',opt.energia_especifica_J_kg);
end

fprintf('=== VALIDACION DE LOS %d MEJORES DISENOS ===\n\n', K);

% =========================================================================
% 2. Preparativos comunes (journal, plantilla, ANSYS): una sola vez
% =========================================================================
scriptDir = fileparts(mfilename('fullpath'));
cd(scriptDir);
scriptDirPython = strrep(scriptDir, '\', '/');

% Journal generado desde plantilla base
fid = fopen('journal_workbench.wbjn', 'r');
if fid ~= -1
    journalCode = fread(fid, '*char')';
    fclose(fid);
    journalCode = strrep(journalCode, '<PIPELINE_DIR>', scriptDirPython);
    fid = fopen('journal_generado.wbjn', 'w');
    fprintf(fid, '%s', journalCode);
    fclose(fid);
end
journal_path = fullfile(scriptDir, 'journal_generado.wbjn');

% Plantilla de SpaceClaim (se lee una vez; se sustituye por diseno)
fid = fopen('plantilla_spaceclaim.py', 'r');
plantilla_txt = fread(fid, '*char')';
fclose(fid);

% Detectar ANSYS
ansysVersions = {'252','251','242','241','232','231','222','221','212','211'};
ansysPath = '';
for v = 1:length(ansysVersions)
    awp_root = getenv(['AWP_ROOT' ansysVersions{v}]);
    if ~isempty(awp_root)
        posibleRuta = fullfile(awp_root, 'Framework', 'bin', 'Win64', 'runwb2.exe');
        if exist(posibleRuta, 'file')
            ansysPath = posibleRuta;
            break;
        end
    end
end
if isempty(ansysPath)
    ansysPath = 'E:\ANSYS Inc\ANSYS Student\v252\Framework\bin\Win64\runwb2.exe';
end
fprintf('Ruta ANSYS: %s\n', ansysPath);

% =========================================================================
% 3. Bucle de validacion
% =========================================================================
filas = table();

for k = 1:K
    d = disenos(k);
    if k == 1
        sim_id = 'VALIDACION';   % compatible con el visor de la GUI
    else
        sim_id = sprintf('VALIDACION_%d', k);
    end

    fprintf('\n--------- Diseno #%d (Sim_%s) ---------\n', k, sim_id);
    fprintf('  Pilar:   m1=%.1f mm, a1=%.0f mm, b=%.0f mm, l1=%.0f mm\n', d.m1, d.a1, d.b1, d.l1);
    fprintf('  Techo:   m2=%.1f mm, a2=%.0f mm, b=%.0f mm, l2=%.0f mm\n', d.m2, d.a2, d.b2, d.l2);
    fprintf('  Cartela: e_cartela=%.1f mm, c=%.0f mm\n', d.e_cartela, d.c);
    fprintf('  Energia especifica predicha (IA): %.4f J/kg\n', d.epm_pred);

    % Generar script de SpaceClaim para este diseno
    f = plantilla_txt;
    f = strrep(f, 'PAR_M1', num2str(d.m1, '%.4f'));
    f = strrep(f, 'PAR_A1', num2str(d.a1, '%.4f'));
    f = strrep(f, 'PAR_B1', num2str(d.b1, '%.4f'));
    f = strrep(f, 'PAR_L1', num2str(d.l1, '%.4f'));
    f = strrep(f, 'PAR_M2', num2str(d.m2, '%.4f'));
    f = strrep(f, 'PAR_A2', num2str(d.a2, '%.4f'));
    f = strrep(f, 'PAR_B2', num2str(d.b2, '%.4f'));
    f = strrep(f, 'PAR_L2', num2str(d.l2, '%.4f'));
    f = strrep(f, 'PAR_C',  num2str(d.c, '%.4f'));
    f = strrep(f, 'PAR_E_CARTELA', num2str(d.e_cartela, '%.4f'));
    fid = fopen('script_generado_spaceclaim.py', 'w');
    fprintf(fid, '%s', f);
    fclose(fid);

    if isfile('parametrossalida.csv')
        delete('parametrossalida.csv');
    end

    % Variables de entorno para Workbench/Mechanical
    setenv('TFG_BATCH_MODE', '1');
    setenv('TFG_CAMPAIGN_NAME', nombre_campana);
    setenv('TFG_SIM_ID', sim_id);
    setenv('TFG_PIPELINE_DIR', scriptDirPython);
    setenv('TFG_PARAM_B_MM', num2str(d.b1, '%.4f'));
    char_dim = (d.a1 + d.a2 + 2*d.b1) / 4;
    setenv('TFG_CHAR_DIM_MM', num2str(char_dim, '%.4f'));
    setenv('TFG_C_MM', num2str(d.c, '%.4f'));
    setenv('TFG_LONGITUD_VIGA_MM', num2str(d.l1, '%.4f'));
    setenv('TFG_ANGULO_DESPLAZAMIENTO_DEG', num2str(angulo_desplazamiento_deg, '%.4f'));
    setenv('TFG_DIR_X',                    num2str(dir_x_sign));
    setenv('TFG_YIELD_PA',                 num2str(yield_strength_pa, '%.10g'));
    setenv('TFG_TANGENT_MODULUS_PA',       num2str(tangent_modulus_pa, '%.10g'));

    cmd = sprintf('"%s" -B -R "%s"', ansysPath, journal_path);
    fprintf('Ejecutando ANSYS...\n');
    [status, cmdout] = system(cmd); %#ok<ASGLU>

    if ~isfile('parametrossalida.csv')
        fprintf('[ERROR] La simulacion del diseno #%d fallo: no se genero parametrossalida.csv\n', k);
        fprintf('Revisa mechanical_run.log y los mensajes de ANSYS.\n');
        continue;
    end

    T = readtable('parametrossalida.csv');
    energia_real = T{1, 'Energy_J'};
    fuerza_real  = T{1, 'Force_N'};
    stress_real  = T{1, 'Stress_Max_Pa'};
    masa_real    = T{1, 'Mass_kg'};
    epm_real     = T{1, 'Energy_per_Mass_J_kg'};
    if ismember('Y_Max_Stress_mm', T.Properties.VariableNames)
        y_max_stress_mm = T{1, 'Y_Max_Stress_mm'};
    else
        y_max_stress_mm = NaN;
    end
    [pivot_height_mm, lever_arm_mm, modo_fallo] = calcular_pivot(y_max_stress_mm, d.c, d.a1, d.a2, d.l1);

    error_abs = abs(epm_real - d.epm_pred);
    error_rel = 100 * error_abs / abs(epm_real);

    fprintf('  EPM predicha: %10.4f J/kg | EPM real: %10.4f J/kg | error: %.2f%%\n', ...
        d.epm_pred, epm_real, error_rel);
    fprintf('  Energia real: %.2f J | Masa real: %.3f kg | Modo: %s (pivote %.1f mm)\n', ...
        energia_real, masa_real, modo_fallo, pivot_height_mm);

    fila = table(k, {sim_id}, d.m1, d.a1, d.b1, d.l1, d.m2, d.a2, d.b2, d.l2, d.c, d.e_cartela, ...
        d.epm_pred, epm_real, error_rel, energia_real, masa_real, fuerza_real, ...
        stress_real, y_max_stress_mm, {modo_fallo}, pivot_height_mm, lever_arm_mm, ...
        'VariableNames', {'Rank','Sim_ID','m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela', ...
        'EPM_Predicha_J_kg','EPM_Real_J_kg','Error_Pct','Energia_Real_J','Masa_Real_kg', ...
        'Fuerza_Real_N','Stress_Pa','Y_Max_Stress_mm','Modo_Fallo','Pivot_Height_mm','Lever_Arm_mm'});
    filas = [filas; fila]; %#ok<AGROW>

    % Guardado incremental: persistir tras cada diseno para no perder el
    % progreso si la ejecucion se interrumpe a mitad de la validacion.
    writetable(filas, fullfile(carpeta_resultados, 'validacion_optimo.csv'));

    % --- Graficas completas del diseno ---
    curvas_file = fullfile(carpeta_resultados, sprintf('Sim_%s', sim_id), 'Curvas.csv');
    if isfile(curvas_file)
        if k == 1
            img_path = fullfile(carpeta_resultados, 'Graficas_Completas_Optimo.png');
            titulo = 'Resultados Estructurales - DISENO OPTIMO';
        else
            img_path = fullfile(carpeta_resultados, sprintf('Graficas_Completas_Top%d.png', k));
            titulo = sprintf('Resultados Estructurales - DISENO TOP %d', k);
        end
        try
            generar_grafica_validacion(curvas_file, lever_arm_mm, pivot_height_mm, titulo, img_path);
            fprintf('  Graficas guardadas en: %s\n', img_path);
        catch ME
            warning('No se pudo generar la grafica del diseno #%d: %s', k, ME.message);
        end
    end
end

% =========================================================================
% 4. Resumen y guardado
% =========================================================================
if isempty(filas)
    fprintf('\n[ERROR] Ninguna validacion produjo resultados.\n');
else
    writetable(filas, fullfile(carpeta_resultados, 'validacion_optimo.csv'));
    fprintf('\n=========================================================\n');
    fprintf('          RESUMEN DE LA VALIDACION (top %d)\n', K);
    fprintf('=========================================================\n');
    fprintf('%-5s %-14s %-14s %-10s\n', 'Rank', 'EPM pred', 'EPM real', 'Error');
    for r = 1:height(filas)
        fprintf('%-5d %10.4f     %10.4f     %6.2f %%\n', filas.Rank(r), ...
            filas.EPM_Predicha_J_kg(r), filas.EPM_Real_J_kg(r), filas.Error_Pct(r));
    end
    fprintf('---------------------------------------------------------\n');
    err_max = max(filas.Error_Pct);
    if err_max < 5
        fprintf('Modelo IA muy preciso en la zona del optimo (error max < 5%%).\n');
    elseif err_max < 10
        fprintf('Modelo IA aceptable en la zona del optimo (error max < 10%%).\n');
    elseif err_max < 20
        fprintf('Modelo IA mejorable (error max 10-20%%). Conviene mas dataset.\n');
    else
        fprintf('Modelo IA poco fiable en la zona del optimo (error max > 20%%). Reentrenar.\n');
    end
    % Sesgo del optimizador: si la prediccion supera sistematicamente a la
    % realidad en los mejores disenos, es la firma del "winner's curse".
    sesgo = mean(filas.EPM_Predicha_J_kg - filas.EPM_Real_J_kg);
    fprintf('Sesgo medio (pred - real): %+.4f J/kg %s\n', sesgo, ...
        ternario(sesgo > 0, '(prediccion optimista, esperable)', '(sin sesgo optimista)'));
    fprintf('=========================================================\n');
    fprintf('\nResultados guardados en: %s\\validacion_optimo.csv\n', carpeta_resultados);
end

elapsed = toc;
fprintf('\nTiempo total: %.1f s\n', elapsed);

% =========================================================================
% Funciones locales
% =========================================================================
function generar_grafica_validacion(curvas_file, lever_arm_mm, pivot_height_mm, titulo, img_path)
    opts = detectImportOptions(curvas_file);
    opts.VariableNamingRule = 'preserve';
    TC = readtable(curvas_file, opts);

    force_tot = abs(TC.ForceTotal);
    disp_tot  = abs(1000 * TC.DispX);  % m -> mm
    energy_acum = cumtrapz(disp_tot / 1000, force_tot);

    % arcsin: el brazo es la hipotenusa; disp es el cateto opuesto
    angle_deg = asind(min(abs(disp_tot) / lever_arm_mm, 1));
    moment_Nm = force_tot .* (lever_arm_mm / 1000) .* cosd(angle_deg);

    fig = figure('Visible', 'off', 'Position', [100, 100, 1500, 450]);

    subplot(1, 3, 1);
    plot(disp_tot, force_tot, '-b', 'LineWidth', 2);
    grid on;
    xlabel('Desplazamiento X [mm]', 'Interpreter', 'none');
    ylabel('Fuerza Total [N]', 'Interpreter', 'none');
    title('Fuerza vs Desplazamiento X', 'Interpreter', 'none');

    subplot(1, 3, 2);
    plot(disp_tot, energy_acum, '-r', 'LineWidth', 2);
    grid on;
    xlabel('Desplazamiento X [mm]', 'Interpreter', 'none');
    ylabel('Energia Absorbida [J]', 'Interpreter', 'none');
    title('Energia Absorbida vs Desplazamiento X', 'Interpreter', 'none');

    subplot(1, 3, 3);
    plot(angle_deg, moment_Nm, '-k', 'LineWidth', 2);
    grid on;
    xlabel('Angulo de Giro [grados]', 'Interpreter', 'none');
    ylabel('Momento Flector [N*m]', 'Interpreter', 'none');
    title(sprintf('Momento vs Angulo | pivote %.1f mm', pivot_height_mm), 'Interpreter', 'none');

    sgtitle(titulo, 'Interpreter', 'none');
    saveas(fig, img_path);
    close(fig);
end

function out = ternario(cond, si, no)
    if cond, out = si; else, out = no; end
end
