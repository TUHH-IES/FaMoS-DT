function [correct,false,t_cluster,t_train] = normalMain(allData,evalData,folder)
    %only global vars needed for this top level program are listed here, if 
    %needed in subfunctions they are listed only there for simplicity
    global num_var num_ud offsetCluster Ts max_deriv useLMIrefine methodCluster methodTraining
    
    num = 1; x = []; ud = [];
    
    addpath(folder);
    % Changepoint Detection only done by proposed algorithm
    addpath(['ProposedAlgorithm', filesep, 'src']);
    addpath(['HAutLearn', filesep, 'src']);
    
    %% Changepoint determination and trace setup
    normalization = zeros(num_var,1); % obviously not ideal but works
    for i = allData
        load(['training', int2str(i),'.mat']);
        for j = 1:num_var
            normalization(j,1) = max(normalization(j,1),max(xout(:,j)));
        end
        for j = 1:num_ud
            normalization(num_var+j,1) = max(normalization(num_var+j,1),max(abs(udout(:,j))));
        end
    end
    for i = allData
        udout = []; % Needed if system with no input variables present
        load(['training', int2str(i),'.mat']);
        [xout, udout] = FnNormAndDiff(xout, udout, normalization);
        trace_temp = FnDetectChangePoints(xout, udout);
        trace_temp.true_states = states;
        trace_temp.true_chps = chpoints;
        trace(num) = trace_temp;
        %all traces are appended (needed for clustering in that form)
        x = [x; trace(num).x];
        ud = [ud; trace(num).ud];
        num = num+1; 
    end

    %% Determine clustered trace segments
    
    tic;

    % Choose which algorithm to use for clustering
    if(methodCluster == 0) % Use DTW for clustering
        useLMIrefine = 0;
        trace = FnClusterSegsFast(trace, x, ud);
    elseif(methodCluster == 1) % Use DTW refined by LMIs for clustering
        useLMIrefine = 1;
        trace = FnClusterSegsFast(trace, x, ud);
    else % Use LMIs for clustering
        trace = FnClusterSegs(trace, x, ud);
    end
    
    t_cluster = toc;
    
    % Remove changepoints that are not associated with an system mode switch
    trace = FnCleanChangePoints(trace);

    %Eval clusters
    ClusterCorrect = 0;
    ClusterFalse = 0;
    for i = 1:length(trace)
        [cTemp, fTemp] = FnEvalCluster(trace(i).labels_trace,trace(i).true_states,trace(i).true_chps);
        ClusterCorrect = ClusterCorrect + cTemp;
        ClusterFalse = ClusterFalse + fTemp;
    end

    %% Training and short Eval
    
    % Choose which algorithm to use for training
    if(methodTraining == 0) % Use DTL for training
        %legacy eval paras
        N = 1; % how many past states should be used to predict
        
        %compute eval data
        Xe = [];
        Ye = [];
        
        for i = evalData
            [Xnew,Ynew,states] = FnTraceToTrainingData(trace(i));
            Xe = [Xe; Xnew];
            Ye = [Ye; Ynew];
        end
        
        %compute maximal training data
        X = [];
        Y = [];
        count = 1;
        for i = setdiff(allData,evalData)
            [Xnew,Ynew,states] = FnTraceToTrainingData(trace(count));
            X = [X; Xnew];
            Y = [Y; Ynew];
            count= count + 1;
        end
        
        tic;
        [Mdl,impure_leaves,num_nodes,learn_time] = FnBuildDT(X,Y);
        t_train = toc;
    
        % Actual Eval
        correct = 0;
        false = 0;
        
        for i = 1:size(Xe,1)
            if(predict(Mdl,Xe(i,:)) == Ye(i,1))
                correct = correct + 1;
            else
                false = false + 1;
                %disp([mat2str((i+N)*fixedIntervalLength),' in: ',mat2str(Xe(i,:)),' real: ',mat2str(Ye(i,:)),' predict: ',mat2str(predict(Mdl,Xe(i,:)))]);
            end
        end
    else % Use PTA for training
        global eta lambda gamma tolLI

        for n =1:length(trace)
            trace(n).labels_trace = [trace(n).labels_trace;0];
        end
        
        tic;
        ode = FnEstODE(trace(setdiff(allData,evalData)));
        
        % LI Estimation given parameters
        [trace_train,label_guard] = FnLI(trace(setdiff(allData,evalData)), eta, lambda, gamma);
        % Extend label_guard by zeros for considered derivatives so
        % that generated automaton xml file is clean (currently no
        % transitions based on derivatives are allowed)
        for k = 1:length(label_guard)
            curr_label_guard = cell2mat(label_guard(k));
            label_guard(k) = {[curr_label_guard(1:num_var); zeros(offsetCluster*num_var,1); curr_label_guard((num_var+1):end)]};
        end
        
        % Setup PTA given LIs and ODEs
        pta_trace = FnPTA(trace_train);
        % Can solve bugs if you comment out next line. But why ?
        %pta_trace = pta_filter(pta_trace);
        
        % Generate Final Automaton model
        
        FnGenerateHyst([folder, filesep, 'automata_learning'],label_guard, num_var*(1+offsetCluster), num_ud, ode, pta_trace);
        t_train = toc; %how to measure this time should be discussed

        xmlstruct = readstruct([folder, filesep, 'automata_learning.xml']);
        
        conditions = FnParseHA(xmlstruct,ode,label_guard);
        [correct,false] = FnEvaluateHA(trace(evalData),conditions,tolLI);
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function pta_trace_new = pta_filter(pta_trace)
    % remove false pta
    label1s = extractfield(pta_trace,'label1');
    label2s = extractfield(pta_trace,'label2');
    id1s = extractfield(pta_trace,'id1');
    id2s = extractfield(pta_trace,'id2');
    nn = 1;
    while true
        if nn>length(pta_trace)
            break;
        end
        %flag1 = pta_trace(nn).times<=2;
        flag2 = ~ismember(pta_trace(nn).label1, label2s);
        flag3 = ~ismember(pta_trace(nn).label2, label1s);
        flag4 = ~ismember(pta_trace(nn).id1, id1s);
        flag5 = ~ismember(pta_trace(nn).id2, id2s);
        
        if (~ismember(pta_trace(nn).id1, id2s)) && (pta_trace(nn).id1~=1) || ~ismember(pta_trace(nn).id2, id1s)
            pta_trace(nn) = [];
        else
            nn = nn+1;
        end
    end
    pta_trace_new = pta_trace;
end
