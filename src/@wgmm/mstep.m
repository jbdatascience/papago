function mstep(wgmm, X, W, K)
% m-step (parameter updates)
    

	narginchk(4, 4);
    Nk = sum(wgmm.expect.gammank, 1);
    
    % mu update
    wgmm.mu = muupdate(wgmm, X, W, K, wgmm.muUpdateMethod);
    if wgmm.debug
        assert(~strncmp(wgmm.muUpdateMethod, 'memsafe', 7));
        muc = muupdate(wgmm, X, W, K, ['memsafe-', wgmm.muUpdateMethod]);
        fprintf(2, 'debug mudiff: %f\n', max(abs(wgmm.mu(:) - muc(:))));
    end
    
    % sigma update
    [wgmm.sigma, wgmm.sigmainv] = sigmaupdate(wgmm, X, W, K);
    if wgmm.debug
        assert(~strncmp(wgmm.sigmaUpdateMethod, 'memsafe', 7));
        sigmac = sigmaupdate(wgmm, X, W, K, ['memsafe-', wgmm.covarUpdateMethod]);
        fprintf(2, 'debug sigmadiff: %f\n', max(abs(wgmm.sigma - sigmac)));
    end
    
    % pi update
    wgmm.pi = Nk ./ size(X, 1); 
    assert(isclean(wgmm.pi));
end

% mu update
function mu = muupdate(wgmm, X, W, K, method)
    gammank = wgmm.expect.gammank; % all models have the cluster assignment probability expectation
    
    % prepare the mu update method
    if ~exist('method', 'var'); 
        method = wgmm.muUpdateMethod;
    end

    % initialize
    mu = zeros(size(wgmm.mu));   
    switch method
        case 'model0'
            % compute mu without weights
            for k = 1:K
                mu(k, :) = gammank(:, k)' * X ./ sum(gammank(:, k));
            end
        
        case 'model1'
            for k = 1:K
                % method 1. using matrix algebra, but running into memory issues, and not that much faster.
                wwtsigmainv = wgmm.iwAiw(W, wgmm.sigmainv(:,:,k)); % warning: this is still too big.
                s = wgmm.sx(X, wwtsigmainv);
                bottom = sum(bsxfun(@times, gammank(:,k), permute(wwtsigmainv, [3, 1, 2])), 1);
                mu = sum(bsxfun(@times, gammank(:, k), s), 1) / squeeze(bottom);
            end
            
        case 'memsafe-model1'
            % model1, with internal loop (memory safe). 
            % Can also be used to make sure model1 implementation above yields similar results.
            for k = 1:K
                numer = 0; 
                denom = 0;
                for i = 1:size(X, 1)
                    localwt = W(i, :)';
                    wwt = localwt * localwt';
                    sm = wwt .* wgmm.sigmainv(:,:,k);
                    gsm = gammank(i, k) * sm;
                    numer = numer + gsm * X(i, :)';
                    denom = denom + gsm;
                end
                mu(k, :) = denom \ numer;
            end
            
        case 'model3'
            for k = 1:K
                zz = bsxfun(@times, gammank(:, k), W);
                mu(k, :) = sum(zz .* X, 1) ./ sum(zz, 1);
            end
                
        case 'memsafe-model3'
            % model3, with internal loop (memory safe). 
            % Can also be used to make sure model1 implementation above yields similar results.
            for k = 1:K
                numer = 0;
                denom = 0;
                for i = 1:size(X, 1)
                    w = W(i, :)';
                    gsm = gammank(i, k) * w;
                    numer = numer + gsm .* X(i, :)';
                    denom = denom + gsm;
                end
                mu(k, :) = numer ./ denom;
            end
            
        case 'model4'
            for k = 1:K
                numer = 0;
                denom = 0;
                sigmak = wgmm.sigma(:,:,k);
                for i = 1:size(X, 1)
                    w = W(i, :);
                    x = X(i, :);
                    
                    % sigmas
                    Di = wgmm.model4fn(w);
                    sigma = sigmak + Di;
                    
                    numer = numer + gammank(i, k) * ((sigma + Di) \ x(:));
                    denom = denom + gammank(i, k) * inv(sigma + Di);
                end
                mu(k, :) = denom \ numer; 
            end
            
        case 'model5'
            % compute mu without weights
            Xr = wgmm.expect.Xk; % is N-by-D-by-K
            for k = 1:K
                mu(k, :) = gammank(:, k)' * Xr(:,:,k) ./ sum(gammank(:, k));
            end
            
        otherwise
            error('unknown mu update method');
    end
    
    % check mu cleanliness
    assert(isclean(mu));
end

% sigma update
function [sigma, sigmainv] = sigmaupdate(wg, X, W, K)
    
    methods = struct('core', wg.covarUpdateMethod, 'recon', wg.covarReconMethod, ...
        'merge', wg.covarMergeMethod);
    opts = struct('mergeargs', {wg.sigmaopt}, 'sigmareg', wg.sigmareg);
    if ~iscell(opts.mergeargs)
        opts.mergeargs = {opts.mergeargs};
    end
    
    [sigma, sigmainv] = wg.sigmafull(wg.mu, X, W, K, methods, opts, wg);
end
