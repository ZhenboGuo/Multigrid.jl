export solveMG,solveGMRES_MG,solveBiCGSTAB_MG,solveCG_MG

function solveMG(param::MGparam,b::ArrayTypes,x::ArrayTypes,verbose::Bool)
param = adjustMemoryForNumRHS(param,eltype(b),size(b,2));
tol = param.relativeTol;
numCores = param.numCores;
const oneType = one(eltype(b));
const zeroType = zero(eltype(b));
maxIter = param.maxOuterIter;
A = param.As[1];
r = param.memCycle[1].r;
oneType = one(eltype(b));
r[:] = b;

if vecnorm(x)==0	
    res = vecnorm(b);
    res_init = res;
else
	SpMatMul(-oneType,A,x,oneType,r,numCores)#  r -= A'*x;
    res = vecnorm(r);
    res_init = res;
end

for count = 1:maxIter
	x = recursiveCycle(param,b,x,1);
	SpMatMul(-oneType,A,x,zeroType,r,numCores); #  r = -A'*x;
	addVectors(oneType,b,r); # r = r + b;
	res_prev = res;
	res = vecnorm(r);
	if verbose
		println(string("Cycle ",count," done with relres: ",res/res_init,". Convergence factor: ",res/res_prev));
	end
	if res/res_init < tol 
		break;
	end
end
return x,param;
end
####################################################################################################################

function getMultigridPreconditioner(param::MGparam,B::ArrayTypes,forTransposed::Bool=false,verbose::Bool=false)
	TYPE = eltype(B);
	n = size(B,1)
	nrhs = size(B,2);
	if hierarchyExists(param)==false
		println("You have to do a setup first.")
	end
	param = adjustMemoryForNumRHS(param,TYPE,nrhs);
	if (forTransposed != param.doTranspose)
		transposeHierarchy(param);
	end
	z = param.memCycle[1].x;
	MMG(b) = (z[:] = 0.0; recursiveCycle(param,b,z,1));
	# MMG(b) = (z = copy(b);z[:] = 0.0; recursiveCycle(param,b,z,1));
	
	return MMG;
end

function getAfun(AT::SparseMatrixCSC,Az::Array,numCores::Int64)
	function Afun(z::ArrayTypes)
		SpMatMul(AT,z,Az,numCores);
		return Az;
	end
	return Afun;
end


function solveBiCGSTAB_MG(AT::SparseCSCTypes,param::MGparam,b::ArrayTypes,x0::ArrayTypes,verbose::Bool = false)
	return solveBiCGSTAB_MG(getAfun(AT,zeros(eltype(b),size(b)),param.numCores),param,b,x0,verbose);
end

function solveBiCGSTAB_MG(Afun::Function,param::MGparam,b::ArrayTypes,x0::ArrayTypes,verbose::Bool = false)
MMG = getMultigridPreconditioner(param,b,false,verbose);
out= -2;
if verbose
	out = 1;
end
if size(b,2)==1
	b = vec(b);
	x, flag,rnorm,iter = KrylovMethods.bicgstb(Afun,b,tol = param.relativeTol,maxIter = param.maxOuterIter,M1 = MMG,M2 = identity, x = x0,out=out);
else
	x, flag,rnorm,iter = KrylovMethods.blockBiCGSTB(Afun,b,tol = param.relativeTol,maxIter = param.maxOuterIter,M1 = MMG,M2 = identity, x = x0,out=out);
end
return x,param,iter;
end

function solveCG_MG(AT::SparseCSCTypes,param::MGparam,b::ArrayTypes,x0::ArrayTypes,verbose::Bool = false) 
	return solveCG_MG(getAfun(AT,zeros(eltype(b),size(b)),param.numCores),param,b,x0,verbose);
end

function solveCG_MG(Afun::Function,param::MGparam,b::ArrayTypes,x0::ArrayTypes,verbose::Bool = false)
MMG = getMultigridPreconditioner(param,b,false,verbose);
out = -2;
if verbose
	out = 1;
end
if size(b,2)==1
	b = vec(b);
	x, flag,rnorm,iter = KrylovMethods.cg(Afun,b,tol = param.relativeTol,maxIter = param.maxOuterIter,M = MMG, x = x0,out=out);
else
	x, flag,rnorm,iter = KrylovMethods.blockCG(Afun,b,tol = param.relativeTol,maxIter = param.maxOuterIter,M = MMG, X = x0,out=out);
end
return x,param,iter;
end

####################################################################################################################
function solveGMRES_MG(AT::SparseCSCTypes,param::MGparam,b::ArrayTypes,x0::ArrayTypes,verbose::Bool = false,inner=3)
function ATfun(alpha,z::ArrayTypes,beta,w::ArrayTypes)
	w = SpMatMul(alpha,AT,z,beta,w,param.numCores);
	return w;
end
return solveGMRES_MG(ATfun,param,b,x0,verbose,inner);
end

function solveGMRES_MG(mulAT::Function,param::MGparam,b::ArrayTypes,x0::ArrayTypes,verbose::Bool = false,inner=3)
param = adjustMemoryForNumRHS(param,eltype(b),size(b,2));
outerIter = param.maxOuterIter;
nrhs = size(b,2);
N 	 = size(b,1);
rhsType = eltype(b);

flexible = true; # there are tons of reasons here why this mey be true. So, assuming this is true. 
# TODO: fix to have an expression for flexible.
if nrhs == 1
	GMRES_MEM = getFGMRESmem(N,flexible,rhsType,inner);
else
	GMRES_MEM = getBlockFGMRESmem(N,nrhs,flexible,rhsType,inner);
end

numCores = param.numCores;

oneType = one(eltype(b));

r = copy(b);
MMG(x,y) = (y[:] = 0.0; recursiveCycle(param,x,y,1));

x = param.memCycle[1].x;

if length(x0)==0
	x[:] = 0.0;
	res = vecnorm(b);
	res_init = res;
else
	x[:] = x0;
	if vecnorm(x)==0	
		res = vecnorm(b);
		res_init = res;
	else
		mulAT(-oneType,x,oneType,r) # r -= HT'*x;
		res = vecnorm(r);
		res_init = res;
	end
end
tol = copy(param.relativeTol);
tol *= res_init;
num_iter = 0; 
for k=1:outerIter
	if verbose
		println("Outer iter ",k-1,":");
	end
	if nrhs==1
		(x,rnorms) = FGMRES(mulAT,r,x,inner,MMG,tol,verbose,true,numCores,GMRES_MEM);
	else
		(x,rnorms) = BlockFGMRES_relaxation(mulAT,r,x,inner,MMG,tol,verbose,true,numCores,GMRES_MEM);
	end
	num_iter = num_iter+1;
	if verbose
		println(rnorms[end]/res_init)
		println("--------------------------------")
	end
	if rnorms[end] < tol
		break;
	end
	r[:] = b;
	mulAT(-oneType,x,oneType,r); #  r -= HT'*x;
end
return x,param,num_iter;
end
