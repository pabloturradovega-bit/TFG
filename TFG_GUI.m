classdef TFG_GUI < handle
% TFG_GUI  Interfaz gráfica para el pipeline de optimización ECE R66.
% Uso:  app = TFG_GUI;

    properties (Access = private)
        fig
        htabs
        lbl_campana
        dd_campana   % desplegable de campañas en la barra superior

        U           % struct con handles por pestaña

        pipeline_dir  (1,:) char
        campana       (1,:) char
        ansys_path    (1,:) char

        cat_esp_viga  (1,:) double = [2 3 4]
        cat_dims      (1,:) double = [40 45 50 55 60 70 80 90 100]
        cat_esp_cart  (1,:) double = [2 3 4]
        cat_c         (1,:) double = [80]
        cat_c_auto    (1,1) logical = true  % true = cat_c se autoajusta a la campaña; false = editado a mano
        materiales_db               % struct array: nombre, fy_mpa, Et_gpa
        modelos_cache               % struct array de modelos entrenados con sus métricas
        diseno_validar              % struct con el diseño actualmente seleccionado para validar
        hp                          % struct de hiperparámetros de entrenamiento
        umbral_ecr66  (1,1) double = 0   % umbral ECE R66 [J/kg]; 0 = sin comprobar
        stop_requested (1,1) logical = false  % flag para detener el batch entre sims
        epm_ga_cat     (1,1) double = NaN    % mejor EPM del GA de catálogo (para comparar con la fuerza bruta)
        epm_ga_camp    (1,:) char = ''        % campaña en la que se obtuvo epm_ga_cat
    end

    properties (Constant, Access = private)
        % Paleta unificada de la GUI: un color por ROL, no por botón.
        % Cualquier botón nuevo debe usar una de estas seis constantes.
        COL_AZUL   = [0.16 0.35 0.60]   % acción principal (lanzar/generar)
        COL_AZUL2  = [0.36 0.49 0.66]   % acción secundaria
        COL_VERDE  = [0.15 0.46 0.27]   % guardar / exportar / positivo
        COL_MORADO = [0.38 0.24 0.58]   % análisis (MC, Sobol, ECE R66, entrenar)
        COL_ROJO   = [0.66 0.18 0.16]   % parar / eliminar
        COL_GRIS   = [0.44 0.47 0.52]   % utilidades neutras
    end

    % ===================================================================
    methods (Access = public)
    % ===================================================================
        function app = TFG_GUI()
            app.pipeline_dir = fileparts(mfilename('fullpath'));
            if isempty(app.pipeline_dir), app.pipeline_dir = pwd; end
            app.ansys_path = app.detectar_ansys();
            app.cargar_mat_db();
            app.cargar_campana();
            app.autoset_cat_c();
            app.hp = app.hp_defaults();
            app.crear_ui();
            % Mostrar la campaña activa en la pestaña DOE al arrancar
            try, app.refrescar_doe(); catch, end
        end
    end

    % ===================================================================
    methods (Access = private)
    % ===================================================================

        % ---------------------------------------------------------------
        % UTILIDADES
        % ---------------------------------------------------------------
        function cargar_campana(app)
            f = fullfile(app.pipeline_dir,'active_campaign.txt');
            if isfile(f)
                fid = fopen(f,'r'); app.campana = strtrim(fgetl(fid)); fclose(fid);
            else
                app.campana = '';
            end
        end

        function autoset_cat_c(app)
            % Sincroniza el catálogo de c con la campaña activa:
            %   - c VARIABLE en el DOE -> barrido dentro del rango (paso 5 mm).
            %   - c FIJA               -> el único valor de c del DOE.
            % Solo actúa mientras el catálogo de c está en modo automático; en
            % cuanto el usuario lo edita a mano (cb_add_cat/cb_del_cat sobre
            % 'cc') queda fijado y se respeta tal cual.
            if ~app.cat_c_auto, return; end
            if isempty(app.campana), return; end
            try
                db = readtable(fullfile(app.ruta_campana(),'basededatos.csv'));
            catch
                return;
            end
            if ~ismember('c', db.Properties.VariableNames) || isempty(db.c), return; end
            if std(db.c) > 1e-10
                lo = 5*floor(min(db.c)/5);
                hi = 5*ceil(max(db.c)/5);
                if hi > lo, app.cat_c = lo:5:hi; end
            else
                app.cat_c = round(db.c(1));   % c fija: un único valor
            end
        end

        function guardar_campana(app, nombre)
            app.campana = nombre;
            fid = fopen(fullfile(app.pipeline_dir,'active_campaign.txt'),'w');
            fprintf(fid,'%s',nombre); fclose(fid);
            app.actualizar_barra();
        end

        function cargar_mat_db(app)
            defaults(1) = struct('nombre','S235JR','fy_mpa',235.5,'Et_gpa',1.16);
            defaults(2) = struct('nombre','S275JR','fy_mpa',275.0,'Et_gpa',1.16);
            defaults(3) = struct('nombre','S355JR','fy_mpa',355.0,'Et_gpa',1.50);
            f = fullfile(app.pipeline_dir,'materiales.mat');
            if isfile(f)
                m = load(f,'materiales_db');
                app.materiales_db = m.materiales_db;
            else
                app.materiales_db = defaults;
            end
        end

        function guardar_mat_db(app)
            materiales_db = app.materiales_db;
            save(fullfile(app.pipeline_dir,'materiales.mat'),'materiales_db');
        end

        function nombres = nombres_materiales(app)
            nombres = {app.materiales_db.nombre};
        end

        function [fy, Et] = props_material(app, nombre)
            idx = strcmp({app.materiales_db.nombre}, nombre);
            if any(idx)
                fy = app.materiales_db(idx).fy_mpa;
                Et = app.materiales_db(idx).Et_gpa;
            else
                fy = 235.5; Et = 1.16;
            end
        end

        function hp = hp_defaults(~)
            hp.kfold               = 5;
            % Modo de validación: 'kfold' | 'holdout' | 'kfold_holdout'
            hp.val_mode            = 'kfold';
            hp.holdout_frac        = 0.20;   % fracción reservada como test
            % Grupos: activar/desactivar familias de modelos
            hp.grupos.gpr          = true;
            hp.grupos.ensemble     = true;
            hp.grupos.trees        = true;
            hp.grupos.svm          = true;
            hp.grupos.kernel       = true;
            hp.grupos.lineal       = true;
            hp.grupos.redes        = true;
            % Ensemble (Boosting + Bagging)
            hp.ens_cycles          = 200;
            hp.ens_lr              = 0.10;
            hp.ens_leafsize        = 5;
            % GPR
            hp.gpr_basis           = 'none';   % none|constant|linear|pureQuadratic
            % Redes neuronales
            hp.nn_layers           = '64 32';  % texto: "64 32" → [64 32]
            hp.nn_activations      = 'relu';   % relu|tanh|sigmoid
            % SVM
            hp.svm_box             = 1.0;
            hp.svm_scale           = 0;        % 0 = 'auto'
            % Árboles individuales
            hp.tree_mod_splits     = 20;
            hp.tree_deep_leafsize  = 2;
        end

        function actualizar_barra(app)
            % Sincroniza el desplegable de campañas con Resultados/ y
            % muestra el progreso de simulaciones de la campaña activa.
            if ~isempty(app.dd_campana) && isvalid(app.dd_campana)
                lista = app.listar_campanas();
                if isempty(lista), lista = {'(sin campañas)'}; end
                app.dd_campana.Items = lista;
                if ~isempty(app.campana) && any(strcmp(lista, app.campana))
                    app.dd_campana.Value = app.campana;
                end
            end
            if isempty(app.campana)
                app.lbl_campana.Text = 'Sin campaña activa';
                app.lbl_campana.FontColor = [1.0 0.55 0.55];
            else
                info = '';
                try
                    db_f = fullfile(app.ruta_campana(),'basededatos.csv');
                    if isfile(db_f)
                        db_ = readtable(db_f);
                        if ismember('energy', db_.Properties.VariableNames)
                            info = sprintf('%d/%d sims hechas', ...
                                sum(isfinite(db_.energy)), height(db_));
                        else
                            info = sprintf('%d filas', height(db_));
                        end
                    end
                catch, end
                app.lbl_campana.Text = info;
                app.lbl_campana.FontColor = [0.9 0.95 1.0];
            end
        end

        function lista = listar_campanas(app)
            % Carpetas de Resultados/ que contienen basededatos.csv
            lista = {};
            base = fullfile(app.pipeline_dir,'Resultados');
            if ~isfolder(base), return; end
            d = dir(base);
            for k = 1:numel(d)
                if d(k).isdir && d(k).name(1) ~= '.' && ...
                        isfile(fullfile(base, d(k).name, 'basededatos.csv'))
                    lista{end+1} = d(k).name; %#ok<AGROW>
                end
            end
        end

        function cb_campana_sel(app, nombre)
            % Cambiar la campaña activa desde el desplegable de la barra.
            % Equivale a editar active_campaign.txt: afecta a GUI y CLI.
            if isempty(nombre) || strcmp(nombre,'(sin campañas)'), return; end
            app.guardar_campana(nombre);
            app.autoset_cat_c();
            % Recargar la pestaña DOE (tabla + gráficas) sin regenerar
            try, app.refrescar_doe(); catch, end
            % Refrescar el panel dependiente si está a la vista
            try
                if ~isempty(app.htabs.SelectedTab)
                    switch app.htabs.SelectedTab.Title
                        case 'Validación', app.refrescar_panel_optimo();
                        case 'Visor',      app.cb_visor_refresh();
                    end
                end
            catch, end
        end

        function cb_abrir_carpeta(app)
            app.cargar_campana();
            r = app.ruta_campana();
            if ~isempty(app.campana) && isfolder(r)
                try, winopen(r); catch, end
            else
                uialert(app.fig,'No hay carpeta de campaña activa.','Aviso');
            end
        end

        function r = ruta_campana(app)
            c = app.campana;
            % Ruta absoluta: Windows X:\... o UNC \\...
            if numel(c) >= 2 && (c(2) == ':' || (c(1) == '\' && c(2) == '\'))
                r = c;
            else
                r = fullfile(app.pipeline_dir,'Resultados',c);
            end
        end

        function p = detectar_ansys(~)
            vers = {'252','251','242','241','232','231','222','221'};
            p = '';
            for i = 1:numel(vers)
                raiz = getenv(['AWP_ROOT' vers{i}]);
                if ~isempty(raiz)
                    c = fullfile(raiz,'Framework','bin','Win64','runwb2.exe');
                    if isfile(c), p = c; return; end
                end
            end
            if isempty(p)
                p = 'E:\ANSYS Inc\ANSYS Student\v252\Framework\bin\Win64\runwb2.exe';
            end
        end

        function estilo_tabla(~, t, col_kpi)
            % Bandas alternas + fila 1 (mejor diseño) y columna KPI en negrita.
            % Llamar SIEMPRE después de asignar t.Data.
            try
                removeStyle(t);
                n = size(t.Data, 1);
                if n >= 2
                    addStyle(t, uistyle('BackgroundColor',[0.94 0.96 1.00]), 'row', 2:2:n);
                end
                if n >= 1
                    addStyle(t, uistyle('FontWeight','bold'), 'row', 1);
                    if nargin >= 3 && col_kpi <= size(t.Data, 2)
                        addStyle(t, uistyle('FontColor',[0.07 0.38 0.18],...
                            'FontWeight','bold'), 'column', col_kpi);
                    end
                end
            catch
            end
        end

        function log_tab(~, hTxt, msg)
            ts  = char(datetime('now','Format','HH:mm:ss'));
            hTxt.Value = [hTxt.Value; {[ts '  ' msg]}];
            scroll(hTxt,'bottom');
            drawnow limitrate;
        end

        % Ambos helpers delegan en masa_analitica.m (formula unica del
        % pipeline, compartida con T03/T04/T06). No duplicar la formula.
        function masa = masa_scalar(~, m1,a1,b,l1,m2,a2,l2,c,ec)
            masa = masa_analitica(m1, a1, b, l1, m2, a2, b, l2, c, ec);
        end

        function masa = masa_vec(~, pop, l1, l2, c_fixed)
            % pop: Nx6 [m1 a1 m2 a2 b e_cartela]  o  Nx7 [..., c]
            if size(pop,2) >= 7
                c_vec = pop(:,7);
            else
                c_vec = c_fixed;
            end
            masa = masa_analitica(pop(:,1), pop(:,2), pop(:,5), l1, ...
                                  pop(:,3), pop(:,4), pop(:,5), l2, ...
                                  c_vec, pop(:,6));
        end

        function preparar_journal(app)
            tmpl = fullfile(app.pipeline_dir,'journal_workbench.wbjn');
            gen  = fullfile(app.pipeline_dir,'journal_generado.wbjn');
            fid  = fopen(tmpl,'r'); txt = fread(fid,'*char')'; fclose(fid);
            txt  = strrep(txt,'<PIPELINE_DIR>',strrep(app.pipeline_dir,'\','/'));
            fid  = fopen(gen,'w'); fprintf(fid,'%s',txt); fclose(fid);
        end

        function generar_script_sc(app, m1,a1,b1,l1,m2,a2,b2,l2,c,ec)
            plantilla = fullfile(app.pipeline_dir,'plantilla_spaceclaim.py');
            fid = fopen(plantilla,'r'); f = fread(fid,'*char')'; fclose(fid);
            f = strrep(f,'PAR_E_CARTELA',num2str(ec, '%.4f'));
            f = strrep(f,'PAR_M1',num2str(m1,'%.4f'));
            f = strrep(f,'PAR_A1',num2str(a1,'%.4f'));
            f = strrep(f,'PAR_B1',num2str(b1,'%.4f'));
            f = strrep(f,'PAR_L1',num2str(l1,'%.4f'));
            f = strrep(f,'PAR_M2',num2str(m2,'%.4f'));
            f = strrep(f,'PAR_A2',num2str(a2,'%.4f'));
            f = strrep(f,'PAR_B2',num2str(b2,'%.4f'));
            f = strrep(f,'PAR_L2',num2str(l2,'%.4f'));
            f = strrep(f,'PAR_C', num2str(c, '%.4f'));
            fid = fopen(fullfile(app.pipeline_dir,'script_generado_spaceclaim.py'),'w');
            fprintf(fid,'%s',f); fclose(fid);
        end

        function ok = esperar_csv(app, csv_path, timeout_s, hLog)
            ok = false;
            t0 = tic;
            while toc(t0) < timeout_s
                if isfile(csv_path), ok = true; return; end
                if app.stop_requested, return; end
                pause(3); drawnow;
                if mod(round(toc(t0)),60) < 3
                    app.log_tab(hLog,sprintf('  Esperando ANSYS... %.0f s',toc(t0)));
                end
            end
        end

        % ---------------------------------------------------------------
        % CREACIÓN DE UI PRINCIPAL
        % ---------------------------------------------------------------
        function crear_ui(app)
            app.fig = uifigure('Name','TFG — Optimización ECE R66',...
                'Position',[30 30 1150 720],'Color',[0.15 0.18 0.22]);

            % Barra superior
            barra = uipanel(app.fig,'Position',[0 685 1150 35],...
                'BackgroundColor',[0.18 0.27 0.45],'BorderType','none');
            uilabel(barra,'Text','TFG — Optimización ECE R66  |  Arco de seguridad bus',...
                'Position',[10 6 410 22],'FontColor',[0.9 0.95 1],...
                'FontSize',12,'FontWeight','bold');

            % Selector de campaña: cambia active_campaign.txt sin re-ejecutar T01
            uilabel(barra,'Text','Campaña:','Position',[440 8 58 18],...
                'FontColor',[0.75 0.85 1],'FontSize',10);
            app.dd_campana = uidropdown(barra,'Items',{'(sin campañas)'},...
                'Position',[500 5 340 25],'FontSize',10,...
                'ValueChangedFcn',@(s,~) app.cb_campana_sel(s.Value));
            uibutton(barra,'Text','↻','Position',[845 5 28 25],'FontSize',12,...
                'Tooltip','Recargar lista de campañas y contador',...
                'ButtonPushedFcn',@(~,~) app.actualizar_barra());
            uibutton(barra,'Text','📂','Position',[877 5 28 25],'FontSize',11,...
                'Tooltip','Abrir carpeta de la campaña activa',...
                'ButtonPushedFcn',@(~,~) app.cb_abrir_carpeta());

            app.lbl_campana = uilabel(barra,'Position',[910 6 230 22],...
                'FontColor',[0.9 0.95 1],'FontSize',10,...
                'HorizontalAlignment','right');
            app.actualizar_barra();

            % Tabs
            app.htabs = uitabgroup(app.fig,'Position',[5 5 1140 678]);
            nombres = {'DOE','Simulaciones','Entrenamiento','Optimización GA',...
                       'Validación','Monte Carlo','Visor'};
            app.U = struct();
            for i = 1:numel(nombres)
                t = uitab(app.htabs,'Title',nombres{i});
                switch i
                    case 1, app.tab_doe(t);
                    case 2, app.tab_sim(t);
                    case 3, app.tab_train(t);
                    case 4, app.tab_ga(t);
                    case 5, app.tab_val(t);
                    case 6, app.tab_mc(t);
                    case 7, app.tab_visor(t);
                end
            end
        end

        % ---------------------------------------------------------------
        % TAB 1 — DOE
        % ---------------------------------------------------------------
        function tab_doe(app, par)
            U = struct();
            x0 = 12;
            y_mat = 624;   % fila material (arriba)
            y_doe = 594;   % fila DOE params (debajo)

            % ── Fila 1: Material ────────────────────────────────────────
            uilabel(par,'Text','Material:','Position',[x0 y_mat 62 22],'FontWeight','bold');
            U.material = uidropdown(par,'Items',app.nombres_materiales(),...
                'Position',[x0+65 y_mat 100 22],...
                'ValueChangedFcn',@(s,~) app.cb_material_sel(s.Value));

            uilabel(par,'Text','fy (MPa):','Position',[x0+178 y_mat 65 22],'FontWeight','bold');
            U.fy = uieditfield(par,'numeric','Value',235.5,'Limits',[50 2000],...
                'Position',[x0+245 y_mat 72 22]);

            uilabel(par,'Text','Et (GPa):','Position',[x0+328 y_mat 62 22],'FontWeight','bold');
            U.Et = uieditfield(par,'numeric','Value',1.16,'Limits',[0.01 500],...
                'Position',[x0+392 y_mat 68 22]);

            uibutton(par,'Text','Guardar preset',...
                'Position',[x0+472 y_mat 118 22],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'ButtonPushedFcn',@(~,~) app.cb_guardar_preset());

            uibutton(par,'Text','Eliminar preset',...
                'Position',[x0+600 y_mat 110 22],...
                'BackgroundColor',app.COL_ROJO,'FontColor','white',...
                'ButtonPushedFcn',@(~,~) app.cb_eliminar_preset());

            % ── Fila 2: DOE params ───────────────────────────────────────
            uilabel(par,'Text','Método DOE:','Position',[x0 y_doe 85 22],'FontWeight','bold');
            U.metodo = uidropdown(par,'Items',{'Sobol','LHS'},...
                'Position',[x0+90 y_doe 80 22],'Value','Sobol');

            uilabel(par,'Text','Muestras:','Position',[x0+185 y_doe 70 22],'FontWeight','bold');
            U.nsamples = uispinner(par,'Value',256,'Limits',[1 5000],'Step',64,...
                'Position',[x0+258 y_doe 75 22]);

            uilabel(par,'Text','Ángulo (°):','Position',[x0+348 y_doe 72 22],'FontWeight','bold');
            U.angulo = uispinner(par,'Value',30,'Limits',[5 90],'Step',5,...
                'Position',[x0+423 y_doe 65 22],...
                'ValueChangedFcn',@(~,~) app.cb_actualizar_desp_doe());

            uilabel(par,'Text','|','Position',[x0+500 y_doe 10 22],...
                'FontColor',[0.65 0.65 0.65],'FontSize',14);

            uilabel(par,'Text','L (mm):','Position',[x0+518 y_doe 55 22],'FontWeight','bold');
            U.l_fijo = uieditfield(par,'numeric','Value',1000,'Limits',[100 10000],...
                'Position',[x0+576 y_doe 72 22],...
                'ValueChangedFcn',@(~,~) app.cb_actualizar_desp_doe());

            uilabel(par,'Text','|','Position',[x0+660 y_doe 10 22],...
                'FontColor',[0.65 0.65 0.65],'FontSize',14);
            uilabel(par,'Text','Dir. X:','Position',[x0+678 y_doe 50 22],'FontWeight','bold');
            U.dir_x = uidropdown(par,...
                'Items',{'-X  (ECE R66 estándar)', '+X  (invertida)'},...
                'Value','-X  (ECE R66 estándar)',...
                'Position',[x0+731 y_doe 188 22],'FontSize',9,...
                'ValueChangedFcn',@(~,~) app.cb_actualizar_desp_doe());
            U.lbl_desp = uilabel(par,'Text','≈ -500 mm',...
                'Position',[x0+924 y_doe 190 22],...
                'FontSize',9,'FontWeight','bold','FontColor',[0.15 0.40 0.65]);

            % Cabecera variables
            y1 = y_doe - 32;
            hdrs = {'Variable','Min (mm)','Max (mm)','Fijar','Val. fijo','Vincular'};
            xh   = [x0, x0+110, x0+205, x0+300, x0+355, x0+475];
            for k = 1:numel(hdrs)
                uilabel(par,'Text',hdrs{k},'Position',[xh(k) y1 95 20],...
                    'FontWeight','bold','FontSize',10);
            end

            % 6 variables
            var_labels = {'m1 — esp. Viga A','a1 — alt. Viga A',...
                          'm2 — esp. Viga B','a2 — alt. Viga B',...
                          'b  — ancho común','e_cartela','c — cateto cartela'};
            dmin = [2 40  2  40  40 2  60];
            dmax = [4 100 4 100 100 4 100];
            links = {'=m2','=a2','=m1','=a1','b1=b2','',''};

            % Var 7 (c) arranca fijada a 80 por defecto
            dy = 34; U.var = struct();
            for i = 1:7
                yy = y1 - i*dy;
                uilabel(par,'Text',var_labels{i},'Position',[x0 yy 105 22],'FontSize',9);
                U.var(i).vmin = uieditfield(par,'numeric','Value',dmin(i),...
                    'Limits',[0.1 2000],'Position',[x0+110 yy 85 22]);
                U.var(i).vmax = uieditfield(par,'numeric','Value',dmax(i),...
                    'Limits',[0.1 2000],'Position',[x0+205 yy 85 22]);
                U.var(i).fix  = uicheckbox(par,'Text','','Position',[x0+310 yy 22 22],...
                    'ValueChangedFcn',@(s,~) app.cb_fix_var(i,s.Value));
                U.var(i).val  = uieditfield(par,'numeric','Value',dmin(i),...
                    'Limits',[0.1 2000],'Position',[x0+335 yy 115 22],'Enable','off');
                if ~isempty(links{i})
                    U.var(i).link = uicheckbox(par,'Text',links{i},...
                        'Position',[x0+460 yy 140 22],'FontSize',9);
                    if i == 5
                        U.var(i).link.Value = true;
                    end
                end
            end

            % c (var 7) fijada a 80 mm por defecto
            U.var(7).fix.Value = true;
            U.var(7).val.Value = 80;
            U.var(7).val.Enable = 'on';
            U.var(7).vmin.Enable = 'off';
            U.var(7).vmax.Enable = 'off';

            % Botón generar
            yb = y1 - 8*dy - 10;
            U.btn = uibutton(par,'Text','▶  Generar DOE',...
                'Position',[x0 yb 160 34],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',12,...
                'ButtonPushedFcn',@(~,~) app.cb_generar_doe());
            U.lbl_res = uilabel(par,'Text','','Position',[x0+170 yb 860 34],...
                'FontSize',11,'WordWrap','on');

            % Tabla de preview (izquierda)
            U.tabla = uitable(par,'Position',[x0 10 528 yb-18],...
                'ColumnName',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_c',...
                'energy','stress','force','mass_kg','epm','t_sim','valid'},...
                'RowName',{},'FontSize',8);

            % Tabs de gráficas DOE (derecha)
            U.htabs_doe = uitabgroup(par,'Position',[548 10 579 yb-18]);

            t_dist = uitab(U.htabs_doe,'Title','Distribución variables');
            aw = 182; ah = 108;
            U.ax_d = gobjects(2,3);
            for row = 0:1
                for col = 0:2
                    U.ax_d(row+1,col+1) = uiaxes(t_dist,...
                        'Position',[6+col*(aw+5), 6+row*(ah+5), aw, ah]);
                    U.ax_d(row+1,col+1).FontSize = 7;
                    grid(U.ax_d(row+1,col+1),'on');
                end
            end

            t_corr = uitab(U.htabs_doe,'Title','Correlación');
            U.ax_corr = uiaxes(t_corr,'Position',[5 5 565 yb-55]);
            U.ax_corr.FontSize = 8;

            app.U.doe = U;
        end

        function cb_material_sel(app, nombre)
            [fy, Et] = app.props_material(nombre);
            app.U.doe.fy.Value = fy;
            app.U.doe.Et.Value = Et;
        end

        function cb_guardar_preset(app)
            U = app.U.doe;
            nombre_act = U.material.Value;
            resp = inputdlg('Nombre del preset:','Guardar material',1,{nombre_act});
            if isempty(resp) || isempty(strtrim(resp{1})), return; end
            nombre = strtrim(resp{1});
            fy = U.fy.Value;  Et = U.Et.Value;

            idx = strcmp({app.materiales_db.nombre}, nombre);
            if any(idx)
                app.materiales_db(idx).fy_mpa = fy;
                app.materiales_db(idx).Et_gpa = Et;
            else
                nuevo.nombre = nombre; nuevo.fy_mpa = fy; nuevo.Et_gpa = Et;
                app.materiales_db(end+1) = nuevo;
            end
            app.guardar_mat_db();
            U.material.Items = app.nombres_materiales();
            U.material.Value = nombre;
            uialert(app.fig, sprintf('Preset "%s" guardado (fy=%.1f MPa, Et=%.2f GPa).',nombre,fy,Et),...
                'Guardado','Icon','success');
        end

        function cb_eliminar_preset(app)
            U = app.U.doe;
            nombre = U.material.Value;
            protegidos = {'S235JR','S275JR','S355JR'};
            if any(strcmp(protegidos, nombre))
                uialert(app.fig,sprintf('"%s" es un material base y no puede eliminarse.',nombre),'Error');
                return;
            end
            resp = uiconfirm(app.fig,sprintf('¿Eliminar preset "%s"?',nombre),'Confirmar',...
                'Options',{'Eliminar','Cancelar'},'DefaultOption',2,'CancelOption',2);
            if strcmp(resp,'Cancelar'), return; end
            app.materiales_db(strcmp({app.materiales_db.nombre},nombre)) = [];
            app.guardar_mat_db();
            U.material.Items = app.nombres_materiales();
            U.material.Value = app.materiales_db(1).nombre;
            app.cb_material_sel(U.material.Value);
        end

        function cb_fix_var(app, i, val)
            U = app.U.doe;
            if val
                U.var(i).val.Enable  = 'on';
                U.var(i).vmin.Enable = 'off';
                U.var(i).vmax.Enable = 'off';
            else
                U.var(i).val.Enable  = 'off';
                U.var(i).vmin.Enable = 'on';
                U.var(i).vmax.Enable = 'on';
            end
        end

        function cb_generar_doe(app)
            U = app.U.doe;
            rng(0);

            N        = U.nsamples.Value;
            metodo   = U.metodo.Value;
            material = U.material.Value;
            l_fijo   = U.l_fijo.Value;

            lb = zeros(1,7); ub = zeros(1,7);
            fixed = false(1,7); fval = zeros(1,7);
            for i = 1:7
                if U.var(i).fix.Value
                    fixed(i) = true; fval(i) = U.var(i).val.Value;
                    lb(i) = fval(i); ub(i) = fval(i);
                else
                    lb(i) = U.var(i).vmin.Value;
                    ub(i) = U.var(i).vmax.Value;
                    if lb(i) >= ub(i)
                        uialert(app.fig,sprintf('Variable %d: Min debe ser < Max.',i),'Error'); return;
                    end
                end
            end

            n_act = sum(~fixed);
            idx_act = find(~fixed);

            if strcmp(metodo,'Sobol')
                p = sobolset(max(n_act,1),'Skip',1);
                X = net(p,N);
            else
                X = lhsdesign(N,max(n_act,1));
            end

            samples = zeros(N,7);
            for i = 1:7
                if fixed(i), samples(:,i) = fval(i); end
            end
            for k = 1:n_act
                i = idx_act(k);
                samples(:,i) = lb(i)+(ub(i)-lb(i))*X(:,k);
            end

            % Vínculos: m1=m2 si var(1).link, a1=a2 si var(2).link
            if isfield(U.var(1),'link') && U.var(1).link.Value && ~fixed(3)
                samples(:,3) = samples(:,1);
            end
            if isfield(U.var(2),'link') && U.var(2).link.Value && ~fixed(4)
                samples(:,4) = samples(:,2);
            end

            m1=samples(:,1); a1=samples(:,2); m2=samples(:,3);
            a2=samples(:,4); b1=samples(:,5); ec=samples(:,6); cv=samples(:,7);

            % b2: igual a b1 si el vínculo está activo; independiente si no
            b2_linked = isfield(U.var(5),'link') && U.var(5).link.Value;
            if b2_linked || fixed(5)
                b2 = b1;
            else
                % Muestrear b2 independientemente del mismo rango
                if strcmp(metodo,'Sobol')
                    p_b2 = sobolset(1,'Skip',N*3+7);
                    b2   = lb(5) + (ub(5)-lb(5))*net(p_b2,N);
                else
                    b2   = lb(5) + (ub(5)-lb(5))*rand(N,1);
                end
            end
            l1v=ones(N,1)*l_fijo; l2v=l1v;

            viol = sum((m1>min(a1,b1)/4)|(m2>min(a2,b2)/4));
            if viol>0
                uialert(app.fig,sprintf('%d muestras violan m≤min(a,b)/4. Ajusta rangos.',viol),'Restricción');
                return;
            end

            nan_col = NaN(N,1);
            data = table(m1,a1,b1,l1v,m2,a2,b2,l2v,cv,ec,...
                nan_col,nan_col,nan_col,nan_col,nan_col,nan_col,nan_col,nan_col,nan_col,nan_col,...
                'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela',...
                'energy','stress','force','mass_kg','energy_per_mass',...
                'sim_time_s','y_max_stress_mm','valid_ansys','pivot_height_mm','lever_arm_mm'});

            str_l = sprintf('L%d',l_fijo);
            if fixed(7), str_c = sprintf('C%d',fval(7)); else, str_c = 'Cvar'; end
            nombre = sprintf('%s_%d_%s_%s_%s',metodo,N,str_l,str_c,material);
            carpeta = fullfile(app.pipeline_dir,'Resultados',nombre);
            if ~exist(carpeta,'dir'), mkdir(carpeta); end

            writetable(data,fullfile(carpeta,'basededatos.csv'));

            meta.material=material; meta.l_fijo=l_fijo; meta.c_fijo=cv(1);
            meta.angulo=U.angulo.Value; meta.fy_pa=U.fy.Value*1e6;
            meta.Et_pa=U.Et.Value*1e9; meta.lb=lb; meta.ub=ub;
            if startsWith(U.dir_x.Value,'+'), meta.dir_x=1; else, meta.dir_x=-1; end
            save(fullfile(carpeta,'meta_campana.mat'),'meta');

            app.guardar_campana(nombre);
            U.lbl_res.Text = sprintf('✓  Campaña: %s  —  %d muestras  —  Restricción OK',nombre,N);
            U.lbl_res.FontColor = [0.1 0.5 0.1];

            U.tabla.Data = data{1:min(300,N),:};

            % ── Gráficas DOE ────────────────────────────────────────────
            % Variables activas (las que tienen varianza real)
            app.dibujar_doe(m1,a1,m2,a2,b1,ec,cv);
        end

        function dibujar_doe(app, m1,a1,m2,a2,b1,ec,cv)
            % Dibuja los scatter/histogramas y la matriz de correlación de
            % la pestaña DOE a partir de las variables de diseño dadas.
            % Compartido por cb_generar_doe (muestras nuevas) y
            % refrescar_doe (campaña existente, sin regenerar).
            U = app.U.doe;
            N = numel(m1);

            etiq_v    = {'m1','a1','m2','a2','b','e_c','c'};
            vals_v    = {m1, a1, m2, a2, b1, ec, cv};
            activo_v  = cellfun(@(v) std(double(v)) > 1e-10, vals_v);
            nombres_act = etiq_v(activo_v);
            vals_act    = vals_v(activo_v);
            nact = sum(activo_v);

            % Colores para los 6 subplots fijos
            colores = {[0.20 0.45 0.85],[0.85 0.35 0.20],[0.25 0.65 0.35],...
                       [0.55 0.20 0.70],[0.80 0.55 0.10],[0.15 0.55 0.65]};

            % Fila 0 (top): scatters de pares
            pares = {1,2; 3,4; 5,6};   % índices dentro de vals_act
            titulos_sc = {'Viga A (m,a)','Viga B (m,a)','b vs e_c'};
            for k = 1:3
                ax = U.ax_d(2,k);   % fila superior = row index 2 (gráfica arriba)
                cla(ax);
                i1 = pares{k,1}; i2 = pares{k,2};
                if i1<=nact && i2<=nact
                    scatter(ax, double(vals_act{i1}), double(vals_act{i2}), ...
                        18, colores{k}, 'filled', 'MarkerFaceAlpha', 0.5);
                    xlabel(ax, nombres_act{i1},'FontSize',7);
                    ylabel(ax, nombres_act{i2},'FontSize',7);
                    title(ax, titulos_sc{k},'FontSize',7);
                else
                    title(ax,'—','FontSize',7);
                end
            end

            % Fila 1 (bottom): histogramas de la 2ª variable de cada par
            hist_idx  = [2, 4, 5];   % a1, a2, b
            for k = 1:3
                ax = U.ax_d(1,k);   % fila inferior = row index 1
                cla(ax);
                ii = hist_idx(k);
                if ii <= nact
                    histogram(ax, double(vals_act{ii}), 20, ...
                        'FaceColor', colores{k}, 'EdgeColor','w');
                    xlabel(ax, nombres_act{ii},'FontSize',7);
                    title(ax, ['Dist. ' nombres_act{ii}],'FontSize',7);
                else
                    title(ax,'—','FontSize',7);
                end
            end

            % Correlación
            ax_c = U.ax_corr;
            cla(ax_c);
            if nact >= 2
                mat_corr = zeros(N, nact);
                for k = 1:nact
                    mat_corr(:,k) = double(vals_act{k});
                end
                C = corrcoef(mat_corr);
                imagesc(ax_c, C);
                colormap(ax_c, 'cool');
                caxis(ax_c, [-1 1]);
                colorbar(ax_c);
                ax_c.XTick = 1:nact; ax_c.YTick = 1:nact;
                ax_c.XTickLabel = nombres_act; ax_c.YTickLabel = nombres_act;
                ax_c.XTickLabelRotation = 35;
                for i = 1:nact
                    for j = 1:nact
                        text(ax_c, j, i, sprintf('%.2f',C(i,j)),...
                            'HorizontalAlignment','center',...
                            'FontSize',7,'Color','k');
                    end
                end
                title(ax_c,'Correlación de Pearson','FontSize',9);
            end
        end

        function refrescar_doe(app)
            % Rellena la tabla y las gráficas de la pestaña DOE con la
            % campaña ACTIVA leyendo basededatos.csv. NO regenera nada:
            % las simulaciones y los resultados quedan intactos.
            if ~isfield(app.U,'doe') || isempty(app.U.doe), return; end
            U = app.U.doe;
            db_f = fullfile(app.ruta_campana(),'basededatos.csv');
            if ~isfile(db_f)
                U.tabla.Data = [];
                for r = 1:2, for c = 1:3, cla(U.ax_d(r,c)); end, end
                cla(U.ax_corr);
                U.lbl_res.Text = 'La campaña activa no tiene basededatos.csv.';
                U.lbl_res.FontColor = [0.75 0.35 0.10];
                return;
            end
            T = readtable(db_f);
            % Tabla (solo columnas numéricas, hasta 300 filas)
            Tnum = T(:, vartype('numeric'));
            nfil = min(300, height(Tnum));
            U.tabla.Data = Tnum{1:nfil, :};
            % Gráficas desde las variables de diseño almacenadas
            app.dibujar_doe(T.m1, T.a1, T.m2, T.a2, T.b1, T.e_cartela, T.c);
            % Restaurar el formulario desde meta (best-effort)
            try, app.restaurar_form_doe(T); catch, end
            U.lbl_res.Text = sprintf('Campaña cargada: %s  —  %d muestras (sin regenerar).',...
                app.campana, height(T));
            U.lbl_res.FontColor = [0.15 0.40 0.65];
        end

        function restaurar_form_doe(app, T)
            % Sincroniza los campos del formulario DOE con la campaña
            % activa (método, nº de muestras, material, rangos...).
            U = app.U.doe;
            if startsWith(app.campana,'LHS')
                U.metodo.Value = 'LHS';
            elseif startsWith(app.campana,'Sobol')
                U.metodo.Value = 'Sobol';
            end
            U.nsamples.Value = min(max(height(T),1),5000);
            meta_f = fullfile(app.ruta_campana(),'meta_campana.mat');
            if ~isfile(meta_f), return; end
            S = load(meta_f,'meta'); meta = S.meta;
            if isfield(meta,'material') && any(strcmp(U.material.Items,meta.material))
                U.material.Value = meta.material;
                app.cb_material_sel(meta.material);
            end
            if isfield(meta,'fy_pa'),  U.fy.Value = meta.fy_pa/1e6; end
            if isfield(meta,'Et_pa'),  U.Et.Value = meta.Et_pa/1e9; end
            if isfield(meta,'l_fijo'), U.l_fijo.Value = meta.l_fijo; end
            if isfield(meta,'angulo'), U.angulo.Value = meta.angulo; end
            if isfield(meta,'dir_x')
                if meta.dir_x > 0
                    U.dir_x.Value = '+X  (invertida)';
                else
                    U.dir_x.Value = '-X  (ECE R66 estándar)';
                end
            end
            if isfield(meta,'lb') && isfield(meta,'ub') && numel(meta.lb) >= 7
                for i = 1:7
                    if meta.lb(i) == meta.ub(i)
                        U.var(i).fix.Value = true;  app.cb_fix_var(i,true);
                        U.var(i).val.Value = meta.lb(i);
                    else
                        U.var(i).fix.Value = false; app.cb_fix_var(i,false);
                        U.var(i).vmin.Value = meta.lb(i);
                        U.var(i).vmax.Value = meta.ub(i);
                    end
                end
            end
            try, app.cb_actualizar_desp_doe(); catch, end
        end

        % ---------------------------------------------------------------
        % TAB 2 — SIMULACIONES
        % ---------------------------------------------------------------
        function tab_sim(app, par)
            U = struct();
            uilabel(par,'Text','Batch de simulaciones ANSYS',...
                'Position',[12 630 400 24],'FontSize',12,'FontWeight','bold');

            U.lbl_camp = uilabel(par,'Text','','Position',[12 606 900 20],'FontSize',10);

            % --- Panel configuración ANSYS ---
            pan = uipanel(par,'Title','Configuración ANSYS',...
                'Position',[12 490 1118 110],'FontSize',10);

            % Substeps
            pss = uipanel(pan,'Title','Pasos de tiempo (substeps)',...
                'Position',[5 5 390 82],'FontSize',9);
            uilabel(pss,'Text','Iniciales:','Position',[5 40 65 20]);
            U.ss_init = uispinner(pss,'Value',50,'Limits',[1 2000],'Step',10,...
                'Position',[75 40 75 22]);
            uilabel(pss,'Text','Mínimos:','Position',[165 40 60 20]);
            U.ss_min  = uispinner(pss,'Value',20,'Limits',[1 2000],'Step',10,...
                'Position',[230 40 75 22]);
            uilabel(pss,'Text','Máximos:','Position',[5 12 65 20]);
            U.ss_max  = uispinner(pss,'Value',250,'Limits',[1 10000],'Step',50,...
                'Position',[75 12 75 22]);
            uilabel(pss,'Text','(más substeps = más precisión pero más lento)',...
                'Position',[165 12 215 20],'FontSize',8,'FontColor',[0.5 0.5 0.5]);

            % Malla
            pm = uipanel(pan,'Title','Mallado',...
                'Position',[403 5 730 82],'FontSize',9);
            uilabel(pm,'Text','Resolución global (1-7):','Position',[5 42 160 20]);
            U.mesh_res = uispinner(pm,'Value',4,'Limits',[1 7],'Step',1,...
                'Position',[168 42 55 22]);
            uilabel(pm,'Text','1=gruesa, 7=fina','Position',[230 42 110 20],'FontSize',8,...
                'FontColor',[0.5 0.5 0.5]);
            uilabel(pm,'Text','Gruesa  d_c ÷','Position',[5 14 80 20],...
                'Tooltip','d_c = (a1+a2+2·b)/4  — dimensión característica de malla');
            U.mesh_coarse_div = uispinner(pm,'Value',4,'Limits',[1 100],'Step',1,...
                'Position',[88 14 50 22]);
            uilabel(pm,'Text','Fina  d_c ÷','Position',[148 14 65 20],...
                'Tooltip','d_c = (a1+a2+2·b)/4  — dimensión característica de malla');
            U.mesh_fine_div = uispinner(pm,'Value',14,'Limits',[1 500],'Step',1,...
                'Position',[216 14 50 22]);
            uilabel(pm,'Text','h_mín:','Position',[275 14 45 20],...
                'Tooltip','Suelo del elemento fino (mm): evita mallas excesivas en secciones pequeñas (a,b≈40 mm)');
            U.mesh_fine_min = uieditfield(pm,'numeric','Value',4.5,'Limits',[0.5 20],...
                'Position',[323 14 42 22]);
            uilabel(pm,'Text','h_máx:','Position',[372 14 45 20],...
                'Tooltip','Techo del elemento fino (mm): garantiza ≥60k nodos en secciones grandes (a,b≈100 mm)');
            U.mesh_fine_max = uieditfield(pm,'numeric','Value',7.0,'Limits',[1 50],...
                'Position',[420 14 42 22]);
            uilabel(pm,'Text','SOI (mm):','Position',[470 14 65 20],...
                'Tooltip','Sphere of Influence: radio (mm) de la zona de malla fina alrededor de la cartela');
            U.mesh_soi = uieditfield(pm,'numeric','Value',300,'Limits',[10 5000],...
                'Position',[538 14 60 22]);
            uilabel(pm,'Text','h = clamp(d_c ÷ div, h_mín, h_máx)  |  d_c=(a1+a2+2·b)/4  |  SOI=zona fina en cartela  |  rango ~75-115k nodos',...
                'Position',[5 -4 700 16],'FontSize',8,'FontColor',[0.5 0.5 0.5]);

            % --- Barra progreso y botones ---
            uilabel(par,'Text','Progreso:','Position',[12 466 70 20]);
            U.lbl_prog = uilabel(par,'Text','—','Position',[85 466 620 20],'FontSize',10);
            U.prog_outer = uipanel(par,'Position',[12 446 700 16],...
                'BackgroundColor',[0.75 0.75 0.75],'BorderType','none');
            U.prog_inner = uipanel(U.prog_outer,'Position',[0 0 1 16],...
                'BackgroundColor',app.COL_AZUL,'BorderType','none');

            % --- Botones (2 filas, alineados con la barra de progreso 700px) ---
            U.btn = uibutton(par,'Text','▶  Lanzar Batch',...
                'Position',[12 408 226 34],...
                'BackgroundColor',app.COL_AZUL,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_sim());
            U.btn_stop = uibutton(par,'Text','⏹  Detener',...
                'Position',[248 408 226 34],...
                'BackgroundColor',app.COL_ROJO,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_stop_sim());
            uibutton(par,'Text','📁  Cargar carpeta de campaña',...
                'Position',[484 408 226 34],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_cargar_carpeta());
            uibutton(par,'Text','📂  Cargar Excel / CSV',...
                'Position',[12 366 345 34],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_cargar_excel());
            uibutton(par,'Text','📋  Ver log de simulación',...
                'Position',[367 366 345 34],...
                'BackgroundColor',app.COL_GRIS,'FontColor','white',...
                'FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_ver_log());

            U.log = uitextarea(par,'Position',[12 10 1116 348],...
                'Editable','off','FontSize',8,'FontName','Consolas','Value',{'Listo.'});

            app.U.sim = U;
        end

        function cb_cargar_excel(app)
            U = app.U.sim;

            % 1. Seleccionar archivo
            [fname, fpath] = uigetfile({'*.xlsx;*.xls;*.csv','Excel / CSV'},...
                'Selecciona el archivo con las simulaciones', app.pipeline_dir);
            if isequal(fname, 0), return; end
            ruta = fullfile(fpath, fname);
            app.log_tab(U.log, ['Leyendo: ' ruta]);

            % 2. Leer
            try
                opts = detectImportOptions(ruta);
                opts.VariableNamingRule = 'preserve';
                raw = readtable(ruta, opts);
            catch ex
                uialert(app.fig, ['No se pudo leer el archivo: ' ex.message], 'Error');
                return;
            end
            app.log_tab(U.log, sprintf('  %d filas × %d columnas leídas.', height(raw), width(raw)));

            % 3. Mapear columnas al esquema esperado
            % Columnas obligatorias de geometría
            geo_map = {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'};
            % Columnas de resultados (opcionales pero importantes)
            res_map = {'energy','stress','force','mass_kg','energy_per_mass',...
                       'sim_time_s','y_max_stress_mm','valid_ansys',...
                       'pivot_height_mm','lever_arm_mm'};
            todas   = [geo_map, res_map];

            col_raw = raw.Properties.VariableNames;
            data    = table();
            encontradas = {}; faltantes = {};

            for k = 1:numel(todas)
                col = todas{k};
                % Buscar coincidencia exacta o insensible a mayúsculas
                idx = find(strcmpi(col_raw, col), 1);
                % Alias comunes
                if isempty(idx)
                    alias = app.alias_columna(col);
                    for a = 1:numel(alias)
                        idx = find(strcmpi(col_raw, alias{a}), 1);
                        if ~isempty(idx), break; end
                    end
                end

                if ~isempty(idx)
                    data.(col) = raw{:, idx};
                    encontradas{end+1} = col;
                else
                    % Columna no encontrada: rellenar con NaN
                    data.(col) = NaN(height(raw), 1);
                    if ismember(col, geo_map)
                        faltantes{end+1} = col;
                    end
                end
            end

            app.log_tab(U.log, ['  Columnas mapeadas: ' strjoin(encontradas, ', ')]);
            if ~isempty(faltantes)
                app.log_tab(U.log, ['  ⚠ Columnas de geometría no encontradas: ' strjoin(faltantes, ', ')]);
            end

            % 4. Calcular energy_per_mass si falta pero hay energy+mass_kg
            if all(isnan(data.energy_per_mass)) && ...
               any(isfinite(data.energy)) && any(isfinite(data.mass_kg)) && any(data.mass_kg > 0)
                data.energy_per_mass = data.energy ./ data.mass_kg;
                app.log_tab(U.log, '  energy_per_mass calculada desde energy / mass_kg.');
            end

            % 5. Nombre de campaña
            [~, nombre_base, ~] = fileparts(fname);
            nombre_base = regexprep(nombre_base, '[^a-zA-Z0-9_]', '_');
            resp = inputdlg('Nombre de la campaña:','Cargar datos externos',1,{nombre_base});
            if isempty(resp), return; end
            nombre_camp = strtrim(resp{1});
            if isempty(nombre_camp), nombre_camp = nombre_base; end

            carpeta = fullfile(app.pipeline_dir, 'Resultados', nombre_camp);
            if ~exist(carpeta, 'dir'), mkdir(carpeta); end

            archivo_db = fullfile(carpeta, 'basededatos.csv');
            writetable(data, archivo_db);
            app.guardar_campana(nombre_camp);

            n_ok = sum(isfinite(data.energy));
            app.log_tab(U.log, sprintf('  Guardado en: %s', archivo_db));
            app.log_tab(U.log, sprintf('  Total filas: %d  |  Con energy válida: %d', height(data), n_ok));
            app.log_tab(U.log, '  ✓ Campaña activa actualizada. Puedes ir a Entrenamiento.');

            U.lbl_camp.Text  = ['Campaña: ' nombre_camp];
            U.lbl_prog.Text  = sprintf('%d simulaciones cargadas (%d con datos completos)', height(data), n_ok);
            app.set_prog(U.prog_outer, U.prog_inner, n_ok/max(height(data),1));
        end

        % ---------------------------------------------------------------
        function cb_cargar_carpeta(app)
        % Carga una campaña completa (basededatos.csv + Sim_NNN/) desde cualquier ruta.
        % ---------------------------------------------------------------
            U = app.U.sim;

            carpeta_sel = uigetdir(app.pipeline_dir, 'Selecciona la carpeta de campaña');
            if isequal(carpeta_sel, 0), return; end

            db_file = fullfile(carpeta_sel, 'basededatos.csv');
            if ~isfile(db_file)
                uialert(app.fig, ...
                    'La carpeta seleccionada no contiene basededatos.csv.', 'Error');
                return;
            end

            app.log_tab(U.log, ['Cargando campaña desde: ' carpeta_sel]);

            % ── Determinar nombre de campaña ─────────────────────────────
            % Si la carpeta ya está dentro de Resultados/, usar nombre relativo.
            res_base = fullfile(app.pipeline_dir, 'Resultados');
            if numel(carpeta_sel) > numel(res_base) && ...
               strncmpi(carpeta_sel, res_base, numel(res_base))
                nombre_camp = strtrim(carpeta_sel(numel(res_base)+2:end));
                % Solo usar nombre relativo si es subcarpeta directa (sin separador)
                if ~contains(nombre_camp, {'\','/'})
                    app.guardar_campana(nombre_camp);
                    app.log_tab(U.log, ['  Campaña reconocida: ' nombre_camp]);
                else
                    app.guardar_campana(carpeta_sel);
                end
            else
                % Carpeta externa: usar ruta absoluta
                app.guardar_campana(carpeta_sel);
                app.log_tab(U.log, '  Campaña externa (fuera de Resultados/). Ruta absoluta guardada.');
            end

            % ── Estadísticas rápidas ─────────────────────────────────────
            try
                data_tmp = readtable(db_file);
                n_tot    = height(data_tmp);
                if ismember('energy', data_tmp.Properties.VariableNames)
                    n_ok = sum(isfinite(data_tmp.energy));
                else
                    n_ok = 0;
                end

                d_sim = dir(fullfile(carpeta_sel,'Sim_*'));
                n_sim_dirs = sum([d_sim.isdir]);
                has_model  = isfile(fullfile(carpeta_sel,'modelo_surrogate.mat'));
                has_opt    = isfile(fullfile(carpeta_sel,'optimo_GA.mat'));

                if has_model, sm = 'Sí'; else, sm = 'No'; end
                if has_opt,   so = 'Sí'; else, so = 'No'; end

                app.log_tab(U.log, sprintf(...
                    '  Filas: %d  |  Con energy: %d  |  Carpetas Sim_*: %d', ...
                    n_tot, n_ok, n_sim_dirs));
                app.log_tab(U.log, sprintf(...
                    '  Modelo surrogate: %s  |  Óptimo GA: %s', sm, so));
                app.log_tab(U.log, '  ✓ Campaña activa actualizada. Puedes ir a Entrenamiento, GA o Visor.');

                U.lbl_camp.Text = ['Campaña: ' app.campana];
                U.lbl_prog.Text = sprintf('%d filas  |  %d con datos  |  %d Sim_*', ...
                    n_tot, n_ok, n_sim_dirs);
                app.set_prog(U.prog_outer, U.prog_inner, n_ok / max(n_tot,1));
            catch ex
                app.log_tab(U.log, ['  Error leyendo basededatos.csv: ' ex.message]);
            end
            app.sincronizar_dir_x(carpeta_sel);
        end

        % ---------------------------------------------------------------
        function cb_ver_log(app)
        % Abre una ventana emergente con el log de la última simulación.
        % Busca primero mechanical_run.log en la raíz; si no, en la última Sim_NNN/.
        % ---------------------------------------------------------------
            log_f = fullfile(app.pipeline_dir, 'mechanical_run.log');
            titulo = 'Log ANSYS — última simulación';

            if ~isfile(log_f)
                % Buscar en carpetas de simulación, de más reciente a más antigua
                if ~isempty(app.campana)
                    d = dir(fullfile(app.ruta_campana(),'Sim_*'));
                    d = d([d.isdir]);
                    if ~isempty(d)
                        [~, ord] = sort({d.name});
                        d = d(fliplr(ord));
                        for k = 1:numel(d)
                            cand = fullfile(d(k).folder, d(k).name, 'mechanical_run.log');
                            if isfile(cand)
                                log_f = cand;
                                titulo = ['Log ANSYS — ' d(k).name];
                                break;
                            end
                        end
                    end
                end
            end

            if ~isfile(log_f)
                uialert(app.fig, 'No se encontró mechanical_run.log.', 'Sin log');
                return;
            end

            try, content = fileread(log_f); catch ex
                uialert(app.fig, ['No se pudo leer: ' ex.message], 'Error'); return;
            end
            lines = strsplit(content, newline);

            fw = uifigure('Name', titulo, 'Position', [150 80 960 620]);
            uilabel(fw,'Text',log_f,'Position',[8 590 944 22],...
                'FontSize',8,'FontColor',[0.5 0.5 0.5],'WordWrap','on');
            uitextarea(fw,'Position',[8 10 944 575],...
                'Editable','off','FontSize',8,'FontName','Courier New','Value',lines);
        end

        function alias = alias_columna(~, col)
            % Alias comunes para tolerancia de nombres distintos
            mapa = {
                'energy',           {'Energy_J','Energia_J','E_J','Energia'};
                'stress',           {'Stress_Max_Pa','Stress','Tension','sigma'};
                'force',            {'Force_N','Fuerza_N','Fuerza','F_N'};
                'mass_kg',          {'Mass_kg','Masa_kg','Weight_N','Peso_N','Peso','W_N'};
                'energy_per_mass',  {'Energy_per_Mass_J_kg','EPM','epm','E_kg'};
                'valid_ansys',      {'Valid','Valido','valid'};
                'sim_time_s',       {'t_sim','tiempo','time_s'};
                'y_max_stress_mm',  {'Y_Max_Stress','Y_Max','y_max'};
                'b1',               {'b','B1','ancho','width'};
                'b2',               {'b','B2'};
                'e_cartela',        {'e_c','ec','espesor_cartela','e_cart'};
            };
            alias = {};
            for k = 1:size(mapa,1)
                if strcmp(mapa{k,1}, col)
                    alias = mapa{k,2};
                    return;
                end
            end
        end


        function cb_actualizar_desp_doe(app)
            if ~isfield(app.U,'doe'), return; end
            U = app.U.doe;
            ang   = U.angulo.Value;
            l     = U.l_fijo.Value;
            if startsWith(U.dir_x.Value,'+'), signo = 1; else, signo = -1; end
            d_mm  = signo * l * sind(ang);
            U.lbl_desp.Text = sprintf('≈ %+.0f mm en X', d_mm);
        end

        function sincronizar_dir_x(app, carpeta)
            % Actualiza el dropdown Dir. X del DOE desde meta_campana.mat de la carpeta dada
            meta_f = fullfile(carpeta, 'meta_campana.mat');
            if ~isfile(meta_f), return; end
            try
                m = load(meta_f, 'meta');
                if isfield(m.meta, 'dir_x') && isfield(app.U, 'doe') && ...
                   isfield(app.U.doe, 'dir_x') && isvalid(app.U.doe.dir_x)
                    if m.meta.dir_x > 0
                        app.U.doe.dir_x.Value = '+X  (invertida)';
                    else
                        app.U.doe.dir_x.Value = '-X  (ECE R66 estándar)';
                    end
                end
            catch, end
        end

        function s = dir_x_sign(app)
            % Lee la dirección del dropdown del tab DOE (guardado también en meta_campana.mat)
            if isfield(app.U,'doe') && isfield(app.U.doe,'dir_x') && ...
               isvalid(app.U.doe.dir_x)
                if startsWith(app.U.doe.dir_x.Value, '+')
                    s = 1;
                else
                    s = -1;
                end
            else
                s = -1;  % default ECE R66
            end
        end

        function cb_stop_sim(app)
        % Activa el flag de parada. El bucle de cb_sim lo comprueba entre sims.
            app.stop_requested = true;
            if isfield(app.U,'sim') && isfield(app.U.sim,'lbl_prog') && isvalid(app.U.sim.lbl_prog)
                app.U.sim.lbl_prog.Text = '⏹ Detención solicitada — esperando fin de sim actual...';
            end
            app.log_tab(app.U.sim.log, '⏹ DETENCIÓN solicitada por el usuario.');
        end

        function cb_sim(app)
            app.stop_requested = false;  % Resetear flag al inicio de cada batch
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'Genera un DOE primero.','Sin campaña'); return;
            end
            U = app.U.sim;
            U.lbl_camp.Text = ['Campaña: ' app.campana];

            carpeta   = app.ruta_campana();
            arch_db   = fullfile(carpeta,'basededatos.csv');
            if ~isfile(arch_db)
                uialert(app.fig,'No se encuentra basededatos.csv.','Error'); return;
            end

            meta_f = fullfile(carpeta,'meta_campana.mat');
            if isfile(meta_f), m=load(meta_f,'meta'); meta=m.meta;
            else, meta.fy_pa=235500000; meta.Et_pa=1160000000; meta.angulo=30; meta.c_fijo=80;
            end

            data = readtable(arch_db);
            nr   = height(data);
            cols = {'stress','force','mass_kg','energy_per_mass','sim_time_s',...
                    'y_max_stress_mm','valid_ansys','pivot_height_mm','lever_arm_mm'};
            for k=1:numel(cols)
                if ~ismember(cols{k},data.Properties.VariableNames)
                    data.(cols{k}) = NaN(nr,1);
                end
            end
            if ~ismember('energy',data.Properties.VariableNames)
                data.energy = NaN(nr,1);
            end
            if ~ismember('modo_fallo',data.Properties.VariableNames)
                data.modo_fallo = repmat({'N/A'},nr,1);
            end

            idx = find(isnan(data.energy));
            nt  = numel(idx);
            app.log_tab(U.log,sprintf('Pendientes: %d / %d',nt,nr));

            if ~isfile(app.ansys_path)
                uialert(app.fig,['ANSYS no encontrado: ' app.ansys_path],'Error'); return;
            end
            app.preparar_journal();
            journal_gen = fullfile(app.pipeline_dir,'journal_generado.wbjn');
            csv_out     = fullfile(app.pipeline_dir,'parametrossalida.csv');

            for ii = 1:nt
                % --- Comprobar si el usuario ha pedido detener ---
                if app.stop_requested
                    app.log_tab(U.log, sprintf('⏹ Batch detenido por el usuario tras %d/%d sims.', ii-1, nt));
                    U.lbl_prog.Text = sprintf('⏹ Detenido en sim %d/%d. Puedes relanzar para continuar.', ii-1, nt);
                    writetable(data, arch_db);
                    break;
                end
                n = idx(ii);
                t_sim = tic;

                m1=data.m1(n); a1=data.a1(n); b1=data.b1(n); l1=data.l1(n);
                m2=data.m2(n); a2=data.a2(n); b2=data.b2(n); l2=data.l2(n);
                c=data.c(n);   ec=data.e_cartela(n);

                app.generar_script_sc(m1,a1,b1,l1,m2,a2,b2,l2,c,ec);
                if isfile(csv_out), delete(csv_out); end

                setenv('TFG_PIPELINE_DIR',strrep(app.pipeline_dir,'\','/'));
                setenv('TFG_BATCH_MODE','1');
                setenv('TFG_CAMPAIGN_NAME',app.campana);
                setenv('TFG_SIM_ID',sprintf('%03d',n));
                setenv('TFG_PARAM_B_MM',num2str(b1,'%.4f'));
                char_dim = (a1 + a2 + 2*b1) / 4;
                setenv('TFG_CHAR_DIM_MM', num2str(char_dim,'%.4f'));
                setenv('TFG_C_MM',num2str(c,'%.4f'));
                setenv('TFG_LONGITUD_VIGA_MM',num2str(l1,'%.4f'));
                setenv('TFG_ANGULO_DESPLAZAMIENTO_DEG',num2str(meta.angulo,'%.4f'));
                setenv('TFG_DIR_X',num2str(app.dir_x_sign(),'%d'));
                setenv('TFG_YIELD_PA',num2str(meta.fy_pa,'%.10g'));
                setenv('TFG_TANGENT_MODULUS_PA',num2str(meta.Et_pa,'%.10g'));
                % Substeps y malla desde GUI
                setenv('TFG_SUBSTEPS_INIT', num2str(U.ss_init.Value));
                setenv('TFG_SUBSTEPS_MIN',  num2str(U.ss_min.Value));
                setenv('TFG_SUBSTEPS_MAX',  num2str(U.ss_max.Value));
                setenv('TFG_MESH_RESOLUTION', num2str(U.mesh_res.Value));
                setenv('TFG_MESH_SOI_RADIUS', num2str(U.mesh_soi.Value,'%.1f'));
                setenv('TFG_MESH_COARSE_DIV', num2str(U.mesh_coarse_div.Value));
                setenv('TFG_MESH_FINE_DIV',   num2str(U.mesh_fine_div.Value));
                setenv('TFG_MESH_FINE_MIN_MM', num2str(U.mesh_fine_min.Value,'%.2f'));
                setenv('TFG_MESH_FINE_MAX_MM', num2str(U.mesh_fine_max.Value,'%.2f'));

                dos(sprintf('start "" "%s" -B -R "%s"',app.ansys_path,journal_gen));
                U.lbl_prog.Text = sprintf('Sim %d/%d  (fila %d) — esperando ANSYS...',ii,nt,n);
                app.set_prog(U.prog_outer, U.prog_inner, (ii-1)/nt);
                app.log_tab(U.log,sprintf('Sim %d/%d fila=%d lanzada',ii,nt,n));

                if app.esperar_csv(csv_out,10800,U.log)
                    try
                        T = readtable(csv_out);
                        data.energy(n)          = T{1,'Energy_J'};
                        data.force(n)           = T{1,'Force_N'};
                        data.stress(n)          = T{1,'Stress_Max_Pa'};
                        data.mass_kg(n)         = T{1,'Mass_kg'};
                        data.energy_per_mass(n) = T{1,'Energy_per_Mass_J_kg'};
                        if ismember('Y_Max_Stress_mm',T.Properties.VariableNames)
                            data.y_max_stress_mm(n) = T{1,'Y_Max_Stress_mm'};
                        end
                        if ismember('Valid',T.Properties.VariableNames)
                            data.valid_ansys(n) = T{1,'Valid'};
                        end
                        [ph,la,mf] = calcular_pivot(data.y_max_stress_mm(n),c,a1,a2,l1);
                        data.pivot_height_mm(n) = ph;
                        data.lever_arm_mm(n)    = la;
                        data.modo_fallo{n}       = mf;
                        app.log_tab(U.log,sprintf('  → E=%.1f J | EPM=%.2f J/kg | Modo: %s (Y=%.0f mm, c=%.0f mm)',...
                            data.energy(n),data.energy_per_mass(n),mf,data.y_max_stress_mm(n),c));
                    catch ex
                        app.log_tab(U.log,['  ERROR: ' ex.message]);
                        data.energy(n) = NaN;
                    end
                else
                    app.log_tab(U.log,'  TIMEOUT — sim marcada como NaN');
                    data.energy(n) = NaN;
                end

                data.sim_time_s(n) = toc(t_sim);
                writetable(data,arch_db);

                % Copiar log de Mechanical a la carpeta de la simulación
                log_src = fullfile(app.pipeline_dir,'mechanical_run.log');
                sim_dir_n = fullfile(carpeta, sprintf('Sim_%03d',n));
                if isfile(log_src) && isfolder(sim_dir_n)
                    try, copyfile(log_src, fullfile(sim_dir_n,'mechanical_run.log')); catch, end
                end

                % Generar Graficas_Completas.png desde Curvas.csv
                curvas_f = fullfile(carpeta,sprintf('Sim_%03d',n),'Curvas.csv');
                if isfile(curvas_f)
                    try
                        app.generar_graficas_sim(curvas_f,...
                            fullfile(carpeta,sprintf('Sim_%03d',n),'Graficas_Completas.png'),...
                            data.pivot_height_mm(n), data.lever_arm_mm(n), n);
                    catch, end
                end

                app.set_prog(U.prog_outer, U.prog_inner, ii/nt);
            end

            n_ok = sum(isfinite(data.energy));
            app.log_tab(U.log,sprintf('Batch completado. Válidas: %d/%d',n_ok,nr));
            if ismember('modo_fallo',data.Properties.VariableNames)
                mf_vals   = data.modo_fallo(isfinite(data.energy));
                n_viga    = sum(strcmp(mf_vals,'Viga'));
                n_cartela = sum(strcmp(mf_vals,'Cartela'));
                n_hibrido = sum(strcmp(mf_vals,'Hibrido'));
                app.log_tab(U.log,sprintf('Modos de fallo → Viga: %d (%.0f%%)  |  Cartela: %d (%.0f%%)  |  Hibrido: %d (%.0f%%)',...
                    n_viga, 100*n_viga/max(n_ok,1), n_cartela, 100*n_cartela/max(n_ok,1), n_hibrido, 100*n_hibrido/max(n_ok,1)));
            end
            U.lbl_prog.Text = sprintf('Completado: %d válidas / %d total',n_ok,nr);
        end

        % ---------------------------------------------------------------
        % TAB 3 — ENTRENAMIENTO
        % ---------------------------------------------------------------
        function tab_train(app, par)
            U = struct();
            uilabel(par,'Text','Comparación y selección de modelos sustitutos',...
                'Position',[12 630 700 24],'FontSize',12,'FontWeight','bold');

            % ── Botones (fila 1: entrenar + config + cargar; fila 2: guardar) ──
            U.btn = uibutton(par,'Text','▶  Entrenar todos',...
                'Position',[12 596 142 30],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_train());
            uibutton(par,'Text','⚙  Configurar',...
                'Position',[162 596 118 30],...
                'BackgroundColor',app.COL_GRIS,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_opciones_train());
            uibutton(par,'Text','📂  Cargar externo',...
                'Position',[288 596 135 30],...
                'BackgroundColor',app.COL_AZUL,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_cargar_modelo());
            uibutton(par,'Text','🖼  Guardar gráficas',...
                'Position',[428 596 114 30],...
                'BackgroundColor',app.COL_AZUL2,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'Tooltip','Exporta los 3 diagnósticos a PNG con fondo blanco y título, a 300 ppp',...
                'ButtonPushedFcn',@(~,~) app.guardar_diagnostico_limpio());
            uibutton(par,'Text','💾  Guardar en campaña',...
                'Position',[12 560 155 30],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_usar_modelo());
            uibutton(par,'Text','💾  Guardar como...',...
                'Position',[177 560 148 30],...
                'BackgroundColor',app.COL_AZUL,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_guardar_modelo_como());
            uibutton(par,'Text','📊  Análisis por modo',...
                'Position',[335 560 168 30],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'Tooltip','Compara IAv (Viga) vs IAc (Cartela) vs IA_0 (global)',...
                'ButtonPushedFcn',@(~,~) app.abrir_analisis_modo());

            U.lbl_status = uilabel(par,'Text','','Position',[12 528 518 28],...
                'FontSize',9,'WordWrap','on');

            % ── Tabla de comparación (izquierda) ─────────────────────────
            uilabel(par,'Text','Modelos entrenados — clic para seleccionar:',...
                'Position',[12 516 380 20],'FontSize',9,'FontWeight','bold');
            U.tabla_mod = uitable(par,'Position',[12 272 530 240],...
                'ColumnName',{'Modelo','RMSE CV (J)','R²','Tiempo (s)'},...
                'ColumnWidth',{180,90,60,80},...
                'RowName',{},'FontSize',9,...
                'SelectionType','row',...
                'CellSelectionCallback',@(~,e) app.cb_model_row(e));

            uilabel(par,'Text','Predictores activos:','Position',[12 248 120 20],'FontSize',9);
            U.lbl_pred = uilabel(par,'Text','—','Position',[134 248 408 20],...
                'FontSize',9,'FontColor',[0.2 0.2 0.6]);

            uilabel(par,'Text','Muestras válidas:','Position',[12 226 120 20],'FontSize',9);
            U.lbl_nval = uilabel(par,'Text','—','Position',[134 226 100 20],'FontSize',9);

            U.log = uitextarea(par,'Position',[12 10 530 210],...
                'Editable','off','FontSize',8,'FontName','Consolas','Value',{'Listo.'});

            % ── Plots (derecha) ──────────────────────────────────────────
            uilabel(par,'Text','Predicho vs Real (validación cruzada 5-fold):',...
                'Position',[552 630 460 20],'FontSize',9,'FontWeight','bold');
            U.ax_scatter = uiaxes(par,'Position',[552 400 575 228]);
            xlabel(U.ax_scatter,'Real (J)'); ylabel(U.ax_scatter,'Predicho (J)');
            title(U.ax_scatter,'Selecciona un modelo'); grid(U.ax_scatter,'on');
            axis(U.ax_scatter,'equal');

            uilabel(par,'Text','Residuos (Predicho − Real):',...
                'Position',[552 388 300 18],'FontSize',9,'FontWeight','bold');
            U.ax_resid = uiaxes(par,'Position',[552 168 575 218]);
            xlabel(U.ax_resid,'Real (J)'); ylabel(U.ax_resid,'Residuo (J)');
            title(U.ax_resid,'—'); grid(U.ax_resid,'on');

            uilabel(par,'Text','Distribución de residuos:',...
                'Position',[552 156 300 18],'FontSize',9,'FontWeight','bold');
            U.ax_hist = uiaxes(par,'Position',[552 10 575 145]);
            xlabel(U.ax_hist,'Residuo (J)'); ylabel(U.ax_hist,'Frecuencia');
            grid(U.ax_hist,'on');

            app.U.train = U;
        end

        function cb_train(app)
            rng(0);
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U = app.U.train;
            arch = fullfile(app.ruta_campana(),'basededatos.csv');
            if ~isfile(arch), uialert(app.fig,'No hay basededatos.csv.','Error'); return; end

            data = readtable(arch);
            mask = isfinite(data.energy) & data.energy > 0;
            if ismember('mass_kg',data.Properties.VariableNames) && any(isfinite(data.mass_kg))
                mask = mask & isfinite(data.mass_kg) & data.mass_kg > 0;
            end
            if ismember('valid_ansys',data.Properties.VariableNames) && any(data.valid_ansys == 1)
                mask = mask & data.valid_ansys == 1;
            end
            data = data(mask,:);
            nv = height(data);
            U.lbl_nval.Text = num2str(nv);
            app.log_tab(U.log,sprintf('Muestras válidas: %d',nv));
            if nv < 10
                uialert(app.fig,'Menos de 10 muestras válidas.','Datos insuficientes'); return;
            end

            % Guardar dataset limpio (equivalente a T03)
            nombre_csv = sprintf('dataset_%d_muestras_limpio.csv', nv);
            ruta_limpio = fullfile(app.ruta_campana(), nombre_csv);
            writetable(data, ruta_limpio);
            app.log_tab(U.log, ['Dataset limpio guardado: ' nombre_csv]);

            cands = {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'};
            activo = cellfun(@(v) ismember(v,data.Properties.VariableNames) && std(data.(v))>1e-10, cands);
            pred_names = cands(activo);

            % Eliminar columnas redundantes (ej. b2 = b1 siempre) para
            % evitar rango deficiente en modelos lineales (fitlm).
            Xcheck = table2array(data(:, pred_names));
            to_keep = true(1, numel(pred_names));
            for ii_ = 1:numel(pred_names)
                if ~to_keep(ii_), continue; end
                for jj_ = ii_+1:numel(pred_names)
                    if to_keep(jj_) && std(Xcheck(:,ii_) - Xcheck(:,jj_)) < 1e-10
                        to_keep(jj_) = false;
                    end
                end
            end
            pred_names = pred_names(to_keep);

            U.lbl_pred.Text = strjoin(pred_names,', ');
            app.log_tab(U.log,['Predictores: ' strjoin(pred_names,', ')]);

            Xt = data(:,pred_names);  yt = data.energy;

            % ── Split holdout (si el modo lo requiere) ────────────────────
            hp_  = app.hp;
            Xt_ho = table.empty; yt_ho = [];
            if strcmp(hp_.val_mode,'holdout') || strcmp(hp_.val_mode,'kfold_holdout')
                n_ho  = max(1, round(hp_.holdout_frac * nv));
                n_tr  = nv - n_ho;
                if n_tr < 5
                    uialert(app.fig,'Datos de entrenamiento insuficientes con esa fracción holdout.','Error'); return;
                end
                idx_p  = randperm(nv);
                idx_tr = sort(idx_p(1:n_tr));
                idx_ho = sort(idx_p(n_tr+1:end));
                Xt_ho  = Xt(idx_ho,:);  yt_ho = yt(idx_ho);
                Xt     = Xt(idx_tr,:);  yt    = yt(idx_tr);
                nv     = n_tr;
                app.log_tab(U.log, sprintf('Split: %d entrenamiento / %d test (holdout %.0f%%)', n_tr, n_ho, hp_.holdout_frac*100));
            end

            ss_tot = sum((yt - mean(yt)).^2);
            Xm   = table2array(Xt);   % para modelos que no aceptan tabla

            % Parámetros de ensemble y SVM
            t_ens = templateTree('MinLeafSize', hp_.ens_leafsize);
            nc = hp_.ens_cycles;  lr = hp_.ens_lr;  bc = hp_.svm_box;
            gb = hp_.gpr_basis;

            % KernelScale para SVM Gaussiana (fino/medio/grueso como en RL)
            nf = numel(pred_names);
            ks_fine   = max(sqrt(nf)/4,   0.01);
            ks_med    = max(sqrt(nf),      0.10);
            ks_coarse = max(sqrt(nf)*4,   1.00);

            % Recetas: {nombre, @fn, cv_mode, grupo_flag}
            %   cv_mode = true   → crossval estándar, predict con tabla
            %   cv_mode = false  → crossval estándar, predict con matriz
            %   cv_mode = 'fitlm'→ k-fold manual; fn recibe (Xtr_tabla, ytr)
            robust_opts_ = struct('WgtFun','bisquare','MaxIter',200);
            recetas = { ...
                % ── Árboles (Fine / Medium / Coarse) ─────────────────────
                'Árbol Fino',          @() fitrtree(Xt,yt,'MinLeafSize',1),   true,  hp_.grupos.trees; ...
                'Árbol Medio',         @() fitrtree(Xt,yt,'MinLeafSize',4),   true,  hp_.grupos.trees; ...
                'Árbol Grueso',        @() fitrtree(Xt,yt,'MinLeafSize',36),  true,  hp_.grupos.trees; ...
                % ── Regresión Lineal (OLS, Interacciones, Robusto, Stepwise)
                'Lineal (OLS)',        @(X,y) fitlm(X,y),                                                    'fitlm', hp_.grupos.lineal; ...
                'Lineal Interacc.',    @(X,y) fitlm(X,y,'interactions'),                                     'fitlm', hp_.grupos.lineal; ...
                'Lineal Robusto',      @(X,y) fitlm(X,y,'RobustOpts',robust_opts_),                         'fitlm', hp_.grupos.lineal; ...
                'Stepwise Lineal',     @(X,y) stepwiselm(X,y,'linear','Upper','quadratic','Verbose',0),      'fitlm', hp_.grupos.lineal; ...
                % ── SVM ─────────────────────────────────────────────────
                'SVM Lineal',          @() fitrsvm(Xt,yt,'KernelFunction','linear',    'Standardize',true,'BoxConstraint',bc),                            true, hp_.grupos.svm; ...
                'SVM Cuadrática',      @() fitrsvm(Xt,yt,'KernelFunction','polynomial','PolynomialOrder',2,'Standardize',true,'BoxConstraint',bc),         true, hp_.grupos.svm; ...
                'SVM Cúbica',          @() fitrsvm(Xt,yt,'KernelFunction','polynomial','PolynomialOrder',3,'Standardize',true,'BoxConstraint',bc),         true, hp_.grupos.svm; ...
                'SVM Gauss. Fina',     @() fitrsvm(Xt,yt,'KernelFunction','rbf','KernelScale',ks_fine,  'Standardize',true,'BoxConstraint',bc),            true, hp_.grupos.svm; ...
                'SVM Gauss. Media',    @() fitrsvm(Xt,yt,'KernelFunction','rbf','KernelScale',ks_med,   'Standardize',true,'BoxConstraint',bc),            true, hp_.grupos.svm; ...
                'SVM Gauss. Gruesa',   @() fitrsvm(Xt,yt,'KernelFunction','rbf','KernelScale',ks_coarse,'Standardize',true,'BoxConstraint',bc),            true, hp_.grupos.svm; ...
                % ── Lineal Eficiente ─────────────────────────────────────
                'Ef. Lineal LS',  @(X,y) fitrlinear(table2array(X),y,'Learner','leastsquares','Regularization','ridge','Lambda',1e-4), 'fitlm', hp_.grupos.lineal; ...
                'Ef. Lineal SVM', @(X,y) fitrlinear(table2array(X),y,'Learner','svm',         'Regularization','ridge','Lambda',1e-4), 'fitlm', hp_.grupos.lineal; ...
                % ── Ensemble ────────────────────────────────────────────
                sprintf('Boosted Trees x%d',nc), @() fitrensemble(Xt,yt,'Method','LSBoost','NumLearningCycles',nc,'Learners',t_ens,'LearnRate',lr), true, hp_.grupos.ensemble; ...
                sprintf('Bagged Trees  x%d',nc), @() fitrensemble(Xt,yt,'Method','Bag',    'NumLearningCycles',nc,'Learners',t_ens),                 true, hp_.grupos.ensemble; ...
                % ── GPR ─────────────────────────────────────────────────
                'GPR Sq.Exp.',         @() fitrgp(Xt,yt,'KernelFunction','squaredexponential','BasisFunction',gb,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'GPR Matern 5/2',      @() fitrgp(Xt,yt,'KernelFunction','matern52',          'BasisFunction',gb,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'GPR Exponencial',     @() fitrgp(Xt,yt,'KernelFunction','exponential',        'BasisFunction',gb,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'GPR Rat.Cuad.',       @() fitrgp(Xt,yt,'KernelFunction','rationalquadratic',  'BasisFunction',gb,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                % ── Redes Neuronales ─────────────────────────────────────
                'Red Estrecha [10]',      @() fitrnet(Xt,yt,'LayerSizes',10,          'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Media [25]',         @() fitrnet(Xt,yt,'LayerSizes',25,          'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Ancha [100]',        @() fitrnet(Xt,yt,'LayerSizes',100,         'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Bicapa [10 10]',     @() fitrnet(Xt,yt,'LayerSizes',[10 10],    'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Tricapa [10 10 10]', @() fitrnet(Xt,yt,'LayerSizes',[10 10 10],'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                % ── Kernel ──────────────────────────────────────────────
                'Kernel SVM (Gauss)', @(X,y) fitrkernel(table2array(X),y,'Learner','svm',         'Standardize',true), 'fitlm', hp_.grupos.kernel; ...
                'Kernel LS (Gauss)',  @(X,y) fitrkernel(table2array(X),y,'Learner','leastsquares','Standardize',true), 'fitlm', hp_.grupos.kernel; ...
            };

            % Filtrar por grupos activos
            mask_grp = cell2mat(recetas(:,4));
            recetas  = recetas(mask_grp, :);
            app.log_tab(U.log, sprintf('Modelos a entrenar: %d  |  K-fold: %d', ...
                size(recetas,1), hp_.kfold));

            app.modelos_cache = [];
            tabla_data = {};

            for k = 1:size(recetas,1)
                nombre_k = recetas{k,1};
                cv_mode  = recetas{k,3};
                app.log_tab(U.log,sprintf('[%d/%d] %s...', k, size(recetas,1), nombre_k));
                drawnow;
                t0 = tic;
                try
                    pn = pred_names;
                    val_mode_ = hp_.val_mode;

                    if strcmp(val_mode_,'holdout')
                        % ── Holdout: entrenar en Xt, predecir en Xt_ho ──────
                        if ischar(cv_mode) && strcmp(cv_mode,'fitlm')
                            fn_ = recetas{k,2};
                            mdl_k = fn_(Xt, yt);
                            needs_mx = isa(mdl_k,'RegressionKernel') || isa(mdl_k,'RegressionLinear');
                            if needs_mx
                                yh = predict(mdl_k, table2array(Xt_ho(:,pn)));
                                pfcn = @(t) predict(mdl_k, table2array(t(:,pn)));
                            else
                                yh = predict(mdl_k, Xt_ho(:,pn));
                                pfcn = @(t) predict(mdl_k, t(:,pn));
                            end
                        else
                            usa_tabla = cv_mode;
                            mdl_k = recetas{k,2}();
                            if usa_tabla
                                yh = predict(mdl_k, Xt_ho(:,pn));
                                pfcn = @(t) predict(mdl_k, t(:,pn));
                            else
                                yh = predict(mdl_k, table2array(Xt_ho(:,pn)));
                                pfcn = @(t) predict(mdl_k, table2array(t(:,pn)));
                            end
                        end
                        ss_ho  = max(sum((yt_ho - mean(yt_ho)).^2), eps);
                        rmse_k = sqrt(mean((yh - yt_ho).^2));
                        r2_k   = 1 - sum((yh - yt_ho).^2) / ss_ho;
                        ypred_cv = yh;

                    elseif ischar(cv_mode) && strcmp(cv_mode,'fitlm')
                        % Modelos fitlm/stepwiselm/fitrkernel: k-fold manual
                        fn_fitlm = recetas{k,2};   % @(Xtr,ytr) fitXXX(...)
                        cvp = cvpartition(nv,'KFold',hp_.kfold);
                        ypred_cv = zeros(nv,1);
                        % Detectar si el modelo necesita matriz (fitrkernel)
                        % entrenando un fold de prueba
                        m_probe = fn_fitlm(Xt(training(cvp,1),:), yt(training(cvp,1)));
                        usa_matrix_pred = isa(m_probe,'RegressionKernel') || isa(m_probe,'RegressionLinear');
                        clear m_probe;
                        for fold = 1:hp_.kfold
                            tr_idx = training(cvp,fold);
                            te_idx = test(cvp,fold);
                            m_fold = fn_fitlm(Xt(tr_idx,:), yt(tr_idx));
                            if usa_matrix_pred
                                ypred_cv(te_idx) = predict(m_fold, table2array(Xt(te_idx,:)));
                            else
                                ypred_cv(te_idx) = predict(m_fold, Xt(te_idx,:));
                            end
                        end
                        mdl_k = fn_fitlm(Xt, yt);
                        if usa_matrix_pred
                            pfcn = @(t) predict(mdl_k, table2array(t(:,pn)));
                        else
                            pfcn = @(t) predict(mdl_k, t(:,pn));
                        end
                    else
                        usa_tabla = cv_mode;
                        mdl_k    = recetas{k,2}();
                        if isa(mdl_k,'RegressionNeuralNetwork')
                            ws = warning('off','all');
                            cv_k = crossval(mdl_k,'KFold',hp_.kfold);
                            warning(ws);
                        else
                            cv_k = crossval(mdl_k,'KFold',hp_.kfold);
                        end
                        ypred_cv = kfoldPredict(cv_k);
                        if usa_tabla
                            pfcn = @(t) predict(mdl_k, t(:,pn));
                        else
                            pfcn = @(t) predict(mdl_k, table2array(t(:,pn)));
                        end
                    end

                    if ~strcmp(val_mode_,'holdout')
                        rmse_k = sqrt(mean((ypred_cv - yt).^2));
                        r2_k   = 1 - sum((ypred_cv - yt).^2)/ss_tot;
                    end
                    t_s    = toc(t0);

                    entry.nombre      = nombre_k;
                    entry.mdl         = mdl_k;
                    entry.predictFcn  = pfcn;
                    entry.rmse        = rmse_k;
                    entry.r2          = r2_k;
                    entry.t_s         = t_s;
                    entry.ypred_cv    = ypred_cv;
                    entry.ytrue       = yt;
                    entry.pred_names  = pred_names;
                    if isempty(app.modelos_cache)
                        app.modelos_cache = entry;
                    else
                        app.modelos_cache(end+1) = entry;
                    end
                    tabla_data{end+1} = {nombre_k, round(rmse_k,2), round(r2_k,4), round(t_s,1)};
                    if strcmp(val_mode_,'holdout')
                        app.log_tab(U.log,sprintf('  → RMSE test=%.2f J  R²=%.4f  t=%.1f s', rmse_k, r2_k, t_s));
                    else
                        app.log_tab(U.log,sprintf('  → RMSE CV=%.2f J  R²=%.4f  t=%.1f s', rmse_k, r2_k, t_s));
                    end
                catch ex
                    app.log_tab(U.log,['  ✗ Error: ' ex.message]);
                end
            end

            if isempty(tabla_data)
                uialert(app.fig,'Ningún modelo pudo entrenarse.','Error'); return;
            end

            % ── Ordenar por RMSE y marcar el mejor ──────────────────────
            rmses = [app.modelos_cache.rmse];
            [~, sort_idx] = sort(rmses);
            app.modelos_cache = app.modelos_cache(sort_idx);
            tabla_data = tabla_data(sort_idx);

            best_idx = 1;

            % Evaluación holdout final del mejor modelo (solo en modo kfold_holdout)
            if strcmp(hp_.val_mode,'kfold_holdout') && ~isempty(yt_ho)
                try
                    best_pre = app.modelos_cache(best_idx);
                    yh_best  = best_pre.predictFcn(Xt_ho);
                    rmse_ho  = sqrt(mean((yh_best - yt_ho).^2));
                    r2_ho    = 1 - sum((yh_best - yt_ho).^2) / max(sum((yt_ho - mean(yt_ho)).^2), eps);
                    app.log_tab(U.log, sprintf('   Holdout final (%d muestras): RMSE=%.2f J  R²=%.4f', numel(yt_ho), rmse_ho, r2_ho));
                catch ex_ho
                    app.log_tab(U.log, ['   [Holdout] Error: ' ex_ho.message]);
                end
            end

            % Añadir estrella al mejor
            tabla_data{best_idx}{1} = ['★ ' tabla_data{best_idx}{1}];
            U.tabla_mod.Data = vertcat(tabla_data{:});
            app.estilo_tabla(U.tabla_mod, 2);

            % Auto-guardar CSV para generar_figura_comparativa_modelos.m
            try
                comp = cell2table(vertcat(tabla_data{:}), ...
                    'VariableNames', {'Modelo','RMSE_CV_J','R2_CV','Tiempo_s'});
                writetable(comp, fullfile(app.ruta_campana(), 'tabla_comparativa_modelos.csv'));
                app.log_tab(U.log, sprintf('   Tabla comparativa guardada (%d modelos).', numel(tabla_data)));
            catch ex_csv
                app.log_tab(U.log, ['   [Aviso] No se guardó tabla_comparativa_modelos.csv: ' ex_csv.message]);
            end

            best = app.modelos_cache(best_idx);
            app.actualizar_plots_modelo(best_idx);
            app.guardar_modelo_seleccionado(best_idx);

            % ── Clasificador de modo automático (Viga / Cartela) ─────────
            try
                if ismember('modo_fallo', data.Properties.VariableNames)
                    mask_cl = (strcmp(data.modo_fallo,'Viga') | ...
                               strcmp(data.modo_fallo,'Cartela') | ...
                               strcmp(data.modo_fallo,'Hibrido')) & ...
                              isfinite(data.energy) & data.energy > 0;
                    data_cl   = data(mask_cl, :);
                    target_cl = data_cl.modo_fallo;
                    target_cl(strcmp(target_cl,'Hibrido')) = {'Cartela'};
                    target_cat = categorical(target_cl);
                    Xcl = data_cl(:, pred_names);
                    n_cl = height(Xcl);
                    kf_cl = min(5, n_cl);
                    nv_cl = sum(strcmp(target_cl,'Viga'));
                    nc_cl = sum(strcmp(target_cl,'Cartela'));

                    app.log_tab(U.log, repmat('─',1,60));
                    app.log_tab(U.log, sprintf('CLASIFICADOR DE MODO  (%d Viga | %d Cartela)', nv_cl, nc_cl));

                    % Candidatos: misma filosofía que el surrogate
                    t_ce = templateTree('MinLeafSize',5);
                    nf_cl = numel(pred_names);
                    ks_cl = max(sqrt(nf_cl), 0.1);
                    candidatos_cl = {
                        'LDA',              @() fitcdiscr(Xcl, target_cat, 'DiscrimType','linear');
                        'QDA',              @() fitcdiscr(Xcl, target_cat, 'DiscrimType','quadratic');
                        'Árbol Fino',       @() fitctree(Xcl,  target_cat, 'MinLeafSize',1);
                        'Árbol Medio',      @() fitctree(Xcl,  target_cat, 'MinLeafSize',5);
                        'SVM Lineal',       @() fitcsvm(Xcl,   target_cat, 'KernelFunction','linear',  'Standardize',true);
                        'SVM RBF',          @() fitcsvm(Xcl,   target_cat, 'KernelFunction','rbf','KernelScale',ks_cl,'Standardize',true);
                        'KNN (k=1)',        @() fitcknn(Xcl,   target_cat, 'NumNeighbors',1,  'Standardize',true);
                        'KNN (k=5)',        @() fitcknn(Xcl,   target_cat, 'NumNeighbors',5,  'Standardize',true);
                        'Boosted Trees',    @() fitcensemble(Xcl, target_cat, 'Method','AdaBoostM1','NumLearningCycles',100,'Learners',t_ce);
                        'Bagged Trees',     @() fitcensemble(Xcl, target_cat, 'Method','Bag',        'NumLearningCycles',100,'Learners',t_ce);
                        'Naive Bayes',      @() fitcnb(Xcl,    target_cat);
                    };

                    best_acc = 0; best_cl_mdl = []; best_cl_nombre = '—';
                    pn_cl_ = pred_names;
                    for kc = 1:size(candidatos_cl,1)
                        try
                            m_cl  = candidatos_cl{kc,2}();
                            cv_cl = crossval(m_cl, 'KFold', kf_cl);
                            acc_k = 1 - kfoldLoss(cv_cl);
                            app.log_tab(U.log, sprintf('  %s: precisión CV=%.1f%%', candidatos_cl{kc,1}, 100*acc_k));
                            if acc_k > best_acc
                                best_acc      = acc_k;
                                best_cl_mdl   = m_cl;
                                best_cl_nombre = candidatos_cl{kc,1};
                            end
                        catch
                        end
                    end

                    if ~isempty(best_cl_mdl)
                        classifierModel.predictFcn    = @(t) cellstr(char(predict(best_cl_mdl, t(:,pn_cl_))));
                        classifierModel.ClassifierModel = best_cl_mdl;
                        classifierModel.predictorNames  = pred_names;
                        classifierModel.accuracy_cv     = best_acc;
                        classifierModel.modelo_tipo     = best_cl_nombre;

                        % Matriz de confusión CV: la accuracy sola engaña con
                        % clases desbalanceadas (un clasificador trivial acierta
                        % el % de la clase mayoritaria). Reportamos recall por
                        % clase y precisión balanceada (media de recalls).
                        try
                            cv_best = crossval(best_cl_mdl, 'KFold', kf_cl);
                            pred_cv = kfoldPredict(cv_best);
                            clases  = categories(target_cat);
                            CM = confusionmat(target_cat, pred_cv);
                            app.log_tab(U.log, '  Matriz de confusión (CV) — filas=real, columnas=predicho:');
                            cab = sprintf('%12s', '');
                            for ci = 1:numel(clases)
                                cab = [cab sprintf('%10s', clases{ci})]; %#ok<AGROW>
                            end
                            app.log_tab(U.log, ['  ' cab]);
                            recalls = zeros(numel(clases),1);
                            for ri = 1:numel(clases)
                                fila_txt = sprintf('%12s', clases{ri});
                                for ci = 1:numel(clases)
                                    fila_txt = [fila_txt sprintf('%10d', CM(ri,ci))]; %#ok<AGROW>
                                end
                                recalls(ri) = CM(ri,ri) / max(sum(CM(ri,:)), 1);
                                app.log_tab(U.log, sprintf('  %s   recall=%.1f%%', fila_txt, 100*recalls(ri)));
                            end
                            bal_acc = mean(recalls);
                            app.log_tab(U.log, sprintf('  Precisión balanceada (media de recalls): %.1f%%  |  accuracy: %.1f%%', ...
                                100*bal_acc, 100*best_acc));
                            classifierModel.confusion_cv          = CM;
                            classifierModel.clases                = clases;
                            classifierModel.balanced_accuracy_cv  = bal_acc;
                        catch ex_cm
                            app.log_tab(U.log, ['  (No se pudo calcular la matriz de confusión: ' ex_cm.message ')']);
                        end

                        ruta_mdl = fullfile(app.ruta_campana(), 'modelo_surrogate.mat');
                        save(ruta_mdl, 'classifierModel', '-append');
                        app.log_tab(U.log, sprintf('★ MEJOR CLASIFICADOR: %s  (precisión CV=%.1f%%)', best_cl_nombre, 100*best_acc));
                    end
                    app.log_tab(U.log, repmat('─',1,60));
                end
            catch ex_cl
                app.log_tab(U.log, ['[Aviso] Clasificador de modo: ' ex_cl.message]);
            end

            U.lbl_status.Text = sprintf('★ MEJOR: %s  —  RMSE %.2f J  |  R² %.4f  (de %d modelos entrenados)',...
                best.nombre, best.rmse, best.r2, numel(app.modelos_cache));
            U.lbl_status.FontColor = [0.08 0.45 0.08];
            app.log_tab(U.log, '');
            app.log_tab(U.log, repmat('─',1,60));
            app.log_tab(U.log, sprintf('★ MEJOR MODELO: %s', best.nombre));
            app.log_tab(U.log, sprintf('   RMSE CV: %.4f J    R²: %.4f    Tiempo: %.1f s', best.rmse, best.r2, best.t_s));
            app.log_tab(U.log, '   → Guardado como modelo_surrogate.mat');
            app.log_tab(U.log, repmat('─',1,60));
        end

        function cb_model_row(app, e)
            if isempty(e.Indices), return; end
            row = e.Indices(1);
            if row > numel(app.modelos_cache), return; end
            app.actualizar_plots_modelo(row);
            U = app.U.train;
            U.lbl_status.Text = sprintf('Seleccionado: %s (RMSE %.2f J) — pulsa "Usar" para guardar.',...
                app.modelos_cache(row).nombre, app.modelos_cache(row).rmse);
            U.lbl_status.FontColor = [0.3 0.3 0.7];
        end

        function cb_usar_modelo(app)
            U = app.U.train;
            sel = U.tabla_mod.Selection;
            if isempty(sel) || isempty(app.modelos_cache)
                uialert(app.fig,'Selecciona un modelo de la tabla primero.','Sin selección'); return;
            end
            row = sel(1);
            if row > numel(app.modelos_cache), return; end
            app.guardar_modelo_seleccionado(row);
            dest = fullfile(app.ruta_campana(),'modelo_surrogate.mat');
            U.lbl_status.Text = sprintf('✓ Guardado: %s (RMSE %.2f J)  →  %s',...
                app.modelos_cache(row).nombre, app.modelos_cache(row).rmse, dest);
            U.lbl_status.FontColor = [0.1 0.5 0.1];
            app.log_tab(U.log, sprintf('💾 Guardado en campaña: %s', dest));
        end

        function guardar_diagnostico_limpio(app)
            % Exporta los 3 diagnosticos de la pestana Entrenamiento a PNG con
            % fondo blanco y titulo, a 300 ppp. Copia exactamente lo que hay en
            % pantalla (mismos puntos y titulo que la GUI) a una figura blanca,
            % evitando el fondo oscuro del tema que arrastra el exportador del axes.
            U = app.U.train;
            r = app.ruta_campana();
            if isempty(app.campana) || ~isfolder(r)
                uialert(app.fig,'No hay carpeta de campaña activa.','Aviso'); return;
            end
            if isempty(allchild(U.ax_scatter))
                uialert(app.fig,'Primero entrena y selecciona un modelo para tener gráficas que guardar.','Aviso'); return;
            end
            try
                app.exportar_axes_limpio(U.ax_scatter, fullfile(r,'diag_predicho_vs_real.png'), true);
                app.exportar_axes_limpio(U.ax_resid,   fullfile(r,'diag_residuos.png'),        false);
                app.exportar_axes_limpio(U.ax_hist,    fullfile(r,'diag_hist_residuos.png'),    false);
                uialert(app.fig, sprintf(['3 gráficas guardadas (fondo blanco, 300 ppp):\n' ...
                    'diag_predicho_vs_real.png\ndiag_residuos.png\ndiag_hist_residuos.png\n\nen %s'], r), ...
                    'Guardar gráficas', 'Icon','success');
            catch ex
                uialert(app.fig, ['No se pudieron exportar las gráficas: ' ex.message], 'Error');
            end
        end

        function exportar_axes_limpio(~, srcAx, ruta, igualar)
            % Reconstruye un uiaxes en una figura blanca tradicional y exporta.
            f = figure('Visible','off','Color','w','Position',[100 100 760 560]);
            dst = axes('Parent', f);
            copyobj(allchild(srcAx), dst);
            tl = srcAx.Title;
            title(dst, tl.String, 'Interpreter', tl.Interpreter);
            xlabel(dst, srcAx.XLabel.String);
            ylabel(dst, srcAx.YLabel.String);
            dst.XLim = srcAx.XLim; dst.YLim = srcAx.YLim;
            grid(dst,'on'); box(dst,'on'); dst.FontSize = 12;
            dst.XColor = [0 0 0]; dst.YColor = [0 0 0]; dst.Title.Color = [0 0 0];
            if igualar, dst.DataAspectRatio = [1 1 1]; end
            exportgraphics(f, ruta, 'Resolution', 300);
            close(f);
        end

        function cb_guardar_modelo_como(app)
            U = app.U.train;
            sel = U.tabla_mod.Selection;
            if isempty(sel) || isempty(app.modelos_cache)
                uialert(app.fig,'Selecciona un modelo de la tabla primero.','Sin selección'); return;
            end
            row = sel(1);
            if row > numel(app.modelos_cache), return; end

            [fname, fpath] = uiputfile('*.mat','Guardar modelo como...',...
                fullfile(app.pipeline_dir,'modelo_surrogate.mat'));
            if isequal(fname,0), return; end

            e = app.modelos_cache(row);
            pred_names = e.pred_names;
            trainedModel.predictFcn      = e.predictFcn;
            trainedModel.RegressionModel = e.mdl;
            trainedModel.modelo_tipo     = e.nombre;
            trainedModel.predictorNames  = pred_names;
            trainedModel.rmse_cv         = e.rmse;
            trainedModel.r2_cv           = e.r2;
            dest = fullfile(fpath, fname);
            save(dest,'trainedModel');

            U.lbl_status.Text = sprintf('✓ Guardado: %s  →  %s', e.nombre, dest);
            U.lbl_status.FontColor = [0.1 0.5 0.1];
            app.log_tab(U.log, sprintf('💾 Guardado en ruta personalizada: %s', dest));
        end

        function guardar_modelo_seleccionado(app, idx)
            e = app.modelos_cache(idx);
            trainedModel.predictFcn      = e.predictFcn;
            trainedModel.RegressionModel = e.mdl;
            trainedModel.modelo_tipo     = e.nombre;
            trainedModel.predictorNames  = e.pred_names;
            trainedModel.rmse_cv         = e.rmse;
            trainedModel.r2_cv           = e.r2;
            save(fullfile(app.ruta_campana(),'modelo_surrogate.mat'),'trainedModel');
            app.log_tab(app.U.train.log,['Guardado: ' e.nombre ...
                sprintf(' — RMSE %.2f J, R² %.4f',e.rmse,e.r2)]);
        end

        function actualizar_plots_modelo(app, idx)
            U  = app.U.train;
            e  = app.modelos_cache(idx);
            yt = e.ytrue;  yp = e.ypred_cv;
            res = yp - yt;

            % Scatter predicho vs real
            cla(U.ax_scatter);
            scatter(U.ax_scatter, yt, yp, 28, [0.2 0.45 0.8], 'filled', 'MarkerFaceAlpha', 0.6);
            hold(U.ax_scatter,'on');
            lims = [min(yt) max(yt)];
            plot(U.ax_scatter, lims, lims, 'r--', 'LineWidth', 1.5);
            hold(U.ax_scatter,'off');
            xlabel(U.ax_scatter,'Real (J)'); ylabel(U.ax_scatter,'Predicho (J)');
            title(U.ax_scatter, sprintf('%s  |  RMSE=%.2f J  R²=%.4f', e.nombre, e.rmse, e.r2));
            grid(U.ax_scatter,'on'); axis(U.ax_scatter,'equal');

            % Residuos vs real
            cla(U.ax_resid);
            scatter(U.ax_resid, yt, res, 22, [0.7 0.3 0.1], 'filled', 'MarkerFaceAlpha', 0.6);
            hold(U.ax_resid,'on');
            yline(U.ax_resid, 0, 'k--', 'LineWidth', 1.2);
            hold(U.ax_resid,'off');
            xlabel(U.ax_resid,'Real (J)'); ylabel(U.ax_resid,'Residuo (J)');
            title(U.ax_resid, sprintf('Residuos  |  Sesgo medio: %.2f J', mean(res)));
            grid(U.ax_resid,'on');

            % Histograma residuos
            cla(U.ax_hist);
            histogram(U.ax_hist, res, 30, 'FaceColor',[0.4 0.6 0.85],'EdgeColor','none');
            hold(U.ax_hist,'on');
            xline(U.ax_hist, 0,'k--','LineWidth',1.2);
            hold(U.ax_hist,'off');
            xlabel(U.ax_hist,'Residuo (J)'); ylabel(U.ax_hist,'Frecuencia');
            title(U.ax_hist, sprintf('σ=%.2f J', std(res)));
            grid(U.ax_hist,'on');
        end

        % ---------------------------------------------------------------
        function cb_opciones_train(app)
        % Ventana de configuración de hiperparámetros de entrenamiento.
        % ---------------------------------------------------------------
            fw = uifigure('Name','⚙  Configuración de entrenamiento',...
                'Position',[180 80 660 556]);

            % ── Panel izquierdo: grupos ──────────────────────────────────
            pl = uipanel(fw,'Title','Grupos de modelos a entrenar',...
                'Position',[8 54 205 494],'FontSize',9);
            grupos = {
                'gpr',      'GPR (4 kernels)';
                'ensemble', 'Ensemble (2 variantes)';
                'trees',    'Árboles (3)';
                'svm',      'SVM (6 variantes)';
                'kernel',   'Kernel Nyström (2)';
                'lineal',   'Lineal (6)';
                'redes',    'Redes neuronales (5)';
            };
            hh.cb_grp = {};
            for k = 1:size(grupos,1)
                hh.cb_grp{k} = uicheckbox(pl,...
                    'Text',  grupos{k,2},...
                    'Value', app.hp.grupos.(grupos{k,1}),...
                    'Position',[8 370-(k-1)*48 190 28],'FontSize',9);
            end

            % ── Panel derecho: hiperparámetros ───────────────────────────
            pr = uipanel(fw,'Title','Hiperparámetros',...
                'Position',[221 54 432 494],'FontSize',9);

            % Validación
            uilabel(pr,'Text','VALIDACIÓN',...
                'Position',[8 452 100 18],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.18 0.38 0.70]);
            uilabel(pr,'Text','Modo:','Position',[8 428 42 20],'FontSize',9);
            hh.val_mode = uidropdown(pr,...
                'Items',{'K-fold CV','Holdout','K-fold + Holdout final'},...
                'ItemsData',{'kfold','holdout','kfold_holdout'},...
                'Value',app.hp.val_mode,'Position',[54 428 200 22]);
            uilabel(pr,'Text','Fracción test:','Position',[266 428 92 20],'FontSize',9);
            hh.holdout_frac = uispinner(pr,'Value',app.hp.holdout_frac,...
                'Limits',[0.10 0.50],'Step',0.05,'ValueDisplayFormat','%.2f',...
                'Position',[362 428 64 22]);

            % K-fold
            uilabel(pr,'Text','K-fold validación cruzada:',...
                'Position',[8 392 185 20],'FontSize',9,'FontWeight','bold');
            hh.kfold = uispinner(pr,'Value',app.hp.kfold,'Limits',[2 20],'Step',1,...
                'Position',[200 392 65 22]);

            % Ensemble
            uilabel(pr,'Text','ENSEMBLE',...
                'Position',[8 360 100 18],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.18 0.38 0.70]);
            uilabel(pr,'Text','Ciclos:','Position',[8 334 50 20],'FontSize',9);
            hh.ens_cycles = uispinner(pr,'Value',app.hp.ens_cycles,'Limits',[20 5000],'Step',50,...
                'Position',[60 334 78 22]);
            uilabel(pr,'Text','Tasa aprendizaje:','Position',[150 334 120 20],'FontSize',9);
            hh.ens_lr = uieditfield(pr,'numeric','Value',app.hp.ens_lr,...
                'Limits',[0.001 0.5],'ValueDisplayFormat','%.3f',...
                'Position',[278 334 65 22]);
            uilabel(pr,'Text','MinHoja:','Position',[8 308 65 20],'FontSize',9);
            hh.ens_leaf = uispinner(pr,'Value',app.hp.ens_leafsize,'Limits',[1 100],'Step',1,...
                'Position',[78 308 70 22]);

            % GPR
            uilabel(pr,'Text','GPR',...
                'Position',[8 276 60 18],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.18 0.38 0.70]);
            uilabel(pr,'Text','Función de base:','Position',[8 252 115 20],'FontSize',9);
            hh.gpr_basis = uidropdown(pr,...
                'Items',{'none','constant','linear','pureQuadratic'},...
                'Value',app.hp.gpr_basis,'Position',[130 252 165 22]);

            % Redes neuronales
            uilabel(pr,'Text','REDES NEURONALES',...
                'Position',[8 220 160 18],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.18 0.38 0.70]);
            uilabel(pr,'Text','Capas (ej: "64 32"):','Position',[8 196 145 20],'FontSize',9);
            hh.nn_layers = uieditfield(pr,'text','Value',app.hp.nn_layers,...
                'Position',[158 196 100 22]);
            uilabel(pr,'Text','Activación:','Position',[268 196 75 20],'FontSize',9);
            hh.nn_act = uidropdown(pr,'Items',{'relu','tanh','sigmoid'},...
                'Value',app.hp.nn_activations,'Position',[348 196 78 22]);

            % SVM
            uilabel(pr,'Text','SVM',...
                'Position',[8 164 60 18],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.18 0.38 0.70]);
            uilabel(pr,'Text','BoxConstraint C:','Position',[8 140 118 20],'FontSize',9);
            hh.svm_box = uieditfield(pr,'numeric','Value',app.hp.svm_box,...
                'Limits',[0.001 1e6],'Position',[132 140 80 22]);
            uilabel(pr,'Text','KernelScale (0=auto):','Position',[225 140 152 20],'FontSize',9);
            hh.svm_scale = uieditfield(pr,'numeric','Value',app.hp.svm_scale,...
                'Limits',[0 1e4],'Position',[382 140 42 22]);

            % Árboles
            uilabel(pr,'Text','ÁRBOLES',...
                'Position',[8 108 80 18],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.18 0.38 0.70]);
            uilabel(pr,'Text','Splits (moderado):',...
                'Position',[8 84 120 20],'FontSize',9);
            hh.tree_splits = uispinner(pr,'Value',app.hp.tree_mod_splits,...
                'Limits',[2 5000],'Step',5,'Position',[132 84 72 22]);
            uilabel(pr,'Text','MinHoja (profundo):',...
                'Position',[218 84 130 20],'FontSize',9);
            hh.tree_dleaf = uispinner(pr,'Value',app.hp.tree_deep_leafsize,...
                'Limits',[1 50],'Step',1,'Position',[352 84 68 22]);

            % ── Botones ─────────────────────────────────────────────────
            uibutton(fw,'Text','✓  Aplicar y cerrar',...
                'Position',[438 12 210 34],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_hp_apply(fw, hh, grupos));
            uibutton(fw,'Text','↺  Restablecer defaults',...
                'Position',[218 12 212 34],...
                'BackgroundColor',app.COL_GRIS,'FontColor','white',...
                'FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_hp_reset(hh, grupos));
            uibutton(fw,'Text','Cancelar',...
                'Position',[8 12 202 34],...
                'FontSize',10,...
                'ButtonPushedFcn',@(~,~) close(fw));
        end

        function cb_hp_apply(app, fw, hh, grupos)
            for k = 1:size(grupos,1)
                app.hp.grupos.(grupos{k,1}) = hh.cb_grp{k}.Value;
            end
            app.hp.val_mode           = hh.val_mode.Value;
            app.hp.holdout_frac       = hh.holdout_frac.Value;
            app.hp.kfold              = hh.kfold.Value;
            app.hp.ens_cycles         = hh.ens_cycles.Value;
            app.hp.ens_lr             = hh.ens_lr.Value;
            app.hp.ens_leafsize       = hh.ens_leaf.Value;
            app.hp.gpr_basis          = hh.gpr_basis.Value;
            app.hp.nn_layers          = strtrim(hh.nn_layers.Value);
            app.hp.nn_activations     = hh.nn_act.Value;
            app.hp.svm_box            = hh.svm_box.Value;
            app.hp.svm_scale          = hh.svm_scale.Value;
            app.hp.tree_mod_splits    = hh.tree_splits.Value;
            app.hp.tree_deep_leafsize = hh.tree_dleaf.Value;
            close(fw);
        end

        function cb_hp_reset(app, hh, grupos)
            d = app.hp_defaults();
            for k = 1:size(grupos,1)
                hh.cb_grp{k}.Value = d.grupos.(grupos{k,1});
            end
            hh.val_mode.Value      = d.val_mode;
            hh.holdout_frac.Value  = d.holdout_frac;
            hh.kfold.Value         = d.kfold;
            hh.ens_cycles.Value    = d.ens_cycles;
            hh.ens_lr.Value      = d.ens_lr;
            hh.ens_leaf.Value    = d.ens_leafsize;
            hh.gpr_basis.Value   = d.gpr_basis;
            hh.nn_layers.Value   = d.nn_layers;
            hh.nn_act.Value      = d.nn_activations;
            hh.svm_box.Value     = d.svm_box;
            hh.svm_scale.Value   = d.svm_scale;
            hh.tree_splits.Value = d.tree_mod_splits;
            hh.tree_dleaf.Value  = d.tree_deep_leafsize;
        end

        function cb_cargar_modelo(app)
            app.cargar_campana();
            U = app.U.train;

            [fname, fpath] = uigetfile('*.mat','Selecciona modelo_surrogate.mat',...
                app.pipeline_dir);
            if isequal(fname,0), return; end

            ruta_origen = fullfile(fpath, fname);
            app.log_tab(U.log,['Cargando: ' ruta_origen]);

            % Validar que contiene trainedModel con predictFcn
            try
                m = load(ruta_origen,'trainedModel');
            catch ex
                uialert(app.fig,['No se pudo leer el archivo: ' ex.message],'Error');
                return;
            end
            if ~isfield(m,'trainedModel') || ~isfield(m.trainedModel,'predictFcn')
                uialert(app.fig,...
                    'El archivo no contiene un trainedModel válido (falta predictFcn).',...
                    'Formato incorrecto');
                return;
            end
            trainedModel = m.trainedModel;

            % Mostrar info del modelo cargado
            tipo   = 'Externo';
            rmse_c = NaN; pred_n = {};
            if isfield(trainedModel,'modelo_tipo'),    tipo   = trainedModel.modelo_tipo;    end
            if isfield(trainedModel,'rmse_cv'),        rmse_c = trainedModel.rmse_cv;        end
            if isfield(trainedModel,'predictorNames'), pred_n = trainedModel.predictorNames; end
            pred_str = strjoin(pred_n,', ');

            U.lbl_pred.Text = pred_str;
            U.lbl_nval.Text = '(externo)';

            % Añadir a la tabla como entrada externa (sin ypred_cv disponible)
            entry.nombre    = tipo;
            entry.mdl       = trainedModel.RegressionModel;
            entry.rmse      = rmse_c;
            entry.r2        = NaN;
            entry.t_s       = 0;
            entry.ypred_cv  = [];
            entry.ytrue     = [];
            entry.pred_names = pred_n;
            if isempty(app.modelos_cache)
                app.modelos_cache = entry;
            else
                app.modelos_cache(end+1) = entry;
            end
            fila = {tipo, round(rmse_c,2), '—', '—'};
            if isempty(U.tabla_mod.Data)
                U.tabla_mod.Data = fila;
            else
                U.tabla_mod.Data = [U.tabla_mod.Data; fila];
            end

            % Si hay campaña activa, copiar el modelo a su carpeta
            if ~isempty(app.campana)
                dest = fullfile(app.ruta_campana(),'modelo_surrogate.mat');
                if ~strcmp(ruta_origen, dest)
                    copyfile(ruta_origen, dest);
                    app.log_tab(U.log,['Copiado a: ' dest]);
                end
                msg = sprintf('✓ Modelo cargado (%s)',tipo);
                if isfinite(rmse_c), msg = sprintf('%s — RMSE: %.2f J', msg, rmse_c); end
                U.lbl_status.Text = msg;
                U.lbl_status.FontColor = [0.1 0.5 0.1];
                app.log_tab(U.log,'Modelo listo. Puedes continuar con la Optimización GA.');
            else
                % Sin campaña activa: preguntar dónde guardarlo
                app.log_tab(U.log,'Sin campaña activa — el modelo no se ha vinculado a ninguna campaña.');
                uialert(app.fig,...
                    'Modelo validado pero sin campaña activa. Genera o carga una campaña primero para vincularlo.',...
                    'Sin campaña','Icon','warning');
            end
        end

        % ---------------------------------------------------------------
        % TAB 4 — GA
        % ---------------------------------------------------------------
        function tab_ga(app, par)
            U = struct();
            uilabel(par,'Text','Optimización — GA y Fuerza Bruta (catálogo)',...
                'Position',[12 630 620 24],'FontSize',12,'FontWeight','bold');

            % ── Panel parámetros GA ──────────────────────────────────────
            pan = uipanel(par,'Title','Parámetros GA','Position',[12 555 560 70],'FontSize',9);
            uilabel(pan,'Text','Población:','Position',[5 28 70 20]);
            U.pop  = uispinner(pan,'Value',150,'Limits',[20 2000],'Step',10,'Position',[78 28 68 22]);
            uilabel(pan,'Text','Generaciones:','Position',[160 28 95 20]);
            U.ngen = uispinner(pan,'Value',60,'Limits',[10 1000],'Step',10,'Position',[258 28 68 22]);
            uilabel(pan,'Text','Mutación:','Position',[340 28 70 20]);
            U.mut  = uispinner(pan,'Value',0.25,'Limits',[0.01 0.9],'Step',0.05,'Position',[415 28 68 22]);
            uilabel(pan,'Text','Top N:','Position',[5 4 50 20]);
            U.topn = uispinner(pan,'Value',10,'Limits',[1 100],'Step',1,'Position',[58 4 60 22]);
            uilabel(pan,'Text','(mejores diseños únicos mostrados en la tabla)',...
                'Position',[130 4 410 20],'FontSize',8,'FontColor',[0.5 0.5 0.5]);

            % ── Botones ─────────────────────────────────────────────────
            U.btn_ga = uibutton(par,'Text','▶  Algoritmo Genético',...
                'Position',[582 568 178 34],...
                'BackgroundColor',app.COL_AZUL,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_ga());
            U.btn_bf = uibutton(par,'Text','▼▼  Fuerza bruta',...
                'Position',[768 568 158 34],...
                'BackgroundColor',app.COL_AZUL2,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_brute_force());
            uibutton(par,'Text','⚙  Catálogo',...
                'Position',[934 568 100 34],...
                'ButtonPushedFcn',@(~,~) app.abrir_catalogo());
            uibutton(par,'Text','💾  Exportar',...
                'Position',[1042 568 84 34],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontSize',9,...
                'ButtonPushedFcn',@(~,~) app.cb_exportar_optim());

            U.lbl_status = uilabel(par,'Text','','Position',[582 532 560 30],...
                'FontSize',10,'WordWrap','on');

            % ── Gráfica (convergencia GA / histograma BF) ────────────────
            U.ax = uiaxes(par,'Position',[12 280 520 248]);
            title(U.ax,'—'); xlabel(U.ax,''); ylabel(U.ax,'Energía específica (J/kg)');
            grid(U.ax,'on');

            % ── Tabla top-N ──────────────────────────────────────────────
            U.tabla = uitable(par,'Position',[542 280 590 248],...
                'ColumnName',{'Rank','m1','a1','b','m2','a2','e_c','EPM J/kg','Masa kg','E J','Modo'},...
                'RowName',{},'FontSize',9,...
                'ColumnWidth',{50,44,35,35,44,35,35,68,58,55,58});

            % ── Panel Evaluar diseño (predicción puntual del surrogate) ──
            pev = uipanel(par,'Title','Evaluar diseño (predicción del modelo cargado)',...
                'Position',[12 212 1118 62],'FontSize',9);
            mk = @(txt,x,w) uilabel(pev,'Text',txt,'Position',[x 14 w 18],'FontSize',9);
            mk('m1',8,20);    U.ev.m1 = uispinner(pev,'Value',4,  'Limits',[1 10], 'Step',0.5,'Position',[30 12 48 22]);
            mk('a1',84,20);   U.ev.a1 = uispinner(pev,'Value',100,'Limits',[20 200],'Step',5,  'Position',[108 12 52 22]);
            mk('m2',166,22);  U.ev.m2 = uispinner(pev,'Value',2,  'Limits',[1 10], 'Step',0.5,'Position',[190 12 48 22]);
            mk('a2',244,22);  U.ev.a2 = uispinner(pev,'Value',100,'Limits',[20 200],'Step',5,  'Position',[268 12 52 22]);
            mk('b',326,14);   U.ev.b  = uispinner(pev,'Value',40, 'Limits',[20 200],'Step',5,  'Position',[344 12 52 22]);
            mk('e_c',402,28); U.ev.ec = uispinner(pev,'Value',4,  'Limits',[1 10], 'Step',0.5,'Position',[434 12 48 22]);
            mk('c',488,14);   U.ev.c  = uispinner(pev,'Value',80, 'Limits',[40 200],'Step',5,  'Position',[506 12 52 22]);
            U.ev.btn = uibutton(pev,'Text','Evaluar','Position',[566 11 88 26],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white','FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_evaluar_diseno());
            U.ev.result = uilabel(pev,'Text','Introduce una geometría y pulsa Evaluar.',...
                'Position',[662 2 448 40],'FontSize',9,'WordWrap','on');

            U.log = uitextarea(par,'Position',[12 10 1118 194],...
                'Editable','off','FontSize',8,'FontName','Consolas','Value',{'Listo.'});

            app.U.ga = U;
        end

        function kpi = set_cols_ranking(app, c_varia)
            % Ajusta las columnas de la tabla de ranking: inserta 'c' tras
            % 'e_c' cuando el cateto de cartela es variable (campaña Cvar).
            % Devuelve el índice de la columna KPI (EPM) para estilo_tabla.
            U = app.U.ga;
            if c_varia
                U.tabla.ColumnName  = {'Rank','m1','a1','b','m2','a2','e_c','c',...
                    'EPM J/kg','Masa kg','E J','Modo'};
                U.tabla.ColumnWidth = {44,44,33,33,44,33,33,30,62,52,50,52};
                kpi = 9;
            else
                U.tabla.ColumnName  = {'Rank','m1','a1','b','m2','a2','e_c',...
                    'EPM J/kg','Masa kg','E J','Modo'};
                U.tabla.ColumnWidth = {50,44,35,35,44,35,35,68,58,55,58};
                kpi = 8;
            end
        end

        function cb_ga(app)
            app.cargar_campana();
            app.autoset_cat_c();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U   = app.U.ga;
            car = app.ruta_campana();
            mf  = fullfile(car,'modelo_surrogate.mat');
            if ~isfile(mf), uialert(app.fig,'Falta modelo_surrogate.mat.','Error'); return; end

            m = load(mf,'trainedModel'); mdl = m.trainedModel;
            db = readtable(fullfile(car,'basededatos.csv'));
            l1_f=db.l1(1); l2_f=db.l2(1); c_f=db.c(1);
            c_varia = std(db.c) > 1e-10;  % c es variable si varía en el DOE

            ps   = U.pop.Value;
            ng   = U.ngen.Value;
            mr   = U.mut.Value;
            topN = U.topn.Value;
            if c_varia
                lb = [2  40  2  40  40  2  min(db.c)];
                ub = [4 100  4 100 100  4  max(db.c)];
                app.log_tab(U.log,sprintf('c variable detectada: [%.0f, %.0f] mm',min(db.c),max(db.c)));
            else
                lb = [2  40  2  40  40  2];
                ub = [4 100  4 100 100  4];
                app.log_tab(U.log,sprintf('c fija: %.0f mm',c_f));
            end
            nV = numel(lb);

            rng(0);

            % ---- GA catálogo ----
            app.log_tab(U.log,'GA catálogo...');
            pop = zeros(ps,nV);
            for i=1:ps, pop(i,:)=app.ga_gen(lb,ub,true); end
            fit = app.ga_eval_pop(pop,mdl,l1_f,l2_f,c_f);
            hist_c = zeros(ng,1);
            for g=1:ng
                np=zeros(ps,nV); [~,bi]=min(fit); np(1,:)=pop(bi,:);
                for i=2:ps
                    p1=app.ga_sel(pop,fit); p2=app.ga_sel(pop,fit);
                    ch=app.ga_cx(p1,p2,nV); ch=app.ga_mut(ch,lb,ub,mr,nV);
                    ch=app.ga_gen(lb,ub,true,ch); np(i,:)=ch;
                end
                pop=np; fit=app.ga_eval_pop(pop,mdl,l1_f,l2_f,c_f);
                hist_c(g)=-min(fit);
                if mod(g,10)==0||g==ng
                    app.log_tab(U.log,sprintf('Cat gen %d/%d → %.4f J/kg',g,ng,hist_c(g)));
                end
            end

            % ---- GA continuo ----
            app.log_tab(U.log,'GA continuo...');
            pop2=max(min(repmat(lb,ps,1)+repmat(ub-lb,ps,1).*rand(ps,nV),repmat(ub,ps,1)),repmat(lb,ps,1));
            fit2=app.ga_eval_pop(pop2,mdl,l1_f,l2_f,c_f);
            hist_k=zeros(ng,1);
            for g=1:ng
                np=zeros(ps,nV); [~,bi]=min(fit2); np(1,:)=pop2(bi,:);
                for i=2:ps
                    p1=app.ga_sel(pop2,fit2); p2=app.ga_sel(pop2,fit2);
                    ch=app.ga_cx(p1,p2,nV); ch=app.ga_mut(ch,lb,ub,mr,nV);
                    ch=max(min(ch,ub),lb); np(i,:)=ch;
                end
                pop2=np; fit2=app.ga_eval_pop(pop2,mdl,l1_f,l2_f,c_f);
                hist_k(g)=-min(fit2);
                if mod(g,10)==0||g==ng
                    app.log_tab(U.log,sprintf('Cont gen %d/%d → %.4f J/kg',g,ng,hist_k(g)));
                end
            end

            % ---- Gráfica ----
            cla(U.ax);
            plot(U.ax,1:ng,hist_c,'-b','LineWidth',2,'DisplayName','Catálogo');
            hold(U.ax,'on');
            plot(U.ax,1:ng,hist_k,'--r','LineWidth',1.5,'DisplayName','Continuo');
            legend(U.ax,'Location','southeast'); hold(U.ax,'off');
            try
                fg=figure('Visible','off','Position',[100 100 820 360]);
                ax_=axes(fg);
                plot(ax_,1:ng,hist_c,'-b','LineWidth',2,'DisplayName','Catálogo');
                hold(ax_,'on');
                plot(ax_,1:ng,hist_k,'--r','LineWidth',1.5,'DisplayName','Continuo');
                hold(ax_,'off');
                legend(ax_,'Location','southeast');
                xlabel(ax_,'Generación'); ylabel(ax_,'Energía específica (J/kg)');
                title(ax_,'Convergencia GA'); grid(ax_,'on');
                saveas(fg,fullfile(car,'convergencia_GA.png'));
                close(fg);
            catch, end

            % ---- Top-N catálogo ----
            [rows_cat, cvals_cat] = app.extraer_top_n(pop,  fit,  topN, nV, l1_f, l2_f, c_f, 'Cat');
            % ---- Top-N continuo  ----
            [rows_con, cvals_con] = app.extraer_top_n(pop2, fit2, topN, nV, l1_f, l2_f, c_f, 'Cont');

            rows  = [rows_cat, rows_con];
            cvals = [cvals_cat, cvals_con];
            if ~isempty(rows)
                kpi_col = app.set_cols_ranking(c_varia);
                if c_varia
                    disp_rows = cell(1, numel(rows));
                    for kk = 1:numel(rows)
                        r = rows{kk};
                        disp_rows{kk} = {r{1}, r{2}, r{3}, r{4}, r{5}, r{6}, r{7}, ...
                            round(cvals(kk),1), r{8}, r{9}, r{10}, ''};
                    end
                    U.tabla.Data = vertcat(disp_rows{:});
                else
                    U.tabla.Data = vertcat(rows{:});
                end
                app.estilo_tabla(U.tabla, kpi_col);
            end

            % Ganador catálogo
            [~,bi]=min(fit); w=pop(bi,:);
            c_w=c_f; if nV>=7, c_w=w(7); end
            mw=app.masa_scalar(w(1),w(2),w(5),l1_f,w(3),w(4),l2_f,c_w,w(6));
            tw=array2table([w(1),w(2),w(5),l1_f,w(3),w(4),w(5),l2_f,c_w,w(6)],...
                'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
            Ew=mdl.predictFcn(tw); epm_w=Ew/mw;

            % Ganador continuo para el optimo struct
            [~,bi2]=min(fit2); wc=pop2(bi2,:);
            c_wc=c_f; if nV>=7, c_wc=wc(7); end
            mc  =app.masa_scalar(wc(1),wc(2),wc(5),l1_f,wc(3),wc(4),l2_f,c_wc,wc(6));
            ep_c=-fit2(bi2); Ec=ep_c*mc;

            U.lbl_status.Text=sprintf('✓ Cat #1: %.4f | Cont #1: %.4f J/kg',epm_w,ep_c);
            U.lbl_status.FontColor=[0.1 0.4 0.1];
            if c_varia
                app.log_tab(U.log,sprintf('ÓPTIMO CAT:  m1=%.0f a1=%.0f b=%.0f m2=%.0f a2=%.0f ec=%.0f c=%.0f → %.4f J/kg',...
                    w(1),w(2),w(5),w(3),w(4),w(6),c_w,epm_w));
                app.log_tab(U.log,sprintf('ÓPTIMO CONT: m1=%.2f a1=%.2f b=%.2f m2=%.2f a2=%.2f ec=%.2f c=%.2f → %.4f J/kg',...
                    wc(1),wc(2),wc(5),wc(3),wc(4),wc(6),c_wc,ep_c));
            else
                app.log_tab(U.log,sprintf('ÓPTIMO CAT:  m1=%.0f a1=%.0f b=%.0f m2=%.0f a2=%.0f ec=%.0f → %.4f J/kg',...
                    w(1),w(2),w(5),w(3),w(4),w(6),epm_w));
                app.log_tab(U.log,sprintf('ÓPTIMO CONT: m1=%.2f a1=%.2f b=%.2f m2=%.2f a2=%.2f ec=%.2f → %.4f J/kg',...
                    wc(1),wc(2),wc(5),wc(3),wc(4),wc(6),ep_c));
            end

            % Guardar el óptimo del GA (catálogo) para que la fuerza bruta pueda
            % comprobar después si el GA alcanzó el óptimo global del catálogo.
            app.epm_ga_cat  = epm_w;
            app.epm_ga_camp = app.campana;

            optimo.m1=w(1); optimo.a1=w(2); optimo.b1=w(5); optimo.l1=l1_f;
            optimo.m2=w(3); optimo.a2=w(4); optimo.b2=w(5); optimo.l2=l2_f;
            optimo.c=c_w; optimo.e_cartela=w(6); optimo.masa_estimada=mw;
            optimo.energia_especifica_J_kg=epm_w; optimo.energia_absorbida_J=Ew;
            optimo.metodo='GA';
            optimo.continuo=struct('ind',wc,'epm',ep_c,'E_J',Ec,'masa_kg',mc);
            optimo.top_catalog=rows_cat; optimo.top_continuo=rows_con;
            optimo.top_catalog_c=cvals_cat; optimo.top_continuo_c=cvals_con;  % c por diseño (Validación)

            % Incertidumbre GPR en el ganador (sesgo optimista del optimizador)
            optimo.energia_sigma_J = NaN; optimo.epm_ic95 = [NaN NaN];
            try
                gp = extraer_gpr(mdl);
                if ~isempty(gp)
                    [~, sd_w] = predict(gp, tw);
                    ic = [Ew-1.96*sd_w, Ew+1.96*sd_w]/mw;
                    optimo.energia_sigma_J = sd_w;
                    optimo.epm_ic95 = ic;
                    app.log_tab(U.log,sprintf('GPR: sigma=%.1f J → IC95 EPM [%.2f, %.2f] J/kg',...
                        sd_w, ic(1), ic(2)));
                end
            catch, end

            % ranking_top (tabla) para que T05 pueda validar top-K por consola
            if ~c_varia && ~isempty(rows_cat)
                n_rk = numel(rows_cat);
                rk = zeros(n_rk, 13);
                for k = 1:n_rk
                    r = rows_cat{k};
                    rk(k,:) = [r{2}, r{3}, r{4}, l1_f, r{5}, r{6}, r{4}, l2_f, ...
                               c_f, r{7}, r{10}, r{9}, r{8}];
                end
                ranking_top = array2table(rk, 'VariableNames', ...
                    {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela',...
                     'energia_J','masa_kg','epm_J_kg'});
                save(fullfile(car,'optimo_GA.mat'),'optimo','ranking_top');
            else
                save(fullfile(car,'optimo_GA.mat'),'optimo');
            end
        end

        % ---------------------------------------------------------------
        % EVALUAR DISEÑO — predicción puntual del surrogate cargado
        % ---------------------------------------------------------------
        function cb_evaluar_diseno(app)
            app.cargar_campana();
            U = app.U.ga;
            if isempty(app.campana)
                U.ev.result.Text = 'No hay campaña activa.';
                U.ev.result.FontColor = [0.7 0.1 0.1]; return;
            end
            car = app.ruta_campana();
            mf  = fullfile(car,'modelo_surrogate.mat');
            if ~isfile(mf)
                U.ev.result.Text = 'Falta modelo_surrogate.mat. Entrena el modelo primero.';
                U.ev.result.FontColor = [0.7 0.1 0.1]; return;
            end
            mf_all = load(mf); mdl = mf_all.trainedModel;
            db = readtable(fullfile(car,'basededatos.csv'));
            l1_f = db.l1(1); l2_f = db.l2(1); c_f = db.c(1);
            c_varia = std(db.c) > 1e-10;

            m1=U.ev.m1.Value; a1=U.ev.a1.Value; m2=U.ev.m2.Value;
            a2=U.ev.a2.Value; b=U.ev.b.Value;  ec=U.ev.ec.Value;
            if c_varia, c = U.ev.c.Value; else, c = c_f; end

            % Tabla de 10 columnas, igual que el optimizador
            tab = array2table([m1,a1,b,l1_f,m2,a2,b,l2_f,c,ec],...
                'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
            try
                E = mdl.predictFcn(tab);
            catch ex
                U.ev.result.Text = ['Error en la predicción: ' ex.message];
                U.ev.result.FontColor = [0.7 0.1 0.1]; return;
            end
            masa = app.masa_scalar(m1,a1,b,l1_f,m2,a2,l2_f,c,ec);
            sea  = E / masa;

            % Incertidumbre del GPR (sigma e IC95), si el modelo es GPR
            txt_sigma = '';
            gp = extraer_gpr(mdl);
            if ~isempty(gp)
                try
                    [~,sd] = predict(gp,tab);
                    ic = [E-1.96*sd, E+1.96*sd] / masa;
                    txt_sigma = sprintf('  (sigma %.0f J -> IC95 [%.1f, %.1f] J/kg)', sd, ic(1), ic(2));
                catch, end
            end

            % Modo de fallo estimado, si hay clasificador entrenado
            txt_modo = '';
            if isfield(mf_all,'classifierModel')
                try
                    modo = char(string(mf_all.classifierModel.predictFcn(tab)));
                    txt_modo = sprintf('  |  Modo: %s', modo);
                catch, end
            end

            % Aviso 1: restricción de fabricabilidad m <= min(a,b)/4
            avisos = {};
            if 4*m1 > min(a1,b), avisos{end+1} = sprintf('m1 viola m<=min(a,b)/4 (max %.2f)', min(a1,b)/4); end
            if 4*m2 > min(a2,b), avisos{end+1} = sprintf('m2 viola m<=min(a,b)/4 (max %.2f)', min(a2,b)/4); end

            % Aviso 2: fuera del rango del DOE (meta.lb/ub = [m1 a1 m2 a2 b e_c (c)])
            lb = [2 40 2 40 40 2]; ub = [4 100 4 100 100 4];
            mfm = fullfile(car,'meta_campana.mat');
            if isfile(mfm)
                try
                    mm = load(mfm,'meta');
                    if isfield(mm.meta,'lb'), lb = mm.meta.lb(:).'; end
                    if isfield(mm.meta,'ub'), ub = mm.meta.ub(:).'; end
                catch, end
            end
            nombres = {'m1','a1','m2','a2','b','e_c','c'};
            vals    = [m1 a1 m2 a2 b ec c];
            nv = min([numel(lb) numel(ub) numel(vals)]);
            fuera = {};
            for i=1:nv
                if vals(i) < lb(i)-1e-6 || vals(i) > ub(i)+1e-6
                    fuera{end+1} = sprintf('%s=%.4g (rango [%.0f,%.0f])', nombres{i}, vals(i), lb(i), ub(i));
                end
            end

            base = sprintf('SEA = %.1f J/kg   |   E = %.1f J   |   masa = %.3f kg%s%s', sea, E, masa, txt_sigma, txt_modo);
            col  = [0.10 0.45 0.10];
            extra = '';
            if ~isempty(avisos)
                extra = [extra '   ⚠ ' strjoin(avisos,'; ')];
                col   = [0.75 0.30 0.00];
            end
            if ~isempty(fuera)
                extra = [extra '   ⚠ Fuera de rango (extrapolación): ' strjoin(fuera,', ')];
                col   = [0.75 0.30 0.00];
            end
            if ~c_varia
                extra = [extra sprintf('   [c fija de la campaña = %.0f mm]', c_f)];
            end
            U.ev.result.Text = [base extra];
            U.ev.result.FontColor = col;
        end

        % ---------------------------------------------------------------
        % FUERZA BRUTA — evalúa todas las combinaciones válidas del catálogo
        % ---------------------------------------------------------------
        function cb_brute_force(app)
            app.cargar_campana();
            app.autoset_cat_c();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U   = app.U.ga;
            car = app.ruta_campana();
            mf  = fullfile(car,'modelo_surrogate.mat');
            if ~isfile(mf)
                uialert(app.fig,'Falta modelo_surrogate.mat. Entrena el modelo primero.','Error');
                return;
            end

            m   = load(mf,'trainedModel'); mdl = m.trainedModel;
            db  = readtable(fullfile(car,'basededatos.csv'));
            l1_f = db.l1(1); l2_f = db.l2(1); c_f = db.c(1);
            c_varia = std(db.c) > 1e-10;
            topN    = U.topn.Value;

            U.btn_bf.Enable = 'off'; U.btn_ga.Enable = 'off';
            U.lbl_status.Text = 'Enumerando catálogo...';
            drawnow;

            % ── Catálogos activos ────────────────────────────────────────
            cat_m  = sort(app.cat_esp_viga);   % [2 3 4]
            cat_ab = sort(app.cat_dims);        % [40 45 ... 100]
            cat_ec = sort(app.cat_esp_cart);    % [2 3 4]

            % ndgrid sobre [m1, a1, b, m2, a2, ec]
            [M1,A1,B_,M2,A2,EC] = ndgrid(cat_m, cat_ab, cat_ab, cat_m, cat_ab, cat_ec);
            m1v = M1(:); a1v = A1(:); bv = B_(:);
            m2v = M2(:); a2v = A2(:); ecv = EC(:);

            % Constraint: m <= min(a,b)/4   (condición de fabricación)
            ok = (4*m1v <= min(a1v,bv)) & (4*m2v <= min(a2v,bv));
            m1v=m1v(ok); a1v=a1v(ok); bv=bv(ok);
            m2v=m2v(ok); a2v=a2v(ok); ecv=ecv(ok);
            n_base = numel(m1v);

            % c variable: replica para cada valor del catálogo
            if c_varia
                cat_c_v = sort(app.cat_c);
                nc = numel(cat_c_v);
                m1v = repmat(m1v,nc,1); a1v = repmat(a1v,nc,1); bv  = repmat(bv, nc,1);
                m2v = repmat(m2v,nc,1); a2v = repmat(a2v,nc,1); ecv = repmat(ecv,nc,1);
                cv  = repelem(cat_c_v(:), n_base);
                app.log_tab(U.log, sprintf('c variable [%s] mm', num2str(cat_c_v)));
            else
                cv = repmat(c_f, n_base, 1);
                app.log_tab(U.log, sprintf('c fija: %.0f mm', c_f));
            end
            n_total = numel(m1v);
            app.log_tab(U.log, sprintf('Combinaciones válidas: %d  →  evaluando surrogate...', n_total));
            drawnow;

            % ── Evaluación batch del surrogate ───────────────────────────
            l1v = repmat(l1_f, n_total,1);
            l2v = repmat(l2_f, n_total,1);
            tab = array2table([m1v, a1v, bv, l1v, m2v, a2v, bv, l2v, cv, ecv],...
                'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
            try
                E_pred = mdl.predictFcn(tab);
            catch ex
                uialert(app.fig, ['Error en surrogate: ' ex.message], 'Error');
                U.btn_bf.Enable='on'; U.btn_ga.Enable='on'; return;
            end

            % ── Masa analítica vectorizada (fórmula compartida) ──────────
            masa  = masa_analitica(m1v, a1v, bv, l1_f, m2v, a2v, bv, l2_f, cv, ecv);
            epm   = E_pred ./ masa;

            % Filtrar inválidos
            ok2   = isfinite(epm) & epm > 0 & isfinite(masa) & masa > 0;
            % Umbral ECE R66 (si está definido): excluir diseños que no cumplen
            u_ecr = app.umbral_ecr66;
            if u_ecr > 0
                ok_u = ok2 & epm >= u_ecr;
                if any(ok_u)
                    app.log_tab(U.log, sprintf('Umbral ECE R66 (%.1f J/kg): %d de %d diseños cumplen.', ...
                        u_ecr, sum(ok_u), sum(ok2)));
                    ok2 = ok_u;
                else
                    app.log_tab(U.log, sprintf('⚠ Ningún diseño cumple el umbral ECE R66 (%.1f J/kg); ranking sin filtrar.', u_ecr));
                end
            end
            n_ok  = sum(ok2);
            app.log_tab(U.log, sprintf('Válidos: %d / %d', n_ok, n_total));

            % ── Ordenar: mejor EPM primero ────────────────────────────────
            epm_v  = epm(ok2);  E_v  = E_pred(ok2);  masa_v = masa(ok2);
            m1_v   = m1v(ok2);  a1_v = a1v(ok2);     bv_v   = bv(ok2);
            m2_v   = m2v(ok2);  a2_v = a2v(ok2);     ec_v   = ecv(ok2);
            cv_v   = cv(ok2);

            [epm_s, idx_s] = sort(epm_v,'descend');

            % ── Clasificar modos de toda la combinatoria ──────────────────
            modos_ok = repmat({'—'}, n_ok, 1);
            try
                mf_mat = load(fullfile(car,'modelo_surrogate.mat'));
                if isfield(mf_mat,'classifierModel')
                    cl = mf_mat.classifierModel;
                    pred_cl = cl.predictFcn(tab);
                    modos_all = cellstr(char(pred_cl));
                    modos_ok  = modos_all(ok2);
                end
            catch, end
            modos_s = modos_ok(idx_s);  % ordenados por EPM

            % ── Histograma en el eje principal ───────────────────────────
            cla(U.ax);
            histogram(U.ax, epm_s, min(60,n_ok), 'FaceColor',[0.2 0.5 0.8],'EdgeColor','none');
            hold(U.ax,'on');
            if n_ok >= topN
                xline(U.ax, epm_s(topN),'r-','LineWidth',2,'Label',sprintf('Top-%d',topN));
            end
            hold(U.ax,'off');
            xlabel(U.ax,'Energía específica (J/kg)');
            ylabel(U.ax,'Nº combinaciones');
            title(U.ax, sprintf('Distribución — %d combinaciones evaluadas', n_ok));
            grid(U.ax,'on');

            % ── Top-N tabla ──────────────────────────────────────────────
            kpi_col = app.set_cols_ranking(c_varia);
            tabla_data  = {};
            rows_cat_bf = {};   % formato compatible con Validación: {rank,m1,a1,b,m2,a2,e_c,EPM,masa,E,modo}
            for k = 1:min(topN, n_ok)
                i = idx_s(k);
                row_bf = {k, m1_v(i), a1_v(i), bv_v(i), m2_v(i), a2_v(i), ec_v(i), ...
                    epm_s(k), masa_v(i), E_v(i), modos_s{k}};
                rows_cat_bf{end+1} = row_bf; %#ok<AGROW>
                if c_varia
                    tabla_data{end+1} = {sprintf('BF %d',k), ...
                        row_bf{2}, row_bf{3}, row_bf{4}, row_bf{5}, row_bf{6}, row_bf{7}, ...
                        round(cv_v(i),0), round(row_bf{8},2), round(row_bf{9},3), round(row_bf{10},1), row_bf{11}}; %#ok<AGROW>
                else
                    tabla_data{end+1} = {sprintf('BF %d',k), ...
                        row_bf{2}, row_bf{3}, row_bf{4}, row_bf{5}, row_bf{6}, row_bf{7}, ...
                        round(row_bf{8},2), round(row_bf{9},3), round(row_bf{10},1), row_bf{11}}; %#ok<AGROW>
                end
            end
            if ~isempty(tabla_data)
                U.tabla.Data = vertcat(tabla_data{:});
                app.estilo_tabla(U.tabla, kpi_col);
            end

            % ── Guardar óptimo (compatible con T05/Validación) ───────────
            i1 = idx_s(1);
            optimo.m1  = m1_v(i1);  optimo.a1 = a1_v(i1); optimo.b1 = bv_v(i1);
            optimo.l1  = l1_f;
            optimo.m2  = m2_v(i1);  optimo.a2 = a2_v(i1); optimo.b2 = bv_v(i1);
            optimo.l2  = l2_f;
            optimo.c   = cv_v(i1);  optimo.e_cartela = ec_v(i1);
            optimo.masa_estimada          = masa_v(i1);
            optimo.energia_especifica_J_kg = epm_s(1);
            optimo.energia_absorbida_J    = E_v(i1);
            optimo.metodo = 'BruteForce';
            optimo.top_catalog = rows_cat_bf;
            optimo.top_catalog_c = cv_v(idx_s(1:numel(rows_cat_bf)));  % c por diseño (Validación)
            optimo.top_continuo = {};

            % Si antes se había lanzado GA continuo, conservar sus candidatos.
            optimo_prev_f = fullfile(car,'optimo_GA.mat');
            if isfile(optimo_prev_f)
                try
                    prev = load(optimo_prev_f,'optimo');
                    if isfield(prev.optimo,'continuo')
                        optimo.continuo = prev.optimo.continuo;
                    end
                    if isfield(prev.optimo,'top_continuo')
                        optimo.top_continuo = prev.optimo.top_continuo;
                    end
                    if isfield(prev.optimo,'top_continuo_c')
                        optimo.top_continuo_c = prev.optimo.top_continuo_c;
                    end
                catch, end
            end

            % ── Incertidumbre GPR: sigma en el #1 y óptimo robusto LCB ───
            optimo.energia_sigma_J = NaN; optimo.epm_ic95 = [NaN NaN];
            try
                gp = extraer_gpr(mdl);
                if ~isempty(gp)
                    [mu_gp, sd_gp] = predict(gp, tab);
                    sd_v = sd_gp(ok2);
                    sd1  = sd_v(i1);
                    ic   = [E_v(i1)-1.96*sd1, E_v(i1)+1.96*sd1]/masa_v(i1);
                    optimo.energia_sigma_J = sd1;
                    optimo.epm_ic95 = ic;
                    app.log_tab(U.log,sprintf('GPR: sigma(#1)=%.1f J → IC95 EPM [%.2f, %.2f] J/kg',...
                        sd1, ic(1), ic(2)));
                    % LCB = (mu - 1.96*sigma)/masa sobre todo el catálogo
                    lcb_all = (mu_gp - 1.96*sd_gp) ./ masa;
                    lcb_v   = lcb_all(ok2);
                    [lcb_best, i_lcb] = max(lcb_v);
                    if i_lcb == i1
                        app.log_tab(U.log,'GPR: el óptimo robusto (LCB 95%) COINCIDE con el nominal.');
                    else
                        app.log_tab(U.log,sprintf(['GPR: óptimo robusto (LCB 95%%) DISTINTO: '...
                            'm1=%g a1=%g b=%g m2=%g a2=%g ec=%g → LCB %.2f J/kg'],...
                            m1_v(i_lcb),a1_v(i_lcb),bv_v(i_lcb),...
                            m2_v(i_lcb),a2_v(i_lcb),ec_v(i_lcb),lcb_best));
                    end
                end
            catch ex_gp
                app.log_tab(U.log,['(Sin incertidumbre GPR: ' ex_gp.message ')']);
            end

            % ── ranking_top (tabla) para validación top-K por consola (T05)
            n_rk   = min(5, n_ok);
            idx_rk = idx_s(1:n_rk);
            ranking_top = table(m1_v(idx_rk), a1_v(idx_rk), bv_v(idx_rk), ...
                repmat(l1_f,n_rk,1), m2_v(idx_rk), a2_v(idx_rk), bv_v(idx_rk), ...
                repmat(l2_f,n_rk,1), cv_v(idx_rk), ec_v(idx_rk), ...
                E_v(idx_rk), masa_v(idx_rk), epm_s(1:n_rk), ...
                'VariableNames', {'m1','a1','b1','l1','m2','a2','b2','l2','c',...
                'e_cartela','energia_J','masa_kg','epm_J_kg'});

            save(fullfile(car,'optimo_GA.mat'),'optimo','ranking_top');

            % ── Log resumen ──────────────────────────────────────────────
            app.log_tab(U.log,'');
            app.log_tab(U.log,repmat('─',1,60));
            app.log_tab(U.log,sprintf('★ ÓPTIMO GLOBAL (BF): m1=%.0f a1=%.0f b=%.0f m2=%.0f a2=%.0f ec=%.0f  →  Modo: %s',...
                m1_v(i1),a1_v(i1),bv_v(i1),m2_v(i1),a2_v(i1),ec_v(i1),modos_s{1}));
            app.log_tab(U.log,sprintf('   EPM=%.4f J/kg  |  E=%.1f J  |  Masa=%.3f kg',...
                epm_s(1),E_v(i1),masa_v(i1)));
            % Distribución de modos en el top-N
            n_top = min(topN, n_ok);
            n_viga_top = sum(strcmp(modos_s(1:n_top),'Viga'));
            n_cart_top = n_top - n_viga_top;
            app.log_tab(U.log,sprintf('   Top-%d: %d Viga (%.0f%%)  |  %d Cartela (%.0f%%)',...
                n_top, n_viga_top,100*n_viga_top/n_top, n_cart_top,100*n_cart_top/n_top));
            % ── ¿El GA alcanzó el óptimo global? (si se lanzó el GA en esta campaña) ──
            if isfinite(app.epm_ga_cat) && strcmp(app.epm_ga_camp, app.campana)
                deficit_ga = epm_s(1) - app.epm_ga_cat;
                if deficit_ga <= 1e-3
                    app.log_tab(U.log,'✓ El GA ALCANZÓ el óptimo global del catálogo.');
                else
                    app.log_tab(U.log,sprintf('✗ El GA NO alcanzó el óptimo global (déficit %.4f J/kg = %.2f%%).',...
                        deficit_ga, 100*deficit_ga/epm_s(1)));
                end
            else
                app.log_tab(U.log,'(Lanza el GA en esta campaña para comprobar si alcanza el óptimo global.)');
            end
            app.log_tab(U.log,repmat('─',1,60));

            U.lbl_status.Text = sprintf('✓ BF: #1 %.4f J/kg | #2 %.4f | #3 %.4f J/kg  (%d evaluados)',...
                epm_s(1), epm_s(min(2,n_ok)), epm_s(min(3,n_ok)), n_ok);
            U.lbl_status.FontColor = [0.05 0.35 0.62];

            % Guardar imagen del histograma
            try
                fg = figure('Visible','off','Position',[100 100 700 380]);
                ax_ = axes(fg);
                histogram(ax_, epm_s, min(60,n_ok),'FaceColor',[0.2 0.5 0.8],'EdgeColor','none');
                hold(ax_,'on');
                if n_ok >= topN
                    xline(ax_,epm_s(topN),'r-','LineWidth',2,'Label',sprintf('Top-%d',topN));
                end
                hold(ax_,'off');
                xlabel(ax_,'Energía específica (J/kg)');
                ylabel(ax_,'Nº combinaciones');
                title(ax_,sprintf('Distribución BF — %d combinaciones  |  Mejor: %.4f J/kg',n_ok,epm_s(1)));
                grid(ax_,'on');
                saveas(fg, fullfile(car,'brute_force_histograma.png'));
                close(fg);
            catch, end

            U.btn_bf.Enable = 'on'; U.btn_ga.Enable = 'on';
        end

        % ---------------------------------------------------------------
        % Extrae los top-N diseños únicos de una población
        % ---------------------------------------------------------------
        function [rows, cvals] = extraer_top_n(app, pop, fit, topN, nV, l1_f, l2_f, c_f, etiqueta)
            [fit_s, idx_s] = sort(fit);
            ps   = size(pop,1);
            seen = {};
            rows = {};
            cvals = [];   % cateto c de cada fila (para la tabla en campañas Cvar)
            rank = 0;
            for k = 1:ps
                if rank >= topN, break; end
                ind = pop(idx_s(k),:);
                % Clave de unicidad: redondea a 2 decimales para no duplicar
                % soluciones continuas casi idénticas
                key = sprintf('%.2f_%.2f_%.2f_%.2f_%.2f_%.2f', ...
                    ind(1),ind(2),ind(3),ind(4),ind(5),ind(6));
                if nV >= 7, key = [key sprintf('_%.2f',ind(7))]; end
                if any(strcmp(seen, key)), continue; end
                seen{end+1} = key;
                rank = rank + 1;

                c_ind = c_f;
                if nV >= 7, c_ind = ind(7); end
                mas = app.masa_scalar(ind(1),ind(2),ind(5),l1_f,...
                    ind(3),ind(4),l2_f,c_ind,ind(6));
                ep  = -fit_s(k);
                E   = ep * mas;

                label = sprintf('%s %d', etiqueta, rank);
                rows{end+1} = {label, ...
                    round(ind(1),2), round(ind(2),1), round(ind(5),1), ...
                    round(ind(3),2), round(ind(4),1), round(ind(6),2), ...
                    round(ep,2), round(mas,3), round(E,1)};
                cvals(end+1) = c_ind;
            end
        end

        % GA helpers
        function ind = ga_gen(app, lb, ub, catalog, ind_in)
            nv = numel(lb);
            if nargin<5
                ind_in = lb+(ub-lb).*rand(1,nv);
            end
            ind = max(min(ind_in,ub),lb);
            if catalog
                ind(1)=app.snap(ind(1),app.cat_esp_viga);
                ind(3)=app.snap(ind(3),app.cat_esp_viga);
                ind(6)=app.snap(ind(6),app.cat_esp_cart);
                ind(2)=app.snap(ind(2),app.cat_dims);
                ind(4)=app.snap(ind(4),app.cat_dims);
                ind(5)=app.snap(ind(5),app.cat_dims);
                if nv >= 7
                    ind(7)=app.snap(ind(7),app.cat_c);
                end
                mm1=min(ind(2),ind(5))/4;
                if ind(1)>mm1, ind(1)=app.snap_below(mm1,app.cat_esp_viga); end
                mm2=min(ind(4),ind(5))/4;
                if ind(3)>mm2, ind(3)=app.snap_below(mm2,app.cat_esp_viga); end
            end
        end

        function v = snap(~,x,vals)
            [~,i]=min(abs(vals-x)); v=vals(i);
        end

        function v = snap_below(~,x,vals)
            ok=vals(vals<=x); if isempty(ok), v=vals(1); else, v=max(ok); end
        end

        function fit = ga_eval_pop(app, pop, mdl, l1, l2, c_fixed)
            n=size(pop,1); nv=size(pop,2);
            fp=zeros(n,10);
            for i=1:n
                d=pop(i,:);
                c_i = c_fixed;
                if nv>=7, c_i=d(7); end
                fp(i,:)=[d(1),d(2),d(5),l1,d(3),d(4),d(5),l2,c_i,d(6)];
            end
            tab=array2table(fp,'VariableNames',...
                {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
            E=mdl.predictFcn(tab);
            masa=app.masa_vec(pop,l1,l2,c_fixed);
            epm=E./masa;
            u_ecr = app.umbral_ecr66;
            fit=zeros(n,1);
            for i=1:n
                if ~isfinite(epm(i))||epm(i)<=0
                    fit(i)=1e9;
                elseif u_ecr > 0 && epm(i) < u_ecr
                    % Penalización ECE R66: gradiente hacia la factibilidad,
                    % siempre peor que cualquier diseño factible (= T04)
                    fit(i)=1e6 + (u_ecr - epm(i));
                else
                    fit(i)=-epm(i);
                end
            end
        end

        function p=ga_sel(~,pop,fit)
            k=3; n=size(pop,1); idx=randi(n,[k,1]); [~,b]=min(fit(idx)); p=pop(idx(b),:);
        end

        function c=ga_cx(~,p1,p2,nv)
            mask=rand(1,nv)<0.5; c=p1; c(mask)=p2(mask);
        end

        function ind=ga_mut(~,ind,lb,ub,r,nv)
            for j=1:nv
                if rand<r, ind(j)=ind(j)+randn*0.1*(ub(j)-lb(j)); end
            end
        end

        % ---------------------------------------------------------------
        % VENTANA FLOTANTE — CATÁLOGO
        % ---------------------------------------------------------------
        function abrir_catalogo(app)
            app.cargar_campana();
            app.autoset_cat_c();
            existing = findall(0,'Type','figure','Name','Catálogo de perfiles');
            if ~isempty(existing)
                figure(existing(1)); return;
            end
            win = uifigure('Name','Catálogo de perfiles',...
                'Position',[200 80 840 680],...
                'Resize','off');
            app.tab_catalog(win);
        end

        function tab_catalog(app, par)
            U = struct();
            uilabel(par,'Text','Catálogo de perfiles de acero',...
                'Position',[12 646 460 22],'FontSize',12,'FontWeight','bold');
            uilabel(par,'Text',...
                ['Los valores del catálogo que queden fuera del rango del DOE son extrapolación ' ...
                 '— el surrogate los predice con menos fiabilidad.'],...
                'Position',[12 624 816 18],'FontSize',8,'FontColor',[0.45 0.45 0.45],...
                'WordWrap','on');

            tipos  = {'Espesores viga  m  (mm)','Dimensiones a / b (mm)',...
                      'Espesores cartela  e_c  (mm)','Cateto cartela  c  (mm)'};
            campos = {'ev','dim','ec','cc'};
            y0s    = [490 365 240 115];   % 4 paneles, h=115 cada uno

            U.cat = struct();
            for k = 1:4
                pan = uipanel(par,'Title',tipos{k},...
                    'Position',[12 y0s(k) 816 115],'FontSize',9);
                U.cat.(campos{k}).lista = uilistbox(pan,...
                    'Position',[5 6 225 82],'Multiselect','on','FontSize',10);
                uilabel(pan,'Text','Añadir valor:','Position',[242 78 90 18],'FontSize',9);
                U.cat.(campos{k}).edit = uieditfield(pan,'numeric','Value',0,...
                    'Position',[242 56 78 22]);
                uibutton(pan,'Text','+ Añadir','Position',[328 56 80 22],...
                    'ButtonPushedFcn',@(~,~) app.cb_add_cat(campos{k}));
                uibutton(pan,'Text','− Eliminar sel.','Position',[416 56 110 22],...
                    'ButtonPushedFcn',@(~,~) app.cb_del_cat(campos{k}));
                U.cat.(campos{k}).rango = uilabel(pan,...
                    'Text','Rango del DOE activo: —',...
                    'Position',[242 32 570 18],'FontSize',9,'FontColor',[0.3 0.3 0.3]);
                U.cat.(campos{k}).aviso = uilabel(pan,'Text','',...
                    'Position',[242 8 570 22],'FontSize',9);
            end

            uibutton(par,'Text','↻  Aplicar catálogo y relanzar GA',...
                'Position',[12 72 250 34],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white','FontWeight','bold',...
                'ButtonPushedFcn',@(~,~) app.cb_recalc_cat());
            uilabel(par,...
                'Text',['Añadir/eliminar valores no regenera el DOE ni el surrogate. ' ...
                        'Solo afecta a qué puntos evalúa el GA y la Fuerza bruta.'],...
                'Position',[272 72 560 34],'FontSize',8,'FontColor',[0.45 0.45 0.45],...
                'WordWrap','on');

            app.U.cat = U;
            app.refrescar_cat();
        end

        function refrescar_cat(app)
            U = app.U.cat;
            cats  = {app.cat_esp_viga, app.cat_dims, app.cat_esp_cart, app.cat_c};
            campos= {'ev','dim','ec','cc'};
            for k=1:4
                U.cat.(campos{k}).lista.Items = ...
                    cellfun(@num2str,num2cell(sort(cats{k})),'UniformOutput',false);
            end
            app.actualizar_rangos_cat();
        end

        function actualizar_rangos_cat(app)
            if isempty(app.campana), return; end
            U = app.U.cat;
            cats   = {app.cat_esp_viga, app.cat_dims, app.cat_esp_cart, app.cat_c};
            campos = {'ev','dim','ec','cc'};

            % Variables DOE: [m1, a1, m2, a2, b, e_cartela, c] → índices 1-7
            % Grupos de catálogo → índices correspondientes en meta.lb/ub
            idx_grp = {[1 3], [2 4 5], [6], [7]};

            % Preferencia: usar los límites declarados en el DOE (meta.lb/ub).
            % Con LHS/Sobol los puntos muestreados nunca caen exactamente en el
            % borde → usar min/max observado daría falsos positivos.
            lb_ref = []; ub_ref = [];
            meta_f = fullfile(app.ruta_campana(),'meta_campana.mat');
            if isfile(meta_f)
                try
                    m = load(meta_f,'meta');
                    if isfield(m.meta,'lb') && numel(m.meta.lb) >= 6
                        lb_ref = m.meta.lb;
                        ub_ref = m.meta.ub;
                        % Metas antiguas (6 elementos) no incluyen c como 7º.
                        % Añadirlo desde c_fijo para que idx_grp{4}=[7] funcione.
                        if numel(lb_ref) == 6 && isfield(m.meta,'c_fijo')
                            lb_ref(7) = m.meta.c_fijo;
                            ub_ref(7) = m.meta.c_fijo;
                        end
                    end
                catch, end
            end

            % Fallback: usar min/max del CSV si no hay meta
            if isempty(lb_ref)
                db_f = fullfile(app.ruta_campana(),'basededatos.csv');
                if ~isfile(db_f), return; end
                try
                    db = readtable(db_f);
                    % Construir lb/ub sintéticos desde los datos observados
                    cols_grp = {{'m1','m2'}, {'a1','a2','b1'}, {'e_cartela'}, {'c'}};
                    for k = 1:4
                        vals = [];
                        for c2 = cols_grp{k}
                            if ismember(c2{1}, db.Properties.VariableNames)
                                vals = [vals; db.(c2{1})]; %#ok<AGROW>
                            end
                        end
                        lo = min(vals); hi = max(vals);
                        % Expandir ligeramente: LHS/Sobol nunca toca los bordes exactos
                        marg = max(0.05, (hi - lo) * 0.02);
                        app.mostrar_rango_cat(U, campos{k}, cats{k}, lo - marg, hi + marg, true);
                    end
                catch, end
                return;
            end

            % Camino principal: límites del DOE desde meta
            for k = 1:4
                lo = min(lb_ref(idx_grp{k}));
                hi = max(ub_ref(idx_grp{k}));
                app.mostrar_rango_cat(U, campos{k}, cats{k}, lo, hi, false);
            end
        end

        function mostrar_rango_cat(~, U, campo, cat_vals, lo, hi, es_observado)
            if es_observado
                U.cat.(campo).rango.Text = sprintf(...
                    'Rango observado (sin meta): [%.0f, %.0f] mm', lo, hi);
            else
                U.cat.(campo).rango.Text = sprintf(...
                    'Espacio del DOE: [%.0f, %.0f] mm', lo, hi);
            end
            fuera = cat_vals(cat_vals < lo | cat_vals > hi);
            if ~isempty(fuera)
                U.cat.(campo).aviso.Text = sprintf(...
                    '⚠  %s mm quedan fuera del espacio de diseño (extrapolación)', num2str(fuera));
                U.cat.(campo).aviso.FontColor = [0.65 0.30 0.00];
            else
                U.cat.(campo).aviso.Text = '✓  Todos los valores están dentro del espacio de diseño';
                U.cat.(campo).aviso.FontColor = [0.10 0.48 0.10];
            end
        end

        function cb_add_cat(app, campo)
            U  = app.U.cat;
            v  = U.cat.(campo).edit.Value;
            if v<=0, uialert(app.fig,'El valor debe ser > 0.','Error'); return; end
            switch campo
                case 'ev',  app.cat_esp_viga = unique([app.cat_esp_viga v]);
                case 'dim', app.cat_dims     = unique([app.cat_dims v]);
                case 'ec',  app.cat_esp_cart = unique([app.cat_esp_cart v]);
                case 'cc',  app.cat_c        = unique([app.cat_c v]); app.cat_c_auto = false;
            end
            app.refrescar_cat();
        end

        function cb_del_cat(app, campo)
            U   = app.U.cat;
            sel = U.cat.(campo).lista.Value;
            if isempty(sel), return; end
            vd = cellfun(@str2double,sel);
            switch campo
                case 'ev',  app.cat_esp_viga = setdiff(app.cat_esp_viga,vd);
                case 'dim', app.cat_dims     = setdiff(app.cat_dims,vd);
                case 'ec',  app.cat_esp_cart = setdiff(app.cat_esp_cart,vd);
                case 'cc',  app.cat_c        = setdiff(app.cat_c,vd); app.cat_c_auto = false;
            end
            if isempty(app.cat_esp_viga), app.cat_esp_viga=[2];  end
            if isempty(app.cat_dims),     app.cat_dims=[40];      end
            if isempty(app.cat_esp_cart), app.cat_esp_cart=[2];   end
            if isempty(app.cat_c),        app.cat_c=[80];         end
            app.refrescar_cat();
        end

        function cb_recalc_cat(app)
            app.cb_ga();
        end

        % ---------------------------------------------------------------
        function abrir_calc_ecr66(app)
        % Calculadora del umbral ECE R66 desde parámetros físicos del autobús.
        % Fórmula: E_total = M·g·h_cg·(1-cosθ)   [Reg. 66, Anexo 4]
        % E por sección = E_total / n_bahías
        % EPM_umbral   = E_seccion / masa_seccion
        % ---------------------------------------------------------------
            fw = uifigure('Name','Criterio ECE R66 — calculadora',...
                'Position',[200 150 560 430],'Resize','off');

            uilabel(fw,'Text','Cálculo del umbral mínimo de energía específica',...
                'Position',[12 396 536 22],'FontSize',11,'FontWeight','bold');
            uilabel(fw,'Text',...
                'ECE R66 Anexo 4:  E_total = M · g · h_cg · (1 − cos θ)   →   E_sección = E_total / n_bahías',...
                'Position',[12 376 536 16],'FontSize',8,'FontColor',[0.4 0.4 0.4]);

            % ── Parámetros del autobús ────────────────────────────────────
            pan = uipanel(fw,'Title','Parámetros del autobús',...
                'Position',[12 222 536 148],'FontSize',10);

            % Filas de arriba a abajo (y decrece hacia el fondo del panel)
            % panel tiene 148px; título ~18px; espacio útil ~130px
            %   fila 1 (Masa total)     → y=102
            %   fila 2 (Altura CdG)     → y=76
            %   fila 3 (Núm. bahías)    → y=50
            %   fila 4 (Ángulo vuelco)  → y=24
            %   nota inferior           → y=4
            % Leer ángulo de meta_campana.mat si existe (campo 'angulo')
            ang_default = 30;
            if ~isempty(app.campana)
                mf_ = fullfile(app.ruta_campana(),'meta_campana.mat');
                if isfile(mf_)
                    try, mm_=load(mf_,'meta'); ang_default=mm_.meta.angulo; catch, end
                end
            end

            % Solo 3 filas que el usuario rellena; ángulo y masa son automáticos
            ys = [102 76 50];
            etqs_u = {'Masa total del autobús  M (kg):', ...
                      'Altura CdG sobre eje  h_cg (m):', ...
                      'Número de bahías (arcos)  n:'};
            vals_u  = {12000,   1.0,    4};
            lims_u  = {[500 50000], [0.1 5.0], [1 30]};
            steps_u = {100,    0.05,   1};
            fmts_u  = {'%.0f', '%.2f', '%.0f'};   % evita notación científica
            keys_u  = {'M','hcg','nb'};
            hh = struct();
            for k = 1:3
                uilabel(pan,'Text',etqs_u{k},...
                    'Position',[8 ys(k) 248 20],'FontSize',9);
                hh.(keys_u{k}) = uispinner(pan,...
                    'Value',vals_u{k},'Limits',lims_u{k},'Step',steps_u{k},...
                    'ValueDisplayFormat',fmts_u{k},...
                    'Position',[260 ys(k)-2 130 24]);
            end

            % Ángulo: solo lectura, viene del meta
            uilabel(pan,'Text','Ángulo de vuelco  θ (°):',...
                'Position',[8 24 248 20],'FontSize',9);
            hh.ang = uispinner(pan,'Value',ang_default,'Limits',[5 90],'Step',1,...
                'ValueDisplayFormat','%.0f',...
                'Position',[260 22 130 24],'Enable','on');
            uilabel(pan,'Text',...
                sprintf('Leído de meta_campana.mat (angulo=%.0f°). Cambia en T01 si hace falta.',ang_default),...
                'Position',[8 4 520 16],'FontSize',7,'FontColor',[0.35 0.50 0.35]);

            % ── Parámetro de sección ─────────────────────────────────────
            pan2 = uipanel(fw,'Title','Parámetro de la sección optimizada',...
                'Position',[12 148 536 68],'FontSize',10);
            uilabel(pan2,'Text','Masa de la sección  m_sec (kg):',...
                'Position',[8 32 240 20],'FontSize',9);
            m_sec_def = 1.0;
            if ~isempty(app.campana)
                of_ = fullfile(app.ruta_campana(),'optimo_GA.mat');
                if isfile(of_)
                    try, o_=load(of_,'optimo'); m_sec_def=o_.optimo.masa_estimada; catch, end
                end
            end
            hh.msec = uispinner(pan2,'Value',m_sec_def,'Limits',[0.001 1000],'Step',0.01,...
                'ValueDisplayFormat','%.3f',...
                'Position',[252 30 130 24]);
            uilabel(pan2,'Text','(se lee del óptimo GA si está disponible)',...
                'Position',[8 8 520 16],'FontSize',7,'FontColor',[0.5 0.5 0.5]);

            % ── Resultado ────────────────────────────────────────────────
            pan3 = uipanel(fw,'Title','Umbral calculado',...
                'Position',[12 60 536 90],'FontSize',10);
            % y=0 es fondo del panel; el título ocupa ~20px desde arriba (y=70 top).
            % Ponemos los items bien separados del borde superior.
            uilabel(pan3,'Text','E_total (J):',     'Position',[8 44 150 18],'FontSize',9);
            lbl_Et  = uilabel(pan3,'Text','—',      'Position',[165 44 180 18],...
                'FontSize',9,'FontWeight','bold');
            uilabel(pan3,'Text','E_sección (J):',   'Position',[8 24 150 18],'FontSize',9);
            lbl_Es  = uilabel(pan3,'Text','—',      'Position',[165 24 180 18],...
                'FontSize',9,'FontWeight','bold');
            uilabel(pan3,'Text','EPM mínimo (J/kg):','Position',[8 4 150 18],'FontSize',9);
            lbl_EPM = uilabel(pan3,'Text','—',      'Position',[165 2 230 20],...
                'FontSize',11,'FontWeight','bold','FontColor',[0.30 0.16 0.48]);

            % Recálculo en tiempo real — anonymous function capturando handles por referencia
            recalcFcn = @(~,~) app.cb_recalc_ecr66(hh, lbl_Et, lbl_Es, lbl_EPM);
            for k = 1:3
                hh.(keys_u{k}).ValueChangedFcn = recalcFcn;
            end
            hh.ang.ValueChangedFcn  = recalcFcn;
            hh.msec.ValueChangedFcn = recalcFcn;
            recalcFcn([],[]);

            % ── Botones ──────────────────────────────────────────────────
            uibutton(fw,'Text','✓  Aplicar umbral y cerrar',...
                'Position',[288 12 260 46],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.aplicar_umbral_ecr66(fw, lbl_EPM));
            uibutton(fw,'Text','Cancelar',...
                'Position',[12 12 140 46],...
                'FontSize',10,...
                'ButtonPushedFcn',@(~,~) close(fw));
        end

        function aplicar_umbral_ecr66(app, fw, lbl_EPM)
            txt = lbl_EPM.Text;  % e.g. "312.45 J/kg"
            val = str2double(extractBefore(txt,' '));
            if isnan(val) || val <= 0
                uialert(fw,'Valor inválido — revisa los parámetros.','Error'); return;
            end
            app.umbral_ecr66 = val;
            % Actualizar labels en Val y MC
            txt_set = sprintf('Umbral: %.2f J/kg', val);
            if isfield(app.U,'val') && isfield(app.U.val,'lbl_ecr66') && isvalid(app.U.val.lbl_ecr66)
                app.U.val.lbl_ecr66.Text = txt_set;
                app.U.val.lbl_ecr66.FontColor = [0.30 0.16 0.48];
            end
            if isfield(app.U,'mc') && isfield(app.U.mc,'lbl_ecr66_mc') && isvalid(app.U.mc.lbl_ecr66_mc)
                app.U.mc.lbl_ecr66_mc.Text = txt_set;
                app.U.mc.lbl_ecr66_mc.FontColor = [0.30 0.16 0.48];
            end
            close(fw);
        end

        % ---------------------------------------------------------------
        function cb_recalc_ecr66(~, hh, lbl_Et, lbl_Es, lbl_EPM)
        % Recalcula energías ECE R66 y actualiza labels en tiempo real.
        % ---------------------------------------------------------------
            Et_  = hh.M.Value * 9.81 * hh.hcg.Value * (1 - cosd(hh.ang.Value));
            Es_  = Et_ / hh.nb.Value;
            epm_ = Es_ / hh.msec.Value;
            lbl_Et.Text  = sprintf('%.0f J',    Et_);
            lbl_Es.Text  = sprintf('%.0f J',    Es_);
            lbl_EPM.Text = sprintf('%.2f J/kg', epm_);
        end

        % ---------------------------------------------------------------
        function cb_exportar_optim(app)
        % Exporta la tabla Top-N de la optimización a CSV.
        % ---------------------------------------------------------------
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U = app.U.ga;
            datos = U.tabla.Data;
            if isempty(datos)
                uialert(app.fig,'La tabla está vacía. Ejecuta primero el GA o la Fuerza bruta.','Sin datos');
                return;
            end
            n_cols = size(datos, 2);
            cols10 = {'Rank','m1','a1','b','m2','a2','e_c','EPM_J_kg','Masa_kg','E_J'};
            cols11 = {'Rank','m1','a1','b','m2','a2','e_c','EPM_J_kg','Masa_kg','E_J','Modo'};
            if n_cols == 11
                cols = cols11;
            else
                cols = cols10;
            end
            try
                t = cell2table(datos,'VariableNames',cols);
            catch
                uialert(app.fig,'Error formando la tabla. Comprueba que la optimización está completa.','Error');
                return;
            end
            % Guardar siempre en campaña y ofrecer también "Guardar como..."
            ruta_camp = fullfile(app.ruta_campana(),'resultados_optimizacion.csv');
            writetable(t, ruta_camp);
            [fn,fp] = uiputfile('*.csv','Guardar también como...',...
                fullfile(app.pipeline_dir,'resultados_optimizacion.csv'));
            if ~isequal(fn,0)
                writetable(t, fullfile(fp,fn));
                uialert(app.fig, sprintf('Guardado en campaña y en:\n%s', fullfile(fp,fn)),...
                    'Exportado','Icon','success');
            else
                uialert(app.fig, sprintf('Guardado en campaña:\n%s', ruta_camp),...
                    'Exportado','Icon','success');
            end
        end

        % ---------------------------------------------------------------
        % TAB 6 — VALIDACIÓN
        % ---------------------------------------------------------------
        function tab_val(app, par)
            U = struct();
            uilabel(par,'Text','Validación con ANSYS — elige el diseño a simular',...
                'Position',[12 630 700 24],'FontSize',12,'FontWeight','bold');

            % ── Controles top-N por fuente ───────────────────────────────
            uilabel(par,'Text','Top a validar:','Position',[12 610 95 18],...
                'FontSize',9,'FontWeight','bold');
            uilabel(par,'Text','Global cat.:','Position',[110 610 72 18],'FontSize',9);
            U.n_cat_spin = uispinner(par,'Value',3,'Limits',[1 20],'Step',1,...
                'Position',[184 607 42 22]);
            uilabel(par,'Text','Global cont.:','Position',[232 610 75 18],'FontSize',9);
            U.n_cont_spin = uispinner(par,'Value',2,'Limits',[0 20],'Step',1,...
                'Position',[309 607 42 22]);
            uilabel(par,'Text','IAv (Viga):','Position',[357 610 68 18],'FontSize',9);
            U.n_iav_spin = uispinner(par,'Value',1,'Limits',[0 10],'Step',1,...
                'Position',[427 607 42 22]);
            uilabel(par,'Text','IAc (Cart.):','Position',[475 610 68 18],'FontSize',9);
            U.n_iac_spin = uispinner(par,'Value',1,'Limits',[0 10],'Step',1,...
                'Position',[545 607 42 22]);
            U.n_cat_spin.ValueChangedFcn  = @(~,~) app.refrescar_panel_optimo();
            U.n_cont_spin.ValueChangedFcn = @(~,~) app.refrescar_panel_optimo();
            U.n_iav_spin.ValueChangedFcn  = @(~,~) app.refrescar_panel_optimo();
            U.n_iac_spin.ValueChangedFcn  = @(~,~) app.refrescar_panel_optimo();
            uibutton(par,'Text','↻ Refrescar','Position',[595 606 110 26],...
                'FontSize',9,'ButtonPushedFcn',@(~,~) app.refrescar_panel_optimo());
            uilabel(par,'Text','Diseños disponibles — clic para seleccionar:',...
                'Position',[715 610 395 18],'FontSize',9,'FontColor',[0.4 0.4 0.4]);

            U.tabla_sel = uitable(par,'Position',[12 448 1118 152],...
                'ColumnName',{'Tipo','m1','a1','b','l','m2','a2','e_c','c','EPM pred. (J/kg)'},...
                'ColumnWidth',{70,42,42,42,55,42,42,42,42,105},...
                'RowName',{},'FontSize',9,...
                'SelectionType','row',...
                'CellSelectionCallback',@(~,e) app.cb_val_sel(e));

            % ── Panel diseño seleccionado (y=358, h=84) ──────────────────
            pan=uipanel(par,'Title','Diseño seleccionado',...
                'Position',[12 358 1118 84],'FontSize',10);
            etqs={'m1:','a1:','b:','l:','m2:','a2:','e_c:','c:'};
            keys={'m1','a1','b1','l1','m2','a2','ec','c'};
            U.opt=struct();
            for k=1:8
                col=mod(k-1,4); row_k=floor((k-1)/4);
                y_item = 42 - row_k*28;        % row0→y=42, row1→y=14
                uilabel(pan,'Text',etqs{k},...
                    'Position',[8+col*278 y_item 32 18],'FontSize',9);
                U.opt.(keys{k})=uilabel(pan,'Text','—',...
                    'Position',[42+col*278 y_item 190 18],...
                    'FontSize',10,'FontWeight','bold');
            end

            % ── Botones ──────────────────────────────────────────────────
            U.btn=uibutton(par,'Text','▶  Lanzar seleccionado',...
                'Position',[12 316 195 36],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_val());

            uibutton(par,'Text','▶▶  Validar todos',...
                'Position',[217 316 160 36],...
                'BackgroundColor',app.COL_AZUL,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_val_todos());

            U.lbl_status=uilabel(par,'Text','Selecciona una fila o lanza todos.',...
                'Position',[387 316 356 36],'FontSize',10,'WordWrap','on');

            % ── Umbral ECE R66 (calculado desde parámetros del autobús) ──
            uibutton(par,'Text','📐  Criterio ECE R66...',...
                'Position',[750 318 185 34],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white',...
                'FontSize',9,'FontWeight','bold',...
                'ButtonPushedFcn',@(~,~) app.abrir_calc_ecr66());
            U.lbl_ecr66 = uilabel(par,'Text','Sin umbral definido',...
                'Position',[944 316 184 36],...
                'FontSize',10,'FontWeight','bold','WordWrap','on',...
                'FontColor',[0.5 0.5 0.5]);

            % ── Resultados comparación (y=196, h=114) ────────────────────
            pan2=uipanel(par,'Title','Último resultado — Comparación IA vs ANSYS real',...
                'Position',[12 186 1118 124],'FontSize',10);
            etqs2={'EPM predicha (J/kg):','EPM real (J/kg):','Error relativo:',...
                   'Energía real (J):','Fuerza máx (N):','Modo real ANSYS:',...
                   'Modo predicho (IA):','Acierto modo:'};
            keys2={'epm_p','epm_r','err','E_J','F_N','modo','modo_pred','modo_ok'};
            U.res=struct();
            y_filas=[76 50 24];
            for k=1:8
                col=mod(k-1,3); row_k=floor((k-1)/3); yy=y_filas(row_k+1);
                uilabel(pan2,'Text',etqs2{k},'Position',[10+col*358 yy 200 20],'FontSize',9);
                U.res.(keys2{k})=uilabel(pan2,'Text','—',...
                    'Position',[215+col*358 yy 130 22],'FontSize',11,'FontWeight','bold');
            end
            U.lbl_verdict=uilabel(pan2,'Text','','Position',[955 8 150 90],...
                'FontSize',12,'FontWeight','bold','WordWrap','on');

            U.log=uitextarea(par,'Position',[12 10 1118 180],...
                'Editable','off','FontSize',8,'FontName','Consolas','Value',{'Selecciona un diseño y pulsa Lanzar.'});

            app.U.val=U;
            app.htabs.SelectionChangedFcn=@(~,e) app.cb_tab_changed(e);
        end

        function cb_tab_changed(app, e)
            switch e.NewValue.Title
                case 'Validación'
                    app.refrescar_panel_optimo();
                case 'Visor'
                    app.cb_visor_refresh();
            end
        end

        function refrescar_panel_optimo(app)
            app.cargar_campana();
            if isempty(app.campana), return; end
            of = fullfile(app.ruta_campana(),'optimo_GA.mat');
            if ~isfile(of), return; end
            o = load(of,'optimo'); opt = o.optimo;
            U = app.U.val;

            % Construir lista de diseños disponibles
            filas = {};
            disenos = {};   % cell array de structs
            avisos = {};

            % Función helper para construir struct de diseño
            hacer_diseno = @(m1,a1,b,l1,m2,a2,ec,c,l2) struct(...
                'm1',m1,'a1',a1,'b1',b,'l1',l1,'m2',m2,'a2',a2,...
                'b2',b,'l2',l2,'c',c,'e_cartela',ec);

            % Leer límites de los spinners
            n_cat  = app.U.val.n_cat_spin.Value;
            n_cont = app.U.val.n_cont_spin.Value;
            n_iav  = app.U.val.n_iav_spin.Value;
            n_iac  = app.U.val.n_iac_spin.Value;

            % 1. Top catalog desde top_catalog
            if isfield(opt,'top_catalog') && ~isempty(opt.top_catalog)
                tiene_c = isfield(opt,'top_catalog_c') && numel(opt.top_catalog_c) >= numel(opt.top_catalog);
                for k = 1:min(n_cat, numel(opt.top_catalog))
                    r = opt.top_catalog{k};
                    % r = {rank, m1, a1, b, m2, a2, e_c, EPM, masa, E}
                    try
                        m1=r{2}; a1=r{3}; b=r{4}; m2=r{5}; a2=r{6}; ec=r{7}; epm=r{8};
                        if tiene_c, cc = opt.top_catalog_c(k); else, cc = opt.c; end  % c propia del diseño
                        filas{end+1} = {sprintf('Cat %d',k), m1, a1, b, opt.l1, m2, a2, ec, cc, epm};
                        disenos{end+1} = hacer_diseno(m1,a1,b,opt.l1,m2,a2,ec,cc,opt.l2);
                        disenos{end}.energia_especifica_J_kg = epm;
                    catch, end
                end
            elseif n_cat >= 1
                % Fallback: solo el ganador si el optimo antiguo no contiene Top-N.
                filas{end+1} = {'Cat 1', opt.m1, opt.a1, opt.b1, opt.l1,...
                    opt.m2, opt.a2, opt.e_cartela, opt.c, opt.energia_especifica_J_kg};
                disenos{end+1} = opt;
                if n_cat > 1
                    avisos{end+1} = 'Global cat.: solo hay 1 diseño guardado; relanza Fuerza bruta/GA para generar Top-N.'; %#ok<AGROW>
                end
            end

            % 2. Top continuo desde top_continuo
            if isfield(opt,'top_continuo') && ~isempty(opt.top_continuo)
                tiene_cc = isfield(opt,'top_continuo_c') && numel(opt.top_continuo_c) >= numel(opt.top_continuo);
                for k = 1:min(n_cont, numel(opt.top_continuo))
                    r = opt.top_continuo{k};
                    try
                        m1=r{2}; a1=r{3}; b=r{4}; m2=r{5}; a2=r{6}; ec=r{7}; epm=r{8};
                        if tiene_cc, cc = opt.top_continuo_c(k); else, cc = opt.c; end  % c propia del diseño
                        filas{end+1} = {sprintf('Cont %d',k), m1, a1, b, opt.l1, m2, a2, ec, cc, epm};
                        disenos{end+1} = hacer_diseno(m1,a1,b,opt.l1,m2,a2,ec,cc,opt.l2);
                        disenos{end}.energia_especifica_J_kg = epm;
                    catch, end
                end
            elseif n_cont >= 1 && isfield(opt,'continuo')
                wc = opt.continuo.ind;
                epm_c = opt.continuo.epm;
                filas{end+1} = {'Cont 1', round(wc(1),2), round(wc(2),1), round(wc(5),1),...
                    opt.l1, round(wc(3),2), round(wc(4),1), round(wc(6),2), opt.c, epm_c};
                d = hacer_diseno(wc(1),wc(2),wc(5),opt.l1,wc(3),wc(4),wc(6),opt.c,opt.l2);
                d.energia_especifica_J_kg = epm_c;
                disenos{end+1} = d;
                if n_cont > 1
                    avisos{end+1} = 'Global cont.: solo hay 1 diseño guardado; relanza GA para generar Top-N continuo.'; %#ok<AGROW>
                end
            elseif n_cont > 0
                avisos{end+1} = 'Global cont.: no hay candidatos continuos guardados; relanza GA continuo.'; %#ok<AGROW>
            end

            % 3. Óptimos modo-específicos (IAv / IAc) — top-N por spinner
            opt_modo_f = fullfile(app.ruta_campana(),'optimos_modo.mat');
            if isfile(opt_modo_f)
                try
                    om = load(opt_modo_f,'modo_optimos');
                    for k_om = 1:numel(om.modo_optimos)
                        entry   = om.modo_optimos{k_om};
                        lbl_om  = entry{1};
                        data_om = entry{2};   % cell array de structs (top-N) o struct único (legacy)
                        if isstruct(data_om), data_om = {data_om}; end  % compatibilidad legacy
                        if contains(lbl_om,'Viga'),  n_om = n_iav;
                        else,                         n_om = n_iac; end
                        for rank_om = 1:min(n_om, numel(data_om))
                            d_om  = data_om{rank_om};
                            lbl_r = sprintf('%s #%d', lbl_om, rank_om);
                            filas{end+1}   = {lbl_r, d_om.m1, d_om.a1, d_om.b1, d_om.l1,...
                                d_om.m2, d_om.a2, d_om.e_cartela, d_om.c,...
                                d_om.energia_especifica_J_kg};
                            disenos{end+1} = d_om;
                        end
                    end
                catch, end
            end

            if ~isempty(filas)
                U.tabla_sel.Data = vertcat(filas{:});
                app.estilo_tabla(U.tabla_sel, 10);
            else
                U.tabla_sel.Data = cell(0,10);
            end

            % Almacenar los structs de diseño para cb_val_sel
            U.tabla_sel.UserData = disenos;

            % Seleccionar automáticamente la primera fila
            if ~isempty(disenos)
                app.diseno_validar = disenos{1};
                app.actualizar_info_diseno(disenos{1});
                if ~isempty(avisos)
                    U.lbl_status.Text = strjoin(avisos,'  ');
                    U.lbl_status.FontColor = [0.65 0.35 0.05];
                else
                    U.lbl_status.Text = sprintf('%d diseños disponibles para validar.', numel(disenos));
                    U.lbl_status.FontColor = [0.2 0.2 0.6];
                end
            else
                app.diseno_validar = [];
                U.lbl_status.Text = 'No hay diseños disponibles. Ejecuta GA/Fuerza bruta o Análisis por modo.';
                U.lbl_status.FontColor = [0.7 0.1 0.1];
            end
        end

        function cb_val_sel(app, e)
            if isempty(e.Indices), return; end
            row = e.Indices(1);
            disenos = app.U.val.tabla_sel.UserData;
            if isempty(disenos) || row > numel(disenos), return; end
            app.diseno_validar = disenos{row};
            app.actualizar_info_diseno(disenos{row});
            app.U.val.lbl_status.Text = sprintf('Seleccionado: fila %d — pulsa "Lanzar" para validar.', row);
            app.U.val.lbl_status.FontColor = [0.2 0.2 0.6];
        end

        function actualizar_info_diseno(app, d)
            U = app.U.val;
            U.opt.m1.Text = num2str(d.m1,'%.2f');
            U.opt.a1.Text = num2str(d.a1,'%.1f');
            U.opt.b1.Text = num2str(d.b1,'%.1f');
            U.opt.l1.Text = num2str(d.l1,'%.0f');
            U.opt.m2.Text = num2str(d.m2,'%.2f');
            U.opt.a2.Text = num2str(d.a2,'%.1f');
            U.opt.ec.Text = num2str(d.e_cartela,'%.2f');
            U.opt.c.Text  = num2str(d.c,'%.0f');
        end

        function cb_val(app)
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            if isempty(app.diseno_validar)
                uialert(app.fig,'Selecciona un diseño de la tabla primero.','Sin selección'); return;
            end
            U   = app.U.val;
            car = app.ruta_campana();
            opt = app.diseno_validar;   % diseño elegido por el usuario

            mf=fullfile(car,'meta_campana.mat');
            if isfile(mf), m=load(mf,'meta'); meta=m.meta;
            else, meta.fy_pa=235500000; meta.Et_pa=1160000000; meta.angulo=30;
            end

            app.generar_script_sc(opt.m1,opt.a1,opt.b1,opt.l1,...
                opt.m2,opt.a2,opt.b2,opt.l2,opt.c,opt.e_cartela);
            app.preparar_journal();
            csv_out=fullfile(app.pipeline_dir,'parametrossalida.csv');
            if isfile(csv_out), delete(csv_out); end

            setenv('TFG_BATCH_MODE','1');
            setenv('TFG_CAMPAIGN_NAME',app.campana);
            setenv('TFG_SIM_ID','VALIDACION');
            setenv('TFG_PIPELINE_DIR',strrep(app.pipeline_dir,'\','/'));
            setenv('TFG_PARAM_B_MM',num2str(opt.b1,'%.4f'));
            char_dim_val = (opt.a1 + opt.a2 + 2*opt.b1) / 4;
            setenv('TFG_CHAR_DIM_MM', num2str(char_dim_val,'%.4f'));
            setenv('TFG_C_MM',num2str(opt.c,'%.4f'));
            setenv('TFG_LONGITUD_VIGA_MM',num2str(opt.l1,'%.4f'));
            setenv('TFG_ANGULO_DESPLAZAMIENTO_DEG',num2str(meta.angulo,'%.4f'));
            setenv('TFG_DIR_X',num2str(app.dir_x_sign(),'%d'));
            setenv('TFG_YIELD_PA',num2str(meta.fy_pa,'%.10g'));
            setenv('TFG_TANGENT_MODULUS_PA',num2str(meta.Et_pa,'%.10g'));
            % Reutiliza la configuracion de substeps/malla de la pestaña Sim si existe
            Us = app.U.sim;
            setenv('TFG_SUBSTEPS_INIT', num2str(Us.ss_init.Value));
            setenv('TFG_SUBSTEPS_MIN',  num2str(Us.ss_min.Value));
            setenv('TFG_SUBSTEPS_MAX',  num2str(Us.ss_max.Value));
            setenv('TFG_MESH_RESOLUTION', num2str(Us.mesh_res.Value));
            setenv('TFG_MESH_SOI_RADIUS', num2str(Us.mesh_soi.Value,'%.1f'));
            setenv('TFG_MESH_COARSE_DIV', num2str(Us.mesh_coarse_div.Value));
            setenv('TFG_MESH_FINE_DIV',   num2str(Us.mesh_fine_div.Value));
            setenv('TFG_MESH_FINE_MIN_MM', num2str(Us.mesh_fine_min.Value,'%.2f'));
            setenv('TFG_MESH_FINE_MAX_MM', num2str(Us.mesh_fine_max.Value,'%.2f'));

            journal_gen=fullfile(app.pipeline_dir,'journal_generado.wbjn');
            % ── Predecir modo antes de lanzar ANSYS ──────────────────────
            mf_pred = '—';
            try
                mf_mat2 = load(fullfile(car,'modelo_surrogate.mat'));
                if isfield(mf_mat2,'classifierModel')
                    cl2 = mf_mat2.classifierModel;
                    t_cl = array2table([opt.m1,opt.a1,opt.b1,opt.l1,opt.m2,opt.a2,opt.b1,opt.l2,opt.c,opt.e_cartela],...
                        'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
                    mf_pred = char(cl2.predictFcn(t_cl));
                end
            catch, end
            U.res.modo_pred.Text = mf_pred;
            U.res.modo_ok.Text   = '—';
            app.log_tab(U.log, sprintf('Modo predicho por clasificador: %s', mf_pred));

            dos(sprintf('start "" "%s" -B -R "%s"',app.ansys_path,journal_gen));
            app.log_tab(U.log,'ANSYS lanzado. Esperando...');

            if app.esperar_csv(csv_out,10800,U.log)
                T    = readtable(csv_out);
                epm_r = T{1,'Energy_per_Mass_J_kg'};
                E_r   = T{1,'Energy_J'};
                F_r   = T{1,'Force_N'};
                epm_p = opt.energia_especifica_J_kg;
                err   = 100*abs(epm_r-epm_p)/abs(epm_r);

                % Leer Y_Max y calcular modo de fallo
                if ismember('Y_Max_Stress_mm',T.Properties.VariableNames)
                    y_max_val = T{1,'Y_Max_Stress_mm'};
                else
                    y_max_val = NaN;
                end
                [ph_v,la_v,mf_v] = calcular_pivot(y_max_val, opt.c, opt.a1, opt.a2, opt.l1);

                % Actualizar panel de resultados
                U.res.epm_p.Text = sprintf('%.4f',epm_p);
                U.res.epm_r.Text = sprintf('%.4f',epm_r);
                U.res.err.Text   = sprintf('%.2f %%',err);
                U.res.E_J.Text   = sprintf('%.1f',E_r);
                U.res.F_N.Text   = sprintf('%.0f',F_r);
                U.res.modo.Text  = mf_v;
                switch mf_v
                    case 'Viga',    U.res.modo.FontColor=[0.05 0.45 0.10];
                    case 'Cartela', U.res.modo.FontColor=[0.65 0.25 0.00];
                    otherwise,      U.res.modo.FontColor=[0.40 0.40 0.40];
                end
                % Acierto del clasificador de modo
                % Hibrido se trata como Cartela para la comparacion
                mf_v_cmp = mf_v;
                if strcmp(mf_v_cmp,'Hibrido'), mf_v_cmp = 'Cartela'; end
                if ~strcmp(mf_pred,'—')
                    if strcmp(mf_pred, mf_v_cmp)
                        U.res.modo_ok.Text      = '✓ Correcto';
                        U.res.modo_ok.FontColor = [0.05 0.45 0.10];
                    else
                        U.res.modo_ok.Text      = '✗ Incorrecto';
                        U.res.modo_ok.FontColor = [0.70 0.08 0.08];
                    end
                end

                if err<5,      verd='Muy preciso (<5%)';   vc=[0.1 0.5 0.1];
                elseif err<10, verd='Aceptable (<10%)';    vc=[0.4 0.5 0.0];
                elseif err<20, verd='Mejorable (10-20%)';  vc=[0.7 0.4 0.0];
                else,          verd='Poco fiable (>20%)';  vc=[0.7 0.1 0.1];
                end
                U.lbl_verdict.Text=verd; U.lbl_verdict.FontColor=vc;
                U.lbl_status.Text=sprintf('✓ Error: %.2f %%  |  Modo: %s',err,mf_v);
                U.lbl_status.FontColor=vc;
                % Verificación ECE R66
                u_ecr = app.umbral_ecr66;
                if u_ecr > 0
                    if epm_r >= u_ecr
                        U.lbl_ecr66.Text = sprintf('✓ ECE R66  (+%.1f%%)', 100*(epm_r-u_ecr)/u_ecr);
                        U.lbl_ecr66.FontColor = [0.08 0.48 0.08];
                    else
                        U.lbl_ecr66.Text = sprintf('✗ ECE R66  (−%.1f%%)', 100*(u_ecr-epm_r)/u_ecr);
                        U.lbl_ecr66.FontColor = [0.70 0.08 0.08];
                    end
                else
                    U.lbl_ecr66.Text = 'Umbral no establecido';
                    U.lbl_ecr66.FontColor = [0.5 0.5 0.5];
                end

                if strcmp(mf_pred,'—')
                    acierto_str = '(sin clasificador)';
                elseif strcmp(mf_pred, mf_v_cmp)
                    acierto_str = '✓ modo correcto';
                else
                    acierto_str = sprintf('✗ modo incorrecto (pred=%s)',mf_pred);
                end
                app.log_tab(U.log,sprintf('EPM pred=%.4f | real=%.4f | error=%.2f%% | Modo real: %s | %s (Y=%.1f mm)',...
                    epm_p,epm_r,err,mf_v,acierto_str,y_max_val));

                resultado=table(opt.m1,opt.a1,opt.b1,opt.l1,opt.m2,opt.a2,opt.b2,opt.l2,...
                    opt.c,opt.e_cartela,epm_p,epm_r,err,E_r,F_r,y_max_val,{mf_v},...
                    'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela',...
                    'EPM_Predicha_J_kg','EPM_Real_J_kg','Error_Pct','Energia_Real_J','Fuerza_Real_N',...
                    'Y_Max_Stress_mm','Modo_Fallo'});
                writetable(resultado,fullfile(car,'validacion_optimo.csv'));

                % Gráficas en Sim_VALIDACION/ (igual que las del batch)
                sim_val_dir = fullfile(car,'Sim_VALIDACION');
                curvas_val  = fullfile(sim_val_dir,'Curvas.csv');
                % Copiar log antes de que lo sobreescriba la siguiente sim
                log_src = fullfile(app.pipeline_dir,'mechanical_run.log');
                if isfile(log_src) && isfolder(sim_val_dir)
                    try, copyfile(log_src,fullfile(sim_val_dir,'mechanical_run.log')); catch, end
                end
                if isfile(curvas_val)
                    try
                        app.generar_graficas_sim(curvas_val,...
                            fullfile(sim_val_dir,'Graficas_Completas.png'),...
                            ph_v, la_v, 'VALIDACION');
                        app.log_tab(U.log,'Graficas_Completas.png guardada en Sim_VALIDACION/');
                    catch ex
                        app.log_tab(U.log,['Aviso gráficas: ' ex.message]);
                    end
                end
            else
                U.lbl_status.Text='ERROR: ANSYS no generó CSV.';
                U.lbl_status.FontColor=[0.7 0.1 0.1];
                app.log_tab(U.log,'TIMEOUT — revisa mechanical_run.log');
            end
        end

        function key = clave_validacion(~, d)
            % Clave persistente para reutilizar resultados ANSYS entre sesiones.
            c_val = 80;   if isfield(d,'c'),  c_val = d.c;  end
            l_val = 1000; if isfield(d,'l1'), l_val = d.l1; end
            key = sprintf('g_%d_%d_%d_%d_%d_%d_%d_%d', ...
                round(double(d.m1)*1000), round(double(d.a1)*1000), round(double(d.b1)*1000), ...
                round(double(d.m2)*1000), round(double(d.a2)*1000), round(double(d.e_cartela)*1000), ...
                round(double(c_val)*1000), round(double(l_val)*1000));
        end

        function cache_ansys = cargar_cache_validaciones(app, car, l1_ref, U)
            cache_ansys = struct();
            vf = fullfile(car,'validacion_todos.csv');
            if ~isfile(vf), return; end
            try
                opts = detectImportOptions(vf);
                opts.VariableNamingRule = 'preserve';
                Tval = readtable(vf, opts);
                req = {'m1','a1','b1','m2','a2','e_cartela','c','EPM_Real_J_kg',...
                       'Energia_Real_J','Fuerza_Real_N','Y_Max_Stress_mm','Modo_Fallo'};
                if ~all(ismember(req, Tval.Properties.VariableNames))
                    app.log_tab(U.log,'  validacion_todos.csv existe, pero no tiene el esquema esperado; se ignora cache.');
                    return;
                end

                n_loaded = 0;
                for ii = 1:height(Tval)
                    epm_r = Tval.EPM_Real_J_kg(ii);
                    if ~(isfinite(epm_r) && epm_r > 0), continue; end

                    d0 = struct('m1',Tval.m1(ii),'a1',Tval.a1(ii),'b1',Tval.b1(ii),...
                        'l1',l1_ref,'m2',Tval.m2(ii),'a2',Tval.a2(ii),...
                        'b2',Tval.b1(ii),'l2',l1_ref,'c',Tval.c(ii),...
                        'e_cartela',Tval.e_cartela(ii));
                    y_max = Tval.Y_Max_Stress_mm(ii);
                    [ph, la, mf_calc] = calcular_pivot(y_max, d0.c, d0.a1, d0.a2, d0.l1);

                    mf_saved = 'N/A';
                    try
                        raw_mf = Tval.Modo_Fallo(ii);
                        if iscell(raw_mf), raw_mf = raw_mf{1}; end
                        mf_saved = char(string(raw_mf));
                    catch, end
                    if isempty(mf_saved) || strcmp(mf_saved,'<missing>') || strcmp(mf_saved,'N/A')
                        mf_saved = mf_calc;
                    end

                    % Reconstruir la carpeta de origen (Sim_VAL_<Tipo>) para poder
                    % copiar sus imagenes/graficas/log si esta geometria se reutiliza.
                    src_dir = '';
                    if ismember('Tipo', Tval.Properties.VariableNames)
                        try
                            tp = char(string(Tval.Tipo(ii)));
                            src_dir = fullfile(car, ['Sim_VAL_' regexprep(tp,'[^a-zA-Z0-9]','_')]);
                        catch, end
                    end

                    key = app.clave_validacion(d0);
                    cache_ansys.(key) = struct('epm_r',epm_r,...
                        'E_r',Tval.Energia_Real_J(ii),'F_r',Tval.Fuerza_Real_N(ii),...
                        'y_max_k',y_max,'ph_k',ph,'la_k',la,'mf_k',mf_saved,...
                        'sim_dir_k',src_dir,'ansys_ok',true);
                    n_loaded = n_loaded + 1;
                end
                if n_loaded > 0
                    app.log_tab(U.log, sprintf('  Cache persistente: %d validaciones cargadas de validacion_todos.csv.', n_loaded));
                end
            catch ex
                app.log_tab(U.log, ['  Aviso cache validaciones: ' ex.message]);
            end
        end

        function guardar_validacion_incremental(app, car, resumen, cols) %#ok<INUSL>
            % Persiste validacion_todos.csv de forma incremental y no
            % destructiva: fusiona las filas nuevas (por 'Tipo') con las que
            % ya hubiera en el CSV, de modo que validar un subconjunto no borra
            % al resto y un cierre a media validación conserva lo ya hecho.
            if isempty(resumen), return; end
            vf = fullfile(car, 'validacion_todos.csv');
            tab_new = cell2table(vertcat(resumen{:}), 'VariableNames', cols);
            tab_out = tab_new;
            if isfile(vf)
                try
                    opts = detectImportOptions(vf);
                    opts.VariableNamingRule = 'preserve';
                    tab_old = readtable(vf, opts);
                    if all(ismember(cols, tab_old.Properties.VariableNames))
                        tab_old = tab_old(:, cols);
                        keep = ~ismember(string(tab_old.Tipo), string(tab_new.Tipo));
                        tab_old = tab_old(keep, :);
                        for cc = {'Tipo','Fuente_Modelo','Modo_Fallo'}
                            nm = cc{1};
                            tab_old.(nm) = cellstr(string(tab_old.(nm)));
                            tab_new.(nm) = cellstr(string(tab_new.(nm)));
                        end
                        tab_out = [tab_old; tab_new];
                    end
                catch
                    tab_out = tab_new;   % ante cualquier problema, no destruir lo nuevo
                end
            end
            try
                writetable(tab_out, vf);
            catch
                writetable(tab_new, vf);
            end
        end

        function cb_val_todos(app)
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U = app.U.val;
            disenos = U.tabla_sel.UserData;
            if isempty(disenos)
                uialert(app.fig,'No hay diseños disponibles. Ejecuta primero el GA.','Sin diseños');
                return;
            end

            n = numel(disenos);
            car = app.ruta_campana();
            app.log_tab(U.log, sprintf('── Iniciando validación de %d diseños ──', n));
            resumen = {};
            cols = {'Tipo','Fuente_Modelo','m1','a1','b1','m2','a2','e_cartela','c',...
                    'EPM_Modo_J_kg','EPM_IA0_J_kg','EPM_Real_J_kg',...
                    'Error_Modo_Pct','Error_IA0_Pct',...
                    'Energia_Real_J','Fuerza_Real_N','Y_Max_Stress_mm','Modo_Fallo'};
            cache_ansys = app.cargar_cache_validaciones(car, disenos{1}.l1, U);

            for k = 1:n
                d = disenos{k};
                tipo_k = U.tabla_sel.Data{k,1};
                app.log_tab(U.log, sprintf('[%d/%d] %s...', k, n, tipo_k));
                U.lbl_status.Text = sprintf('Validando %d/%d: %s', k, n, tipo_k);
                drawnow;

                app.diseno_validar = d;
                app.actualizar_info_diseno(d);
                % Clave de cache persistente basada en geometría y campaña.
                geo_key = app.clave_validacion(d);

                % Inicializar variables de resultado
                ansys_ok = false;
                epm_r = NaN; E_r = NaN; F_r = NaN; y_max_k = NaN;
                ph_k = 0; la_k = d.l1; mf_k = 'N/A'; sim_dir_k = '';

                if isfield(cache_ansys, geo_key)
                    % CACHE HIT: misma geometria ya simulada
                    ch = cache_ansys.(geo_key);
                    epm_r = ch.epm_r; E_r = ch.E_r; F_r = ch.F_r;
                    y_max_k = ch.y_max_k; ph_k = ch.ph_k; la_k = ch.la_k;
                    mf_k = ch.mf_k; ansys_ok = ch.ansys_ok;
                    app.log_tab(U.log,'  Geometria ya validada - reutilizando resultado ANSYS guardado.');

                    % Crear la carpeta de ESTE diseno y copiarle las imagenes,
                    % graficas, Curvas.csv y log de la carpeta de origen, para que
                    % el optimo por modo (Viga/Cartela) tenga su propia carpeta.
                    src_dir   = ch.sim_dir_k;
                    sim_id_k  = regexprep(tipo_k,'[^a-zA-Z0-9]','_');
                    sim_dir_k = fullfile(car, ['Sim_VAL_' sim_id_k]);
                    if ~isempty(src_dir) && isfolder(src_dir) && ~strcmp(src_dir, sim_dir_k)
                        if ~isfolder(sim_dir_k), try, mkdir(sim_dir_k); catch, end, end
                        pngs = dir(fullfile(src_dir,'*.png'));
                        for pp = 1:numel(pngs)
                            try, copyfile(fullfile(src_dir,pngs(pp).name), sim_dir_k); catch, end
                        end
                        for ff = {'Curvas.csv','mechanical_run.log'}
                            sfile = fullfile(src_dir, ff{1});
                            if isfile(sfile), try, copyfile(sfile, sim_dir_k); catch, end, end
                        end
                        app.log_tab(U.log, sprintf('  Imagenes/graficas/log copiadas de %s a esta carpeta.', src_dir));
                    end
                else
                    % CACHE MISS: lanzar ANSYS
                    mf_f = fullfile(car,'meta_campana.mat');
                    if isfile(mf_f), m_=load(mf_f,'meta'); meta=m_.meta;
                    else, meta.fy_pa=235500000; meta.Et_pa=1160000000; meta.angulo=30; end

                    app.generar_script_sc(d.m1,d.a1,d.b1,d.l1,...
                        d.m2,d.a2,d.b2,d.l2,d.c,d.e_cartela);
                    app.preparar_journal();

                    csv_out = fullfile(app.pipeline_dir,'parametrossalida.csv');
                    if isfile(csv_out), delete(csv_out); end

                    sim_id_k  = regexprep(tipo_k,'[^a-zA-Z0-9]','_');
                    sim_dir_k = fullfile(car, ['Sim_VAL_' sim_id_k]);

                    setenv('TFG_BATCH_MODE','1');
                    setenv('TFG_CAMPAIGN_NAME',app.campana);
                    setenv('TFG_SIM_ID', ['VAL_' sim_id_k]);
                    setenv('TFG_PIPELINE_DIR',strrep(app.pipeline_dir,'\','/'));
                    setenv('TFG_PARAM_B_MM',num2str(d.b1,'%.4f'));
                    char_dim_k = (d.a1 + d.a2 + 2*d.b1) / 4;
                    setenv('TFG_CHAR_DIM_MM', num2str(char_dim_k,'%.4f'));
                    setenv('TFG_C_MM',num2str(d.c,'%.4f'));
                    setenv('TFG_LONGITUD_VIGA_MM',num2str(d.l1,'%.4f'));
                    setenv('TFG_ANGULO_DESPLAZAMIENTO_DEG',num2str(meta.angulo,'%.4f'));
                    setenv('TFG_DIR_X',num2str(app.dir_x_sign(),'%d'));
                    setenv('TFG_YIELD_PA',num2str(meta.fy_pa,'%.10g'));
                    setenv('TFG_TANGENT_MODULUS_PA',num2str(meta.Et_pa,'%.10g'));
                    Us = app.U.sim;
                    setenv('TFG_SUBSTEPS_INIT',num2str(Us.ss_init.Value));
                    setenv('TFG_SUBSTEPS_MIN', num2str(Us.ss_min.Value));
                    setenv('TFG_SUBSTEPS_MAX', num2str(Us.ss_max.Value));
                    setenv('TFG_MESH_RESOLUTION', num2str(Us.mesh_res.Value));
                    setenv('TFG_MESH_SOI_RADIUS', num2str(Us.mesh_soi.Value,'%.1f'));
                    setenv('TFG_MESH_COARSE_DIV', num2str(Us.mesh_coarse_div.Value));
                    setenv('TFG_MESH_FINE_DIV',   num2str(Us.mesh_fine_div.Value));

                    journal_gen = fullfile(app.pipeline_dir,'journal_generado.wbjn');
                    dos(sprintf('start "" "%s" -B -R "%s"',app.ansys_path,journal_gen));

                    if app.esperar_csv(csv_out, 18000, U.log)   % 5 h por diseño (validación desatendida)
                        try
                            T = readtable(csv_out);
                            epm_r = T{1,'Energy_per_Mass_J_kg'};
                            E_r   = T{1,'Energy_J'};
                            F_r   = T{1,'Force_N'};
                            if ismember('Y_Max_Stress_mm',T.Properties.VariableNames)
                                y_max_k = T{1,'Y_Max_Stress_mm'};
                            end
                            [ph_k,la_k,mf_k] = calcular_pivot(y_max_k, d.c, d.a1, d.a2, d.l1);
                            ansys_ok = true;
                            cache_ansys.(geo_key) = struct('epm_r',epm_r,'E_r',E_r,'F_r',F_r,...
                                'y_max_k',y_max_k,'ph_k',ph_k,'la_k',la_k,'mf_k',mf_k,...
                                'sim_dir_k',sim_dir_k,'ansys_ok',true);
                            log_src = fullfile(app.pipeline_dir,'mechanical_run.log');
                            if isfile(log_src) && isfolder(sim_dir_k)
                                try, copyfile(log_src,fullfile(sim_dir_k,'mechanical_run.log')); catch, end
                            end
                            curvas_k = fullfile(sim_dir_k,'Curvas.csv');
                            if isfile(curvas_k)
                                try
                                    app.generar_graficas_sim(curvas_k,...
                                        fullfile(sim_dir_k,'Graficas_Completas.png'),...
                                        ph_k, la_k, tipo_k);
                                catch, end
                            end
                        catch ex
                            app.log_tab(U.log,['  ERROR leyendo CSV: ' ex.message]);
                        end
                    else
                        app.log_tab(U.log,'  TIMEOUT');
                    end
                end

                % Registrar resultado (comun para hit y miss)
                fuente_k = 'IA_0 (global)';
                if isfield(d,'fuente_modelo'), fuente_k = d.fuente_modelo; end

                if ansys_ok
                    epm_modo_p = d.energia_especifica_J_kg;
                    err_modo_k = 100*abs(epm_r-epm_modo_p)/abs(epm_r);
                    tiene_modo = isfield(d,'fuente_modelo') && ~strcmp(fuente_k,'IA_0 (global)');
                    if tiene_modo && isfield(d,'epm_ia0') && isfinite(d.epm_ia0)
                        epm_ia0_p = d.epm_ia0;
                    else
                        epm_ia0_p = epm_modo_p;
                    end
                    err_ia0_k = 100*abs(epm_r-epm_ia0_p)/abs(epm_r);
                    if tiene_modo
                        app.log_tab(U.log,sprintf(...
                            '  EPM real=%.4f J/kg | Error %s: %.2f%% | Error IA_0: %.2f%% | Modo: %s',...
                            epm_r,fuente_k,err_modo_k,err_ia0_k,mf_k));
                    else
                        app.log_tab(U.log,sprintf('  EPM real=%.4f J/kg | Error: %.2f%% | Modo: %s',...
                            epm_r,err_modo_k,mf_k));
                    end
                    U.res.epm_p.Text = sprintf('%.4f',epm_modo_p);
                    U.res.epm_r.Text = sprintf('%.4f',epm_r);
                    U.res.err.Text   = sprintf('%.2f %%',err_modo_k);
                    U.res.E_J.Text   = sprintf('%.1f',E_r);
                    U.res.F_N.Text   = sprintf('%.0f',F_r);
                    U.res.modo.Text  = mf_k;
                    resumen{end+1} = {tipo_k,fuente_k,d.m1,d.a1,d.b1,d.m2,d.a2,d.e_cartela,d.c,...
                        epm_modo_p,epm_ia0_p,epm_r,err_modo_k,err_ia0_k,E_r,F_r,y_max_k,mf_k};
                else
                    resumen{end+1} = {tipo_k,fuente_k,d.m1,d.a1,d.b1,d.m2,d.a2,d.e_cartela,d.c,...
                        NaN,NaN,NaN,NaN,NaN,NaN,NaN,NaN,'N/A'};
                end

                % Guardado incremental: persistir tras CADA diseño para que
                % cerrar la GUI a mitad de la validación no pierda lo ya hecho.
                app.guardar_validacion_incremental(car, resumen, cols);
            end
            if ~isempty(resumen)
                app.log_tab(U.log,'── Resumen guardado en validacion_todos.csv ──');
            end

            U.lbl_status.Text = sprintf('✓ Validación completa: %d diseños.', n);
            U.lbl_status.FontColor = [0.1 0.5 0.1];
        end

        % ---------------------------------------------------------------
        % TAB 7 — MONTE CARLO
        % ---------------------------------------------------------------
        function tab_mc(app, par)
            U=struct();
            uilabel(par,'Text','Análisis de robustez — Monte Carlo',...
                'Position',[12 630 500 24],'FontSize',12,'FontWeight','bold');

            pan=uipanel(par,'Title','Tolerancias de fabricación (1σ)',...
                'Position',[12 548 1118 78],'FontSize',10);
            etqs={'Espesor (mm):','Dimensión a/b (mm):','N muestras MC:'};
            defs={0.1,1.0,10000}; lims={[0.01 5],[0.05 50],[100 200000]};
            keys_t={'tol_e','tol_d','n_mc'}; xp=[5 168 335];
            U.p=struct();
            for k=1:3
                uilabel(pan,'Text',etqs{k},'Position',[xp(k) 38 135 20],'FontSize',9);
                U.p.(keys_t{k})=uispinner(pan,'Value',defs{k},'Limits',lims{k},...
                    'Position',[xp(k) 12 120 26]);
            end
            uilabel(pan,'Text','l1/l2 no se perturban: el surrogate excluye predictores constantes',...
                'Position',[500 12 150 46],'FontSize',8,...
                'FontColor',[0.5 0.5 0.5],'WordWrap','on');
            % Umbral ECE R66 en el mismo panel
            uibutton(pan,'Text','📐  Criterio ECE R66...',...
                'Position',[654 22 185 34],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white',...
                'FontSize',9,'FontWeight','bold',...
                'ButtonPushedFcn',@(~,~) app.abrir_calc_ecr66());
            U.lbl_ecr66_mc = uilabel(pan,'Text','Sin umbral',...
                'Position',[848 22 262 34],'FontSize',9,'FontWeight','bold',...
                'FontColor',[0.5 0.5 0.5],'WordWrap','on');

            U.btn=uibutton(par,'Text','▶  Lanzar Monte Carlo',...
                'Position',[12 508 200 34],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white',...
                'FontWeight','bold','FontSize',11,...
                'ButtonPushedFcn',@(~,~) app.cb_mc());
            U.btn_sobol=uibutton(par,'Text','📊  Sensibilidad Sobol',...
                'Position',[920 508 210 34],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white',...
                'FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_sobol());
            U.lbl_status=uilabel(par,'Text','','Position',[220 508 690 34],'FontSize',10,'WordWrap','on');

            % Panel estadísticas (bajado para que no solape con el botón)
            pan2=uipanel(par,'Title','Estadísticas de energía específica (J/kg)',...
                'Position',[12 368 620 132],'FontSize',10);
            etqs2={'Nominal:','Media:','Desv. std:','CV (%):','Perc. 5%:','Perc. 1%:','P(<95% nom):'};
            keys2={'nom','med','std','cv','p05','p01','prob'};
            U.res=struct();
            for k=1:7
                c=mod(k-1,4); r=floor((k-1)/4);
                uilabel(pan2,'Text',etqs2{k},'Position',[8+c*152 96-r*48 105 20],'FontSize',9);
                U.res.(keys2{k})=uilabel(pan2,'Text','—',...
                    'Position',[8+c*152 72-r*48 105 24],'FontSize',12,'FontWeight','bold');
            end
            U.lbl_rob=uilabel(pan2,'Text','Robustez: —',...
                'Position',[470 44 145 50],'FontSize',14,'FontWeight','bold');

            % Axes histograma
            U.ax=uiaxes(par,'Position',[640 368 482 132]);
            title(U.ax,'Distribución MC'); xlabel(U.ax,'J/kg'); grid(U.ax,'on');

            U.log=uitextarea(par,'Position',[12 10 1118 350],...
                'Editable','off','FontSize',8,'FontName','Consolas','Value',{'Listo.'});

            app.U.mc=U;
        end

        function cb_mc(app)
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U=app.U.mc; car=app.ruta_campana();

            of=fullfile(car,'optimo_GA.mat'); mf=fullfile(car,'modelo_surrogate.mat');
            if ~isfile(of)||~isfile(mf)
                uialert(app.fig,'Faltan optimo_GA.mat o modelo_surrogate.mat.','Error'); return;
            end
            o=load(of,'optimo'); opt=o.optimo;
            m=load(mf,'trainedModel'); mdl=m.trainedModel;

            rng(0);
            N    =round(U.p.n_mc.Value);
            te   =U.p.tol_e.Value; td=U.p.tol_d.Value;
            % Variables activas del DOE. l1/l2 NO se perturban: el surrogate
            % excluye los predictores constantes de la campaña, asi que la
            % variacion de l solo entraria via masa (inconsistente). El cateto
            % de la cartela (c) solo se perturba si es variable de diseño en la
            % campaña (Cvar): se detecta porque el surrogate lo incluye como
            % predictor. Asi el mismo MC vale para campañas de 6 y de 7 vars.
            c_var = isfield(opt,'c') && any(strcmp('c', mdl.predictorNames));
            %      m1     a1     m2     a2     b      e_cartela
            nom  =[opt.m1,opt.a1,opt.m2,opt.a2,opt.b1,opt.e_cartela];
            sig  =[te,    td,    te,    td,    td,    te];
            if c_var, nom(7)=opt.c; sig(7)=td; end   % c: tolerancia dimensional
            d_mc =numel(nom);
            mu   =nom+sig.*randn(N,d_mc);
            mu(:,1)=max(mu(:,1),0.5); mu(:,3)=max(mu(:,3),0.5);
            mu(:,6)=max(mu(:,6),0.5); mu(:,2)=max(mu(:,2),10);
            mu(:,4)=max(mu(:,4),10);  mu(:,5)=max(mu(:,5),10);
            if c_var, mu(:,7)=max(mu(:,7),10); end

            c_col=opt.c*ones(N,1);
            if c_var, c_col=mu(:,7); end

            fm=zeros(N,10);
            fm(:,1)=mu(:,1); fm(:,2)=mu(:,2); fm(:,3)=mu(:,5); fm(:,4)=opt.l1;
            fm(:,5)=mu(:,3); fm(:,6)=mu(:,4); fm(:,7)=mu(:,5); fm(:,8)=opt.l2;
            fm(:,9)=c_col;   fm(:,10)=mu(:,6);
            tab=array2table(fm,'VariableNames',...
                {'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});

            app.log_tab(U.log,sprintf('Evaluando %d muestras (%d variables)...',N,d_mc)); drawnow;
            E_pred=mdl.predictFcn(tab);

            masa=masa_analitica(mu(:,1),mu(:,2),mu(:,5),opt.l1, ...
                                mu(:,3),mu(:,4),mu(:,5),opt.l2,c_col,mu(:,6));
            epm=E_pred./masa;

            nom_epm=opt.energia_especifica_J_kg;
            umbral =0.95*nom_epm;
            n_bajo =sum(epm<umbral);
            cv_pct =100*std(epm)/abs(mean(epm));
            pr_pct =100*n_bajo/N;

            U.res.nom.Text=sprintf('%.4f',nom_epm);
            U.res.med.Text=sprintf('%.4f',mean(epm));
            U.res.std.Text=sprintf('%.4f',std(epm));
            U.res.cv.Text =sprintf('%.2f',cv_pct);
            U.res.p05.Text=sprintf('%.4f',prctile(epm,5));
            U.res.p01.Text=sprintf('%.4f',prctile(epm,1));
            U.res.prob.Text=sprintf('%.2f%%',pr_pct);

            if pr_pct<1&&cv_pct<5,      rob='ALTA';  rc=[0.1 0.5 0.1];
            elseif pr_pct<5&&cv_pct<10, rob='MEDIA'; rc=[0.6 0.4 0.0];
            else,                        rob='BAJA';  rc=[0.7 0.1 0.1];
            end
            U.lbl_rob.Text=['Robustez: ' rob]; U.lbl_rob.FontColor=rc;

            % Histograma con líneas de referencia
            cla(U.ax);
            histogram(U.ax,epm,50,'FaceColor',[0.3 0.6 0.9],'EdgeColor','none');
            hold(U.ax,'on');
            xline(U.ax,nom_epm,'g--','LineWidth',1.5,'Label','Nominal');
            xline(U.ax,umbral, 'r-', 'LineWidth',1.5,'Label','95% nom.');
            % Línea del umbral ECE R66 si está definido
            u_ecr = app.umbral_ecr66;
            if u_ecr > 0
                xline(U.ax,u_ecr,'m-','LineWidth',2.5,'Label','ECE R66');
                p_cumple = 100*sum(epm >= u_ecr)/N;
                if p_cumple >= 95
                    txt_ecr = sprintf('✓ ECE R66  %.1f%%', p_cumple);
                    col_ecr = [0.08 0.48 0.08];
                elseif p_cumple >= 50
                    txt_ecr = sprintf('⚠ ECE R66  %.1f%%', p_cumple);
                    col_ecr = [0.65 0.35 0.00];
                else
                    txt_ecr = sprintf('✗ ECE R66  %.1f%%', p_cumple);
                    col_ecr = [0.70 0.08 0.08];
                end
                U.lbl_ecr66_mc.Text = txt_ecr;
                U.lbl_ecr66_mc.FontColor = col_ecr;
                app.log_tab(U.log, sprintf('P(EPM ≥ %.1f J/kg) = %.1f%%  → %s', u_ecr, p_cumple, txt_ecr));
            else
                U.lbl_ecr66_mc.Text = '—';
                U.lbl_ecr66_mc.FontColor = [0.5 0.5 0.5];
            end
            hold(U.ax,'off');

            try
                fg=figure('Visible','off','Position',[100 100 900 400]);
                ax1_=subplot(1,2,1,'Parent',fg);
                histogram(ax1_,epm,50,'FaceColor',[0.3 0.6 0.9],'EdgeColor','none');
                hold(ax1_,'on');
                xline(ax1_,nom_epm,'g--','LineWidth',1.5,'Label','Nominal');
                xline(ax1_,umbral,'r-','LineWidth',1.5,'Label','95% nom.');
                if u_ecr > 0
                    xline(ax1_,u_ecr,'m-','LineWidth',2.5,'Label',sprintf('ECE R66 (%.1f J/kg)',u_ecr));
                end
                % Centrar el histograma en la zona de los datos (el umbral ECE R66
                % suele quedar muy a la izquierda y aplastaria la distribucion).
                xlim(ax1_, [min([epm(:); umbral])*0.99, max(epm)*1.01]);
                hold(ax1_,'off');
                xlabel(ax1_,'J/kg'); ylabel(ax1_,'Frecuencia');
                title(ax1_,sprintf('Distribución MC (N=%d)',N));
                ax2_=subplot(1,2,2,'Parent',fg);
                boxplot(ax2_,epm);
                ylabel(ax2_,'Energía específica (J/kg)');
                title(ax2_,sprintf('Robustez: %s | CV %.2f%%',rob,cv_pct));
                grid(ax2_,'on');
                saveas(fg,fullfile(car,'analisis_montecarlo_epw.png'));
                close(fg);
            catch, end

            res_mc.epm_nominal=nom_epm; res_mc.epm_media=mean(epm);
            res_mc.epm_std=std(epm); res_mc.cv_pct=cv_pct;
            res_mc.epm_p01=prctile(epm,1); res_mc.epm_p05=prctile(epm,5);
            res_mc.umbral=umbral; res_mc.prob_pct=pr_pct; res_mc.robustez=rob;
            save(fullfile(car,'resultados_montecarlo.mat'),'res_mc');

            U.lbl_status.Text=sprintf('✓ Robustez: %s  |  CV: %.2f%%',rob,cv_pct);
            U.lbl_status.FontColor=rc;
            app.log_tab(U.log,sprintf('Media: %.4f | Std: %.4f | P(<95%%nom): %.2f%%',...
                mean(epm),std(epm),pr_pct));
        end

        % ---------------------------------------------------------------
        % Sensibilidad global de Sobol (delegada en
        % analizar_sensibilidad_sobol.m, compartida con la CLI)
        % ---------------------------------------------------------------
        function cb_sobol(app)
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            U = app.U.mc;
            if ~isfile(fullfile(app.ruta_campana(),'modelo_surrogate.mat'))
                uialert(app.fig,'Falta modelo_surrogate.mat. Entrena el modelo primero.','Error');
                return;
            end
            U.btn_sobol.Enable='off'; U.btn.Enable='off';
            app.log_tab(U.log,'Calculando índices de Sobol sobre el surrogate...');
            dlg = uiprogressdlg(app.fig,'Title','Sensibilidad de Sobol',...
                'Message','Evaluando el surrogate (N·(d+2) diseños)...',...
                'Indeterminate','on');
            drawnow;
            try
                res = analizar_sensibilidad_sobol();
                close(dlg);
                app.log_tab(U.log,'── Sensibilidad de Sobol (energía específica) ──');
                for k = 1:numel(res.orden)
                    i = res.orden(k);
                    app.log_tab(U.log,sprintf('  %-12s  S=%.3f   ST=%.3f',...
                        res.nombres{i}, res.S(i), res.ST(i)));
                end
                app.log_tab(U.log,['Figura: ' res.ruta_png]);
                app.log_tab(U.log,['Tabla:  ' res.ruta_csv]);
                U.lbl_status.Text = sprintf('✓ Sobol: %s domina (ST=%.2f). Resultados en el log y la figura.',...
                    res.nombres{res.orden(1)}, res.ST(res.orden(1)));
                U.lbl_status.FontColor = [0.10 0.40 0.45];
            catch ex
                try, close(dlg); catch, end
                app.log_tab(U.log,['ERROR Sobol: ' ex.message]);
                uialert(app.fig,['Error en el análisis de Sobol: ' ex.message],'Error');
            end
            U.btn_sobol.Enable='on'; U.btn.Enable='on';
        end

        % ---------------------------------------------------------------
        % TAB 8 — VISOR DE RESULTADOS
        % ---------------------------------------------------------------
        function tab_visor(app, par)
            U = struct();
            uilabel(par,'Text','Visor de resultados por simulación',...
                'Position',[12 630 300 24],'FontSize',12,'FontWeight','bold');

            U.lbl_camp = uilabel(par,'Text','','Position',[320 632 800 20],'FontSize',10);

            % Lista de simulaciones (izquierda)
            uilabel(par,'Text','Simulaciones:','Position',[12 582 120 20],'FontWeight','bold');
            uibutton(par,'Text','↻ Regenerar gráficas',...
                'Position',[12 554 220 26],...
                'BackgroundColor',app.COL_AZUL,'FontColor','white','FontSize',9,...
                'Tooltip','Regenera Graficas_Completas.png de todas las sims con el pivote actual del CSV',...
                'ButtonPushedFcn',@(~,~) app.cb_regenerar_graficas());
            U.lista = uilistbox(par,'Position',[12 10 220 540],...
                'FontSize',9,...
                'ValueChangedFcn',@(s,~) app.cb_visor_select(s.Value));

            % Panel de datos de la sim seleccionada
            U.pan_info = uipanel(par,'Title','Parámetros y resultados',...
                'Position',[242 569 888 61],'FontSize',9);
            U.info_txt = uilabel(U.pan_info,'Text','Selecciona una simulación.',...
                'Position',[5 2 472 44],'FontSize',9,'WordWrap','on');
            uilabel(U.pan_info,'Text','Modo:',...
                'Position',[483 9 38 16],'FontSize',9,'FontWeight','bold');
            U.dd_modo = uidropdown(U.pan_info,...
                'Items',{'Viga','Cartela','Hibrido','N/A'},...
                'Value','N/A',...
                'Position',[521 6 90 22],'FontSize',9,...
                'Enable','off',...
                'ValueChangedFcn',@(s,~) app.cb_modo_changed(s.Value));
            uilabel(U.pan_info,'Text','Pivot (mm):',...
                'Position',[619 9 68 16],'FontSize',9,'FontWeight','bold');
            U.edit_pivot = uieditfield(U.pan_info,'numeric',...
                'Value',0,'Limits',[0 1000],'LowerLimitInclusive','on',...
                'Position',[689 6 70 22],'FontSize',9,...
                'Enable','off');
            U.btn_modo = uibutton(U.pan_info,'Text','✓ Guardar',...
                'Position',[767 6 110 22],'FontSize',9,...
                'BackgroundColor',app.COL_VERDE,'FontColor','white',...
                'Enable','off',...
                'ButtonPushedFcn',@(~,~) app.cb_aplicar_modo());

            % Tabs de imágenes / curvas
            U.htabs_img = uitabgroup(par,'Position',[242 10 888 558]);

            t1 = uitab(U.htabs_img,'Title','Tensiones');
            U.ax_ten = uiaxes(t1,'Position',[5 5 875 520]);
            axis(U.ax_ten,'off'); U.ax_ten.Toolbar.Visible = 'off';

            t2 = uitab(U.htabs_img,'Title','Vista Iso.');
            U.ax_iso = uiaxes(t2,'Position',[5 5 875 520]);
            axis(U.ax_iso,'off'); U.ax_iso.Toolbar.Visible = 'off';

            t3a = uitab(U.htabs_img,'Title','Vista Frontal');
            U.ax_front = uiaxes(t3a,'Position',[5 5 875 520]);
            axis(U.ax_front,'off'); U.ax_front.Toolbar.Visible = 'off';

            t3b = uitab(U.htabs_img,'Title','Vista Lateral');
            U.ax_lat = uiaxes(t3b,'Position',[5 5 875 520]);
            axis(U.ax_lat,'off'); U.ax_lat.Toolbar.Visible = 'off';

            t3c = uitab(U.htabs_img,'Title','Zoom Cartela');
            U.ax_zoom = uiaxes(t3c,'Position',[5 5 875 520]);
            axis(U.ax_zoom,'off'); U.ax_zoom.Toolbar.Visible = 'off';

            t4 = uitab(U.htabs_img,'Title','Curvas F-d / E-d / M-θ');
            U.ax_Fd  = uiaxes(t4,'Position',[5 270 280 240]);
            U.ax_Ed  = uiaxes(t4,'Position',[300 270 280 240]);
            U.ax_Mt  = uiaxes(t4,'Position',[595 270 280 240]);
            U.ax_raw = uiaxes(t4,'Position',[5 5 870 255]);

            t5 = uitab(U.htabs_img,'Title','Log Mechanical');
            uilabel(t5,'Text','Log de ANSYS Mechanical para la simulación seleccionada:',...
                'Position',[5 498 870 20],'FontSize',9,'FontColor',[0.4 0.4 0.4]);
            U.log_ruta = uilabel(t5,'Text','—','Position',[5 478 870 18],...
                'FontSize',8,'FontColor',[0.55 0.55 0.55],'WordWrap','on');
            U.log_txt  = uitextarea(t5,'Position',[5 5 870 470],...
                'Editable','off','FontSize',8,'FontName','Courier New',...
                'Value',{'Selecciona una simulación para ver su log.'});

            app.U.visor = U;
        end

        function cb_visor_refresh(app)
            app.cargar_campana();
            U = app.U.visor;
            if isempty(app.campana)
                U.lbl_camp.Text = 'Sin campaña activa';
                return;
            end

            carpeta = app.ruta_campana();

            % Estadísticas de modo de fallo desde basededatos.csv
            db_file = fullfile(carpeta,'basededatos.csv');
            camp_txt = app.campana;
            if isfile(db_file)
                try
                    db = readtable(db_file);
                    n_tot = height(db);
                    if ismember('energy',db.Properties.VariableNames)
                        n_ok = sum(isfinite(db.energy));
                    else, n_ok = 0; end
                    if ismember('modo_fallo',db.Properties.VariableNames) && n_ok > 0
                        mf_ok = db.modo_fallo(isfinite(db.energy));
                        n_v = sum(strcmp(mf_ok,'Viga'));
                        n_c = sum(strcmp(mf_ok,'Cartela'));
                        n_h = sum(strcmp(mf_ok,'Hibrido'));
                        camp_txt = sprintf('%s  |  %d sims  |  Viga: %d (%.0f%%)  Cartela: %d (%.0f%%)  Hibrido: %d (%.0f%%)',...
                            app.campana, n_ok, n_v, 100*n_v/n_ok, n_c, 100*n_c/n_ok, n_h, 100*n_h/n_ok);
                    else
                        camp_txt = sprintf('%s  |  %d/%d simulaciones completadas',...
                            app.campana, n_ok, n_tot);
                    end
                catch, end
            end
            U.lbl_camp.Text = camp_txt;
            d = dir(fullfile(carpeta,'Sim_*'));
            d = d([d.isdir]);
            nombres = {d.name};
            if isempty(nombres)
                U.lista.Items = {'(sin simulaciones)'};
                return;
            end

            % Añadir indicador de estado según si tiene Curvas.csv
            items = cell(1,numel(nombres));
            for k = 1:numel(nombres)
                csv = fullfile(carpeta,nombres{k},'Curvas.csv');
                if isfile(csv), mark = '✓'; else, mark = '—'; end
                items{k} = [mark '  ' nombres{k}];
            end
            U.lista.Items = items;
        end

        function v = val_field(~, row, name, default)
            % Devuelve row.(name) si la columna existe; si no, el valor 'default'.
            v = default;
            if ismember(name, row.Properties.VariableNames)
                x = row.(name);
                if iscell(x),   x = x{1};   end
                if isstring(x), x = char(x); end
                v = x;
            end
        end

        function [row, found] = buscar_fila_validacion(app, car, sim_name) %#ok<INUSL>
            % Localiza la fila de una validación a partir del nombre de carpeta:
            %   Sim_VALIDACION -> validacion_optimo.csv (fila única)
            %   Sim_VAL_<Tipo> -> validacion_todos.csv  (emparejando por 'Tipo')
            row = table(); found = false;
            if strcmp(sim_name, 'Sim_VALIDACION')
                vf = fullfile(car, 'validacion_optimo.csv');
                if isfile(vf)
                    try
                        o = detectImportOptions(vf); o.VariableNamingRule = 'preserve';
                        t = readtable(vf, o);
                        if ~isempty(t), row = t(1,:); found = true; end
                    catch, end
                end
                return;
            end
            vf = fullfile(car, 'validacion_todos.csv');
            if isfile(vf)
                try
                    o = detectImportOptions(vf); o.VariableNamingRule = 'preserve';
                    t = readtable(vf, o);
                    if ismember('Tipo', t.Properties.VariableNames)
                        for i = 1:height(t)
                            sid = regexprep(char(string(t.Tipo(i))), '[^a-zA-Z0-9]', '_');
                            if strcmp(['Sim_VAL_' sid], sim_name)
                                row = t(i,:); found = true; return;
                            end
                        end
                    end
                catch, end
            end
        end

        function [ph, la] = mostrar_info_validacion(app, sim_name)
            % Rellena el panel de info del Visor con los parámetros y resultados
            % REALES de una validación (de validacion_*.csv) y devuelve el
            % pivote/brazo para la curva M-theta. Tolerante a variantes de esquema.
            ph = 0; la = 1000;
            U = app.U.visor;
            U.dd_modo.Enable = 'off'; U.edit_pivot.Enable = 'off'; U.btn_modo.Enable = 'off';
            [row, found] = app.buscar_fila_validacion(app.ruta_campana(), sim_name);
            if ~found
                U.info_txt.Text = 'Validación (sin datos en validacion_*.csv)';
                U.pan_info.BackgroundColor = [0.94 0.94 0.94];
                return;
            end
            m1 = app.val_field(row,'m1',NaN); a1 = app.val_field(row,'a1',NaN);
            b1 = app.val_field(row,'b1',NaN); m2 = app.val_field(row,'m2',NaN);
            a2 = app.val_field(row,'a2',NaN); ec = app.val_field(row,'e_cartela',NaN);
            cc = app.val_field(row,'c',NaN);
            epm_r = app.val_field(row,'EPM_Real_J_kg',NaN);
            epm_p = app.val_field(row,'EPM_Predicha_J_kg', app.val_field(row,'EPM_IA0_J_kg',NaN));
            E_r   = app.val_field(row,'Energia_Real_J',NaN);
            ymax  = app.val_field(row,'Y_Max_Stress_mm',NaN);
            mf    = app.val_field(row,'Modo_Fallo','N/A');
            tipo  = app.val_field(row,'Tipo','Validación');
            err   = app.val_field(row,'Error_Pct', app.val_field(row,'Error_IA0_Pct',NaN));

            % Validaciones por modo (IAv/IAc): además del error del propio
            % modelo de modo (EPM_Modo/Error_Modo) mostramos la predicción y el
            % error de IA_0 sobre el mismo diseño, ambos ya en validacion_todos.csv.
            fuente   = app.val_field(row,'Fuente_Modelo','');
            epm_modo = app.val_field(row,'EPM_Modo_J_kg',NaN);
            err_modo = app.val_field(row,'Error_Modo_Pct',NaN);
            epm_ia0  = app.val_field(row,'EPM_IA0_J_kg',NaN);
            err_ia0  = app.val_field(row,'Error_IA0_Pct',NaN);
            es_modo  = (contains(fuente,'IAv') || contains(fuente,'IAc')) && isfinite(epm_modo);

            geom_txt = sprintf('%s  |  m1=%.2f  a1=%.2f  b=%.2f  m2=%.2f  a2=%.2f  e_c=%.2f  c=%.1f', ...
                tipo, m1, a1, b1, m2, a2, ec, cc);
            if es_modo
                U.info_txt.Text = sprintf(['%s  |  E=%.1f J  EPM real=%.2f J/kg  |  %s pred=%.2f (err=%.2f%%)  |  ' ...
                    'IA_0 pred=%.2f (err=%.2f%%)  |  MODO: %s  (Y_max=%.1f mm)'], ...
                    geom_txt, E_r, epm_r, fuente, epm_modo, err_modo, epm_ia0, err_ia0, mf, ymax);
            else
                U.info_txt.Text = sprintf(['%s  |  E=%.1f J  EPM real=%.2f J/kg  (pred=%.2f, err=%.2f%%)  |  ' ...
                    'MODO: %s  (Y_max=%.1f mm)'], ...
                    geom_txt, E_r, epm_r, epm_p, err, mf, ymax);
            end

            switch mf
                case 'Viga',    U.pan_info.BackgroundColor = [0.86 0.96 0.88];
                case 'Cartela', U.pan_info.BackgroundColor = [1.00 0.91 0.78];
                case 'Hibrido', U.pan_info.BackgroundColor = [0.90 0.88 0.96];
                otherwise,      U.pan_info.BackgroundColor = [0.94 0.94 0.94];
            end
            if ismember(mf, U.dd_modo.Items), U.dd_modo.Value = mf; else, U.dd_modo.Value = 'N/A'; end

            % Pivote/brazo para la curva M-theta (l1 constante de campaña)
            l1v = app.val_field(row,'l1',1000);
            mfm = fullfile(app.ruta_campana(),'meta_campana.mat');
            if isfile(mfm)
                try, mm = load(mfm,'meta'); if isfield(mm.meta,'l_fijo'), l1v = mm.meta.l_fijo; end, catch, end
            end
            if isfinite(ymax)
                [phv, lav, ~] = calcular_pivot(ymax, cc, a1, a2, l1v);
                ph = phv; la = max(lav, 1);
            end
        end

        function cb_visor_select(app, val)
            if isempty(val), return; end
            U = app.U.visor;

            % Extraer nombre real de carpeta (quitar ✓/— del prefijo)
            sim_name    = strtrim(regexprep(val,'^[✓—]\s+',''));
            carpeta     = fullfile(app.ruta_campana(), sim_name);
            db_file     = fullfile(app.ruta_campana(),'basededatos.csv');
            curvas_file = fullfile(carpeta,'Curvas.csv');

            % --- Datos para info + pivot --------------------------------
            % Las validaciones (Sim_VALIDACION, Sim_VAL_<Tipo>) NO están en
            % basededatos.csv: sus parámetros y resultados viven en
            % validacion_optimo.csv / validacion_todos.csv.
            ph = 0; la = 1000;   % defaults
            if startsWith(sim_name, 'Sim_VAL')
                [ph, la] = app.mostrar_info_validacion(sim_name);
            elseif isfile(db_file)
                n_sim = str2double(regexp(sim_name,'\d+','match','once'));
                try
                    db = readtable(db_file);
                    if ~isnan(n_sim) && n_sim <= height(db)
                        r = db(n_sim,:);
                        % Pivot para curvas M-θ
                        if ismember('pivot_height_mm',db.Properties.VariableNames) ...
                                && isfinite(r.pivot_height_mm)
                            ph = r.pivot_height_mm;
                            la = max(r.lever_arm_mm, 1);
                        end
                        % Modo de fallo: desde columna o calculado al vuelo
                        if ismember('modo_fallo',db.Properties.VariableNames)
                            try, mf = char(r.modo_fallo); catch, mf = 'N/A'; end
                        elseif ismember('y_max_stress_mm',db.Properties.VariableNames) && ...
                               ismember('c',db.Properties.VariableNames)
                            [~,~,mf] = calcular_pivot(r.y_max_stress_mm, r.c, r.a1, r.a2, r.l1);
                        else
                            mf = 'N/A';
                        end
                        % Color del panel según modo
                        switch mf
                            case 'Viga'
                                U.pan_info.BackgroundColor = [0.86 0.96 0.88];  % verde suave
                            case 'Cartela'
                                U.pan_info.BackgroundColor = [1.00 0.91 0.78];  % naranja suave
                            case 'Hibrido'
                                U.pan_info.BackgroundColor = [0.90 0.88 0.96];  % lila suave
                            otherwise
                                U.pan_info.BackgroundColor = [0.94 0.94 0.94];  % gris
                        end
                        % Sincronizar dropdown de modo, pivot y habilitar controles
                        if ismember(mf, U.dd_modo.Items)
                            U.dd_modo.Value = mf;
                        else
                            U.dd_modo.Value = 'N/A';
                        end
                        U.edit_pivot.Value = max(0, r.pivot_height_mm);
                        U.dd_modo.Enable   = 'on';
                        U.edit_pivot.Enable = 'on';
                        U.btn_modo.Enable  = 'on';
                        % Texto info
                        cols_req = {'m1','a1','b1','m2','a2','e_cartela','c',...
                                    'energy','energy_per_mass','stress','valid_ansys',...
                                    'y_max_stress_mm'};
                        if all(ismember(cols_req, db.Properties.VariableNames))
                            U.info_txt.Text = sprintf(...
                                'm1=%.2f  a1=%.2f  b=%.2f  m2=%.2f  a2=%.2f  e_c=%.2f  c=%.1f  |  E=%.1f J  EPM=%.2f J/kg  σ=%.0f MPa  |  MODO: %s  (Y_max=%.1f mm)',...
                                r.m1,r.a1,r.b1,r.m2,r.a2,r.e_cartela,r.c,...
                                r.energy,r.energy_per_mass,r.stress/1e6,mf,r.y_max_stress_mm);
                        else
                            U.info_txt.Text = sprintf('%s  —  Modo: %s', sim_name, mf);
                        end
                    end
                catch
                    U.info_txt.Text = sim_name;
                    U.dd_modo.Enable    = 'off';
                    U.edit_pivot.Enable = 'off';
                    U.btn_modo.Enable   = 'off';
                end
            end

            % --- Imágenes ANSYS (las 5 que exporta macro_mechanical.py) ---
            app.cargar_imagen(U.ax_ten,   fullfile(carpeta,'Tensiones.png'));
            app.cargar_imagen(U.ax_iso,   fullfile(carpeta,'Vista_Iso_Gris.png'));
            app.cargar_imagen(U.ax_front, fullfile(carpeta,'Vista_Frontal_Gris.png'));
            app.cargar_imagen(U.ax_lat,   fullfile(carpeta,'Vista_Lateral_Gris.png'));
            app.cargar_imagen(U.ax_zoom,  fullfile(carpeta,'Zoom_Cartela.png'));

            % --- Curvas F-d / E-d / M-θ (usa ph/la ya leídos) -----------
            if isfile(curvas_file)
                try
                    opts = detectImportOptions(curvas_file);
                    opts.VariableNamingRule = 'preserve';
                    TC = readtable(curvas_file,opts);

                    force_tot = abs(TC.ForceTotal);
                    disp_mm   = abs(TC.DispX * 1000);
                    energy_ac = cumtrapz(disp_mm/1000, force_tot);

                    angle_deg  = asind(min(disp_mm / la, 1));
                    moment_Nm  = force_tot .* (la/1000) .* cosd(angle_deg);

                    % Subplot 1: F vs d
                    cla(U.ax_Fd);
                    plot(U.ax_Fd, disp_mm, force_tot,'-b','LineWidth',1.8);
                    xlabel(U.ax_Fd,'Despl. X (mm)'); ylabel(U.ax_Fd,'Fuerza (N)');
                    title(U.ax_Fd,'F vs d'); grid(U.ax_Fd,'on');

                    % Subplot 2: E vs d
                    cla(U.ax_Ed);
                    plot(U.ax_Ed, disp_mm, energy_ac,'-r','LineWidth',1.8);
                    xlabel(U.ax_Ed,'Despl. X (mm)'); ylabel(U.ax_Ed,'E absorbida (J)');
                    title(U.ax_Ed,'E vs d'); grid(U.ax_Ed,'on');

                    % Subplot 3: M vs θ
                    cla(U.ax_Mt);
                    plot(U.ax_Mt, angle_deg, moment_Nm,'-k','LineWidth',1.8);
                    xlabel(U.ax_Mt,'Ángulo (°)'); ylabel(U.ax_Mt,'Momento (N·m)');
                    title(U.ax_Mt,sprintf('M vs θ  (pivote %.0f mm)',ph));
                    grid(U.ax_Mt,'on');

                    % Subplot 4: todas las columnas raw
                    cla(U.ax_raw);
                    cols_plot = {'ForceX','ForceY','ForceZ','ForceTotal'};
                    for k = 1:numel(cols_plot)
                        if ismember(cols_plot{k},TC.Properties.VariableNames)
                            plot(U.ax_raw, disp_mm, TC.(cols_plot{k}),...
                                'LineWidth',1.2,'DisplayName',cols_plot{k});
                            hold(U.ax_raw,'on');
                        end
                    end
                    hold(U.ax_raw,'off');
                    legend(U.ax_raw,'Location','best');
                    xlabel(U.ax_raw,'Despl. X (mm)'); ylabel(U.ax_raw,'Fuerza (N)');
                    title(U.ax_raw,'Componentes de fuerza'); grid(U.ax_raw,'on');
                catch ex
                    cla(U.ax_Fd); cla(U.ax_Ed); cla(U.ax_Mt); cla(U.ax_raw);
                    title(U.ax_Fd,['Error: ' ex.message]);
                end
            else
                cla(U.ax_Fd); cla(U.ax_Ed); cla(U.ax_Mt); cla(U.ax_raw);
                title(U.ax_Fd,'Sin Curvas.csv');
            end

            % --- Log de ANSYS Mechanical --------------------------------
            log_sim = fullfile(carpeta,'mechanical_run.log');
            if isfile(log_sim)
                try
                    content = fileread(log_sim);
                    U.log_txt.Value  = strsplit(content, newline);
                    U.log_ruta.Text  = log_sim;
                catch
                    U.log_txt.Value  = {'Error leyendo el log.'};
                    U.log_ruta.Text  = log_sim;
                end
            else
                U.log_txt.Value = {'Sin mechanical_run.log para esta simulación.', ...
                    '', ...
                    'Nota: solo las simulaciones lanzadas desde la GUI guardan', ...
                    'el log por simulación. Para simulations anteriores, usa', ...
                    '"📋 Ver log de simulación" en la pestaña Simulaciones.'};
                U.log_ruta.Text = '—';
            end
        end

        function cb_modo_changed(app, new_modo)
            % Actualiza el pivot sugerido al cambiar el modo en el dropdown
            U = app.U.visor;
            val = U.lista.Value;
            if isempty(val), return; end
            sim_name = strtrim(regexprep(val, '^[✓—]\s+', ''));
            num_str  = regexp(sim_name, '\d+', 'match', 'once');
            n_sim    = str2double(num_str);
            archivo_db = fullfile(app.ruta_campana(), 'basededatos.csv');
            if ~isfile(archivo_db) || isnan(n_sim), return; end
            try
                opts = detectImportOptions(archivo_db);
                opts.VariableNamingRule = 'preserve';
                data = readtable(archivo_db, opts);
                if n_sim < 1 || n_sim > height(data), return; end
                y_max = data.y_max_stress_mm(n_sim);
                a2    = data.a2(n_sim);
                c     = data.c(n_sim);
                switch new_modo
                    case 'Viga',    sugerido = y_max;
                    case 'Hibrido', sugerido = (a2 + c) / 2;
                    otherwise,      sugerido = 0;
                end
                U.edit_pivot.Value = max(0, sugerido);
            catch, end
        end

        % ── ANÁLISIS POR MODO ────────────────────────────────────────────
        function abrir_analisis_modo(app)
            existing = findall(0,'Type','figure','Name','Análisis por modo de fallo');
            if ~isempty(existing), figure(existing(1)); return; end

            win = uifigure('Name','Análisis por modo de fallo',...
                'Position',[120 60 1020 720],'Resize','off');

            uilabel(win,'Text','Análisis por modo de fallo — IA_0 (global) vs IAv (Viga) vs IAc (Cartela)',...
                'Position',[12 688 1000 24],'FontSize',11,'FontWeight','bold');

            % ── Botones ──────────────────────────────────────────────────
            uibutton(win,'Text','▶  Entrenar IAv + IAc',...
                'Position',[12 652 170 30],...
                'BackgroundColor',app.COL_MORADO,'FontColor','white','FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_entrenar_modos(win));
            uibutton(win,'Text','🔍  Optimizar catálogo por modo',...
                'Position',[192 652 210 30],...
                'BackgroundColor',app.COL_VERDE,'FontColor','white','FontWeight','bold','FontSize',10,...
                'ButtonPushedFcn',@(~,~) app.cb_optimizar_modos(win));

            % ── Panel comparación RMSE ────────────────────────────────────
            pan_rmse = uipanel(win,'Title','Comparación de modelos',...
                'Position',[12 530 636 114],'FontSize',9);
            % La 5ª columna muestra el RMSE de IA_0 evaluado sobre el MISMO
            % subconjunto que IAv/IAc — la única comparación conmensurable.
            etqs_r  = {'Modelo','RMSE CV (J)','R² CV','Mejor modelo','IA_0 mismo subset'};
            xcols_r = [10, 143, 248, 328, 505];
            wcols_r = [128, 100,  75, 170, 125];
            filas   = {'IA_0 (global)','IAv (solo Viga)','IAc (solo Cartela)'};
            keys_r  = {'ia0','iav','iac'};
            am = struct();
            for col_r = 1:5
                uilabel(pan_rmse,'Text',etqs_r{col_r},...
                    'Position',[xcols_r(col_r) 76 wcols_r(col_r) 18],...
                    'FontSize',9,'FontWeight','bold');
            end
            for row_r = 1:3
                uilabel(pan_rmse,'Text',filas{row_r},...
                    'Position',[xcols_r(1) 54-(row_r-1)*22 wcols_r(1) 18],'FontSize',9);
                am.rmse.(keys_r{row_r}) = uilabel(pan_rmse,'Text','—',...
                    'Position',[xcols_r(2) 54-(row_r-1)*22 wcols_r(2) 18],'FontSize',9,'FontWeight','bold');
                am.r2.(keys_r{row_r}) = uilabel(pan_rmse,'Text','—',...
                    'Position',[xcols_r(3) 54-(row_r-1)*22 wcols_r(3) 18],'FontSize',9,'FontWeight','bold');
                am.tipo.(keys_r{row_r}) = uilabel(pan_rmse,'Text','—',...
                    'Position',[xcols_r(4) 54-(row_r-1)*22 wcols_r(4) 18],'FontSize',9,...
                    'FontColor',[0.20 0.20 0.60]);
                am.rmse0sub.(keys_r{row_r}) = uilabel(pan_rmse,'Text','—',...
                    'Position',[xcols_r(5) 54-(row_r-1)*22 wcols_r(5) 18],'FontSize',9);
            end

            % ── Panel muestras por modo ───────────────────────────────────
            pan_n = uipanel(win,'Title','Muestras por modo',...
                'Position',[658 530 350 114],'FontSize',9);
            am.lbl_n_viga    = uilabel(pan_n,'Text','Nv = —',...
                'Position',[10 66 110 20],'FontSize',10,'FontWeight','bold','FontColor',[0.05 0.45 0.10]);
            am.lbl_n_cartela = uilabel(pan_n,'Text','Nc = —',...
                'Position',[10 42 110 20],'FontSize',10,'FontWeight','bold','FontColor',[0.65 0.25 0.00]);
            am.lbl_n_global  = uilabel(pan_n,'Text','N_total = —',...
                'Position',[10 18 110 20],'FontSize',10,'FontWeight','bold');
            uilabel(pan_n,'Text','E/kg medio Viga:',...
                'Position',[125 66 145 20],'FontSize',9);
            am.lbl_epm_v = uilabel(pan_n,'Text','—',...
                'Position',[272 66 70 20],'FontSize',9,'FontWeight','bold','FontColor',[0.05 0.45 0.10]);
            uilabel(pan_n,'Text','E/kg medio Cartela:',...
                'Position',[125 42 145 20],'FontSize',9);
            am.lbl_epm_c = uilabel(pan_n,'Text','—',...
                'Position',[272 42 70 20],'FontSize',9,'FontWeight','bold','FontColor',[0.65 0.25 0.00]);
            uilabel(pan_n,'Text','Modo con mayor E/kg:',...
                'Position',[125 18 145 20],'FontSize',9);
            am.lbl_mejor_modo = uilabel(pan_n,'Text','—',...
                'Position',[272 18 70 20],'FontSize',10,'FontWeight','bold');

            % ── Panel óptimos ─────────────────────────────────────────────
            pan_opt = uipanel(win,'Title','Óptimos por catálogo (brute force)',...
                'Position',[12 388 996 136],'FontSize',9);
            etqs_o = {'Modelo','m1','a1','b','m2','a2','e_c','E/kg (J/kg)','E (J)','Masa (kg)','Modo pred.'};
            wc_o   = {120,40,40,40,40,40,40,90,80,80,80};
            am.tabla_opt = uitable(pan_opt,...
                'Position',[5 5 980 112],...
                'ColumnName',etqs_o,'ColumnWidth',wc_o,...
                'RowName',{},'FontSize',9);

            % ── Ejes distribución E/kg ────────────────────────────────────
            am.ax = uiaxes(win,'Position',[12 200 996 180]);
            title(am.ax,'Distribución E/kg por modo (datos reales del dataset)');
            xlabel(am.ax,'Energía específica (J/kg)'); ylabel(am.ax,'');
            grid(am.ax,'on');

            % ── Log ───────────────────────────────────────────────────────
            am.log = uitextarea(win,'Position',[12 10 996 182],...
                'Editable','off','FontSize',8,'FontName','Consolas','Value',{'Pulsa "Entrenar IAv + IAc" para comenzar.'});

            win.UserData = am;
        end

        function cb_entrenar_modos(app, win)
            am = win.UserData;
            app.cargar_campana();
            if isempty(app.campana)
                uialert(win,'No hay campaña activa.','Error'); return;
            end

            car = app.ruta_campana();
            arch = fullfile(car,'basededatos.csv');
            if ~isfile(arch), uialert(win,'No hay basededatos.csv.','Error'); return; end

            % Cargar modelo global
            mf_mat = load(fullfile(car,'modelo_surrogate.mat'));
            mdl0   = mf_mat.trainedModel;
            rmse0  = mdl0.rmse_cv;
            r2_0   = mdl0.r2_cv;
            pn     = mdl0.predictorNames;

            % Verificar clasificador (necesario para filtrar catálogo por modo)
            if ~isfield(mf_mat,'classifierModel')
                app.log_tab(am.log,'⚠ No hay clasificador en modelo_surrogate.mat.');
                app.log_tab(am.log,'  Entrena primero el modelo general para tener el clasificador.');
                app.log_tab(am.log,'  La separación de entrenamiento usará modo_fallo del CSV (correcto),');
                app.log_tab(am.log,'  pero "Optimizar catálogo por modo" evaluará todos los puntos sin filtrar.');
            else
                app.log_tab(am.log,'✓ Clasificador disponible — la optimización filtrará el catálogo por modo.');
            end

            % Leer dataset limpio
            opts_t = detectImportOptions(arch); opts_t.VariableNamingRule='preserve';
            data = readtable(arch, opts_t);
            mask_ok = isfinite(data.energy) & data.energy > 0;
            if ismember('valid_ansys',data.Properties.VariableNames) && any(data.valid_ansys==1)
                mask_ok = mask_ok & data.valid_ansys==1;
            end
            data = data(mask_ok,:);

            % Masa analítica y E/kg (fórmula compartida)
            masa_an = masa_analitica(data.m1,data.a1,data.b1,data.l1, ...
                                     data.m2,data.a2,data.b2,data.l2, ...
                                     data.c,data.e_cartela);
            epm_an  = data.energy ./ masa_an;

            % Separar por modo
            mask_v = strcmp(data.modo_fallo,'Viga');
            mask_c = strcmp(data.modo_fallo,'Cartela') | strcmp(data.modo_fallo,'Hibrido');
            nv = sum(mask_v); nc = sum(mask_c);

            am.lbl_n_viga.Text    = sprintf('Nv = %d', nv);
            am.lbl_n_cartela.Text = sprintf('Nc = %d', nc);
            am.lbl_n_global.Text  = sprintf('N_total = %d', height(data));
            am.lbl_epm_v.Text     = sprintf('%.1f J/kg', mean(epm_an(mask_v)));
            am.lbl_epm_c.Text     = sprintf('%.1f J/kg', mean(epm_an(mask_c)));
            if mean(epm_an(mask_v)) > mean(epm_an(mask_c))
                am.lbl_mejor_modo.Text = 'Viga'; am.lbl_mejor_modo.FontColor=[0.05 0.45 0.10];
            else
                am.lbl_mejor_modo.Text = 'Cartela'; am.lbl_mejor_modo.FontColor=[0.65 0.25 0.00];
            end

            % Gráfico distribución
            cla(am.ax);
            hold(am.ax,'on');
            histogram(am.ax, epm_an(mask_v),  'FaceColor',[0.20 0.65 0.30],'EdgeColor','none','DisplayName','Viga');
            histogram(am.ax, epm_an(mask_c),  'FaceColor',[0.90 0.50 0.10],'EdgeColor','none','DisplayName','Cartela');
            legend(am.ax,'Location','best');
            hold(am.ax,'off');
            app.log_tab(am.log, sprintf('Muestras: %d Viga | %d Cartela | %d total', nv, nc, height(data)));

            % ── Entrenar IAv: los mismos 28 modelos que el global ────────
            app.log_tab(am.log, repmat('─',1,60));
            app.log_tab(am.log, sprintf('Entrenando IAv — Nv=%d muestras Viga (mismos modelos que el global):', nv));
            Xv = data(mask_v, pn); yv = data.energy(mask_v);
            [mdlv_pfcn, rmse_v, r2_v, tipo_v, ~] = ...
                app.entrenar_todos_modelos(Xv, yv, pn, min(5,nv), am.log);
            app.log_tab(am.log, sprintf('★ IAv → MEJOR: %s  RMSE=%.2f J  R²=%.4f', tipo_v, rmse_v, r2_v));

            % ── Entrenar IAc: los mismos modelos ──────────────────────────
            app.log_tab(am.log, repmat('─',1,60));
            app.log_tab(am.log, sprintf('Entrenando IAc — Nc=%d muestras Cartela+Híbrido (mismos modelos que el global):', nc));
            Xc = data(mask_c, pn); yc = data.energy(mask_c);
            [mdlc_pfcn, rmse_c, r2_c, tipo_c, ~] = ...
                app.entrenar_todos_modelos(Xc, yc, pn, min(5,nc), am.log);
            app.log_tab(am.log, sprintf('★ IAc → MEJOR: %s  RMSE=%.2f J  R²=%.4f', tipo_c, rmse_c, r2_c));
            mdlv = []; mdlc = [];

            % ── Comparación JUSTA: IA_0 evaluado sobre el MISMO subconjunto ─
            % El RMSE CV global de IA_0 mezcla ambas poblaciones (las energías
            % de Viga y Cartela tienen escalas distintas) y NO es comparable
            % con el RMSE de IAv/IAc. Aquí se evalúa IA_0 sobre las mismas
            % muestras de cada modo. OJO: IA_0 se evalúa in-sample (entrenó
            % con estas filas), lo que le da ventaja — si IAv/IAc ganan aun
            % así, la evidencia de mejora es sólida.
            try
                pred0_v = mdl0.predictFcn(data(mask_v,:));
                rmse0_v = sqrt(mean((pred0_v - data.energy(mask_v)).^2));
            catch
                rmse0_v = NaN;
            end
            try
                pred0_c = mdl0.predictFcn(data(mask_c,:));
                rmse0_c = sqrt(mean((pred0_c - data.energy(mask_c)).^2));
            catch
                rmse0_c = NaN;
            end

            % ── Actualizar panel RMSE ──────────────────────────────────────
            am.rmse.ia0.Text = sprintf('%.2f J', rmse0);  am.r2.ia0.Text = sprintf('%.4f', r2_0);
            am.rmse.iav.Text = sprintf('%.2f J', rmse_v); am.r2.iav.Text = sprintf('%.4f', r2_v);
            am.rmse.iac.Text = sprintf('%.2f J', rmse_c); am.r2.iac.Text = sprintf('%.4f', r2_c);
            am.tipo.ia0.Text = mdl0.modelo_tipo;
            am.tipo.iav.Text = tipo_v;
            am.tipo.iac.Text = tipo_c;
            am.rmse0sub.ia0.Text = '—';
            am.rmse0sub.iav.Text = sprintf('%.2f J', rmse0_v);
            am.rmse0sub.iac.Text = sprintf('%.2f J', rmse0_c);

            % Colorear cada modelo de modo según gane o pierda contra IA_0
            % DENTRO de su propio subconjunto (verde = mejora, naranja = no)
            verde   = [0.05 0.45 0.10];
            naranja = [0.75 0.40 0.00];
            am.rmse.ia0.FontColor=[0 0 0]; am.r2.ia0.FontColor=[0 0 0];
            am.tipo.ia0.FontColor=[0.20 0.20 0.60];
            if isfinite(rmse0_v) && rmse_v < rmse0_v, col_v = verde; else, col_v = naranja; end
            if isfinite(rmse0_c) && rmse_c < rmse0_c, col_c = verde; else, col_c = naranja; end
            am.rmse.iav.FontColor=col_v; am.r2.iav.FontColor=col_v; am.tipo.iav.FontColor=col_v;
            am.rmse.iac.FontColor=col_c; am.r2.iac.FontColor=col_c; am.tipo.iac.FontColor=col_c;

            % Guardar modelos en UserData para optimización posterior
            am.mdlv = mdlv; am.mdlc = mdlc; am.mdl0 = mdl0;
            am.mdlv_pfcn = mdlv_pfcn; am.mdlc_pfcn = mdlc_pfcn;
            am.pn   = pn;   am.data = data;
            am.rmse_v = rmse_v; am.rmse_c = rmse_c;
            am.rmse0_v = rmse0_v; am.rmse0_c = rmse0_c;
            win.UserData = am;
            app.log_tab(am.log, repmat('─',1,60));
            app.log_tab(am.log, sprintf('IA_0 global : %s  RMSE=%.2f J  R²=%.4f  (todo el dataset, no comparable con IAv/IAc)', ...
                mdl0.modelo_tipo, rmse0, r2_0));
            app.log_tab(am.log, 'COMPARACIÓN JUSTA por subconjunto (IA_0 evaluado in-sample → parte con ventaja):');
            if isfinite(rmse0_v) && rmse_v < rmse0_v
                txt_v = '→ IAv MEJORA al global pese a su ventaja in-sample';
            else
                txt_v = '→ el global sigue mejor: el split no aporta en Viga';
            end
            app.log_tab(am.log, sprintf('  Viga    (n=%d): IAv %.2f J (CV)  vs  IA_0 %.2f J  %s', nv, rmse_v, rmse0_v, txt_v));
            if isfinite(rmse0_c) && rmse_c < rmse0_c
                txt_c = '→ IAc MEJORA al global pese a su ventaja in-sample';
            else
                txt_c = '→ el global sigue mejor: el split no aporta en Cartela';
            end
            app.log_tab(am.log, sprintf('  Cartela (n=%d): IAc %.2f J (CV)  vs  IA_0 %.2f J  %s', nc, rmse_c, rmse0_c, txt_c));
            app.log_tab(am.log, repmat('─',1,60));
            app.log_tab(am.log,'Pulsa "Optimizar catálogo por modo" para ver los óptimos de cada modelo.');
        end

        function cb_optimizar_modos(app, win)
            am = win.UserData;
            if ~isfield(am,'mdlv_pfcn') || isempty(am.mdlv_pfcn)
                uialert(win,'Primero entrena IAv e IAc.','Error'); return;
            end

            app.autoset_cat_c();
            car = app.ruta_campana();
            db  = readtable(fullfile(car,'basededatos.csv'));
            l1_f = db.l1(1); l2_f = db.l2(1); c_f = db.c(1);
            c_varia = std(db.c) > 1e-10;  % c es variable si varía en el DOE (campaña Cvar)
            pn   = am.pn;

            app.log_tab(am.log,'Optimizando catálogo con IA_0, IAv e IAc...');

            cat_m  = sort(app.cat_esp_viga);
            cat_ab = sort(app.cat_dims);
            cat_ec = sort(app.cat_esp_cart);
            [M1,A1,B_,M2,A2,EC] = ndgrid(cat_m,cat_ab,cat_ab,cat_m,cat_ab,cat_ec);
            m1v=M1(:); a1v=A1(:); bv=B_(:); m2v=M2(:); a2v=A2(:); ecv=EC(:);
            ok = (4*m1v<=min(a1v,bv)) & (4*m2v<=min(a2v,bv));
            m1v=m1v(ok); a1v=a1v(ok); bv=bv(ok);
            m2v=m2v(ok); a2v=a2v(ok); ecv=ecv(ok);
            n_base = numel(m1v);

            % c variable (campaña Cvar): replica el catálogo base por cada valor
            % del catálogo de catetos, igual que hace la fuerza bruta (cb_brute_force).
            % Forzamos orientación COLUMNA en todos los vectores (el (:)) para que
            % el horzcat de array2table nunca falle por una fila colada.
            if c_varia
                cat_c_v = sort(app.cat_c(:)).';   % fila 1xnc
            else
                cat_c_v = c_f;                    % un único valor de c
            end
            nc = numel(cat_c_v);
            m1v=repmat(m1v(:),nc,1); a1v=repmat(a1v(:),nc,1); bv=repmat(bv(:),nc,1);
            m2v=repmat(m2v(:),nc,1); a2v=repmat(a2v(:),nc,1); ecv=repmat(ecv(:),nc,1);
            cv = repelem(cat_c_v(:), n_base);     % cada c repetido n_base veces
            cv = cv(:);   % repelem de un escalar (campana c fijo) devuelve FILA: forzar columna
            n_cat = numel(m1v);
            if c_varia
                app.log_tab(am.log, sprintf('c variable [%s] mm', num2str(cat_c_v)));
            end

            l1v = repmat(l1_f,n_cat,1); l2v = repmat(l2_f,n_cat,1);
            tab_cat = array2table([m1v,a1v,bv,l1v,m2v,a2v,bv,l2v,cv,ecv],...
                'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});

            masa = masa_analitica(m1v,a1v,bv,l1_f,m2v,a2v,bv,l2_f,cv,ecv);

            % Columnas de la tabla de óptimos: inserta 'c' cuando es variable
            if c_varia
                am.tabla_opt.ColumnName  = {'Modelo','m1','a1','b','m2','a2','e_c','c','E/kg (J/kg)','E (J)','Masa (kg)','Modo pred.'};
                am.tabla_opt.ColumnWidth = {120,36,36,36,36,36,36,36,86,72,72,76};
            else
                am.tabla_opt.ColumnName  = {'Modelo','m1','a1','b','m2','a2','e_c','E/kg (J/kg)','E (J)','Masa (kg)','Modo pred.'};
                am.tabla_opt.ColumnWidth = {120,40,40,40,40,40,40,90,80,80,80};
            end

            % Clasificar todos con el clasificador
            modos_cat = repmat({'—'},n_cat,1);
            try
                mf_mat = load(fullfile(car,'modelo_surrogate.mat'));
                if isfield(mf_mat,'classifierModel')
                    modos_cat = cellstr(char(mf_mat.classifierModel.predictFcn(tab_cat)));
                    app.log_tab(am.log,sprintf('Clasificador aplicado a %d puntos de catálogo.',n_cat));
                else
                    app.log_tab(am.log,'(Sin clasificador entrenado — columna Modo pred. mostrará —. Entrena en "Análisis por modo".)');
                end
            catch ex_cl
                app.log_tab(am.log,['Advertencia clasificador: ' ex_cl.message]);
            end

            % Verificar clasificador — es obligatorio para IAv e IAc
            has_cl = ~all(strcmp(modos_cat,'—'));
            if has_cl
                app.log_tab(am.log,sprintf('Clasificador activo — %d puntos catalogados.',n_cat));
            else
                app.log_tab(am.log,'⚠ Sin clasificador: IAv e IAc omitidos (extrapolación fuera de dominio).');
                app.log_tab(am.log,'  Solo IA_0 global puede optimizar sin clasificador.');
                app.log_tab(am.log,'  Entrena el modelo general primero para habilitar IAv e IAc.');
            end

            tabla_data = {};
            pfcns       = {am.mdl0.predictFcn, am.mdlv_pfcn, am.mdlc_pfcn};
            nombres_mdl = {'IA_0 (global)','IAv (Viga)','IAc (Cartela)'};
            labels_modo = {'todos','Viga','Cartela'};

            for km = 1:3
                pfcn_k = pfcns{km};
                if isempty(pfcn_k), continue; end

                % IAv e IAc requieren clasificador — sin él no tienen dominio válido
                if km > 1 && ~has_cl
                    app.log_tab(am.log,sprintf('%s → omitido (sin clasificador).', nombres_mdl{km}));
                    continue;
                end

                % Máscara por modo
                if km == 1
                    ok_modo = true(n_cat,1);
                elseif km == 2
                    ok_modo = strcmp(modos_cat,'Viga');
                else
                    ok_modo = strcmp(modos_cat,'Cartela') | strcmp(modos_cat,'Hibrido');
                end

                n_modo = sum(ok_modo);
                if n_modo == 0
                    app.log_tab(am.log,sprintf('%s → 0 puntos clasificados como %s en el catálogo.', nombres_mdl{km}, labels_modo{km}));
                    continue;
                end

                try
                    E_pred = pfcn_k(tab_cat);
                    epm_k  = E_pred ./ masa;
                    ok2    = isfinite(epm_k) & epm_k > 0 & ok_modo;
                    if ~any(ok2), continue; end
                    [best_epm, best_i_rel] = max(epm_k(ok2));
                    idx_ok    = find(ok2);
                    best_i    = idx_ok(best_i_rel);
                    best_E    = E_pred(best_i);
                    best_masa = masa(best_i);
                    best_modo = modos_cat{best_i};
                    if c_varia
                        tabla_data{end+1} = {nombres_mdl{km},...
                            m1v(best_i), a1v(best_i), bv(best_i),...
                            m2v(best_i), a2v(best_i), ecv(best_i), cv(best_i),...
                            round(best_epm,2), round(best_E,1), round(best_masa,3), best_modo};
                    else
                        tabla_data{end+1} = {nombres_mdl{km},...
                            m1v(best_i), a1v(best_i), bv(best_i),...
                            m2v(best_i), a2v(best_i), ecv(best_i),...
                            round(best_epm,2), round(best_E,1), round(best_masa,3), best_modo};
                    end
                    if km==1 || ~has_cl, lbl_modo2='todos'; elseif km==2, lbl_modo2='Viga'; else, lbl_modo2='Cartela'; end
                    if c_varia
                        app.log_tab(am.log,sprintf('%s [%d pts %s] → m1=%.0f a1=%.0f b=%.0f m2=%.0f a2=%.0f ec=%.0f c=%.0f  E/kg=%.2f J/kg  Modo:%s',...
                            nombres_mdl{km}, n_modo, lbl_modo2, ...
                            m1v(best_i),a1v(best_i),bv(best_i),...
                            m2v(best_i),a2v(best_i),ecv(best_i),cv(best_i),best_epm,best_modo));
                    else
                        app.log_tab(am.log,sprintf('%s [%d pts %s] → m1=%.0f a1=%.0f b=%.0f m2=%.0f a2=%.0f ec=%.0f  E/kg=%.2f J/kg  Modo:%s',...
                            nombres_mdl{km}, n_modo, lbl_modo2, ...
                            m1v(best_i),a1v(best_i),bv(best_i),...
                            m2v(best_i),a2v(best_i),ecv(best_i),best_epm,best_modo));
                    end

                    % Para IAv e IAc: guardar top-5 para selección en validación
                    if km > 1
                        [sorted_epm, sort_rel] = sort(epm_k(ok2), 'descend');
                        idx_ok_all = find(ok2);
                        n_save = min(5, numel(idx_ok_all));
                        top_designs = {};
                        for rank_s = 1:n_save
                            bi     = idx_ok_all(sort_rel(rank_s));
                            epm_s  = sorted_epm(rank_s);
                            masa_s = masa(bi);
                            d_s = struct('m1',m1v(bi),'a1',a1v(bi),'b1',bv(bi),...
                                'l1',l1_f,'m2',m2v(bi),'a2',a2v(bi),'b2',bv(bi),...
                                'l2',l2_f,'c',cv(bi),'e_cartela',ecv(bi));
                            d_s.energia_especifica_J_kg = epm_s;
                            d_s.fuente_modelo = nombres_mdl{km};
                            try
                                t_pt = array2table([m1v(bi),a1v(bi),bv(bi),l1_f,...
                                    m2v(bi),a2v(bi),bv(bi),l2_f,cv(bi),ecv(bi)],...
                                    'VariableNames',{'m1','a1','b1','l1','m2','a2','b2','l2','c','e_cartela'});
                                d_s.epm_ia0 = am.mdl0.predictFcn(t_pt) / masa_s;
                            catch
                                d_s.epm_ia0 = NaN;
                            end
                            top_designs{rank_s} = d_s;
                        end
                        if km == 2, modo_optimos_iav = top_designs;
                        else,       modo_optimos_iac = top_designs; end
                    end
                catch ex_km
                    app.log_tab(am.log,['Error ' nombres_mdl{km} ': ' ex_km.message]);
                end
            end

            % Guardar óptimos modo-específicos para refrescar_panel_optimo
            try
                modo_optimos = {};
                if exist('modo_optimos_iav','var'), modo_optimos{end+1} = {'IAv (Viga)',    modo_optimos_iav}; end
                if exist('modo_optimos_iac','var'), modo_optimos{end+1} = {'IAc (Cartela)', modo_optimos_iac}; end
                if ~isempty(modo_optimos)
                    save(fullfile(car,'optimos_modo.mat'),'modo_optimos');
                    app.log_tab(am.log,'Óptimos IAv/IAc guardados → disponibles en pestaña Validación.');
                end
            catch ex_sv
                app.log_tab(am.log,['Aviso guardar optimos_modo: ' ex_sv.message]);
            end

            if ~isempty(tabla_data)
                am.tabla_opt.Data = vertcat(tabla_data{:});
                app.estilo_tabla(am.tabla_opt);
            end
            win.UserData = am;
            app.log_tab(am.log,'─── Optimización por modo completada ───');
        end

        % ── Entrena los 28 modelos en un subset y devuelve el mejor ─────
        function [best_pfcn, best_rmse, best_r2, best_nombre, tabla_comp] = ...
                entrenar_todos_modelos(app, Xt, yt, pn, kfold, log_handle)

            hp_  = app.hp;
            nv_  = height(Xt);
            kf   = min(kfold, nv_);
            ss   = max(sum((yt - mean(yt)).^2), eps);

            t_ens = templateTree('MinLeafSize', hp_.ens_leafsize);
            nc_   = hp_.ens_cycles; lr_ = hp_.ens_lr; bc_ = hp_.svm_box;
            gb_   = hp_.gpr_basis;
            nf_   = numel(pn);
            ks_fi = max(sqrt(nf_)/4, 0.01);
            ks_me = max(sqrt(nf_),   0.10);
            ks_co = max(sqrt(nf_)*4, 1.00);
            ro_   = struct('WgtFun','bisquare','MaxIter',200);

            % Mismas 28 recetas que cb_train — cv_mode: true=tabla, false=matriz, 'fitlm'=manual
            recetas28 = { ...
                'Árbol Fino',          @() fitrtree(Xt,yt,'MinLeafSize',1),   true,  hp_.grupos.trees; ...
                'Árbol Medio',         @() fitrtree(Xt,yt,'MinLeafSize',4),   true,  hp_.grupos.trees; ...
                'Árbol Grueso',        @() fitrtree(Xt,yt,'MinLeafSize',36),  true,  hp_.grupos.trees; ...
                'Lineal (OLS)',        @(X,y) fitlm(X,y),                                                                    'fitlm', hp_.grupos.lineal; ...
                'Lineal Interacc.',    @(X,y) fitlm(X,y,'interactions'),                                                     'fitlm', hp_.grupos.lineal; ...
                'Lineal Robusto',      @(X,y) fitlm(X,y,'RobustOpts',ro_),                                                  'fitlm', hp_.grupos.lineal; ...
                'Stepwise Lineal',     @(X,y) stepwiselm(X,y,'linear','Upper','quadratic','Verbose',0),                     'fitlm', hp_.grupos.lineal; ...
                'SVM Lineal',          @() fitrsvm(Xt,yt,'KernelFunction','linear',    'Standardize',true,'BoxConstraint',bc_),                            true, hp_.grupos.svm; ...
                'SVM Cuadrática',      @() fitrsvm(Xt,yt,'KernelFunction','polynomial','PolynomialOrder',2,'Standardize',true,'BoxConstraint',bc_),        true, hp_.grupos.svm; ...
                'SVM Cúbica',          @() fitrsvm(Xt,yt,'KernelFunction','polynomial','PolynomialOrder',3,'Standardize',true,'BoxConstraint',bc_),        true, hp_.grupos.svm; ...
                'SVM Gauss. Fina',     @() fitrsvm(Xt,yt,'KernelFunction','rbf','KernelScale',ks_fi,'Standardize',true,'BoxConstraint',bc_),              true, hp_.grupos.svm; ...
                'SVM Gauss. Media',    @() fitrsvm(Xt,yt,'KernelFunction','rbf','KernelScale',ks_me,'Standardize',true,'BoxConstraint',bc_),              true, hp_.grupos.svm; ...
                'SVM Gauss. Gruesa',   @() fitrsvm(Xt,yt,'KernelFunction','rbf','KernelScale',ks_co,'Standardize',true,'BoxConstraint',bc_),              true, hp_.grupos.svm; ...
                'Ef. Lineal LS',       @(X,y) fitrlinear(table2array(X),y,'Learner','leastsquares','Regularization','ridge','Lambda',1e-4), 'fitlm', hp_.grupos.lineal; ...
                'Ef. Lineal SVM',      @(X,y) fitrlinear(table2array(X),y,'Learner','svm',         'Regularization','ridge','Lambda',1e-4), 'fitlm', hp_.grupos.lineal; ...
                sprintf('Boosted Trees x%d',nc_), @() fitrensemble(Xt,yt,'Method','LSBoost','NumLearningCycles',nc_,'Learners',t_ens,'LearnRate',lr_), true, hp_.grupos.ensemble; ...
                sprintf('Bagged Trees  x%d',nc_), @() fitrensemble(Xt,yt,'Method','Bag',    'NumLearningCycles',nc_,'Learners',t_ens),                  true, hp_.grupos.ensemble; ...
                'GPR Sq.Exp.',         @() fitrgp(Xt,yt,'KernelFunction','squaredexponential','BasisFunction',gb_,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'GPR Matern 5/2',      @() fitrgp(Xt,yt,'KernelFunction','matern52',          'BasisFunction',gb_,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'GPR Exponencial',     @() fitrgp(Xt,yt,'KernelFunction','exponential',        'BasisFunction',gb_,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'GPR Rat.Cuad.',       @() fitrgp(Xt,yt,'KernelFunction','rationalquadratic',  'BasisFunction',gb_,'Standardize',true,'FitMethod','exact','PredictMethod','exact'), true, hp_.grupos.gpr; ...
                'Red Estrecha [10]',      @() fitrnet(Xt,yt,'LayerSizes',10,         'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Media [25]',         @() fitrnet(Xt,yt,'LayerSizes',25,         'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Ancha [100]',        @() fitrnet(Xt,yt,'LayerSizes',100,        'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Bicapa [10 10]',     @() fitrnet(Xt,yt,'LayerSizes',[10 10],   'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Red Tricapa [10 10 10]', @() fitrnet(Xt,yt,'LayerSizes',[10 10 10],'Activations',hp_.nn_activations,'Standardize',true,'Verbose',0,'IterationLimit',2000), true, hp_.grupos.redes; ...
                'Kernel SVM (Gauss)', @(X,y) fitrkernel(table2array(X),y,'Learner','svm',         'Standardize',true), 'fitlm', hp_.grupos.kernel; ...
                'Kernel LS (Gauss)',  @(X,y) fitrkernel(table2array(X),y,'Learner','leastsquares','Standardize',true), 'fitlm', hp_.grupos.kernel; ...
            };

            % Filtrar grupos activos
            mask_grp  = cell2mat(recetas28(:,4));
            recetas28 = recetas28(mask_grp, :);
            n_rec     = size(recetas28,1);
            app.log_tab(log_handle, sprintf('  Modelos a evaluar: %d  |  K-fold: %d', n_rec, kf));

            best_pfcn  = []; best_rmse = Inf; best_r2 = NaN; best_nombre = '—';
            tabla_comp = {};
            cvp        = cvpartition(nv_, 'KFold', kf);

            for k = 1:n_rec
                nombre_k = recetas28{k,1};
                cv_mode  = recetas28{k,3};
                app.log_tab(log_handle, sprintf('  [%d/%d] %s...', k, n_rec, nombre_k));
                drawnow;
                t0 = tic;
                ws_rd = warning('off','stats:LinearModel:RankDefDesignMat');
                ws_s  = warning('off','stats:stepwisefit:RankDeficient');
                try
                    if ischar(cv_mode) && strcmp(cv_mode,'fitlm')
                        fn_k = recetas28{k,2};
                        m_probe = fn_k(Xt(training(cvp,1),:), yt(training(cvp,1)));
                        usa_mx  = isa(m_probe,'RegressionKernel') || isa(m_probe,'RegressionLinear');
                        clear m_probe;
                        yp = zeros(nv_,1);
                        for fold = 1:kf
                            tr_ = training(cvp,fold); te_ = test(cvp,fold);
                            mf_ = fn_k(Xt(tr_,:), yt(tr_));
                            if usa_mx
                                yp(te_) = predict(mf_, table2array(Xt(te_,:)));
                            else
                                yp(te_) = predict(mf_, Xt(te_,:));
                            end
                        end
                        mdl_k = fn_k(Xt, yt);
                        if usa_mx
                            pfcn_k = @(t) predict(mdl_k, table2array(t(:,pn)));
                        else
                            pfcn_k = @(t) predict(mdl_k, t(:,pn));
                        end
                    else
                        usa_tab = cv_mode;
                        ws_nn = warning('off','all');
                        mdl_k = recetas28{k,2}();
                        warning(ws_nn);
                        if isa(mdl_k,'RegressionNeuralNetwork')
                            ws_nn2 = warning('off','all');
                            cv_k   = crossval(mdl_k,'KFold',kf);
                            warning(ws_nn2);
                        else
                            cv_k = crossval(mdl_k,'KFold',kf);
                        end
                        yp = kfoldPredict(cv_k);
                        if usa_tab
                            pfcn_k = @(t) predict(mdl_k, t(:,pn));
                        else
                            pfcn_k = @(t) predict(mdl_k, table2array(t(:,pn)));
                        end
                    end
                    rmse_k = sqrt(mean((yp - yt).^2));
                    r2_k   = 1 - sum((yp - yt).^2) / ss;
                    t_s    = toc(t0);
                    tabla_comp{end+1} = {nombre_k, round(rmse_k,2), round(r2_k,4), round(t_s,1)};
                    app.log_tab(log_handle, sprintf('    → RMSE=%.2f J  R²=%.4f  t=%.1f s', rmse_k, r2_k, t_s));
                    if rmse_k < best_rmse
                        best_rmse   = rmse_k;
                        best_r2     = r2_k;
                        best_nombre = nombre_k;
                        best_pfcn   = pfcn_k;
                    end
                catch ex_k
                    app.log_tab(log_handle, ['    ✗ ' ex_k.message]);
                end
                warning(ws_rd);
                warning(ws_s);
            end
            % Ordenar tabla por RMSE
            if ~isempty(tabla_comp)
                rmses_t = cellfun(@(r) r{2}, tabla_comp);
                [~,si]  = sort(rmses_t);
                tabla_comp = tabla_comp(si);
                tabla_comp{find(si==find(rmses_t==min(rmses_t),1),1)}{1} = ...
                    ['★ ' strtrim(tabla_comp{find(si==find(rmses_t==min(rmses_t),1),1)}{1})];
            end
        end

        function fn = receta_por_tipo(~, tipo)
            % Devuelve una función @(X,y)->modelo que replica el tipo global.
            % X es tabla de predictores, y es vector respuesta.
            switch tipo
                case {'GPR_Matern52','GPR Matern 5/2'}
                    fn = @(X,y) fitrgp(X, y, 'KernelFunction','matern52',...
                        'Standardize',true,'FitMethod','exact','PredictMethod','exact');
                case {'GPR Sq.Exp.'}
                    fn = @(X,y) fitrgp(X, y, 'KernelFunction','squaredexponential',...
                        'Standardize',true,'FitMethod','exact','PredictMethod','exact');
                case {'GPR Exponencial'}
                    fn = @(X,y) fitrgp(X, y, 'KernelFunction','exponential',...
                        'Standardize',true,'FitMethod','exact','PredictMethod','exact');
                case {'GPR Rat.Cuad.'}
                    fn = @(X,y) fitrgp(X, y, 'KernelFunction','rationalquadratic',...
                        'Standardize',true,'FitMethod','exact','PredictMethod','exact');
                case {'Ensemble_LSBoost','Boosted Trees x200'}
                    t_ = templateTree('MinLeafSize',5);
                    fn = @(X,y) fitrensemble(X, y, 'Method','LSBoost',...
                        'NumLearningCycles',200,'Learners',t_,'LearnRate',0.1);
                case {'Bagged Trees  x200'}
                    t_ = templateTree('MinLeafSize',5);
                    fn = @(X,y) fitrensemble(X, y, 'Method','Bag',...
                        'NumLearningCycles',200,'Learners',t_);
                case {'Stepwise Lineal','☆ Stepwise Lineal'}
                    fn = @(X,y) stepwiselm(X, y, 'linear','Upper','quadratic','Verbose',0);
                case {'Lineal (OLS)'}
                    fn = @(X,y) fitlm(X, y);
                case {'Lineal Interacc.'}
                    fn = @(X,y) fitlm(X, y, 'interactions');
                case {'Árbol Fino'}
                    fn = @(X,y) fitrtree(X, y, 'MinLeafSize',1);
                case {'Árbol Medio'}
                    fn = @(X,y) fitrtree(X, y, 'MinLeafSize',4);
                case {'Árbol Grueso'}
                    fn = @(X,y) fitrtree(X, y, 'MinLeafSize',36);
                otherwise
                    % Fallback: GPR Matern52
                    fn = @(X,y) fitrgp(X, y, 'KernelFunction','matern52',...
                        'Standardize',true,'FitMethod','exact','PredictMethod','exact');
            end
        end

        function cb_aplicar_modo(app)
            U = app.U.visor;
            val = U.lista.Value;
            if isempty(val) || strcmp(strtrim(val),'(sin simulaciones)'), return; end

            sim_name = strtrim(regexprep(val, '^[✓—]\s+', ''));
            num_str  = regexp(sim_name, '\d+', 'match', 'once');
            n_sim    = str2double(num_str);

            carpeta    = app.ruta_campana();
            archivo_db = fullfile(carpeta, 'basededatos.csv');
            if ~isfile(archivo_db), return; end

            opts = detectImportOptions(archivo_db);
            opts.VariableNamingRule = 'preserve';
            data = readtable(archivo_db, opts);

            if isnan(n_sim) || n_sim < 1 || n_sim > height(data)
                uialert(app.fig, 'No se pudo identificar la fila en basededatos.csv.', 'Error');
                return;
            end

            new_modo = U.dd_modo.Value;
            % Usar el pivot que el usuario tiene en el campo (puede haberlo editado)
            pivot = U.edit_pivot.Value;
            l1    = data.l1(n_sim);
            lever = max(l1 - pivot, eps);

            if iscell(data.modo_fallo)
                data.modo_fallo{n_sim} = new_modo;
            else
                data.modo_fallo(n_sim) = {new_modo};
            end
            data.pivot_height_mm(n_sim) = pivot;
            data.lever_arm_mm(n_sim)    = lever;
            writetable(data, archivo_db);

            app.cb_visor_select(val);
        end

        function cb_regenerar_graficas(app)
            app.cargar_campana();
            if isempty(app.campana)
                uialert(app.fig,'No hay campaña activa.','Error'); return;
            end
            carpeta = app.ruta_campana();
            archivo_db = fullfile(carpeta,'basededatos.csv');
            if ~isfile(archivo_db)
                uialert(app.fig,'No se encuentra basededatos.csv.','Error'); return;
            end

            opts = detectImportOptions(archivo_db);
            opts.VariableNamingRule = 'preserve';
            data = readtable(archivo_db, opts);
            nr = height(data);

            d = dir(fullfile(carpeta,'Sim_*'));
            sims = {d([d.isdir]).name};

            n_ok = 0; n_sin = 0; n_err = 0;
            for k = 1:numel(sims)
                sim_name = sims{k};
                curvas_f = fullfile(carpeta, sim_name, 'Curvas.csv');
                if ~isfile(curvas_f), n_sin = n_sin+1; continue; end

                % Obtener indice de fila en basededatos
                num_str = regexp(sim_name,'\d+','match','once');
                n_sim = str2double(num_str);
                if isnan(n_sim) || n_sim < 1 || n_sim > nr
                    n_err = n_err+1; continue;
                end

                try
                    opts_c = detectImportOptions(curvas_f);
                    opts_c.VariableNamingRule = 'preserve';
                    TC = readtable(curvas_f, opts_c);

                    force_tot   = abs(TC.ForceTotal);
                    disp_mm     = abs(TC.DispX * 1000);
                    energy_acum = cumtrapz(disp_mm/1000, force_tot);

                    ph = data.pivot_height_mm(n_sim);
                    la = max(data.lever_arm_mm(n_sim), 1);
                    if iscell(data.modo_fallo)
                        mf = char(data.modo_fallo{n_sim});
                    else
                        mf = char(data.modo_fallo(n_sim));
                    end

                    angle_deg = asind(min(disp_mm / la, 1));
                    moment_Nm = force_tot .* (la/1000) .* cosd(angle_deg);

                    fig = figure('Visible','off','Position',[100 100 1500 450]);

                    subplot(1,3,1);
                    plot(disp_mm, force_tot,'-b','LineWidth',2);
                    grid on;
                    xlabel('Desplazamiento X [mm]','Interpreter','none');
                    ylabel('Fuerza Total [N]','Interpreter','none');
                    title('Fuerza vs Desplazamiento X','Interpreter','none');

                    subplot(1,3,2);
                    plot(disp_mm, energy_acum,'-r','LineWidth',2);
                    grid on;
                    xlabel('Desplazamiento X [mm]','Interpreter','none');
                    ylabel('Energia Absorbida [J]','Interpreter','none');
                    title('Energia Absorbida vs Desplazamiento X','Interpreter','none');

                    subplot(1,3,3);
                    plot(angle_deg, moment_Nm,'-k','LineWidth',2);
                    grid on;
                    xlabel('Angulo de Giro [grados]','Interpreter','none');
                    ylabel('Momento Flector [N·m]','Interpreter','none');
                    title(sprintf('Momento vs Angulo | %s | pivote %.1f mm', mf, ph),'Interpreter','none');

                    sgtitle(sprintf('Resultados Cinematicos y Estructurales - %s', sim_name),'Interpreter','none');

                    img_path = fullfile(carpeta, sim_name, 'Graficas_Completas.png');
                    saveas(fig, img_path);
                    close(fig);
                    n_ok = n_ok + 1;
                catch
                    n_err = n_err + 1;
                end
            end

            msg = sprintf('Gráficas regeneradas: %d  |  Sin Curvas.csv: %d  |  Errores: %d', n_ok, n_sin, n_err);
            uialert(app.fig, msg, 'Regenerar gráficas', 'Icon','success');
        end

        function cargar_imagen(~, ax, ruta)
            cla(ax); axis(ax,'off');
            if isfile(ruta)
                try
                    img = imread(ruta);
                    imshow(img,'Parent',ax);
                    axis(ax,'off');
                catch
                    title(ax,'Error cargando imagen');
                end
            else
                title(ax,'Sin imagen');
            end
        end

        % ---------------------------------------------------------------
        % Genera Graficas_Completas.png desde un Curvas.csv
        % (equivalente al bloque de T02 / T05)
        % ---------------------------------------------------------------
        function generar_graficas_sim(~, curvas_file, img_path, pivot_mm, lever_mm, sim_id)
            opts = detectImportOptions(curvas_file);
            opts.VariableNamingRule = 'preserve';
            TC = readtable(curvas_file, opts);

            force_tot  = abs(TC.ForceTotal);
            disp_mm    = abs(TC.DispX * 1000);
            energy_ac  = cumtrapz(disp_mm / 1000, force_tot);
            angle_deg  = asind(min(disp_mm / lever_mm, 1));
            moment_Nm  = force_tot .* (lever_mm / 1000) .* cosd(angle_deg);

            fig = figure('Visible','off','Position',[100 100 1500 450]);

            ax1 = subplot(1,3,1,'Parent',fig);
            plot(ax1, disp_mm, force_tot, '-b','LineWidth',2);
            grid(ax1,'on');
            xlabel(ax1,'Desplazamiento X [mm]','Interpreter','none');
            ylabel(ax1,'Fuerza Total [N]','Interpreter','none');
            title(ax1,'Fuerza vs Desplazamiento X','Interpreter','none');

            ax2 = subplot(1,3,2,'Parent',fig);
            plot(ax2, disp_mm, energy_ac, '-r','LineWidth',2);
            grid(ax2,'on');
            xlabel(ax2,'Desplazamiento X [mm]','Interpreter','none');
            ylabel(ax2,'Energía Absorbida [J]','Interpreter','none');
            title(ax2,'Energía Absorbida vs Desplazamiento X','Interpreter','none');

            ax3 = subplot(1,3,3,'Parent',fig);
            plot(ax3, angle_deg, moment_Nm, '-k','LineWidth',2);
            grid(ax3,'on');
            xlabel(ax3,'Ángulo de Giro [grados]','Interpreter','none');
            ylabel(ax3,'Momento Flector [N·m]','Interpreter','none');
            title(ax3, sprintf('Momento vs Ángulo | pivote %.1f mm', pivot_mm),'Interpreter','none');

            sgtitle(fig, sprintf('Resultados — Simulación %s', string(sim_id)),'Interpreter','none');

            saveas(fig, img_path);
            close(fig);
        end

        function set_prog(~, outer, inner, val)
            w = outer.Position(3);
            inner.Position(3) = max(1, round(val * w));
            drawnow limitrate;
        end

    end % methods private
end % classdef
