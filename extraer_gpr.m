function gp = extraer_gpr(tm)
% EXTRAER_GPR  Busca un objeto GPR (fitrgp) dentro del struct del surrogate.
%   Devuelve [] si el modelo no es un GPR. Cubre el formato de T03 (export
%   de Regression Learner, campo RegressionGP) y el de la GUI (modelo
%   fitrgp directo), explorando structs anidados hasta 3 niveles.
%   Compartida por T04 y la GUI: no duplicar.

    gp = [];
    queue = {tm};
    for depth = 1:3
        next = {};
        for q = 1:numel(queue)
            x = queue{q};
            if isa(x, 'RegressionGP') || isa(x, 'classreg.learning.regr.CompactRegressionGP')
                gp = x;
                return;
            end
            if isstruct(x) && isscalar(x)
                fn = fieldnames(x);
                for ff = 1:numel(fn)
                    next{end+1} = x.(fn{ff}); %#ok<AGROW>
                end
            end
        end
        queue = next;
        if isempty(queue), return; end
    end
end
