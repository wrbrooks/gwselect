gwglmnet.fit.inner = function(x, y, coords, indx=NULL, loc, bw=NULL, dist=NULL, event=NULL, family, mode.select, tuning, predict, simulation, verbose, gwr.weights=NULL, prior.weights=NULL, gweight=NULL, longlat=FALSE, interact, precondition, N=1, alpha, tau=3, shrunk.fit) {
    if (!is.null(indx)) {
        colocated = which(round(coords[indx,1],5)==round(as.numeric(loc[1]),5) & round(coords[indx,2],5) == round(as.numeric(loc[2]),5))
    }
    else {
        colocated = which(round(coords[,1],5) == round(as.numeric(loc[1]),5) & round(coords[,2],5) == round(as.numeric(loc[2]),5))        
    }
    reps = length(colocated)

    if (is.null(gwr.weights)) {
        gwr.weights = gweight(dist, bw)     
    } 
    gwr.weights = drop(gwr.weights)  

    if (!is.null(indx)) {
        gwr.weights = gwr.weights[indx]
    }

	#Allow for the adaptive elastic net penalty:
	if (substring(as.character(alpha), 1, 1) == 'a') {
		cormat = abs(cor(x))
		diag(cormat) = NA
		alpha = 1 - max(cormat, na.rm=TRUE)
	}

    #For interaction on location:
    if (interact) {
        newnames = vector()
        oldnames = colnames(x)
        for (l in 1:length(oldnames)) {
            newnames = c(newnames, paste(oldnames[l], ":", colnames(coords)[1], sep=""))
            newnames = c(newnames, paste(oldnames[l], ":", colnames(coords)[2], sep=""))
        }
        interacted = matrix(ncol=2*ncol(x), nrow=nrow(x))
        for (k in 1:ncol(x)) {
            interacted[,2*(k-1)+1] = x[,k]*(coords[,1]-loc[1,1])
            interacted[,2*k] = x[,k]*(coords[,2]-loc[1,2])
        }
        x.interacted = cbind(x, interacted)
        colnames(x.interacted) = c(oldnames, newnames)
    }

    if (mode.select=='CV') { 
        xx = as.matrix(x[-colocated,])
        if (interact) {xx.interacted = as.matrix(x.interacted[-colocated,])}
        yy = as.matrix(y[-colocated])
        w <- prior.weights[-colocated] * gwr.weights[-colocated]  
    } else {
        xx = as.matrix(x)
        if (interact) {xx.interacted = as.matrix(x.interacted)}
        yy = as.matrix(y)
        w <- prior.weights * gwr.weights
    }
    
    if (sum(gwr.weights)==length(colocated)) { return(list(loss.local=Inf, resid=Inf)) } 

    n <- nrow(xx)
    weighted = which(w>0)
    n.weighted = length(weighted)
    
    xx = xx[weighted,]
    if (interact) {xx.interacted = xx.interacted[weighted,]}
    yy = as.matrix(yy[weighted])
    w = w[weighted]

    int.list = list()
    coef.list = list()
    coef.unshrunk.list=list()    
    coef.unshrunk.interacted.list=list()
    tunelist = list()

    for (i in 1:N) {
        #Final permutation is the original ordering of the data:
        if (i==N) {            
            permutation = 1:n.weighted
        } else {
            tot.w = sum(w)
            permutation = vector()
            while (sum(w[permutation]) < tot.w) {
                permutation = c(permutation, sample(1:n.weighted, size=1))
            }

            permutation = permutation[1:which.min(tot.w - cumsum(w[permutation]))]
        }

        colocated = which(gwr.weights[weighted][permutation]==1)
        sqrt.w <- diag(sqrt(w[permutation]))

        xxx = xx[permutation,]
        yyy = yy[permutation]
        meany = sum((w*yy)[permutation])/sum(w)

        if (precondition==TRUE) {
            s = svd(xxx)
            F = s$u  %*% diag(1/sqrt(s$d**2 + tau))  %*%  t(s$u)
            xxx = F %*% xxx
            yyy = F %*% yyy
        }
    
        one <- rep(1, nrow(xxx))
        meanx <- drop(one %*% xxx) / nrow(xxx)
        x.centered <- scale(xxx, meanx, FALSE)         # first subtracts mean
        normx <- sqrt(drop(one %*% (x.centered**2)))
        names(normx) <- NULL
        xs = x.centered
        
        for (k in 1:dim(x.centered)[2]) {
            if (normx[k]!=0) {
                xs[,k] = xs[,k] / normx[k]
            } else {
                xs[,k] = rep(0, dim(xs)[1])
                normx[k] = Inf #This should allow the lambda-finding step to work.
            }
        }
        
        glm.step = try(glm(yyy~xs, weights=w[permutation], family=family))
    
        if("try-error" %in% class(glm.step)) { 
            cat(paste("Couldn't make a model for finding the SSR at location ", i, ", bandwidth ", bw, "\n", sep=""))
            return(return(list(loss.local=Inf, resid=Inf)))
        }
        
        beta.glm = glm.step$coeff[-1]                   # mle except for intercept
        adapt.weight = abs(beta.glm)               # weights for adaptive lasso
        for (k in 1:dim(x.centered)[2]) {
            if (!is.na(adapt.weight[k])) {
                xs[,k] = xs[,k] * adapt.weight[k]
            } else {
                xs[,k] = rep(0, dim(xs)[1])
                adapt.weight[k] = 0 #This should allow the lambda-finding step to work.
            }
        }
    
        fitx = xs
        fity = yyy
        if (interact) {xxx = xx.interacted[permutation,]}

		if (family == 'binomial') { model = glmnet(x=fitx, y=cbind(1-fity, fity), standardize=FALSE, intercept=TRUE, family=family, weights=w[permutation], alpha=alpha) }
        else if (family=='cox') { model = glmnet(x=fitx, y=as.matrix(cbind(fity, event)), standardize=FALSE, intercept=TRUE, family=family, weights=w[permutation], alpha=alpha) }
        else { model = glmnet(x=fitx, y=fity, standardize=FALSE, intercept=TRUE, family=family, weights=w[permutation], alpha=alpha) }
        nsteps = length(model$lambda) + 1   
    
        if (mode.select=='CV') {
            predx = matrix(xx[colocated,], reps, dim(xs)[2])    
            vars = apply(predict(model, type='coef')[['coefficients']], 1, function(x) {which(abs(x)>0)})
            df = sapply(vars, length) + 1                        

            predictions = predict(model, newx=predx, type='fit', mode='step')[['fit']]
            loss = colSums(abs(matrix(predictions - matrix(y[colocated], nrow=reps, ncol=nsteps), nrow=reps, ncol=nsteps)))                
            s2 = sum(w*(fitted[,nsteps] - as.matrix(y))**2) / (sum(w)-df-1)

            loss.local = loss        
        } else if (mode.select=='AIC' | mode.select=='BIC') {
            if (mode.select=='AIC') { penalty = 2 }
            if (mode.select=='BIC') { penalty = log(sum(w[permutation])) }
            predx = t(apply(xx[permutation,], 1, function(X) {(X-meanx) * adapt.weight / normx}))
            predy = as.matrix(yy[permutation])
            vars = apply(as.matrix(coef(model)[-1,]), 2, function(x) {which(abs(x)>0)})
            df = sapply(vars, length) + 1

            if (sum(w) > ncol(x)) {
                #Extract the fitted values for each lambda:
                coefs = t(as.matrix(coef(model)))
                fitted = predict(model, newx=predx, type="response")   
                s2 = sum(w[permutation]*(fitted[,ncol(fitted)] - predy)**2) / (sum(w) - df) 
                
                #Compute the loss (varies by family)
                loss = as.vector(deviance(model) + penalty*df)
                
                #Pick the lambda that minimizes the loss:
                k = which.min(loss)
                fitted = fitted[,k]
                localfit = fitted[colocated]
                df = df[k]
                if (k > 1) {
                    varset = vars[[k]]
                    if (interact) {
						for (j in vars[[k]]) {
							varset = c(varset, ncol(x)+2*(j-1)+1, ncol(x)+2*j)
						}
                    }
                    modeldata = data.frame(y=yy[permutation], xxx[,varset])
                    m = glm(y~., data=modeldata, weights=w[permutation], family=family)
                    working.weights = as.vector(m$weights)
                    result = tryCatch({
                        Xh = diag(sqrt(working.weights)) %*% as.matrix(cbind(rep(1,length(permutation)), xxx[,varset]))
                        H = Xh %*% solve(t(Xh) %*% Xh) %*% t(Xh)
                        Hii = H[colocated,colocated]
                    }, error = function(e) {
                        Hii = nrow(x) - 2
                    })
                    if (!shrunk.fit) {
                        fitted = m$fitted
                        localfit = fitted[colocated]
                        df = length(varset) + 1
                        s2 = sum((w[permutation]*m$residuals**2) / (sum(w) - df))
                    }
                    coefs.unshrunk = rep(0, ncol(x) + 1)
                    coefs.unshrunk[c(1, varset + 1)] = coef(m)
                    s2.unshrunk = sum(w[permutation]*m$residuals**2)/sum(w[permutation])
                } else {
                    modeldata = data.frame(y=yy[permutation], xxx)
                    m = glm(y~1, data=modeldata, weights=w[permutation], family=family)
                    
                    coefs.unshrunk = rep(0, ncol(xx) + 1)
                    coefs.unshrunk[1] = sum(fity * w[permutation]) / sum(w[permutation])
                    s2.unshrunk = sum((sqrt(w[permutation])*fity)**2)/sum(w[permutation])

                    Hii = 1 / sum(w[permutation])
                }
                
                if (length(colocated)>0) {
                    tunelist[['ssr-loc']] = list()
                    tunelist[['ssr']] = list()
                    
                    #Pearson residuals:
                    if (family=='gaussian') {
                        tunelist[['ssr-loc']][['pearson']] = sum((w[permutation]*(fitted - yyy)**2)[colocated])
                        tunelist[['ssr']][['pearson']] = sum(w[permutation]*(fitted - yyy)**2)
                    } else if (family=='poisson') {
                        tunelist[['ssr-loc']][['pearson']] = sum((w[permutation]*(yyy - fitted)**2/fitted)[colocated])
                        tunelist[['ssr']][['pearson']] = sum(w[permutation]*(fitted - yyy)**2/fitted)
                    } else if (family=='binomial') {
                        tunelist[['ssr-loc']][['pearson']] = sum((w[permutation]*(yyy - fitted)**2/(fitted*(1-fitted)))[colocated])
                        tunelist[['ssr']][['pearson']] = sum(w[permutation]*(fitted - yyy)**2/(fitted*(1-fitted)))
                    }

                    #Deviance residuals:
                    if (family=='gaussian') {
                        tunelist[['ssr-loc']][['deviance']] = sum((w[permutation]*(fitted - yyy)**2)[colocated])
                        tunelist[['ssr']][['deviance']] = sum(w[permutation]*(fitted - yyy)**2)
                    } else if (family=='poisson') {
                        tunelist[['ssr-loc']][['deviance']] = sum((2*w[permutation]*(ylogy(yyy) - yyy*log(fitted) - (yyy-fitted)))[colocated])
                        tunelist[['ssr']][['deviance']] = sum(2*w[permutation]*(ylogy(yyy) - yyy*log(fitted) - (yyy-fitted)))
                    } else if (family=='binomial') {
                        tunelist[['ssr-loc']][['deviance']] = sum((2*w[permutation]*(ylogy(yyy) - yyy*log(fitted) - ylogy(1-yyy) + (1-yyy)*log(1-fitted)))[colocated])
                        tunelist[['ssr']][['deviance']] = sum(2*w[permutation]*(ylogy(yyy) - yyy*log(fitted) - ylogy(1-yyy) + (1-yyy)*log(1-fitted)))
                    }

                    if (family=='gaussian') {
                        tunelist[['s2']] = s2
                    } else if (family=='poisson') { 
                        tunelist[['s2']] = summary(m)$dispersion
                    } else if (family=='binomial') {
                        tunelist[['s2']] = 1
                    }
                    tunelist[['n']] = sum(w[permutation])
                    tunelist[['trace.local']] = Hii
                    tunelist[['df']] = df
                } else {
                    loss.local = NA
                }                   
            } else {
            	fitted = rep(meany, length(permutation))
                s2 = 0
                loss = Inf
                loss.local = c(Inf)   
                localfit = meany
            }
        }
    
        #Get the tuning parameter to minimize the loss:
        s.optimal = which.min(loss)
        
        #We have all we need for the tuning stage.
        if (!tuning) {
            #Get the coefficients:
            coefs = coefs[s.optimal,]
            coefs = Matrix(coefs, ncol=1)
            rownames(coefs) = c("(Intercept)", colnames(x))   

            coefs = coefs * c(1, adapt.weight) * c(1, 1/normx)
            if (length(coefs)>1) {coefs[1] = mean(sqrt(w[permutation])*fity) - sum(coefs[2:length(coefs)] * drop(sqrt(w[permutation]) %*% xxx) / nrow(xxx))}
    
            coefs.unshrunk = Matrix(coefs.unshrunk[1:(ncol(x)+1)], ncol=1)
            rownames(coefs.unshrunk) = c("(Intercept)", oldnames)  
    
            coef.unshrunk.list[[i]] = coefs.unshrunk
            coef.list[[i]] = coefs
        }
    }
    
    if (tuning) {
        return(list(tunelist=tunelist, s=s.optimal, sigma2=s2, nonzero=colnames(x)[vars[[s.optimal]]], weightsum=sum(w), loss=loss, alpha=alpha))
    } else if (predict) {
        return(list(tunelist=tunelist, coef=coefs, weightsum=sum(w), s=s.optimal, sigma2=s2, nonzero=colnames(x)[vars[[s.optimal]]]))
    } else if (simulation) {
        return(list(tunelist=tunelist, coef=coefs, coeflist=coef.list, s=s.optimal, bw=bw, sigma2=s2, coef.unshrunk=coefs.unshrunk, s2.unshrunk=s2.unshrunk, coef.unshrunk.list=coef.unshrunk.list, fitted=localfit, alpha=alpha, nonzero=colnames(x)[vars[[s.optimal]]], actual=predy[colocated], weightsum=sum(w), loss=loss))
    } else {
        return(list(model=model, loss=loss, coef=coefs, coef.unshrunk=coefs.unshrunk, coeflist=coef.list, nonzero=colnames(x)[vars[[s.optimal]]], s=s.optimal, loc=loc, bw=bw, meanx=meanx, meany=meany, coef.scale=adapt.weight/normx, df=df, loss.local=loss.local, sigma2=s2, sum.weights=sum(w), N=N, fitted=localfit, alpha=alpha, weightsum=sum(w)))
    }
}
