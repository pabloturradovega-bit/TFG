% recalcular_modos_fallo.m
% ============================================================
% Recalcula modo_fallo, pivot_height_mm y lever_arm_mm usando
% la regla de calcular_pivot.m (fuente de verdad: ese fichero):
%   Hibrido -> y_max < 1 mm             pivote = (a2+c)/2
%   Cartela -> 1 <= y_max <= c+a2+0.1   pivote = 0
%   Viga    -> y_max > c+a2+0.1         pivote = y_max
%
% Procesa TODAS las campanas listadas en campanas_a_procesar.
% Hace copia de seguridad del CSV original antes de sobreescribir.
% ============================================================
clc;
scriptDir = fileparts(mfilename('fullpath'));
cd(scriptDir);

% --- Campanas a actualizar ---
campanas_a_procesar = {
    'DOE_60_L1000_C80_S235JR'
};

for k = 1:numel(campanas_a_procesar)
    nombre = campanas_a_procesar{k};
    arch   = fullfile('Resultados', nombre, 'basededatos.csv');

    if ~isfile(arch)
        fprintf('[SKIP] No encontrado: %s\n', arch);
        continue;
    end

    fprintf('\n=== Procesando: %s ===\n', nombre);

    % --- Leer CSV ---
    opts = detectImportOptions(arch);
    opts.VariableNamingRule = 'preserve';
    data = readtable(arch, opts);
    nr   = height(data);

    % --- Asegurar que existen las columnas de salida ---
    if ~ismember('modo_fallo', data.Properties.VariableNames)
        data.modo_fallo = repmat({'N/A'}, nr, 1);
    end
    if ~ismember('pivot_height_mm', data.Properties.VariableNames)
        data.pivot_height_mm = NaN(nr, 1);
    end
    if ~ismember('lever_arm_mm', data.Properties.VariableNames)
        data.lever_arm_mm = NaN(nr, 1);
    end

    % --- Copia de seguridad ---
    backup = strrep(arch, '.csv', '_backup_vieja_regla.csv');
    if ~isfile(backup)
        copyfile(arch, backup);
        fprintf('  Copia de seguridad: %s\n', backup);
    else
        fprintf('  Copia de seguridad ya existe, no se sobreescribe.\n');
    end

    % --- Contadores para el resumen ---
    n_viga = 0; n_cartela = 0; n_hibrido = 0; n_na = 0;

    % --- Recalcular fila a fila ---
    for i = 1:nr
        y = data.y_max_stress_mm(i);
        c  = data.c(i);
        a1 = data.a1(i);
        a2 = data.a2(i);
        l1 = data.l1(i);

        [ph, la, mf] = calcular_pivot(y, c, a1, a2, l1);

        data.pivot_height_mm(i) = ph;
        data.lever_arm_mm(i)    = la;
        if iscell(data.modo_fallo)
            data.modo_fallo{i} = mf;
        else
            data.modo_fallo(i) = {mf};
        end

        switch mf
            case 'Viga',    n_viga    = n_viga    + 1;
            case 'Cartela', n_cartela = n_cartela + 1;
            case 'Hibrido', n_hibrido = n_hibrido + 1;
            otherwise,      n_na      = n_na      + 1;
        end
    end

    % --- Guardar CSV actualizado ---
    writetable(data, arch);
    fprintf('  Guardado: %s\n', arch);
    fprintf('  Modos  ->  Viga: %d  |  Cartela: %d  |  Hibrido: %d  |  N/A: %d  (total: %d)\n', ...
        n_viga, n_cartela, n_hibrido, n_na, nr);
end

fprintf('\nProceso completado.\n');
