function T04_Optimizacion_GA()
    % =========================================================================
    % T04_Optimizacion_GA.m
    % =========================================================================
    % Optimiza la energia especifica [J/kg] = energy_J / mass_kg sobre el
    % catalogo de fabricacion en dos pasos:
    %   1) Algoritmo genetico (metodo principal del TFG)
    %   2) Enumeracion exhaustiva del catalogo (~19.700 combinaciones) como
    %      verificacion: con el surrogate cuesta segundos y confirma si el
    %      AG alcanzo el optimo global del catalogo.
    % Si el surrogate es un GPR, reporta ademas la incertidumbre (sigma) en
    % el optimo y el optimo robusto por Lower Confidence Bound (LCB).
    %
    % Guarda en optimo_GA.mat:
    %   optimo      -> mejor diseno del catalogo (verificado por fuerza bruta)
    %   ranking_top -> tabla con los 5 mejores disenos (la usa T05 para
    %                  validar varios candidatos y acotar el sesgo optimista
    %                  del optimizador, "winner's curse")
    %
    % Variables: m1, a1, m2, a2, b, e_cartela
    % =========================================================================

    clear; clc;
    rng(0);

    % --- Umbral ECE R66 de energia especifica [J/kg]; 0 = sin restriccion ---
    % (mismo significado que app.umbral_ecr66 en la GUI). Los disenos por
    % debajo del umbral se penalizan en el AG y se excluyen del ranking.
    umbral_ecr66 = 0;

    % --- Cargar Campana Activa ---
    if ~isfile('active_campaign.txt')
        error('No se encontro active_campaign.txt. Ejecuta primero T01_Generar_DOE_LHS.m');
    end
    fid = fopen('active_campaign.txt', 'r');
    nombre_campana = strtrim(fgetl(fid));
    fclose(fid);

    carpeta_resultados = fullfile('Resultados', nombre_campana);
    archivo_db = fullfile(carpeta_resultados, 'basededatos.csv');
    fprintf('Campana activa: %s\n', nombre_campana);

    ruta_modelo = fullfile(carpeta_resultados, 'modelo_surrogate.mat');
    if isfile(ruta_modelo)
        load(ruta_modelo, 'trainedModel');
        fprintf('Modelo surrogate cargado desde la campana activa.\n');
    else
        error('No se encontro modelo_surrogate.mat en la carpeta de la campana activa. Entrena el modelo primero.');
    end

    % --- Limites y parametros fijos: leidos de meta_campana.mat ---
    % meta.lb/ub = [m1, a1, m2, a2, b, e_cartela, c]. Los valores por
    % defecto solo se usan si la campana no tiene meta (campanas antiguas).
    lb = [2,  40,  2,  40,  40,  2];
    ub = [4, 100,  4, 100, 100,  4];
    c_fijo = 80;
    [l1_fijo, l2_fijo] = get_fixed_lengths_from_dataset(archivo_db);

    meta_f = fullfile(carpeta_resultados, 'meta_campana.mat');
    if isfile(meta_f)
        m_meta = load(meta_f, 'meta'); meta_camp = m_meta.meta;
        if isfield(meta_camp, 'lb'),     lb = reshape(meta_camp.lb(1:6), 1, 6); end
        if isfield(meta_camp, 'ub'),     ub = reshape(meta_camp.ub(1:6), 1, 6); end
        if isfield(meta_camp, 'c_fijo'), c_fijo = meta_camp.c_fijo; end
        if isfield(meta_camp, 'l_fijo'), l1_fijo = meta_camp.l_fijo; l2_fijo = meta_camp.l_fijo; end
        fprintf('Meta cargada: c=%g mm, l=%g mm, lb/ub de la campana.\n', c_fijo, l1_fijo);
    else
        fprintf('Sin meta_campana.mat: usando limites y c=%g mm por defecto.\n', c_fijo);
    end

    % Parametros del GA
    population_size = 150;
    num_generations = 60;
    mutation_rate = 0.25;
    nVars = 6;

    % Inicializacion
    population = zeros(population_size, nVars);
    for i = 1:population_size
        population(i, :) = generate_valid_individual(lb, ub);
    end

    fprintf('Iniciando AG: objetivo = maximizar energia especifica [J/kg].\n');
    if umbral_ecr66 > 0
        fprintf('Restriccion ECE R66 activa: energia especifica >= %.1f J/kg\n', umbral_ecr66);
    end

    fitness = evaluate_population(population, trainedModel, l1_fijo, l2_fijo, c_fijo, umbral_ecr66);
    best_epw_history = zeros(num_generations, 1);

    % Bucle principal
    for gen = 1:num_generations
        new_population = zeros(size(population));

        [~, best_idx] = min(fitness);
        new_population(1, :) = population(best_idx, :);

        for i = 2:population_size
            parents = select_parents(population, fitness);
            child = crossover(parents{1}, parents{2}, nVars);
            child = mutate(child, lb, ub, mutation_rate, nVars);
            child = repair_individual(child, lb, ub);
            new_population(i, :) = child;
        end

        population = new_population;
        fitness = evaluate_population(population, trainedModel, l1_fijo, l2_fijo, c_fijo, umbral_ecr66);

        best_epm = -min(fitness);
        best_epw_history(gen) = best_epm;

        if mod(gen, 10) == 0 || gen == num_generations
            fprintf('Gen %d/%d - Mejor energia especifica: %.4f J/kg\n', gen, num_generations, best_epm);
        end
    end

    % Resultado del GA
    [~, best_idx] = min(fitness);
    winner = population(best_idx, :);

    winner_tab = individual_to_table(winner, l1_fijo, l2_fijo, c_fijo);
    winner_energy = trainedModel.predictFcn(winner_tab);  % [J]
    winner_mass_kg = masa_analitica(winner(1), winner(2), winner(5), l1_fijo, ...
                                    winner(3), winner(4), winner(5), l2_fijo, ...
                                    c_fijo, winner(6));
    winner_epm = winner_energy / winner_mass_kg;  % [J/kg]

    % =====================================================================
    % Verificacion: enumeracion exhaustiva del catalogo de fabricacion
    % =====================================================================
    % El espacio de catalogo es pequeno (3x9x9x3x9x3 ~ 19.700 combos) y el
    % surrogate lo evalua en segundos, asi que podemos certificar si el AG
    % encontro el optimo GLOBAL del catalogo.
    fprintf('\n--- Verificacion por fuerza bruta sobre el catalogo ---\n');
    esp_viga = [2 3 4];
    esp_cart = [2 3 4];
    cat_ab   = [40 45 50 55 60 70 80 90 100];

    [M1g, A1g, Bg, M2g, A2g, ECg] = ndgrid(esp_viga, cat_ab, cat_ab, esp_viga, cat_ab, esp_cart);
    cat6 = [M1g(:), A1g(:), Bg(:), M2g(:), A2g(:), ECg(:)];  % [m1 a1 b m2 a2 ec]

    % Restriccion de fabricabilidad m <= min(a,b)/4
    ok_fab = (4*cat6(:,1) <= min(cat6(:,2), cat6(:,3))) & ...
             (4*cat6(:,4) <= min(cat6(:,5), cat6(:,3)));
    cat6 = cat6(ok_fab, :);
    n_cat = size(cat6, 1);

    tab_cat = array2table([cat6(:,1), cat6(:,2), cat6(:,3), l1_fijo*ones(n_cat,1), ...
                           cat6(:,4), cat6(:,5), cat6(:,3), l2_fijo*ones(n_cat,1), ...
                           c_fijo*ones(n_cat,1), cat6(:,6)], ...
        'VariableNames', {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});

    E_cat    = trainedModel.predictFcn(tab_cat);  % [J]
    masa_cat = masa_analitica(cat6(:,1), cat6(:,2), cat6(:,3), l1_fijo, ...
                              cat6(:,4), cat6(:,5), cat6(:,3), l2_fijo, ...
                              c_fijo, cat6(:,6));
    epm_cat  = E_cat ./ masa_cat;  % [J/kg]

    feas = isfinite(epm_cat) & epm_cat > 0;
    if umbral_ecr66 > 0
        feas_umb = feas & epm_cat >= umbral_ecr66;
        if any(feas_umb)
            feas = feas_umb;
        else
            warning('Ningun diseno de catalogo cumple el umbral ECE R66 (%.1f J/kg). Ranking sin restriccion.', umbral_ecr66);
        end
    end

    idx_feas = find(feas);
    [~, ord] = sort(epm_cat(idx_feas), 'descend');
    idx_sorted = idx_feas(ord);
    n_top = min(5, numel(idx_sorted));
    idx_top = idx_sorted(1:n_top);

    ranking_top = tab_cat(idx_top, :);
    ranking_top.energia_J = E_cat(idx_top);
    ranking_top.masa_kg   = masa_cat(idx_top);
    ranking_top.epm_J_kg  = epm_cat(idx_top);

    % Comparacion AG vs optimo global del catalogo
    mejor6 = cat6(idx_top(1), :);                                     % [m1 a1 b m2 a2 ec]
    ga6    = [winner(1), winner(2), winner(5), winner(3), winner(4), winner(6)];
    ga_encontro_optimo = isequal(mejor6, ga6);
    epm_global = epm_cat(idx_top(1));

    fprintf('Catalogo enumerado: %d combinaciones validas.\n', n_cat);
    fprintf('Optimo global del catalogo: %.4f J/kg\n', epm_global);
    fprintf('Optimo del AG:              %.4f J/kg\n', winner_epm);
    if ga_encontro_optimo
        fprintf('>>> El AG ENCONTRO el optimo global del catalogo. <<<\n');
    else
        fprintf('>>> El AG NO encontro el optimo global (deficit %.4f J/kg = %.2f%%).\n', ...
            epm_global - winner_epm, 100*(epm_global - winner_epm)/epm_global);
        fprintf('    Se guarda como optimo el resultado de la enumeracion exhaustiva.\n');
    end

    fprintf('\nTop %d disenos del catalogo (surrogate):\n', n_top);
    for k = 1:n_top
        r = ranking_top(k, :);
        fprintf('  #%d  m1=%g a1=%g m2=%g a2=%g b=%g ec=%g  ->  %.4f J/kg (%.1f J, %.3f kg)\n', ...
            k, r.m1, r.a1, r.m2, r.a2, r.b1, r.e_cartela, r.epm_J_kg, r.energia_J, r.masa_kg);
    end

    % =====================================================================
    % Incertidumbre del surrogate (solo GPR): sigma en el optimo y LCB
    % =====================================================================
    % El optimizador explota los errores del modelo ("winner's curse"), por
    % lo que la prediccion en el optimo esta sesgada al alza. Si el modelo
    % es un GPR disponemos de sigma: reportamos el IC95 de la energia en el
    % optimo y el optimo robusto por LCB = (mu - 1.96*sigma)/masa.
    sigma_opt_J = NaN;
    epm_ic95    = [NaN, NaN];
    gp = extraer_gpr(trainedModel);
    if ~isempty(gp)
        try
            [mu_cat, sd_cat] = predict(gp, tab_cat);
            sigma_opt_J = sd_cat(idx_top(1));
            epm_ic95 = [(E_cat(idx_top(1)) - 1.96*sigma_opt_J), ...
                        (E_cat(idx_top(1)) + 1.96*sigma_opt_J)] / masa_cat(idx_top(1));

            epm_lcb = (mu_cat - 1.96*sd_cat) ./ masa_cat;
            epm_lcb(~feas) = -Inf;
            [lcb_val, i_lcb] = max(epm_lcb);

            fprintf('\n--- Incertidumbre GPR en el optimo ---\n');
            fprintf('Energia predicha: %.1f J  (sigma = %.1f J)\n', E_cat(idx_top(1)), sigma_opt_J);
            fprintf('IC95 energia especifica: [%.4f, %.4f] J/kg\n', epm_ic95(1), epm_ic95(2));
            if i_lcb == idx_top(1)
                fprintf('Optimo robusto (LCB 95%%): COINCIDE con el optimo nominal.\n');
            else
                rl = tab_cat(i_lcb, :);
                fprintf('Optimo robusto (LCB 95%%): m1=%g a1=%g m2=%g a2=%g b=%g ec=%g  (LCB %.4f J/kg)\n', ...
                    rl.m1, rl.a1, rl.m2, rl.a2, rl.b1, rl.e_cartela, lcb_val);
                fprintf('  (diseno distinto al nominal: candidato a discutir en la memoria)\n');
            end
        catch ex_gp
            fprintf('\n[Aviso] No se pudo evaluar la incertidumbre GPR: %s\n', ex_gp.message);
        end
    else
        fprintf('\n(El surrogate no es un GPR: sin estimacion de incertidumbre/LCB.)\n');
    end

    % =====================================================================
    % Resultado final (optimo global verificado)
    % =====================================================================
    fprintf('\n======================================================\n');
    fprintf('       RESULTADO DE LA OPTIMIZACION: ENERGIA ESPECIFICA\n');
    fprintf('======================================================\n');
    fprintf('Energia especifica optima (IA): %.4f J/kg\n', epm_global);
    fprintf('Energia absorbida estimada:     %.2f J\n', E_cat(idx_top(1)));
    fprintf('Masa estimada:                  %.3f kg\n', masa_cat(idx_top(1)));
    fprintf('------------------------------------------------------\n');
    fprintf('VIGA A (Pilar):  Alt %.0f, Anch %.0f, Esp %.1f, L %.0f\n', mejor6(2), mejor6(3), mejor6(1), l1_fijo);
    fprintf('VIGA B (Techo):  Alt %.0f, Anch %.0f, Esp %.1f, L %.0f\n', mejor6(5), mejor6(3), mejor6(4), l2_fijo);
    fprintf('Cartela:         catetos=%g mm, espesor=%.1f mm\n', c_fijo, mejor6(6));
    fprintf('======================================================\n');

    fig_conv = figure('Name', 'Convergencia TFG - Energia especifica');
    plot(1:num_generations, best_epw_history, '-b', 'LineWidth', 2);
    hold on;
    yline(epm_global, 'r--', 'Optimo global (fuerza bruta)', 'LineWidth', 1.5);
    hold off;
    xlabel('Generacion'); ylabel('Energia especifica (J/kg)');
    title('Optimizacion de energia especifica'); grid on;
    saveas(fig_conv, fullfile(carpeta_resultados, 'convergencia_GA.png'));

    % Guardar optimo (global) y ranking para validacion top-K y Montecarlo
    optimo.m1 = mejor6(1);
    optimo.a1 = mejor6(2);
    optimo.b1 = mejor6(3);
    optimo.l1 = l1_fijo;
    optimo.m2 = mejor6(4);
    optimo.a2 = mejor6(5);
    optimo.b2 = mejor6(3);
    optimo.l2 = l2_fijo;
    optimo.c  = c_fijo;
    optimo.e_cartela = mejor6(6);
    optimo.masa_estimada = masa_cat(idx_top(1));
    optimo.energia_especifica_J_kg = epm_global;
    optimo.energia_absorbida_J = E_cat(idx_top(1));
    optimo.epm_GA = winner_epm;
    optimo.ga_encontro_optimo = ga_encontro_optimo;
    optimo.umbral_ecr66 = umbral_ecr66;
    optimo.energia_sigma_J = sigma_opt_J;
    optimo.epm_ic95 = epm_ic95;

    save(fullfile(carpeta_resultados, 'optimo_GA.mat'), 'optimo', 'ranking_top');
    fprintf('\nGuardado: optimo_GA.mat (optimo + ranking_top con %d disenos)\n', n_top);
end

% --- Fitness: minimizamos el negativo de energy_per_mass [J/kg] ---
function fitness = evaluate_population(population, trainedModel, l1, l2, c, umbral_ecr66)
    pop_size = size(population, 1);

    full_pop = zeros(pop_size, 10);
    for i = 1:pop_size
        ind = population(i, :);
        full_pop(i, :) = [ind(1), ind(2), ind(5), l1, ind(3), ind(4), ind(5), l2, c, ind(6)];
    end

    tab = array2table(full_pop, 'VariableNames', ...
        {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
    predicted_energy = trainedModel.predictFcn(tab);  % [J]

    mass_kg = masa_analitica(population(:,1), population(:,2), population(:,5), l1, ...
                             population(:,3), population(:,4), population(:,5), l2, ...
                             c, population(:,6));
    epm = predicted_energy ./ mass_kg;  % [J/kg]

    fitness = -epm;
    bad = ~isfinite(epm) | epm <= 0;
    fitness(bad) = 1e9;

    % Penalizacion ECE R66: gradiente hacia la factibilidad (mejor cuanto
    % mas cerca del umbral), pero siempre peor que cualquier factible.
    if umbral_ecr66 > 0
        viol = ~bad & (epm < umbral_ecr66);
        fitness(viol) = 1e6 + (umbral_ecr66 - epm(viol));
    end
end

function tab = individual_to_table(ind, l1, l2, c)
    full = [ind(1), ind(2), ind(5), l1, ind(3), ind(4), ind(5), l2, c, ind(6)];
    tab = array2table(full, 'VariableNames', ...
        {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
end

function [l1_fijo, l2_fijo] = get_fixed_lengths_from_dataset(archivo_db)
    l1_fijo = 1000;
    l2_fijo = 1000;
    if isfile(archivo_db)
        data = readtable(archivo_db);
        if all(ismember({'l1','l2'}, data.Properties.VariableNames)) && height(data) > 0
            l1_fijo = data.l1(1);
            l2_fijo = data.l2(1);
        end
    end
end

% (extraer_gpr vive en extraer_gpr.m, compartida con la GUI)

% --- Generacion y reparacion a catalogo ---
function ind = generate_valid_individual(lb, ub)
    ind = lb + (ub - lb) .* rand(1, 6);
    ind = repair_individual(ind, lb, ub);
end

function ind = repair_individual(ind, lb, ub)
    ind = max(min(ind, ub), lb);

    espesores_viga = [2 3 4];
    espesores_cart = [2 3 4];
    catalogo_ab = [40 45 50 55 60 70 80 90 100];

    ind(1) = snap_to_nearest(ind(1), espesores_viga);
    ind(3) = snap_to_nearest(ind(3), espesores_viga);
    ind(6) = snap_to_nearest(ind(6), espesores_cart);
    ind(2) = snap_to_nearest(ind(2), catalogo_ab);
    ind(4) = snap_to_nearest(ind(4), catalogo_ab);
    ind(5) = snap_to_nearest(ind(5), catalogo_ab);

    max_m1 = min(ind(2), ind(5)) / 4;
    if ind(1) > max_m1, ind(1) = snap_to_closest_below(max_m1, espesores_viga); end
    max_m2 = min(ind(4), ind(5)) / 4;
    if ind(3) > max_m2, ind(3) = snap_to_closest_below(max_m2, espesores_viga); end
end

function val = snap_to_nearest(x, allowed_vals)
    [~, idx] = min(abs(allowed_vals - x));
    val = allowed_vals(idx);
end

function val = snap_to_closest_below(x, allowed_vals)
    valid = allowed_vals(allowed_vals <= x);
    if isempty(valid), val = allowed_vals(1); else, val = max(valid); end
end

% --- AG ---
function parents = select_parents(population, fitness)
    k = 3; pop_size = size(population, 1);
    idx1 = randi(pop_size, [k, 1]); [~, b1] = min(fitness(idx1));
    idx2 = randi(pop_size, [k, 1]); [~, b2] = min(fitness(idx2));
    parents = {population(idx1(b1), :), population(idx2(b2), :)};
end

function child = crossover(p1, p2, nVars)
    mask = rand(1, nVars) < 0.5;
    child = p1; child(mask) = p2(mask);
end

function ind = mutate(ind, lb, ub, rate, nVars)
    for j = 1:nVars
        if rand < rate
            ind(j) = ind(j) + randn * (0.1 * (ub(j)-lb(j)));
        end
    end
end
