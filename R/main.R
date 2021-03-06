#' Adjacency weight matrix by Delaunay triangulations in 2D or 3D
#'
#' @description Adjacency weight matrix by Delaunay triangulations.
#'
#' @param pos Position
#' @param filterDist Euclidean distance beyond which two cells cannot be considered neighbors
#' @param binary Boolean of whether to binarize output; otherwise Euclidean distances provided
#' @param verbose Verbosity
#'
#' @return Matrix where value represents distance between two spatially adjacent cells ie. neighbors
#'
#' @examples
#' data(mOB)
#' pos <- mOB$pos
#' w <- getSpatialNeighbors(pos)
#'
#' @export
#'
getSpatialNeighbors <- function(pos, filterDist = NA, binary=TRUE, verbose=FALSE) {
  if(is.null(rownames(pos))) {
    rownames(pos) <- seq_len(nrow(pos))
  }

  ## shift duplicates slightly or else duplicates are lost
  if(sum(duplicated(pos))>0) {
    if(verbose) { message(paste0("Duplicated points found: ", sum(duplicated(pos)), "...")) }
    pos[duplicated(pos),] <- pos[duplicated(pos),] + 1e-6
  }

  ## delaunay triangulation
  tc <- geometry::delaunayn(pos, output.options=FALSE)

  ## if 2D, trimesh
  if(ncol(pos)==2) {
    ni <- rbind(tc[, -1], tc[, -2], tc[, -3])
  }
  ## if 3D, tetramesh
  if(ncol(pos)==3) {
    nii <- rbind(tc[, -1], tc[, -2], tc[, -3], tc[, -4])
    ni <- rbind(nii[, -1], nii[, -2], nii[, -3])
  }

  ## convert from neighbor indices to adjacency matrix
  N <- nrow(pos)
  D <- matrix(0, N, N)

  ## Euclidean distance
  d <- sapply(seq_len(nrow(ni)), function(i) dist(rbind(pos[ni[i,1],], pos[ni[i,2],])))
  ## make symmetric
  D[ni[,c(1,2)]] <- d
  D[ni[,c(2,1)]] <- d
  rownames(D) <- colnames(D) <- rownames(pos)

  ## filter by distance
  if (!is.na(filterDist)) {
    if(verbose) { message(paste0("Filtering by distance: ", filterDist, "...")) }
    D[D > filterDist] = 0
  }

  ## binarize
  if(binary) {
    if(verbose) { message(paste0("Binarizing adjacency weight matrix ...")) }
    D[D > 0] <- 1
  }

  if(verbose) { message(paste0("Done!")) }
  return(D)
}


#' Identify spatial clusters
#'
#' @description Identify spatially clustered genes using Moran's I
#'
#' @param mat Gene expression matrix. Must be normalized such that correlations
#'     will not be driven by technical artifacts.
#' @param weight Spatial weights such as a weighted adjacency matrix
#' @param alternative a character string specifying the alternative hypothesis,
#'     must be one of "greater" (default), "two.sided" or "less".
#' @param verbose Verbosity
#'
#' @export
#'
getSpatialPatterns <- function(mat, weight, alternative='greater', verbose=TRUE) {

  if (nrow(weight) != ncol(weight)) {
    stop("'weight' must be a square matrix")
  }

  N <- ncol(mat)
  if (nrow(weight) != N) {
    stop("'weight' must have as many rows as observations in 'x'")
  }

  if(sum(rownames(weight) %in% colnames(mat)) != nrow(weight)) {
    stop('Names in feature vector and adjacency weight matrix do not agree.')
  }
  mat <- mat[, rownames(weight)]

  # Calculate Moran's I for each gene
  results <- getSpatialPatterns_C(as.matrix(mat), as.matrix(weight), verbose)
  colnames(results) <- c('observed', 'expected', 'sd')
  rownames(results) <- rownames(mat)
  results <- as.data.frame(results)

  # Get p-value
  # always assume we want greater autocorrelation
  # pv <- 1 - pnorm(results$observed, mean = results$expected, sd = results$sd)
  pv <- sapply(seq_len(nrow(results)), function(i) {
    getPv(results$observed[i], results$expected[i], results$sd[i], alternative)
  })
  results$p.value <- pv;
  # multiple testing correction
  results$p.adj <- stats::p.adjust(results$p.value, method="BH")
  # order by significance
  #results <- results[order(results$p.adj),]

  return(results)
}

#' Filter for spatial patterns
#'
#' @description Filter out spatial patterns driven by small number of cells using LISA
#'
#' @param mat Gene expression matrix.
#' @param I Output of getSpatialPatterns
#' @param w Weight adjacency matrix
#' @param alpha P-value threshold for LISA score to be considered significant.
#' @param adjustPv Whether to perform BH multiple testing correction
#' @param minPercentCells Minimum percent of cells that must be driving spatial pattern
#' @param verbose Verbosity
#' @param details Return details
#'
#' @export
#'
filterSpatialPatterns <- function(mat, I, w, adjustPv=TRUE, alpha = 0.05, minPercentCells = 0.05, verbose=TRUE, details=FALSE) {
  ## filter for significant based on p-value
  if(adjustPv) {
    vi <- I$p.adj < alpha
  } else {
    vi <- I$p.value < alpha
  }
  vi[is.na(vi)] <- FALSE
  results.sig <- rownames(I)[vi]

  if(verbose) {
    message(paste0('Number of significantly autocorrelated genes: ', length(results.sig)))
  }

  if(alpha > 0 | minPercentCells > 0) {
    ## use LISA to remove patterns driven by too few cells
    lisa <- sapply(results.sig, function(g) {
      gexp <- mat[g,]
      Ii <- lisaTest(gexp, w)
      lisa <- Ii$p.value
      names(lisa) <- rownames(Ii)
      sum(lisa < alpha)/length(lisa) ## percent significant
    })
    vi <- lisa > minPercentCells
    if(verbose) {
      message(paste0('...driven by > ', minPercentCells*ncol(mat), ' cells: ', sum(vi)))
    }
  }

  if(details) {
    df <- cbind(I[results.sig,], 'minPercentCells'=lisa)
    df <- df[vi,]
    return(df)
  } else {
    return(results.sig[vi])
  }
}


#' Group significant spatial patterns
#'
#' @description Identify primary spatial patterns using hierarchical clustering and dynamic tree cutting
#'
#' @param pos Position matrix where each row is a cell, columns are
#'     x, y, (optionally z) coordinations
#' @param mat Gene expression matrix. Must be normalized such that correlations
#'     will not be driven by technical artifacts
#' @param scc Spatial cross-correlation matrix
#' @param hclustMethod Linkage criteria for hclust()
#' @param trim Winsorization trim
#' @param deepSplit Tuning parameter for dynamic tree cutting cutreeDynamic()
#' @param minClusterSize Smallest gene cluster size
#' @param power Raise distance matrix to this power
#' @param plot Whether to plot
#' @param verbose Verbosity
#' @param ... Additional plotting parameters
#'
#' @export
#'
groupSigSpatialPatterns <- function(pos, mat, scc, hclustMethod='complete', trim=0, deepSplit=0, minClusterSize=0, power = 1, plot=TRUE, verbose=TRUE, ...) {

    d <- as.dist((-scc - min(-scc))^(power))

    hc <- hclust(d, method=hclustMethod)
    #if(plot) {
    #    par(mfrow=c(1,1))
    #    plot(hc)
    #}

    ## dynamic tree cut
    groups <- dynamicTreeCut::cutreeDynamic(dendro=hc, distM=as.matrix(d), method='hybrid', minClusterSize=minClusterSize, deepSplit=deepSplit)
    names(groups) <- hc$labels
    groups <- factor(groups)
    if(verbose) {
        message('Patterns detected:')
        print(table(groups))
    }

    prs <- lapply(levels(groups), function(g) {
        # summarize as first pc if more than 1 gene in group
        if(sum(groups==g)>1) {
          m <- mat[names(groups)[which(groups==g)],]
          m <- t(scale(t(m)))
            m <- winsorize(m, trim)
            ps <- colMeans(m)
            pr <- scale(ps)[,1]
        } else {
            ps <- winsorize(mat[names(groups)[which(groups==g)],], trim)
            pr <- scale(ps)[,1]
        }
        if(plot) {
            interpolate(pos, pr, main=paste0("Pattern ", g, " : ", sum(groups==g), " genes"), plot=TRUE, trim=trim, ...)
        }
        return(pr)
    })
    names(prs) <- levels(groups)

    return(list(hc=hc, groups=groups, prs=prs))
}


