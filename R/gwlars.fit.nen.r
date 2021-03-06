gwlars.fit.nen = function(x, y, coords, D, N=N, s, mode.select, shrink, verbose, prior.weights, gweight, target, beta1, beta2, tol=1e-25, longlat=FALSE, adapt, mode, precondition=FALSE, AICc) {
    if (!is.null(fit.loc)) {
        coords.unique = fit.loc
    } else {
        coords.unique = unique(coords)
    }
    n = dim(coords.unique)[1]

    gwlars.object = list()
    models = list()

    prior.weights = drop(prior.weights)

    for (i in 1:n) {
        loc = coords.unique[i,]
        dist = drop(D[i,])

        opt = optimize(gwlars.ssr, lower=beta1, upper=beta2, 
            maximum=FALSE, tol=target/1000, x=x, y=y, N=1, coords=coords, loc=loc, s=s,
            gweight=gweight, verbose=verbose, dist=dist, mode.select=mode.select,
            prior.weights=prior.weights, target=target, precondition=precondition)
        bandwidth = opt$minimum

        models[[i]] = gwlars.fit.inner(x=x, y=y, coords=coords, loc=loc, bw=bandwidth, dist=dist, N=N, s=s, mode.select=mode.select, shrink=shrink, verbose=verbose, gwr.weights=NULL, prior.weights=prior.weights, gweight=gweight, precondition=precondition, AICc=AICc)

		if (verbose) {
	        cat(paste("For i=", i, ", target: ", target, ", bw=", bandwidth, ", tolerance=", target/1000, ", miss=", opt$objective, ".\n", sep=''))
    	}
	}
	
    gwlars.object[['models']] = models
    gwlars.object[['mode']] = mode
    gwlars.object[['coords']] = coords
    gwlars.object[['s.range']] = s

    class(gwlars.object) = 'gwlars.object'
    return(gwlars.object)
}
