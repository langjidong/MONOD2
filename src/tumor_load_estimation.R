library(ggplot2)
library(gplots) # required for colorpanel

# This script takes as input the MHL matrix, compute cancer markers using the t-test, build a standard curve from simulated samples, and estimates the cancer proportion in plasma samples using the cancer regions

args <- commandArgs(trailingOnly = TRUE)
rdata.file <- args[1]
ncp_train_list <- args[2]
bin_dir <- "bin"
result_dir <- "results/tumor_fraction"

######################
### PlotFunctions ####
######################

# Multiple plot function
#
# ggplot objects can be passed in ..., or to plotlist (as a list of ggplot objects)
# - cols:   Number of columns in layout
# - layout: A matrix specifying the layout. If present, 'cols' is ignored.
#
# If the layout is something like matrix(c(1,2,3,3), nrow=2, byrow=TRUE),
# then plot 1 will go in the upper left, 2 will go in the upper right, and
# 3 will go all the way across the bottom.
#
multiplot <- function(..., plotlist = NULL, file, cols = 1, layout = NULL) {
  library(grid)
  
  # Make a list from the ... arguments and plotlist
  plots <- c(list(...), plotlist)
  
  numPlots = length(plots)
  
  # If layout is NULL, then use 'cols' to determine layout
  if (is.null(layout)) {
    # Make the panel
    # ncol: Number of columns of plots
    # nrow: Number of rows needed, calculated from # of cols
    layout <- matrix(seq(1, cols * ceiling(numPlots/cols)),
                     ncol = cols, nrow = ceiling(numPlots/cols))
  }
  
  if (numPlots==1) {
    print(plots[[1]])
    
  } else {
    # Set up the page
    grid.newpage()
    pushViewport(viewport(layout = grid.layout(nrow(layout), ncol(layout))))
    
    # Make each plot, in the correct location
    for (i in 1:numPlots) {
      # Get the i,j matrix positions of the regions that contain this subplot
      matchidx <- as.data.frame(which(layout == i, arr.ind = TRUE))
      
      print(plots[[i]], vp = viewport(layout.pos.row = matchidx$row,
                                      layout.pos.col = matchidx$col))
    }
  }
}

# Plot heatmap of grouped datasets
# data have colnames which corresponds to sample groupings
# white is NA or missing values
#
HeatMap <- function(data) {
  colors <- colorpanel(75, low="blue", mid="yellow", high="red")
  sidecol <- function(x){
    x <- as.numeric(as.factor(x))
    col <- rainbow(length(table(colnames(data))))
    sapply(x, function(x) col[x])
  }
  ColSideColors = sidecol(colnames(data))
  print(length(ColSideColors))
  heatmap.2(data,trace = "none", cexRow = 0.1, cexCol = 0.7, ColSideColors=ColSideColors, density.info = "none",
            col = colors, Colv = F, Rowv = T, keysize = 1, dendrogram = "row", labRow = F, labCol = F)
}

######################
##### Functions ######
######################

# Calculate the weighted average scores
weighted.average.score <- function(x, weight){
	weight[is.na(x)] <- NA
	norm.weight <- weight/sum(weight,na.rm=T)
	score<-sum(x*norm.weight, na.rm=T)
	return(score)
}

# Mixes haplotypes from cancer tissue and whole blood tissue to simulate different cancer proportions
# range is vector of strings for foreground simulation
# numSims is the number of simulations
# mixingHapFiles is a table of the haplotype files for mixing
# simulation.directory is the directory to store simulation data in
# return.amf.values determines whether the AMF standard curve should be generated
# markers.info provides the markers information such as loci and weight of each marker
#
HaplotypeMixing <- function(range, numSims=3, mixingHapFiles, simulation.directory, return.amf.values = F, markers.info) {
  
  MHL.simulatedStdValues <- matrix(nrow = numSims, ncol = length(range))
  colnames(MHL.simulatedStdValues) <- range
  if (return.amf.values) {
    AMF.simulatedStdValues <- matrix(nrow = numSims, ncol = length(range))
    colnames(AMF.simulatedStdValues) <- range
  }

  # Write possible markers region file
  markers.file<-paste0(simulation.directory, "/markers.possible.txt")
  write(gsub(":", "\t", rownames(markers.info)), file=markers.file, sep="\n")

  # Command to run a perl script to perform hapinfo file merging to subset of markers region
  merge.cmd.part2 <- sprintf(" | perl %s/mergeHaploInfo_bed.pl %s > ", bin_dir, markers.file)

  # make a list file for all of the mixture files that will be generated
  write.table(paste0(simulation.directory,"/ct_", c(1:numSims),".hapInfo.txt"), file=paste0(simulation.directory,"/list_hapInfo"), quote=F,col=F,row=F)
  
  # Begin iterating through hapinfo files
  for(f in range) {
    # identify the hapinfo files for the mixture level
    hap.ids.list <- which(mixingHapFiles$minFraction == as.numeric(f))
    # generate the mixture files
    for(i in c(1:numSims)){
      simulate.name <- paste0(simulation.directory, "/ct_", i, ".hapInfo.txt")
      merge.cmd <- paste0("zcat ", mixingHapFiles$foreground[ hap.ids.list[i] ], " ", mixingHapFiles$background[ hap.ids.list[i] ], merge.cmd.part2, simulate.name)
      try(system(merge.cmd))
    }
    
    # generate the mixture matrix
    mhl.matrix.cmd <- sprintf("perl %s/hapinfo2mhl.pl %s/list_hapInfo > %s/simulation.mhl.%s.matrix", bin_dir, simulation.directory, simulation.directory, f)
    amf.matrix.cmd <- sprintf("perl %s/hapinfo2amf.pl %s/list_hapInfo > %s/simulation.amf.%s.matrix", bin_dir, simulation.directory, simulation.directory, f)
    
    try(system(mhl.matrix.cmd)) # System call to hapinfo2mhl.pl perl script
    mhl <- read.table(paste0(simulation.directory,"/simulation.mhl.", f, ".matrix"),T,row=1)
  
    # compute the mixture scores
    MHL.simulatedStdValues[,f] <- as.vector(apply(mhl,2,function(x) weighted.average.score(x,markers.info$weight)))
    
    if (return.amf.values) {
      try(system(amf.matrix.cmd)) # System call to hapinfo2amf.pl perl script
      amf <- read.table(paste0(simulation.directory,"/simulation.amf.", f, ".matrix"),T,row=1) # subset to only the matching markers regions
      markers.rows <- match(rownames(markers.info), rownames(amf))
      amf <- amf[markers.rows,]
      AMF.simulatedStdValues[,f] <- as.vector(apply(amf,2, function(x) weighted.average.score(x,markers.info$weight)))
    }
  }
  
  res <- c()
  res$MHL.simulated <- MHL.simulatedStdValues
  
  if (return.amf.values){
    res$AMF.simulated <- AMF.simulatedStdValues
  }

  return(res)
}

# Make standard curves from mixed haplotype matrices
# range is vector of strings for foreground simulation
# numSims is the number of simulations
# mixingHapFiles is a table of the haplotype files for mixing
# simulation.directory is the directory to store simulation data in
# return.amf.values determines whether the AMF standard curve should be generated
# markers.info provides the markers information such as loci and weight of each marker
#
MakeStandardCurve <- function(range, numSims=3, simulation.directory, return.amf.values = F, markers.info) {
  
  MHL.simulatedStdValues <- matrix(nrow = numSims, ncol = length(range))
  colnames(MHL.simulatedStdValues) <- range
  if (return.amf.values) {
    AMF.simulatedStdValues <- matrix(nrow = numSims, ncol = length(range))
    colnames(AMF.simulatedStdValues) <- range
  }
  
  # Begin iterating through matrices
  for(f in range) {

    mhl <- read.table(gzfile(paste0(simulation.directory,"/simulation.mhl.", f, ".matrix.gz")),T,row=1)
    # compute the mixture scores
    MHL.simulatedStdValues[,f] <- as.vector(apply(mhl,2,function(x) weighted.average.score(x,markers.info$weight)))
    
    if (return.amf.values) {
      amf <- read.table(gzfile(paste0(simulation.directory,"/simulation.amf.", f, ".matrix.gz")),T,row=1) # subset to only the matching markers regions
      markers.rows <- match(rownames(markers.info), rownames(amf))
      amf <- amf[markers.rows,]
      AMF.simulatedStdValues[,f] <- as.vector(apply(amf,2, function(x) weighted.average.score(x,markers.info$weight)))
    }
  }
  
  res <- c()
  res$MHL.simulated <- MHL.simulatedStdValues
  
  if (return.amf.values){
    res$AMF.simulated <- AMF.simulatedStdValues
  }
  
  return(res)
}

# Estimate cancer fraction from standard curve
CancerFractionEstimate <- function(mhl.vector, std.curve, range) {	
  std.curve.df <- data.frame(value = as.vector(std.curve), Group = rep(as.numeric(range), each = nrow(std.curve)))
  lin.interp.fun <- approxfun(apply(std.curve, 2, function(x) mean(x, na.rm = T)), as.numeric(range))	
  cancer.frac.est <- data.frame(mhl.average = mhl.vector, fitted.values = lin.interp.fun(mhl.vector), groups = names(mhl.vector))	
  return(cancer.frac.est)
}

# Function for row-wise t-testing. Right now only tests if tumor.samples > normal.samples
t.test.markers <- function(data, tumor.samples, normal.samples) {
  p <- apply(data, 1, function(x) {
    tumor.mhl <- na.omit(x[tumor.samples])
    normal.mhl <- na.omit(x[normal.samples])
    # Ensure we have enough non-missing values to do a t-test
    if (length(tumor.mhl) > 2 && length(normal.mhl) > 2) {
      res <- t.test(tumor.mhl, normal.mhl, alternative = "greater", var.equal = T)
      return(res$p.value)
    } else {
      return(1.0)
    }
  })
  return(p)
}

# Returns the mean expression of samples in data
mean.exp <- function(data, samples) {
  e <- apply(data, 1, function(x) mean(na.omit(x[samples])))
  e[is.na(e)] <- 0
  return(e)
}


# Returns the markers identified from the tumor samples and normal samples
identify.tumor.markers <- function(data, tumor.samples, normal.samples, FDR=1e-5, min.diff=0.2){
  ncp.compare.p <- t.test.markers(data, tumor.samples, normal.samples) # one sided t test
  cancer.exp <- mean.exp(data, tumor.samples) # mean of tumor samples
  ncp.exp<-mean.exp(data, normal.samples) # mean normal plasma levels
  ncp.compare.fdr <- p.adjust(ncp.compare.p, method = "BH") # multiple testing correction
  keep.rows <- which((ncp.compare.fdr < FDR) & (cancer.exp - ncp.exp > min.diff))
  markers<-data.frame(q.value=ncp.compare.fdr[keep.rows], cancer.exp=cancer.exp[keep.rows], normal.exp=ncp.exp[keep.rows])
  markers$weight <- markers$cancer.exp / (markers$cancer.exp+markers$normal.exp)
  return(markers)
}

######################
##### Inputs    ######
######################

load(rdata.file)

# Provide paths to simulation files

simulation_CCT_dir <- paste0(result_dir, "/CCT_mixture")
simulation_LCT_dir <- paste0(result_dir, "/LCT_mixture")

try(system(sprintf("mkdir -p %s", simulation_CCT_dir)))
try(system(sprintf("mkdir -p %s", simulation_LCT_dir)))

colon.markers.file.name <- paste0(result_dir, "/colon_cancer_markers.txt")
lung.markers.file.name <- paste0(result_dir, "/lung_cancer_markers.txt")

# False discovery rate
FDR <- 1e-3
# Filter for plasma missing values
max.plasma.missing <- 0.3
# Filter fold change of cancer over normal
min.diff <- 0.3

# number of simulations
num.sims <- 20
# range for standard curve (must match hapinfo list file)
ct.range <- c("0.20", "0.10", "0.05", "0.01", "0.00")


rrbs.dat <- orig.data$rrbs.dat
rrbs.meta <- orig.data$rrbs.meta

# Subset lung cancer tissues
lct.idx <- which(rrbs.meta$Type == 'Tissue' & rrbs.meta$Tissue == 'Lung')
print("Training lung cancer tissue samples")
print(colnames(rrbs.dat)[lct.idx])
cct.idx <- which(rrbs.meta$Type == 'Tissue' & rrbs.meta$Tissue == 'Colon')
print("Training colon cancer tissue samples")
print(colnames(rrbs.dat)[cct.idx])

# Subset training samples
training.ncp.samples <- read.table(ncp_train_list, header=F, stringsAsFactors=F)$V1 
training.ncp.samples <- make.names(training.ncp.samples)
training.ncp.idx <- which( rrbs.meta$Sample %in% training.ncp.samples )
print("Training normal plasma samples")
print(colnames(rrbs.dat)[training.ncp.idx])

# Colon cancer analysis
colon.markers<-identify.tumor.markers(rrbs.dat, cct.idx, training.ncp.idx, FDR, min.diff) # function to create the markers set
write.table(colon.markers, file = colon.markers.file.name, sep = "\t", quote=F)
print(paste("Number of colon tumor markers: ", nrow(colon.markers)))

# Lung cancer analysis
lung.markers<-identify.tumor.markers(rrbs.dat, lct.idx, training.ncp.idx, FDR, min.diff) # function to create the markers set
write.table(lung.markers, file = lung.markers.file.name, sep = "\t", quote=F)
print(paste("Number of lung tumor markers: ", nrow(lung.markers)))

print(paste("False Discovery Rate: ", FDR))
print(paste("Difference minimum threshold: ", min.diff))

######################
##### Simulation######
######################

# Perform haplotype mixing. Note: this step requires large input files, so we use the prepared matrices instead.
#ref_CCT_haploInfo <- "cct.hapinfo.list20"
#ref_LCT_haploInfo <- "lct.hapinfo.list20"
#cct.mixingHapFiles <- read.table(ref_CCT_haploInfo, header=T)
#lct.mixingHapFiles <- read.table(ref_LCT_haploInfo, header=T)
#cct.mixing.results <- HaplotypeMixing(range=ct.range, numSims=num.sims, cct.mixingHapFiles, simulation.directory=simulation_CCT_dir, return.amf.values=T, colon.markers)
#lct.mixing.results <- HaplotypeMixing(range=ct.range, numSims=num.sims, lct.mixingHapFiles, simulation.directory=simulation_LCT_dir, return.amf.values=T, lung.markers)


# Compute the standard curves from matrices of mixed data
cct.mixing.results <- MakeStandardCurve(range=ct.range, numSims=num.sims, simulation.directory=simulation_CCT_dir, return.amf.values=T, colon.markers)
lct.mixing.results <- MakeStandardCurve(range=ct.range, numSims=num.sims, simulation.directory=simulation_LCT_dir, return.amf.values=T, lung.markers)

MHL.simulatedStdValues.colon <- cct.mixing.results$MHL.simulated
MHL.simulatedStdValues.lung <- lct.mixing.results$MHL.simulated

# Calculate the R-square
colon.curve.df <- data.frame(y = as.vector(MHL.simulatedStdValues.colon), x = rep(as.numeric(colnames(MHL.simulatedStdValues.colon)), each = nrow(MHL.simulatedStdValues.colon)))
lung.curve.df <- data.frame(y = as.vector(MHL.simulatedStdValues.lung), x = rep(as.numeric(colnames(MHL.simulatedStdValues.lung)), each = nrow(MHL.simulatedStdValues.lung)))

print(paste0("Adjusted r^2 for colon cancer standard curve for MHL: ", summary(lm(y ~ x , data=colon.curve.df))$adj.r.squared))
print(paste0("Adjusted r^2 for lung cancer standard curve for MHL: ", summary(lm(y ~ x , data=lung.curve.df))$adj.r.squared))


AMF.simulatedStdValues.colon <- cct.mixing.results$AMF.simulated
AMF.simulatedStdValues.lung <- lct.mixing.results$AMF.simulated

# Calculate the R-square
colon.curve.df <- data.frame(y = as.vector(AMF.simulatedStdValues.colon), x = rep(as.numeric(colnames(AMF.simulatedStdValues.colon)), each = nrow(AMF.simulatedStdValues.colon)))
lung.curve.df <- data.frame(y = as.vector(AMF.simulatedStdValues.lung), x = rep(as.numeric(colnames(AMF.simulatedStdValues.lung)), each = nrow(AMF.simulatedStdValues.lung)))

print(paste0("Adjusted r^2 for colon cancer standard curve for AMF: ", summary(lm(y ~ x , data=colon.curve.df))$adj.r.squared))
print(paste0("Adjusted r^2 for lung cancer standard curve for AMF: ", summary(lm(y ~ x , data=lung.curve.df))$adj.r.squared))


######################
##### Tumor load######
######################

# remove training normal plasma data
rrbs.dat <- rrbs.dat[,-training.ncp.idx]
dim(rrbs.dat)
rrbs.meta <- rrbs.meta[-training.ncp.idx,]
dim(rrbs.meta)

# Identify the test data sets
# Make sure that duplicate data from different batches are not used
lung.plasma <- which(rrbs.meta$Type == 'Plasma' & rrbs.meta$Tissue == 'Lung')
colon.plasma <- which(rrbs.meta$Type == 'Plasma' & rrbs.meta$Tissue == 'Colon')
normal.plasma <- which(rrbs.meta$Type == 'Plasma' & rrbs.meta$Tissue == 'Normal')
plasma.samples<-c(lung.plasma, colon.plasma, normal.plasma)
names(plasma.samples) <- c( rep("LCP", length(lung.plasma)), rep("CCP", length(colon.plasma)), rep("NCP", length(normal.plasma)) )

# Estimate the tumor load
colon.markers.data <- rrbs.dat[na.omit(match(rownames(colon.markers), rownames(rrbs.dat))), plasma.samples]
colon.scores <- apply(colon.markers.data, 2, function(x) weighted.average.score(x,colon.markers$weight))
colon.results <- CancerFractionEstimate(colon.scores, MHL.simulatedStdValues.colon, ct.range)
colon.results$groups <- names(plasma.samples)

# Estimate the tumor load
lung.markers.data <- rrbs.dat[na.omit(match(rownames(lung.markers), rownames(rrbs.dat))), plasma.samples]
lung.scores <- apply(lung.markers.data, 2, function(x) weighted.average.score(x,lung.markers$weight))
lung.results<-CancerFractionEstimate(lung.scores, MHL.simulatedStdValues.lung, ct.range)
lung.results$groups <- names(plasma.samples)

colon.mhl.avg <- apply(MHL.simulatedStdValues.colon,2,function(x)mean(x,na.rm=T))
colon.mhl.sem <- apply(MHL.simulatedStdValues.colon,2,function(x)sd(x,na.rm=T)/sqrt(num.sims))

lung.mhl.avg <- apply(MHL.simulatedStdValues.lung,2,function(x)mean(x,na.rm=T))
lung.mhl.sem <- apply(MHL.simulatedStdValues.lung,2,function(x)sd(x,na.rm=T)/sqrt(num.sims))


mhl.std.curves <- data.frame(avg = c(colon.mhl.avg, lung.mhl.avg), sem = c(colon.mhl.sem, lung.mhl.sem), type = c( rep("CCT", length(ct.range)), rep("LCT", length(ct.range)) ), proportion = rep(as.numeric(ct.range), 2))
write.table(mhl.std.curves, file = paste0(result_dir, "/standard_curve_values_mhl.txt"), quote = F)

colon.amf.avg <- apply(AMF.simulatedStdValues.colon,2,function(x)mean(x,na.rm=T))
colon.amf.sem <- apply(AMF.simulatedStdValues.colon,2,function(x)sd(x,na.rm=T)/sqrt(num.sims))

lung.amf.avg <- apply(AMF.simulatedStdValues.lung,2,function(x)mean(x,na.rm=T))
lung.amf.sem <- apply(AMF.simulatedStdValues.lung,2,function(x)sd(x,na.rm=T)/sqrt(num.sims))

amf.std.curves <- data.frame(avg = c(colon.amf.avg, lung.amf.avg), sem = c(colon.amf.sem, lung.amf.sem), type = c( rep("CCT", length(ct.range)), rep("LCT", length(ct.range)) ), proportion = rep(as.numeric(ct.range), 2))
write.table(amf.std.curves, file = paste0(result_dir, "/standard_curve_values_amf.txt"), quote = F)


# Print fraction of plasma samples out of range of std curve
print("Number of samples out of range or too low of standard curve:")
print(sum(apply(lung.results, 1, anyNA))/nrow(lung.results))
print(sum(apply(colon.results, 1, anyNA))/nrow(colon.results))

# if the NA values are below the range, then set tumor load to 0.
colon.results$fitted.values[which(colon.results$mhl.average < min(colon.mhl.avg))] = 0
lung.results$fitted.values[which(lung.results$mhl.average < min(lung.mhl.avg))] = 0

# test for significance of difference
t.test(colon.results$fitted.values[which(colon.results$groups=="CCP")], colon.results$fitted.values[which(colon.results$groups=="NCP")], alternative="greater")
t.test(lung.results$fitted.values[which(lung.results$groups=="LCP")], lung.results$fitted.values[which(lung.results$groups=="NCP")], alternative="greater")

print("Boxplot summary of fitted values for colon markers, CCP:")
print(summary(colon.results$fitted.values[which(colon.results$groups=="CCP")]))
print("Boxplot summary of fitted values for colon markers, NCP:")
print(summary(colon.results$fitted.values[which(colon.results$groups=="NCP")]))
print("Boxplot summary of fitted values for lung markers, LCP:")
print(summary(lung.results$fitted.values[which(lung.results$groups=="LCP")]))
print("Boxplot summary of fitted values for lung markers, NCP:")
print(summary(lung.results$fitted.values[which(lung.results$groups=="NCP")]))


# match marker regions to subset
colon.marker.idx <- na.omit(match(rownames(colon.markers), rownames(rrbs.dat)))
lung.marker.idx <- na.omit(match(rownames(lung.markers), rownames(rrbs.dat)))

# generate the matrix for heatmap
cct.matrix <- as.matrix(rrbs.dat[colon.marker.idx, c(normal.plasma, colon.plasma, cct.idx)])
colnames(cct.matrix) <- paste0(rrbs.meta$Cancer.Origin[c(normal.plasma, colon.plasma, cct.idx)],".",rrbs.meta$Type[c(normal.plasma, colon.plasma, cct.idx)])
table(colnames(cct.matrix))
dim(cct.matrix)

# generate the matrix for heatmap
lct.matrix <- as.matrix(rrbs.dat[lung.marker.idx, c(normal.plasma, lung.plasma, lct.idx)])
colnames(lct.matrix) <- paste0(rrbs.meta$Cancer.Origin[c(normal.plasma, lung.plasma, lct.idx)],".", rrbs.meta$Type[c(normal.plasma, lung.plasma, lct.idx)])
table(colnames(lct.matrix))
dim(lct.matrix)

# Make heatmaps
pdf(paste0(result_dir, "/heatmap.pdf"), width = 12, height = 15)
HeatMap(cct.matrix)
HeatMap(lct.matrix)
dev.off()

# generate the matrix for boxplots
cct.matrix.mean <- data.frame(NCP=apply(rrbs.dat[colon.marker.idx, normal.plasma], 1, function(x) mean(x, na.rm=T)),
			 CCP=apply(rrbs.dat[colon.marker.idx, colon.plasma], 1, function(x) mean(x, na.rm=T)),
			 CCT=apply(rrbs.dat[colon.marker.idx, cct.idx], 1, function(x) mean(x, na.rm=T)))
# calculate the significance
t.test(cct.matrix.mean$CCP, cct.matrix.mean$NCP, alternative = "greater", var.equal = T)
# converting to data frame for ggplot
cct.df <- as.data.frame.table(as.matrix(cct.matrix.mean))
cct.df$Var1 <- NULL
cct.df <- cct.df[complete.cases(cct.df),]

# generate the matrix for boxplots
lct.matrix.mean <- data.frame(NCP=apply(rrbs.dat[lung.marker.idx, normal.plasma], 1, function(x) mean(x, na.rm=T)),
        LCP=apply(rrbs.dat[lung.marker.idx, lung.plasma], 1, function(x) mean(x, na.rm=T)),
        LCT=apply(rrbs.dat[lung.marker.idx, lct.idx], 1, function(x) mean(x, na.rm=T)))
# calculate the significance
t.test(lct.matrix.mean$LCP, lct.matrix.mean$NCP, alternative = "greater", var.equal = T)
# converting to data frame for ggplot
lct.df <- as.data.frame.table(as.matrix(lct.matrix.mean))
lct.df$Var1 <- NULL
lct.df <- lct.df[complete.cases(lct.df),]

print("Size of markers matrix for colon cancer:")
print(dim(cct.matrix.mean))
print("Size of markers matrix for lung cancer:")
print(dim(lct.matrix.mean))
print("Summary of markers matrix for colon cancer:")
print(summary(cct.matrix.mean))
print("Summary of markers matrix for lung cancer:")
print(summary(lct.matrix.mean))

# Make boxplots
pdf(paste0(result_dir, "/mhl_boxplot.pdf"), width = 3.4, height = 2)
p1 <- ggplot(cct.df, aes(x = Var2, y = Freq)) + ggtitle("Colon cancer markers") +
  geom_boxplot(lwd = 0.3, outlier.colour=NA, outlier.size=1) + theme_classic() + guides(fill = F) + ylab("Average MHL") + coord_cartesian(ylim = c(0,0.25)) +
  theme(axis.title.x=element_blank(), axis.text.x = element_text(size = 7), axis.text.y = element_text(size = 7), 
        axis.title.y = element_text(size = 7), panel.border = element_rect(fill = NA), axis.line.x = element_blank(), axis.line.y = element_blank(),
        axis.ticks = element_line(color = "black", size = 0.3), plot.title = element_text(size = 7))
p2 <- ggplot(cct.df, aes(x = Var2, y = Freq)) + ggtitle("Colon cancer markers") + 
  geom_boxplot(lwd = 0.3, outlier.colour=NA, outlier.size=1) + theme_classic() + guides(fill = F) + ylab("Average MHL") + coord_cartesian(ylim = c(0,1.00)) +
  theme(axis.title.x=element_blank(), axis.text.x = element_text(size = 7), axis.text.y = element_text(size = 7), 
        axis.title.y = element_text(size = 7), panel.border = element_rect(fill = NA), axis.line.x = element_blank(), axis.line.y = element_blank(),
        axis.ticks = element_line(color = "black", size = 0.3), plot.title = element_text(size = 7))


p3<-ggplot(lct.df, aes(x = Var2, y = Freq)) + ggtitle("Lung cancer markers") + 
  geom_boxplot(lwd = 0.3, outlier.colour=NA, outlier.size=1) + theme_classic() + guides(fill = F) + ylab("Average MHL") + coord_cartesian(ylim = c(0,0.25)) +
  theme(axis.title.x=element_blank(), axis.text.x = element_text(size = 7), axis.text.y = element_text(size = 10),
        axis.title.y = element_text(size = 7), panel.border = element_rect(fill = NA), axis.line.x = element_blank(), axis.line.y = element_blank(),
        axis.ticks = element_line(color = "black", size = 0.3), plot.title = element_text(size = 7))
p4<-ggplot(lct.df, aes(x = Var2, y = Freq)) + ggtitle("Lung cancer markers") + 
  geom_boxplot(lwd = 0.3, outlier.colour=NA, outlier.size=1) + theme_classic() + guides(fill = F) + ylab("Average MHL") + coord_cartesian(ylim = c(0,1.00)) +
  theme(axis.title.x=element_blank(), axis.text.x = element_text(size = 7), axis.text.y = element_text(size = 7),
        axis.title.y = element_text(size = 7), panel.border = element_rect(fill = NA), axis.line.x = element_blank(), axis.line.y = element_blank(),
        axis.ticks = element_line(color = "black", size = 0.3), plot.title = element_text(size = 7))
multiplot(p2, p4, cols = 2)
dev.off()

# Make the standard curves
pdf(paste0(result_dir, "/standard_curve.pdf"), width = 2.0 , height = 2.5, useDingbats = FALSE)
p1 <- ggplot(mhl.std.curves, aes(x=proportion, y=avg, group=type, color=type)) + ylab("Average MHL") + xlab("Proportion of cancer component") +  
  geom_line(lwd = 0.3) +
  geom_errorbar(lwd = 0.3, aes(ymin=avg - sem * sqrt(20), ymax=avg+sem * sqrt(20)), width = 0.01, color = "black") +
  theme_classic() + guides(fill = FALSE) +
  theme(axis.title.x = element_text(size=7), axis.text.x = element_text(size = 5), axis.text.y = element_text(size = 5),
        axis.title.y = element_text(size=7), plot.title = element_text(size = 5), axis.line.x = element_line(color="black", size = 0.3), axis.line.y = element_line(color="black", size = 0.3),
        axis.ticks = element_line(color="black", size=0.3), legend.title=element_blank(), legend.text = element_text(size=5), legend.position = "bottom") +
  scale_x_reverse( lim=c(0.22,-0.02)) +
  ylim(0,0.20)
print(p1)
dev.off()



# Make tumor load boxplots
pdf(paste0(result_dir, "/estimated_proportions.pdf"), width = 2.0, height = 2.5, useDingbats=FALSE)
p1 <- ggplot(colon.results[which(colon.results$groups == "CCP" | colon.results$groups == "NCP"), ], aes(x = groups, y = fitted.values*100, fill = groups))  + ggtitle("Colon tumor markers") +
  geom_boxplot(lwd = 0.3, outlier.colour=NA) + theme_classic() + scale_fill_manual(values = c("salmon", "aquamarine3")) + guides(fill = F) +
  geom_jitter(shape=16, size = 0.8, position=position_jitter(0.2)) +
  theme(axis.title.x=element_blank(), axis.text.x = element_text(size = 7), axis.text.y = element_text(size = 7),
        axis.title.y = element_blank(), plot.title = element_text(size = 7), axis.line.x = element_line(color="black", size = 0.3), axis.line.y = element_line(color="black", size = 0.3),
        axis.ticks = element_line(color="black", size=0.3)) + 
  ylim(0,20)

p2 <- ggplot(lung.results[which(lung.results$groups == "LCP" | lung.results$groups == "NCP"), ], aes(x = groups, y = fitted.values*100, fill = groups))  + ggtitle("Lung tumor markers") + 
  geom_boxplot(lwd = 0.3, outlier.colour=NA) + theme_classic() + scale_fill_manual(values = c("salmon", "aquamarine3")) + guides(fill = F) +
  geom_jitter(shape=16, size = 0.8, position=position_jitter(0.2)) +
  theme(axis.title.x=element_blank(), axis.text.x = element_text(size = 7), axis.text.y = element_text(size = 7),
        axis.title.y = element_blank(), plot.title = element_text(size = 7), axis.line.x = element_line(color="black", size = 0.3), axis.line.y = element_line(color="black", size = 0.3),
        axis.ticks = element_line(color="black", size=0.3)) + 
  ylim(0,10)
multiplot(p1, p2, cols = 2)
dev.off()

save.image(paste0(result_dir, "/Tumor_load_estimate.RData"))
