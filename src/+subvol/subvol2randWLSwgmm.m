function subvol2randWLSwgmm(dsSubvolMat, wtSubvolMat, clusterIdxMat, wgmmMat, iniFilename)
% this file structure is a relic from MICCAI 2016 / Thesis 2016 attempt. We'll keep it for now...
% we're hard-coding dsidx2S init.
% 
% dsSubvolMat - matfile name of subvolume
% wtSubvolMat - matfile name of weights
% iniFilename - ini filename with parameters (input)
% clusterIdxMat - matfile name of cluster assignments (if don't have, where to save)
% wgmmMat - matfile name of output wgmm (output)

    params = ini2struct(iniFilename); 
    
    % rename the parameters
    K = params.nClust;
    patchSize = params.patchSize; 
    nPatches = params.nPatches; 
    
    % volume processing
    volsKeep = params.volsKeep; 
    diffPad = params.volPad;  
    
    %% load subvolumes
    tic
    if ischar(dsSubvolMat)
        q = load(dsSubvolMat, 'subvolume'); 
        dsSubvols = q.subvolume;
    else
        dsSubvols = dsSubvolMat;
    end
    if ischar(wtSubvolMat)
        q = load(wtSubvolMat, 'subvolume'); 
        wtSubvols = q.subvolume;
    else 
        wtSubvols = wtSubvolMat;
    end
    clear q;
    assert(all(size(dsSubvols) == size(wtSubvols)));
    fprintf('took %5.3f to load the subvolumes\n', toc);

    tic
    % prune volumes
    if isnumeric(volsKeep)
        nSubj = size(dsSubvols, 4);
        nSubjkeep = round(volsKeep .* nSubj);
        fprintf('keeping %d of %d subjects\n', nSubjkeep, nSubj);
        vidx = randsample(nSubj, nSubjkeep);
        
    else % assume it's a file with numbers
        fid = fopen(volsKeep);
        C = textscan(fid, '%d');
        fclose(fid);
        vidx = cat(1, C{:});
        nSubjkeep = numel(vidx);
    end
    dsSubvols = dsSubvols(:,:,:,vidx);
    wtSubvols = wtSubvols(:,:,:,vidx);
    nSubj = nSubjkeep;
    volSize = size(dsSubvols);
    volSize = volSize(1:3);
    
    if isscalar(diffPad)
        diffPad = diffPad * ones(1, 3);
    end
    
    % crop ds volumes -- we don't want to learn from the edges of the volumes;
    dsSubvolsCrop = cropVolume(dsSubvols, [diffPad+1 1], [volSize-diffPad nSubj]);
    fprintf('took %5.3f to process the %d subvolumes\n', toc, nSubj);
       

    
    %% get patches and init.

    % Need to select which patches to work with.
    % here we'll use clusterIdxMat as the file to dump the trainsetIdx matrix
    if ~sys.isfile(clusterIdxMat)
        gs = patchlib.grid(size(dsSubvolsCrop), [patchSize, 1], 'sliding');
        trainsetIdx = randsample(numel(gs), nPatches);
        
        % get sub
        sub = libLocs(size(dsSubvolsCrop), patchSize, trainsetIdx);
        Y = patchlib.vol2lib(dsSubvolsCrop, [patchSize, 1], 'locations', sub);
        
        dso = params.dsGmm;

        % this is unnecessary for diag method. we should get rid of it...
        gmmopt = statset('Display', 'iter', 'MaxIter', dso.maxIter, 'TolFun', dso.tol);
        % gmmClust = fitgmdist(smallBlurPatches, gmmK, regstring, 1e-4, 'replicates', 3, 'Options', gmmopt);
        % gmdist = gmdistribution.fit(Y, gmmK, regstring, 1e-4, 'replicates', 3, 'Options', gmmopt);
        % [~, wgDs] = fitgmdist2wgmmLS(Y, gmmK, 1e-4, 3, gmmopt, dLow);
        [wgDs, wgDsLs] = fitgmdist2wgmmLS(Y, params.nClust, dso.regVal, dso.reps, gmmopt, params.wgmm.dLow);
        
        save(clusterIdxMat, 'trainsetIdx', 'wgDs', 'wgDsLs');
        fprintf('took %5.3f to prepare wgDs\n', toc);
    else
        q = load(clusterIdxMat, 'trainsetIdx', 'wgDs', 'wgDsLs');
        trainsetIdx = q.trainsetIdx;
        wgDs = q.wgDs;
        wgDsLs = q.wgDsLs;
        assert(numel(trainsetIdx) == nPatches, 'The saved number of patches is incorrect');
        
        sub = libLocs(size(dsSubvolsCrop), patchSize, trainsetIdx);
        Y = patchlib.vol2lib(dsSubvolsCrop, [patchSize, 1], 'locations', sub);
        fprintf('took %5.3f to load wgDs and Idx from %s\n', toc, clusterIdxMat);
    end
    clear dsPatches
    
    % process weights (later to avoid keeping dsPatches and wtPatches in memory at same time)
    wtSubvolsCrop = cropVolume(wtSubvols, [diffPad+1 1], [volSize-diffPad nSubj]);
    sizeWtSubvolsCrop = size(wtSubvolsCrop);
    sub = libLocs(sizeWtSubvolsCrop, patchSize, trainsetIdx);
    w = patchlib.vol2lib(wtSubvolsCrop, [patchSize, 1], 'locations', sub);
    clear wtSubvolsCrop;   
    

    %% entropy to update W
    assert(params.grad.use || params.entropy.use, 'Must use entropy of grad');
    if params.entropy.use
        assert(~params.grad.use, 'cannot use both entropy and grad')

        % get entropy of ds subvolumes
        tic
        enSubvol = dsSubvols*nan; 
        for i = 1:size(enSubvol, 4)
            enSubvol(:,:,:,i) = entropyfilt(dsSubvols(:,:,:,i), getnhood(strel('sphere', 2))); 
        end
        croppedEnSubvols = cropVolume(enSubvol, [diffPad + 1, 1], [volSize - diffPad, nSubj]);
        assert(all(size(croppedEnSubvols) == sizeWtSubvolsCrop));

        % get patches
        enPatchCol = robustVols2lib(croppedEnSubvols, patchSize);
        enDs = enPatchCol(trainsetIdx, :);
        clear enPatchCol;

        % adni
        polyx = [params.entropy.lowEntropy, params.entropy.highEntropy];
        polyy = [params.entropy.lowThr, params.entropy.highThr];
        enFit = polyfit(polyx, polyy, 1);
        wtThrEnDs = within([0.01, params.entropy.highThr], polyval(enFit, enDs));

        wtEnDs = w > wtThrEnDs;
        fprintf('mean entropy-based wt: %3.2f\n', mean(wtEnDs(:)))

        data = struct('Y', Y, 'W', double(wtEnDs), 'K', K);
        fprintf('took %5.3f to prepare entropy weighting\n', toc);
    end

    
    
    %% gradient to update W
    if params.grad.use == 1
        assert(~params.entropy.use, 'cannot use both entropy and grad')
        
        c3 = zeros(1, 3); c3(params.grad.dir) = 1;
        
        % get grad of ds subvolumes
        tic
        gradSubvol = dsSubvols*nan; 
        for i = 1:size(gradSubvol, 4)
            d1 = diff(dsSubvols(:,:,:,i), [], params.grad.dir);
            d1 = padarray(abs(d1), c3, 0, 'pre');
            gradSubvol(:,:,:,i) = volblur(d1, params.grad.blurSigma);
        end
        
        croppedGradSubvols = cropVolume(gradSubvol, [diffPad + 1, 1], [volSize - diffPad, nSubj]);
        assert(all(size(croppedGradSubvols) == sizeWtSubvolsCrop));

        % get patches
        gradPatchCol = robustVols2lib(croppedGradSubvols, patchSize);
        gradDs = gradPatchCol(trainsetIdx, :);
        clear gradPatchCol;

        % get threshold
        polyx = [params.grad.lowGrad, params.grad.highGrad];
        polyy = [params.grad.lowThr, params.grad.highThr];
        gradFit = polyfit(polyx, polyy, 1);
        wtThrGradDs = within([0.01, params.grad.highThr], polyval(gradFit, gradDs));

        wtGradDs = w > wtThrGradDs;
        fprintf('mean grad-based wt: %3.2f\n', mean(wtGradDs(:)))

        data = struct('Y', Y, 'W', double(wtGradDs), 'K', K);
        fprintf('took %5.3f to prepare grad weighting\n', toc);
        
    elseif params.grad.use == 2
        assert(~params.entropy.use, 'cannot use both entropy and grad')
        
        c3 = zeros(1, 3); c3(params.grad.dir) = 1;
        
        % get grad of ds subvolumes
        tic
        gradSubvol = dsSubvols*nan; 
        for i = 1:size(gradSubvol, 4)
            d1 = diff(dsSubvols(:,:,:,i), [], params.grad.dir);
            d1 = padarray(abs(d1), c3, 0, 'pre');
            gradSubvol(:,:,:,i) = volblur(d1, params.grad.blurSigma);
        end
        
        med = median(gradSubvol(wtSubvols(:)>0.1));
        
        % get threshold
        polyx = [params.grad.lowGrad, params.grad.highGrad];
        polyy = [params.grad.lowThr, params.grad.highThr];
        gradFit = polyfit(polyx, polyy, 1);
        wtThrGradDs = within(polyy, polyval(gradFit, med));
        wtThrGradDs 

        wtGradDs = w > wtThrGradDs;
        fprintf('mean grad-based wt: %3.2f\n', mean(wtGradDs(:)))

        data = struct('Y', Y, 'W', double(wtGradDs), 'K', K);
        fprintf('took %5.3f to prepare grad weighting\n', toc);
    end
    
    %% run wgmm
    wgmmOpts = params.wgmm;
    
    % initial
    wgInit = wgmmfit(data, 'modelName', 'latentSubspace', ...
        'modelArgs', struct('dopca', wgmmOpts.dLow), ...
        'minIter', wgmmOpts.minItersInit, 'maxIter', wgmmOpts.maxItersInit, 'TolFun', wgmmOpts.tolFun, ...
        'verbose', 2, 'replicates', wgmmOpts.repsInit, ...
        'init', 'latentSubspace-randW');
    
    % take the highest contender, and go all the way.
    wg = wgmmfit(data, 'modelName', 'latentSubspace', ...
        'modelArgs', struct('dopca', wgmmOpts.dLow), ...
        'minIter', wgmmOpts.minIters, 'maxIter', wgmmOpts.maxIters, 'TolFun', wgmmOpts.tolFun, ...
        'verbose', 2, 'replicates', wgmmOpts.reps, ...
        'init', 'wgmm', 'initArgs', struct('wgmm', wgInit));

    wgwhole = wg;
    wg = wgmm(wg.opts, wg.params);
    if isfield(wg.params, 'sigma')
        wg.params = rmfield(wg.params, 'sigma');
    end
    
    %% save
    if params.saveLargeWg
        save(wgmmMat, 'wg', 'wgwhole', 'trainsetIdx', '-v7.3'); 
    else
        save(wgmmMat, 'wg', 'trainsetIdx', '-v7.3'); 
    end
end


function lib = robustVols2lib(vols, patchSize)
    try
        lib = patchlib.vol2lib(vols, [patchSize 1]);
    catch err
        fprintf(2, 'vol2lib caught %s\n. Going volume by volume', err.message)
        nVols = size(vols, 4);
        libCell = cell(nVols, 1);
        for i = 1:nVols
            libCell{i} = patchlib.vol2lib(vols(:,:,:,i), patchSize);
        end
        lib = cat(1, libCell{:});
    end
end

function sub = libLocs(dsSubvolsCropSize, patchSize, trainsetIdx)
    allsub = patchlib.grid(dsSubvolsCropSize, [patchSize, 1], 'sliding', 'sub');
    allsub = cellfunc(@(s) s(:), allsub);
    allsub = cat(2, allsub{:});
    sub = allsub(trainsetIdx, :);
end
