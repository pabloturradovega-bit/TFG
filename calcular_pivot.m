function [pivot_height_mm, lever_arm_mm, modo_fallo] = calcular_pivot(y_max_stress_mm, c, a1, a2, l1)
% Devuelve la altura de pivote (global Y), el brazo efectivo y el modo de fallo.
%
% Coordenadas globales Y del modelo ANSYS:
%   Y=0        B_Inferior = A_Base (apoyo fijo al chasis)
%   Y=a2       Union L (cara superior de Viga B toca Viga A)
%   Y=a2+c     Tope de la cartela en Viga A
%   Y=l1       A_Tope (punto de carga, extremo libre de Viga A)
%
% Logica de pivote (basada en imagenes de deformada de ANSYS):
%
%   y_max < 1 mm  -> 'Hibrido'
%       y_max estrictamente cero (tolerancia numerica < 1 mm). Plastificacion
%       concentrada en la base, curvatura distribuida por la zona Viga B + cartela.
%       Pivote = (a2+c)/2
%
%   1 <= y_max <= c+a2+0.1  -> 'Cartela'
%       La rotula (puntual o difusa) esta dentro de la zona reforzada.
%       La estructura gira como cuerpo rigido desde la base.
%       Pivote = 0, lever = l1 siempre.
%
%   y_max > c+a2+0.1  -> 'Viga'
%       Rotula plastica concentrada en el pilar libre, por encima de la cartela.
%       Pivote = y_max
%
% lever_arm_mm = l1 - pivot_height_mm
% Angulo: theta = asind(desplazamiento / lever_arm_mm)  [NO atan]

    if isfinite(y_max_stress_mm) && y_max_stress_mm < 1
        % Plastificacion en la base: modo hibrido
        pivot_height_mm = (a2 + c) / 2;
        modo_fallo      = 'Hibrido';
    elseif isfinite(y_max_stress_mm) && y_max_stress_mm > (c + a2 + 0.1)
        % Rotula en el pilar libre: modo Viga
        pivot_height_mm = y_max_stress_mm;
        modo_fallo      = 'Viga';
    elseif isfinite(y_max_stress_mm)
        % Rotula dentro de la zona reforzada (cartela/union/base): Cartela
        pivot_height_mm = 0;
        modo_fallo      = 'Cartela';
    else
        % Sin datos de tension (NaN)
        pivot_height_mm = 0;
        modo_fallo      = 'N/A';
    end
    lever_arm_mm = max(l1 - pivot_height_mm, eps);
end
