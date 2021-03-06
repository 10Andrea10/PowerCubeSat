function results = fcn_power_model(mission, orbit, panel, attitude, activations)
%% Debug data
% clean up workspace clear variables; close all; clc;

% save data from GUI for debugging
% save('data.mat', 'mission', 'orbit', 'panel', 'attitude')

% load data from GUI for debugging
% load('data.mat')


%% Inputs
% ideal power output performance per unit area [W/m^2] 12-2: calcola la potenza ideale della cella moltiplicando la potenza solare per l’efficienza di conversione. Poi calcola la potenza a inizio vita (BOL), la life degradation e la potenza a fine vita (EOL) con le formule li scritte
powerIdeal = mission.solarConstant * mission.efficiency;

% beginning of life power output per unit area (not including cosine loss)
% [W/m^2]
powerBOL = powerIdeal * mission.inherentDeg;

% lifetime degradation of solar panels
lifetimeDeg = (1 - mission.degPerYear)^mission.lifetime;

% end of life power output per unit area (not including cosine loss)
% [W/m^2]
powerEOL = powerBOL * lifetimeDeg;


%% Set up arrays and variables for loop
% attitude arrays
satSunUnitNew = zeros(orbit.numSteps,3);
changeBasisSun = zeros(3,3,orbit.numSteps);
changeBasisSat = zeros(3,3,orbit.numSteps);

% total number of panels
numPanels = length(panel);
% panel cells
for j = 1:numPanels
    panel{j}.newPoints = zeros(4,3,orbit.numSteps);
    panel{j}.polygon(orbit.numSteps,1) = polyshape();
    panel{j}.avgZ = zeros(orbit.numSteps,1);
    panel{j}.newUnitNormal = zeros(orbit.numSteps,3);
end

% power arrays
results.powerPanel = zeros(orbit.numSteps, numPanels);
results.powerTotal = zeros(orbit.numSteps,1);
% TODO(results.powerAvg and results.powerAvgTime size from estimated number
% of orbits)

% set up orbit number variables 50-64 calcola quante volte far girare il satellite attorno alla Terra, in base agli input dati nella prima schermata
orbitNum = 1;
orbitEnd = orbit.reportTime(1) + seconds(orbit.orbitalPeriod);
orbitStartStep = 1;

i = 1;
while orbit.reportTime(i) <  orbitEnd
    i = i + 1;
end
results.orbitStepLength = i;

% start waitbar
prog = waitbar(0, 'Start...');

% radius of earth for eclipse calculations 65 inserisce raggio terrestre
rEarth = 6371e3;


%% Loop over each timestep
for i = 1:orbit.numSteps
    % iterate waitbar each timestep
    % TODO(change this to update once per orbit, updating too often can be
    % slow)
    waitString = sprintf('%i of %i: Calculating...', i, orbit.numSteps);
    waitbar(i / orbit.numSteps, prog, waitString);
    
    
    %% Check if in eclipse
    % solve equation of intersection https://math.stackexchange.com/questions/1939423/calculate-if-vector-intersects-sphere 77-86 condizione di annullamento della potenza se cubesat dietro la Terra
    a = dot(orbit.satSunUnit(i,:), orbit.satSunUnit(i,:));
    b = 2 * dot(orbit.satSunUnit(i,:), orbit.satPos(i,:));
    c = dot(orbit.satPos(i,:), orbit.satPos(i,:)) - rEarth^2;
    
    r = roots([a b c]);
    % if roots positive and non imaginary then in eclipse (intercetion is infront of
    % satellite)
    if r(1) > 0 && r(2) > 0 && imag(r(1)) == 0 && imag(r(2)) == 0
        % in eclipse so don't perform calculations
    else
        % not in eclipse so do perform calculations 90-106 calcola il cambiamento di base per avere il Sole in coordinate centrate nel satellite invece che nella Terra. Earth Centered System (ECI) -> Satellite Centered System (SCS). Input attitude.sat.Positive
        %% Sun vector unit normal in satellite geoemetry basis
        % need the sun vector in the body centred and alligned
        % coordinate system, the satellite body is centred on the
        % origin and alligned to the x-y-z axes
        
        % to get this, change basis from normal earth centered
        % coordinate system to satellite centered and aligned
        % coordinate system
        
        % set change of basis matrix for each timestep, 3x3 matrix made
        % from 3 column vecotrs, each being the desired direction of
        % the positive x, y, and z faces of the satellite in the earth
        % centered coordinate system
        changeBasisSun(:,:,i) = [attitude.satPositiveX(i,:).', attitude.satPositiveY(i,:).', attitude.satPositiveZ(i,:).'];
        
        % find the new sun vector in the satellite's coordinate system
        satSunUnitNew(i,:) = changeBasisSun(:,:,i) \ orbit.satSunUnit(i,:).';
        
        
        %% Change satellite geometry basis to sun pov
        % change the basis of the satellite panel coordinates to be 109-136 modifica la geometria del satellite, allineando l’asse z del SCS al sun vector
        % alligned to Sun's 'point of view'
        
        % the new z axis is the sun vector, the x and y orientation
        % does not matter as long as all three vectors are orthoganal
        
        % pick two components, swap and add a zero, this creates a
        % vector in the perpendicular plane of the original sun vecotor
        v1(1) = -satSunUnitNew(i,2);
        v1(2) = satSunUnitNew(i,1);
        v1(3) = 0;
        % get unit vector
        v1 = v1 / norm(v1);
        
        % cross product to get second vector in perpendicular plane
        v2 = cross([satSunUnitNew(i,1) satSunUnitNew(i,2) satSunUnitNew(i,3)], v1);
        
        % create change of basis matrix from the 3 orthoganal vectors,
        % new z is the sun vector in body centred and aligned
        % coordinate system
        changeBasisSat(:,:,i) = [v1.', v2.', satSunUnitNew(i,:).'];
        
        % find new points
        for j = 1:numPanels
            panel{j}.newPoints(:,:,i) = (changeBasisSat(:,:,i) \ panel{j}.points(:,:).').';
            panel{j}.newUnitNormal(i,:) = (changeBasisSat(:,:,i) \ panel{j}.unitNormal(:));
        end
        
        
        %% Define polygons
        % define polygons from new points, these are the panels as the 137-155 proietta i poligoni dei pannelli (facce e deployable) nel sistema di riferimento con z allineato al sun vector. Questo è il modo in cui il sole vede i pannelli, quindi qui sta tenendo conto dell’angolo Teta di cui sopra (!!)
        % sun views them, polygons allow clipping and area calculations
        % which are equivelent to cosine loss factor
        
        % polyshapes for each panel body mounted panels, check if
        % pointing at Sun, if not then dont bother creating a polygon
        for j = 1:6
            if panel{j}.newUnitNormal(i,3) > 0
                panel{j}.polygon(i) = polyshape(panel{j}.newPoints(:,1:2,i));
            end
        end
        
        % deplotable panels
        for j = 7:numPanels
            panel{j}.polygon(i) = polyshape(panel{j}.newPoints(:,1:2,i));
        end
        
        
        %% Find average z-level of each polygon
        % average z level shows which panels are infront of each other 158-171 calcola la z-media (??) quindi rispetto al punto di vista solare sovrappone i poligoni dei pannelli gli uni con gli altri, in modo da capire quale fa ombra a quale. 
        % with resepect to the Sun's 'point of view', allowing
        % clipping.
        
        % Average of points only works as size and shape of panels is
        % known (arbitrary panels could have lower average z whilst
        % being infront, i.e. very long panels compared to shorter
        % ones)
        
        % average z-level of each panel
        for j = 1:numPanels
            panel{j}.avgZ(i) = mean(panel{j}.newPoints(:,3,i));
        end
        
        
        %% Clip each polygon with every other polygon
        % use average z level to clip polygons, leaving only visible 174-193 usando la z-media sovrappone un pannello all’altro ed estrae le superfici attive, cioè quelle investite dal Sole. Solo loro opereranno la conversione
        % area of visible polygons
        
        % clip all polygons
        for j = 1:numPanels
            % with all other polygons
            for k = (j + 1):numPanels
                % only clip if both polygons have non-zero area
                if area(panel{j}.polygon(i)) ~= 0 && area(panel{k}.polygon(i)) ~= 0
                    % if panel j is above panel k then subtract panel j
                    % from panel k, else do opposite
                    if panel{j}.avgZ(i) > panel{k}.avgZ(i)
                        panel{k}.polygon(i) = subtract(panel{k}.polygon(i), panel{j}.polygon(i));
                    else
                        panel{j}.polygon(i) = subtract(panel{j}.polygon(i), panel{k}.polygon(i));
                    end
                end
            end
        end
        
        
        %% Power calcualtions
        % use the clipped polygons to get panel areas, these include 196-219 calcola la potenza prodotta per pannello moltiplicando la potenza ideale a inizio vita per la superficie effettivamente attiva. Praticamente si moltiplica quanta potenza viene convertita dal rendimento della cella per l’area che effettivamente è attiva. Si passa da W/m^2 a W. Ci saranno altri fattori di rendimento da considerare, fra cui la temperatura molto importante (!!)  (non sappiamo come fare ancora, chiedere TCS)
        % cosine losses due to the geometry transformations
        
        % if not in an eclipse, perform power calculations body mounted
        % panels are active only if activations tells so. activations order: PosX,NegX,PosY,NegY,PosZ,NegZ 
        for j = 1:6
            if(activations(j) == 0)
                continue
            end
            % power for each panel at each timestep
            results.powerPanel(i, j) = powerEOL * area(panel{j}.polygon(i)) / 1e6;
            % total power for the satellite at each timestep
            results.powerTotal(i) = results.powerTotal(i) + results.powerPanel(i, j);
        end
        
        % deployable panels
        for j = 7:numPanels
            % check if panel normal is pointing toward sun, if yes then
            % it is iluminated so calculate power
            if panel{j}.newUnitNormal(i,3) > 0
                results.powerPanel(i, j) = powerEOL * area(panel{j}.polygon(i)) / 1e6;
            end
            results.powerTotal(i) = results.powerTotal(i) + results.powerPanel(i, j);
        end
    end % end if eclipse check
    
    
    %% Orbit averaged power calculations
    % for orbit averaged power results, check if at the end of an orbit 224-239 calcola la potenza mediata sull’orbita. Da capire se può farlo su più orbite o addirittura su tutta la missione. Dove usa la LifeDegradation (????)
    if orbit.reportTime(i) > orbitEnd
        % set orbit end step
        orbitEndStep = i;
        % set avg power for this orbit
        results.powerAvg(orbitNum) = mean(results.powerTotal(orbitStartStep:orbitEndStep));
        % set time for this orbit as halfway through the orbit
        orbitMidStep = floor((orbitStartStep + orbitEndStep) / 2);
        results.powerAvgTime(orbitNum) = orbit.reportTime(orbitMidStep);
        
        % set new orbit start step
        orbitStartStep = i + 1;
        % set new time for next orbit end
        orbitEnd = orbitEnd + seconds(orbit.orbitalPeriod);
        % iterate orbit number
        orbitNum = orbitNum + 1;
    end
end % end for numSteps

% close waitbar
close(prog)
end % end function