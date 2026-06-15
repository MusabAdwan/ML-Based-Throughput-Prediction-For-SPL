function production_simulation_gui
   % Main GUI window with a title and size
    fig = uifigure('Name', 'Production Line Simulation', 'Position', [100 100 400 300]);

    %% Input File Selection
    % Label for input file
    uilabel(fig, 'Position', [20 250 100 22], 'Text', 'Input File:');
    % Text field for input file path
    inputFileEdit = uieditfield(fig, 'text', 'Position', [100 250 200 22]);
    % "Browse" button to choose input file, calls 'selectFile' when clicked
    uibutton(fig, 'Position', [310 250 70 22], 'Text', 'Browse', 'ButtonPushedFcn', @(~,~) selectFile(inputFileEdit));
    
   %% Output File Selection
    % Label for output file
    uilabel(fig, 'Position', [20 220 100 22], 'Text', 'Output File:');
    % Text field for output file path
    outputFileEdit = uieditfield(fig, 'text', 'Position', [100 220 200 22]);
    % "Browse" button to select output file, calls 'selectOutputFile'
    outputBrowseBtn = uibutton(fig, 'push', 'Text', 'Browse...', 'Position', [310 220 70 22], ...
        'ButtonPushedFcn', @(btn,event) selectOutputFile(outputFileEdit));
    %% Simulation Parameters
    % Label and numeric input for total simulation time (T_sim)
    uilabel(fig, 'Position', [20 180 100 22], 'Text', 'T_sim:');
    T_simEdit = uieditfield(fig, 'numeric', 'Position', [100 180 100 22], 'Value', 50000);
    % Label and numeric input for warm-up time (T_wu)
    uilabel(fig, 'Position', [20 150 100 22], 'Text', 'T_wu:');
    T_wuEdit = uieditfield(fig, 'numeric', 'Position', [100 150 100 22], 'Value', 1500);
    % Label and numeric input for number of simulation replicates
    uilabel(fig, 'Position', [20 120 100 22], 'Text', 'Replicates:');
    replicatesEdit = uieditfield(fig, 'numeric', 'Position', [100 120 100 22], 'Value', 5);
    % Label and numeric input for confidence interval (IC)
    uilabel(fig, 'Position', [20 90 100 22], 'Text', 'IC:');
    ICEdit = uieditfield(fig, 'numeric', 'Position', [100 90 100 22], 'Value', 0.95);
    %% Run Simulation Button
    % Button to start the simulation process using all input parameters
    uibutton(fig, 'Position', [150 40 100 30], 'Text', 'Run Simulation', ...
        'ButtonPushedFcn', @(~,~) runSimulation(fig, inputFileEdit.Value, outputFileEdit.Value, ...
        T_simEdit.Value, T_wuEdit.Value, replicatesEdit.Value, ICEdit.Value));
end

function selectFile(editField)
    % Opens a file selection dialog that filters for .csv files
    [file, path] = uigetfile('*.csv');
    % If a file is selected 
    if file
        % Set the value of the associated edit field to the full path of the selected file
        editField.Value = fullfile(path, file);
    end
end

function selectOutputFile(outputFileEdit)
    % Opens a folder selection dialog
    path = uigetdir;
    % If a folder is selected 
    if path
       % Set the value of the output file field to "output.csv" inside the selected folder
        outputFileEdit.Value = fullfile(path, 'output.csv');
    end
end

function runSimulation(fig, inputFile, outputFile, T_sim, T_wu, replicates, IC)
       
    %profile on % Enable MATLAB profiler to analyze performance (for debugging/optimization)
    
%% Check if input file exists
    if ~isfile(inputFile)
        % Show error if input file does not exist
        uialert(gcf, 'Input file not found.', 'Error');
        return;
    end

    % Create the progress dialog
    d = uiprogressdlg(fig, 'Title', 'Running Simulation', ...
        'Message', 'Please wait...', 'Indeterminate', 'on');

    %% Reading and Parsing Input CSV File
    % Open file to read first line (headers)
    filename = inputFile;
    fileID = fopen(filename, 'r');
    firstLine = fgetl(fileID);  % Read the first line
    fclose(fileID);
    % Splitting the header into column names
    firstLineCells = strsplit(firstLine, ',');
    numCols = length(firstLineCells);  % Number of columns
    % Define format for reading: first column numeric, rest are strings
    formatSpec = ['%f ', repmat('%q ', 1, numCols - 1)];
    % Reopen and read the file (excluding the header line)
    fileID = fopen(filename, 'r');
    data = textscan(fileID, formatSpec, 'Delimiter', ',', 'HeaderLines', 1, 'TextType', 'string');
    fclose(fileID);
    % Convert raw data into a table with appropriate headers
    existingData = table(data{:}, 'VariableNames', firstLineCells);
    
    %% Extract parameters from the data
    K = data{1}; % First column: number of machines
    % Second column: buffer capacities (convert 'None' to NaN or empty
    N = cellfun(@(x) str2num(x), strrep(data{2}, 'None', ''), 'UniformOutput', false);%
    % L: Cell array holding matrices for each production line configuration
    L = cell(length(K), 1);
    for i = 1:length(K)
        currentRowMatrices = {};
        for j = 3:length(data)
            matrixStr = data{j}(i);
            if strcmp(matrixStr, 'None')
                continue;
            end
            matrix = str2num(matrixStr); % Convert matrix string to numeric array
            currentRowMatrices{end + 1} = matrix;
        end
        L{i} = currentRowMatrices;
    end
    % mu: Default processing parameters (e.g., uptime/downrate)
    mu = cell(length(K), 1);
    for i = 1:length(K)
        numMachines = K(i);
        mu{i} = cell(numMachines, 1);
        for j = 1:numMachines
            mu{i}{j} = [1, 0]; % Placeholder values (e.g., rate = 1, failure = 0)
        end
    end
    
    %% Initialize results structure
    results = repmat(struct('Avg_NP1', [], 'Std_NP1', [], 'CI_NP', [], 'CI_Std_NP', [], 'Avg_BL', [], 'mTTS', []), length(K), 1);
    %% Seting Up Parallel Processing
       pool = gcp('nocreate');
    if isempty(pool)
    parpool;  % % Start parallel pool (default number of workers)
    end
     % Attach simulation function file to workers
    addAttachedFiles(gcp, {'SPL_Matlab_Simulation.m'}); % Change 'Untitled.m' to the actual file name if needed

  %% Run Simulations in Parallel
  % ===== TIMING STORAGE =====
    row_times = zeros(length(K),1);

    % ===== TOTAL DATASET TIMER =====
    dataset_timer = tic;
   parfor i = 1:length(K)
        disp(['Processing index:', num2str(i)]);  % Display current index
        row_timer = tic;
        [avg_NP1, std_NP1, CI_NP, CI_std_NP, avg_BL, mTTS] = ...
            disc_line_sim(T_sim, T_wu, K(i), N{i}, L{i}, mu{i}, replicates, IC);
        % ===== SAVE ROW TIME =====
        row_times(i) = toc(row_timer);
        % Store results for each configuration
        results(i).Avg_NP1 = avg_NP1;
        results(i).Std_NP1 = std_NP1;
        results(i).CI_NP = CI_NP;
        results(i).CI_Std_NP = CI_std_NP;
        results(i).Avg_BL = avg_BL;
       results(i).mTTS = mTTS;

    end
    % ===== TOTAL DATASET TIME =====
    total_simulation_time = toc(dataset_timer);

    % ===== TIMING STATISTICS =====
    num_samples = length(K);
    avg_time_per_sample = mean(row_times);
    min_time_per_sample = min(row_times);
    max_time_per_sample = max(row_times);
    std_time_per_sample = std(row_times);
    
    % Save Results to CSV
    newResultsTable = struct2table(results);
    if ~isempty(newResultsTable)
        % Combine simulation results with original data
        combinedData = [existingData, newResultsTable];  % Concatenate new results with existing data
        % Define output file name (original name + "_updated")
        [~, name, ext] = fileparts(filename);
        outputDir = fileparts(outputFile);
        newOutputFile = fullfile(outputDir, [name, '_updated', ext]);
        % Write the combined data to a new file
        writetable(combinedData, newOutputFile, 'WriteVariableNames', true);
        % =========================================
        % CREATE TIMING TABLE
        % =========================================
        TimingSummary = table( ...
    total_simulation_time, ...
    avg_time_per_sample, ...
    min_time_per_sample, ...
    max_time_per_sample, ...
    std_time_per_sample, ...
    'VariableNames', { ...
        'Total_Time_sec', ...
        'Avg_Row_Time_sec', ...
        'Min_Row_Time_sec', ...
        'Max_Row_Time_sec', ...
        'Std_Row_Time_sec' ...
    } ...
);
        TimingTable = table( ...
            (1:num_samples)', ...
            row_times, ...
            'VariableNames', { ...
                'Row_Index', ...
                'Row_Time_sec' ...
            } ...
        );
              % =========================================
        % SAVE TIMING CSV
        % =========================================
      %  timingFile = fullfile(outputDir, [name, '_timing.csv']);
      %  writetable(TimingTable, timingFile);
      %  disp(['Timing results saved to ', timingFile]);
        timingFile2 = fullfile(outputDir, [name, '_timing.csv']);
        writetable(TimingSummary, timingFile2);
        disp(['Timing results saved to ', timingFile2]);
         % Confirm successful save
        if exist(newOutputFile, 'file')
            disp(['Results successfully saved to ', newOutputFile]);
        else
            disp('Error: Failed to save the updated results.');
        end
    else
        disp('Error: No simulation results were generated.');
    end
    %%  Finalize
    close(d);% Close the progress dialog
    uialert(fig, 'Simulation completed successfully.', 'Done');  % Notifivation
  %  profile viewer % Show profiler results for performance analysis

end

function [avg_NP1,std_NP1,CI_NP,CI_std_NP,avg_BL,mTTS,vTTS,g]=disc_line_sim(T_sim,T_wu,K,N,L,mu,replicates,IC)
%% Simulates a serial production line over a given time with warm-up period and replicates.
% INPUTS:
%   T_sim     - total simulation time
%   T_wu      - warm-up period
%   K         - number of machines
%   N         - buffer sizes (K-1 values)
%   L         - cell of transition probability matrices for each machine
%   mu        - service rate per state for each machine
%   replicates- number of simulation runs
%   IC        - confidence level (e.g., 0.95)
% OUTPUTS:
%   avg_NP1   - average number of parts from last machine
%   std_NP1   - std deviation of parts
%   CI_NP     - confidence interval of average
%   CI_std_NP - confidence interval of std
%   avg_BL    - average buffer levels across replicates
%   mTTS      - mean time to starvation (of second machine)
%   vTTS      - variance of TTS
%   g         - cell array of all TTS duration

tic  % Start performance timing
%% Run simulation for each replicate
 for q=1:replicates
    % Initialize state vectors
    s_t = zeros(T_sim-T_wu,1); % Track state of machine 2 after warm-up
    bu_T_S1=zeros(T_sim-T_wu,1); % Track buffer 1 levels after warm-up
    st=ones(1,K); % Initial states for all machines
    idle=zeros(1,K);  % Idle flags
    E = zeros(1,K); % Average effective processing rate
    old=0;
    % Initialize state and buffer visit counters
    for i=1:K
        S(i)=length(mu{i}); % Number of states per machine
        % st(i)=1; % Machine state at time zero
        % idle(i)=0;%inizializes the idle indicator
        % E(i)=0;
        S_ID{i}=zeros(1,S(i)+2);  % +1 = starvation, +2 = blocking
        M_stat{i}=zeros(1,S(i)+2); % Collects the final machine-state probabilities
    end
    bl= zeros(1,K-1); % Buffer level initialization
    avg_level= zeros(1,K-1);
    for i=1:K-1
        %   bl(i)=0;%buffer level at time zero
        %  avg_level(i)=0;
        B_ID{i}=zeros(1,N(i)+1); % Buffer level visit frequency
        B_stat{i}=zeros(1,N(i)+1); % Collects the final buffer level probabilities
    end
    
    %% Main simulation loop
    for t=1:T_sim%simulation cycle
        % Show progress every 100,000 steps

        if t/100000 == floor(t/100000)
            t
            q
        end
        %% Machine states updates
        for i=1:K  
            % Blocking/starvation logic
            if i==1
                if (bl(i)==N(i))
                    idle(i)=1;
                    S_ID{i}(1,S(i)+2)=S_ID{i}(1,S(i)+2)+1; % Update of the machine blocking statistics
                end
            elseif i==K
                if bl(i-1)==0
                    idle(i)=1;
                    S_ID{i}(1,S(i)+1)=S_ID{i}(1,S(i)+1)+1; % Update of the machine starvation statistic
                end
            elseif (i>1) || (i<K) % Check for the blocking or starvation conditions
                if bl(i)==N(i) % Blocking
                    idle(i)=1; % Support variable - indicates if a machine is idle (1) or not (0)
                    S_ID{i}(1,S(i)+2)=S_ID{i}(1,S(i)+2)+1; % Update of the machine blocking statistics
                elseif bl(i-1)==0  % Starvation
                    idle(i)=1; % Support variable - indicates if a machine is idle (1) or not (0)
                    S_ID{i}(1,S(i)+1)=S_ID{i}(1,S(i)+1)+1; % Update of the machine starvation statistics
                end
            end
            % If not idle, apply transition based on probabilities
            if idle(i)==0 % Operation dependent transitions
                % Procedure for determining the new state of the machine
                rn=rand(1);
                cont=0;
                for j=1:S(i)
                    cont=cont+L{i}(st(i),j);
                    if (cont>=rn)
                        
                        st(i)=j;
                        cont=-1.1;
                    end
                end
                old=  S_ID{K}(1,st(K));
                S_ID{i}(1,st(i))=S_ID{i}(1,st(i))+1; % Updates the machine statistics
                
            end
            if t>T_wu  % Log machine 2 state after warm-up
                s_t(t-T_wu)=st(2); % Saves the vector of the state of the second machine
            end
            %    if (S_ID{K}(1,st(K)) == old +1 && t> T_wu)
            %   G(t-T_wu,q) = 1;
            %    elseif (t> T_wu)
            %        G(t-T_wu,q) =0;
            %    end
        end
        %% Buffer updates 
        for i=1:K-1 % Buffer levels updates
            bl(i)=bl(i)+mu{i}(1,st(i))*(1-idle(i))-mu{i+1}(1,st(i+1))*(1-idle(i+1));%updates the level of the buffer i
            if t > T_wu
                bu_T_S1(t-T_wu) = bl(i);
            end
            B_ID{i}(1,bl(i)+1)=B_ID{i}(1,bl(i)+1)+1;%updates the buffer statistics
        end
        %% Reset the values of the idle indicator
        for i=1:K 
            idle(i)=0; % Reset idle flags
        end
        %% Reset statistics after warm-up
        if (t==T_wu) % Statistics are reset when the warm up is finished
            for i=1:K
                S_ID{i}=zeros(1,S(i)+2);%inizialize machine statistics
            end
            for i=1:K-1
                B_ID{i}=zeros(1,N(i)+1); % Inizialize buffer statistics
            end
        end
    end
    %% Post-simulation statistics for this replicate 
    for i=1:K
        for j=1:S(i)+2
            M_stat{i}(1,j)=S_ID{i}(1,j)/(T_sim-T_wu);
        end
        for j=1:S(i)
            E(i)=E(i)+M_stat{i}(1,j)*mu{i}(1,j); % Calculates the average production rate of the system.
        end
    end
    
    for i=1:K-1
        for j=1:N(i)+1
            B_stat{i}(1,j)=B_ID{i}(1,j)/(T_sim-T_wu);
            avg_level(i)=avg_level(i)+(j-1)*B_stat{i}(1,j); % Calculates the average buffer levels.
        end
    end
    % Store replicate-level results
    NP(q,:)=E*(T_sim-T_wu);  % Total number of parts produced
    TH(q,:)=E;    % Throughput per machine
    BL(q,:)=avg_level;   % Average buffer levels
    %%  Starvation Time Analysis
    bu_T_S = bu_T_S1;
 %   save('series.mat', 'bu_T_S', 's_t');
s_t = s_t -1 ;  % Convert to binary: 1 = down, 0 = up

gS = find ( s_t == 1 & bu_T_S >0); % to find the time when the second machine is not working| given the buffer is higher than zero
bu_T_S(gS) = [];  % Remove those time steps from buffer series
XX= find(bu_T_S==0);  % Find starvation times
gx = zeros(length(XX)-1,1);  % Durations between zeros
for i=2:length(XX)
    gx(i) = XX(i)-XX(i-1);
end
fx = find(gx>1); % Gaps between starvation events
fx1= length(fx);
TTS=zeros(fx1,1);
TTS=gx(fx)-1;   % Time to starvation between gaps
%save('series2.mat','TTS');
g={TTS};   % Store TTS series
mTTS{1,q} = mean(TTS);  % Mean TTS
vTTS{1,q} = var(TTS) ; % Variance TTS
    
end


%% Aggregate final results across replicates
% Output between the replicates
avg_BL=mean(BL);%average buffer level
avg_TH=mean(TH);%average throughput
avg_NP=mean(NP);%average Number of parts
std_BL=std(BL);%standard deviation of BLs
std_TH=std(TH);%standard deviation of throghput
std_NP=std(NP);%standard deviation of Number of parts
var_NP=var(NP);%variance of Number of parts
%% Confidence interval on the number of parts produced from last machine
[avg_NP1,std_NP1,CI_NP,CI_std_NP] = normfit(NP(:,K), 1-IC); % Confidence interval on the mean and std
% bu_T_S = bu_T_S1;
% s_t = s_t -1 ;  % to make 1 down and 0 up!
% 
% gS = find ( s_t == 1 & bu_T_S >0); % to find the time when the second machine is not working| given the buffer is higher than zero
% bu_T_S(gS) = [];  % to remove gS
% XX= find(bu_T_S==0);
% gx = zeros(length(XX)-1,1);
% for i=2:length(XX)
%     gx(i) = XX(i)-XX(i-1);
% end
% fx = find(gx>1);
% fx1= length(fx);
% TTS=zeros(fx1,1);
% TTS=gx(fx)-1;
% g={TTS};
% mTTS{1,q} = mean(TTS);
% vTTS{1,q} = var(TTS) ;
toc % Stop timer
end