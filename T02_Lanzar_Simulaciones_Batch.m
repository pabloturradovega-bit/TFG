tic;
clc; clear;

% Ejecutar siempre desde la carpeta del pipeline (rutas relativas)
scriptDir = fileparts(mfilename('fullpath'));
cd(scriptDir);

% === PARAMETROS POR DEFECTO (se sobreescriben desde meta_campana.mat si existe) ===
yield_strength_pa         = 235500000;   % Tensión de fluencia [Pa]
tangent_modulus_pa        = 1160000000;  % Módulo tangente bilineal [Pa]
angulo_desplazamiento_deg = 30;          % Ángulo de giro [°]
dir_x_sign                = -1;          % Dirección X: -1 = estándar ECE R66, +1 = invertida

% === PREPARATIVOS DE RUTAS (HACE EL PIPELINE PORTABLE) ===
scriptDirPython = strrep(scriptDir, '\', '/');

% Adaptar journal de Workbench para este ordenador
fid = fopen('journal_workbench.wbjn', 'r');
if fid ~= -1
    journalCode = fread(fid, '*char')';
    fclose(fid);
    journalCode = strrep(journalCode, '<PIPELINE_DIR>', scriptDirPython);
    fid = fopen('journal_generado.wbjn', 'w');
    fprintf(fid, '%s', journalCode);
    fclose(fid);
end

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

% Leer parámetros guardados por T01 en meta_campana.mat (si existe)
meta_f = fullfile(carpeta_resultados, 'meta_campana.mat');
if isfile(meta_f)
    m_meta = load(meta_f, 'meta'); meta_camp = m_meta.meta;
    if isfield(meta_camp, 'fy_pa'),    yield_strength_pa         = meta_camp.fy_pa;    end
    if isfield(meta_camp, 'Et_pa'),    tangent_modulus_pa        = meta_camp.Et_pa;    end
    if isfield(meta_camp, 'angulo'),   angulo_desplazamiento_deg = meta_camp.angulo;   end
    if isfield(meta_camp, 'dir_x'),    dir_x_sign                = meta_camp.dir_x;    end
    fprintf('  Meta cargada: angulo=%.0f°  dir_x=%+d  fy=%.0f MPa\n', ...
        angulo_desplazamiento_deg, dir_x_sign, yield_strength_pa/1e6);
else
    fprintf('  Sin meta_campana.mat — usando parámetros por defecto.\n');
end

% Carga los datos del csv
data = readtable(archivo_db);
[num_rows, ~] = size(data);

% Si el CSV ya tiene columna 'energy', reanudar solo las filas sin resultado (NaN)
if ismember('energy', data.Properties.VariableNames)
    idx_todo = find(isnan(data.energy));
else
    data.energy = NaN(num_rows, 1);
    idx_todo = (1:num_rows)';
end

% Añadir columnas si no existen
if ~ismember('stress', data.Properties.VariableNames)
    data.stress = NaN(num_rows, 1);
end
if ~ismember('force', data.Properties.VariableNames)
    data.force = NaN(num_rows, 1);
end
if ~ismember('mass_kg', data.Properties.VariableNames)
    data.mass_kg = NaN(num_rows, 1);
end
if ~ismember('energy_per_mass', data.Properties.VariableNames)
    data.energy_per_mass = NaN(num_rows, 1);
end
if ~ismember('sim_time_s', data.Properties.VariableNames)
    data.sim_time_s = NaN(num_rows, 1);
end
if ~ismember('y_max_stress_mm', data.Properties.VariableNames)
    data.y_max_stress_mm = NaN(num_rows, 1);
end
if ~ismember('valid_ansys', data.Properties.VariableNames)
    data.valid_ansys = NaN(num_rows, 1);
end
if ~ismember('pivot_height_mm', data.Properties.VariableNames)
    data.pivot_height_mm = NaN(num_rows, 1);
end
if ~ismember('lever_arm_mm', data.Properties.VariableNames)
    data.lever_arm_mm = NaN(num_rows, 1);
end
if ~ismember('modo_fallo', data.Properties.VariableNames)
    data.modo_fallo = repmat({'N/A'}, num_rows, 1);
end

num_todo = numel(idx_todo);
fprintf('Total filas: %d. Pendientes de simular: %d.\n', num_rows, num_todo);

% --- Deteccion automatica de ruta de ANSYS (una sola vez) ---
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
    warning('No se pudo detectar ANSYS automáticamente. Usa tu ruta manual.');
    ansysPath = 'E:\ANSYS Inc\ANSYS Student\v252\Framework\bin\Win64\runwb2.exe';
end

% --- Plantilla de SpaceClaim (se lee una vez; se sustituye por fila) ---
fid = fopen('plantilla_spaceclaim.py', 'r');
plantilla_txt = fread(fid, '*char')';
fclose(fid);

for i = 1:num_todo
    sim_tic = tic; % Inicia contador de tiempo para esta simulacion especifica
    n = idx_todo(i);
    m1 = data.m1(n);
    a1 = data.a1(n);
    b1 = data.b1(n);
    l1 = data.l1(n);
    m2 = data.m2(n);
    a2 = data.a2(n);
    b2 = data.b2(n);
    l2 = data.l2(n);
    c  = data.c(n);
    e_cartela = data.e_cartela(n);

    % Sustituir placeholders de la plantilla con formato controlado
    f = plantilla_txt;
    f = strrep(f, 'PAR_M1', num2str(m1, '%.4f'));
    f = strrep(f, 'PAR_A1', num2str(a1, '%.4f'));
    f = strrep(f, 'PAR_B1', num2str(b1, '%.4f'));
    f = strrep(f, 'PAR_L1', num2str(l1, '%.4f'));
    f = strrep(f, 'PAR_M2', num2str(m2, '%.4f'));
    f = strrep(f, 'PAR_A2', num2str(a2, '%.4f'));
    f = strrep(f, 'PAR_B2', num2str(b2, '%.4f'));
    f = strrep(f, 'PAR_L2', num2str(l2, '%.4f'));
    f = strrep(f, 'PAR_E_CARTELA', num2str(e_cartela, '%.4f'));
    f = strrep(f, 'PAR_C',  num2str(c,  '%.4f'));

    fid = fopen('script_generado_spaceclaim.py', 'w');
    fprintf(fid, '%s', f);
    fclose(fid);

    journalPath = fullfile(scriptDir, 'journal_generado.wbjn');
    useGUI = false;
    if useGUI
        modeFlags = '-X -R';
    else
        modeFlags = '-B -R';
    end

    % Borrar CSV anterior
    if isfile('parametrossalida.csv')
        delete('parametrossalida.csv');
    end

    % Variables de entorno para la macro
    setenv('TFG_PIPELINE_DIR', scriptDirPython);
    setenv('TFG_BATCH_MODE', '1');
    setenv('TFG_CAMPAIGN_NAME', nombre_campana);
    setenv('TFG_SIM_ID', sprintf('%03d', n));
    setenv('TFG_PARAM_B_MM', num2str(b1, '%.4f'));
    char_dim = (a1 + a2 + 2*b1) / 4;  % media de las 4 dim. de seccion → reduce varianza de nodos
    setenv('TFG_CHAR_DIM_MM', num2str(char_dim, '%.4f'));
    setenv('TFG_C_MM', num2str(c, '%.4f'));
    setenv('TFG_LONGITUD_VIGA_MM', num2str(l1, '%.4f'));
    setenv('TFG_ANGULO_DESPLAZAMIENTO_DEG', num2str(angulo_desplazamiento_deg, '%.4f'));
    setenv('TFG_DIR_X',                    num2str(dir_x_sign));
    setenv('TFG_YIELD_PA',                 num2str(yield_strength_pa, '%.10g'));
    setenv('TFG_TANGENT_MODULUS_PA',       num2str(tangent_modulus_pa, '%.10g'));

    cmd = sprintf('"%s" %s "%s"', ansysPath, modeFlags, journalPath);
    system(cmd);

        % Lee resultado desde parametrossalida.csv
    if isfile('parametrossalida.csv')
        T = readtable('parametrossalida.csv');

        data.energy(n) = T{1, 'Energy_J'};
        data.force(n)  = T{1, 'Force_N'};
        data.stress(n) = T{1, 'Stress_Max_Pa'};
        data.mass_kg(n) = T{1, 'Mass_kg'};
        data.energy_per_mass(n) = T{1, 'Energy_per_Mass_J_kg'};

        if ismember('Y_Max_Stress_mm', T.Properties.VariableNames)
            data.y_max_stress_mm(n) = T{1, 'Y_Max_Stress_mm'};
        elseif ismember('Y_Max_Stress', T.Properties.VariableNames)
            data.y_max_stress_mm(n) = T{1, 'Y_Max_Stress'};
        else
            data.y_max_stress_mm(n) = NaN;
        end

        if ismember('Valid', T.Properties.VariableNames)
            data.valid_ansys(n) = T{1, 'Valid'};
        else
            data.valid_ansys(n) = NaN;
        end
    else
        warning('No se encontró parametrossalida.csv tras la simulación %d.', n);
        data.energy(n) = NaN;
        data.force(n)  = NaN;
        data.stress(n) = NaN;
        data.mass_kg(n) = NaN;
        data.energy_per_mass(n) = NaN;
        data.y_max_stress_mm(n) = NaN;
        data.valid_ansys(n) = NaN;
        data.pivot_height_mm(n) = NaN;
        data.lever_arm_mm(n) = NaN;
    end

    % Generar gráfica automáticamente si existe el CSV de curvas
    curvas_file = fullfile(carpeta_resultados, sprintf('Sim_%03d', n), 'Curvas.csv');
    if isfile(curvas_file)
        try
            opts = detectImportOptions(curvas_file);
            opts.VariableNamingRule = 'preserve';
            TC = readtable(curvas_file, opts);
            
            force_tot = abs(TC.ForceTotal);
            disp_tot  = abs(1000 * TC.DispX);  % m → mm
            
            % Calcular energía absorbida acumulada (Julios = N * m)
            energy_acum = cumtrapz(disp_tot / 1000, force_tot);
            
            % Calcular Momento y Angulo con pivote global Y.
            % Si y_max > a2: pivote = y_max (charnela concentrada visible).
            % Si y_max <= a2: pivote = 0 (plasticidad difusa, artefacto BC).
            y_max_i = data.y_max_stress_mm(n);
            [pivot_height_mm, lever_arm_mm, modo_fallo_i] = calcular_pivot(y_max_i, c, a1, a2, l1);
            data.pivot_height_mm(n) = pivot_height_mm;
            data.lever_arm_mm(n)    = lever_arm_mm;
            data.modo_fallo{n}      = modo_fallo_i;
            fprintf('  Modo de fallo: %s  (Y_max=%.1f mm, c=%.0f mm, pivote=%.1f mm)\n', ...
                modo_fallo_i, y_max_i, c, pivot_height_mm);

            % arcsin: el brazo es la hipotenusa; disp es el cateto opuesto
            angle_deg = asind(min(abs(disp_tot) / lever_arm_mm, 1));
            moment_Nm = force_tot .* (lever_arm_mm / 1000) .* cosd(angle_deg);
            
            fig = figure('Visible', 'off', 'Position', [100, 100, 1500, 450]); % Figura más ancha para 3 gráficas
            
            % Subplot 1: Fuerza vs Desplazamiento
            subplot(1, 3, 1);
            plot(disp_tot, force_tot, '-b', 'LineWidth', 2);
            grid on;
            xlabel('Desplazamiento X [mm]', 'Interpreter', 'none');
            ylabel('Fuerza Total [N]', 'Interpreter', 'none');
            title('Fuerza vs Desplazamiento X', 'Interpreter', 'none');
            
            % Subplot 2: Energía vs Desplazamiento
            subplot(1, 3, 2);
            plot(disp_tot, energy_acum, '-r', 'LineWidth', 2);
            grid on;
            xlabel('Desplazamiento X [mm]', 'Interpreter', 'none');
            ylabel('Energía Absorbida [J]', 'Interpreter', 'none');
            title('Energía Absorbida vs Desplazamiento X', 'Interpreter', 'none');
            
            % Subplot 3: Momento vs Ángulo
            subplot(1, 3, 3);
            plot(angle_deg, moment_Nm, '-k', 'LineWidth', 2);
            grid on;
            xlabel('Ángulo de Giro [grados]', 'Interpreter', 'none');
            ylabel('Momento Flector [N·m]', 'Interpreter', 'none');
            title(sprintf('Momento vs Angulo | pivote %.1f mm', pivot_height_mm), 'Interpreter', 'none');
            
            sgtitle(sprintf('Resultados Cinemáticos y Estructurales - Simulación %03d', n), 'Interpreter', 'none');
            
            img_path = fullfile(carpeta_resultados, sprintf('Sim_%03d', n), 'Graficas_Completas.png');
            saveas(fig, img_path);
            close(fig);
        catch ME
            warning('No se pudo generar la gráfica para la simulación %d: %s', n, ME.message);
        end
    end

    % Guardar CSV actualizado tras cada simulación
    sim_time = toc(sim_tic);
    data.sim_time_s(n) = sim_time;

    writetable(data, archivo_db);
    fprintf('Simulación %d/%d completada en %.1f s. Progreso guardado.\n', i, num_todo, sim_time);
end

elapsed = toc;
fprintf('Proceso Finalizado. Tiempo total: %.1f s.\n', elapsed);

