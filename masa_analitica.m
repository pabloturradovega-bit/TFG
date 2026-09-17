function mass_kg = masa_analitica(m1, a1, b1, l1, m2, a2, b2, l2, c, e_cartela)
% MASA_ANALITICA  Masa analitica de la seccion en L [kg].
%   Vigas A y B: tubo rectangular de pared m, seccion a x b, longitud l.
%       Area = 2*m*(a + b - 2*m)  [mm^2]
%   Cartela: dos triangulos verticales (catetos c, espesor e_cartela) + tapa
%       sobre las hipotenusas (ancho b). Tres cuerpos, como en SpaceClaim.
%       Volumen = c^2*e_cartela + sqrt(2)*c*e_cartela*b  [mm^3]
%       (coincide con la masa de ANSYS a +-0.002%).
%
%   Todas las entradas en mm; acepta escalares o vectores columna
%   (dimensiones compatibles elemento a elemento).
%
%   FORMULA UNICA compartida por T03/T04/T06 y la GUI. No duplicar:
%   cualquier correccion debe hacerse SOLO aqui para que el KPI
%   energy_per_mass sea comparable entre todas las etapas del pipeline.

    rho = 7850e-9;  % densidad acero S235JR [kg/mm^3]

    A1 = 2 .* m1 .* (a1 + b1 - 2.*m1);          % [mm^2]
    A2 = 2 .* m2 .* (a2 + b2 - 2.*m2);          % [mm^2]
    V_cartela = c.^2 .* e_cartela + sqrt(2) .* c .* e_cartela .* b1;  % [mm^3] 2 triangulos + tapa

    mass_kg = rho .* (A1 .* l1 + A2 .* l2 + V_cartela);
end
