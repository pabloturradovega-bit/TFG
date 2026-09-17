% regenerar_graficas.m
% ============================================================
% Regenera Graficas_Completas.png para todas las simulaciones
% de la campana activa, usando el pivote ya almacenado en el CSV
% (pivot_height_mm, lever_arm_mm) -- no recalcula nada, solo redibuja.
% ============================================================
clc;
scriptDir = fileparts(mfilename('fullpath'));
cd(scriptDir);

if ~isfile('active_campaign.txt')
    error('No se encontro active_campaign.txt.');
end
fid = fopen('active_campaign.txt','r');
nombre_campana = strtrim(fgetl(fid));
fclose(fid);

carpeta_resultados = fullfile('Resultados', nombre_campana);
archivo_db = fullfile(carpeta_resultados, 'basededatos.csv');
fprintf('Campaña activa: %s\n', nombre_campana);

opts = detectImportOptions(archivo_db);
opts.VariableNamingRule = 'preserve';
data = readtable(archivo_db, opts);
nr = height(data);

n_ok = 0; n_sin_curvas = 0; n_error = 0;

for i = 1:nr
    curvas_file = fullfile(carpeta_resultados, sprintf('Sim_%03d', i), 'Curvas.csv');
    if ~isfile(curvas_file)
        n_sin_curvas = n_sin_curvas + 1;
        continue;
    end

    try
        opts_c = detectImportOptions(curvas_file);
        opts_c.VariableNamingRule = 'preserve';
        TC = readtable(curvas_file, opts_c);

        force_tot   = abs(TC.ForceTotal);
        disp_tot    = abs(1000 * TC.DispX);   % m → mm
        energy_acum = cumtrapz(disp_tot / 1000, force_tot);

        pivot_height_mm = data.pivot_height_mm(i);
        lever_arm_mm    = data.lever_arm_mm(i);
        modo_fallo_i    = data.modo_fallo{i};

        % arcsin: el brazo es la hipotenusa; disp es el cateto opuesto
        angle_deg  = asind(min(abs(disp_tot) / lever_arm_mm, 1));
        moment_Nm  = force_tot .* (lever_arm_mm / 1000) .* cosd(angle_deg);

        fig = figure('Visible','off','Position',[100,100,1500,450]);

        subplot(1,3,1);
        plot(disp_tot, force_tot, '-b', 'LineWidth', 2);
        grid on;
        xlabel('Desplazamiento X [mm]', 'Interpreter','none');
        ylabel('Fuerza Total [N]',      'Interpreter','none');
        title('Fuerza vs Desplazamiento X', 'Interpreter','none');

        subplot(1,3,2);
        plot(disp_tot, energy_acum, '-r', 'LineWidth', 2);
        grid on;
        xlabel('Desplazamiento X [mm]',  'Interpreter','none');
        ylabel('Energia Absorbida [J]',  'Interpreter','none');
        title('Energia Absorbida vs Desplazamiento X', 'Interpreter','none');

        subplot(1,3,3);
        plot(angle_deg, moment_Nm, '-k', 'LineWidth', 2);
        grid on;
        xlabel('Angulo de Giro [grados]',  'Interpreter','none');
        ylabel('Momento Flector [N·m]',    'Interpreter','none');
        title(sprintf('Momento vs Angulo | %s | pivote %.1f mm', modo_fallo_i, pivot_height_mm), ...
            'Interpreter','none');

        sgtitle(sprintf('Resultados Cinematicos y Estructurales - Simulacion %03d', i), ...
            'Interpreter','none');

        img_path = fullfile(carpeta_resultados, sprintf('Sim_%03d',i), 'Graficas_Completas.png');
        saveas(fig, img_path);
        close(fig);
        n_ok = n_ok + 1;
    catch ME
        warning('Sim %03d: %s', i, ME.message);
        n_error = n_error + 1;
    end
end

fprintf('\nGraficas regeneradas: %d  |  Sin Curvas.csv: %d  |  Errores: %d\n', ...
    n_ok, n_sin_curvas, n_error);
