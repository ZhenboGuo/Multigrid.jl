export MGsetup,transposeHierarchy,adjustMemoryForNumRHS

function MGsetup(Msh::RegularMesh,AT::SparseMatrixCSC,param::MGparam,rhsType::DataType = Float64,nrhs::Int64 = 1,verbose::Bool=false)
Ps = Array(SparseMatrixCSC,param.levels-1);
Rs = Array(SparseMatrixCSC,param.levels-1);
As = Array(SparseMatrixCSC,param.levels);
n = Msh.n + 1; # n here is the number of NODES!!!
N = prod(n);
As[1] = AT;
relaxPrecs = Array(SparseMatrixCSC,param.levels-1);
Cop = nnz(AT);
for l = 1:(param.levels-1)
	if verbose
		tic()
	end
    AT = As[l];
    if param.relaxType=="Jac" || param.relaxType=="Jac-GMRES"
		d = param.relaxParam./diag(AT);
		relaxPrecs[l] = spdiagm(d);#d;# here we need to take the conjugate for the SpMatVec, but we give At instead of A so it cancels
	elseif param.relaxType=="SPAI"
		relaxPrecs[l] = spdiagm(param.relaxParam*getSPAIprec(AT)); # here we need to take the conjugate for the SpMatVec, but we give At instead of A so it cancels
	else
		error("Unknown relaxation type !!!!");
	end
	
	(P,nc) = getFWInterp(n);
	if (size(P,1)==size(P,2))
		if verbose; println(string("Stopped Coarsening at level ",l)); end
		param.levels = l;
		As = As[1:l];
		Ps = Ps[1:l-1];
		Rs = Rs[1:l-1];
		relaxPrecs = relaxPrecs[1:l-1];
		break;
	else
		Rs[l] = P; # this is becasue we hold the transpose of the matrices and P = R' anyway here....
		Ps[l] = P';
		Act = Ps[l]*AT*Rs[l];
		As[l+1] = Act;
		Cop = Cop + nnz(Act);
		#fprintf('setup level %3d, dim:%3dx%3d, nnz:%3d\n',nlevels+1,nc(1),nc(2),nnz(Ac))
		
		if verbose; println("MG setup: ",n," took:",toq()); end;
		n = nc;
		N = prod(nc);
	end
end
if verbose 
	tic()
	println("MG Setup: Operator complexity = ",Cop/nnz(As[1]));
end
if param.coarseSolveType == "MUMPS"
	param.LU = factorMUMPS(As[end]',0,0);
else
	param.LU = lufact(As[end]');
end
param.doTranspose = 0;
if verbose 
	println("MG setup coarsest: ",n,", done LU in ",toq());
end
param.As = As;
param.Ps = Ps;
param.Rs = Rs;
param.relaxPrecs = relaxPrecs;
param = adjustMemoryForNumRHS(param,rhsType,nrhs,verbose);
return;
end

function adjustMemoryForNumRHS(param::MGparam,rhsType::DataType = Float64,nrhs::Int64 = 1,verbose::Bool=false)

if length(param.memCycle) > 0
	if size(param.memCycle[1].x,2) == nrhs
		return param;
	end
end

if nrhs==1
	memRelax = Array(FGMRESmem,param.levels-1);
	memKcycle = Array(FGMRESmem,param.levels-2);
else
	memRelax = Array(BlockFGMRESmem,param.levels-1);
	memKcycle = Array(BlockFGMRESmem,param.levels-2); 
end	
memCycle = Array(CYCLEmem,param.levels);

param.memRelax  = memRelax;
param.memKcycle = memKcycle;
param.memCycle  = memCycle;

N = size(param.As[1],2); 

for l = 1:(param.levels-1)
	N = size(param.As[l],2);
	memCycle[l] = getCYCLEmem(N,nrhs,rhsType,true);
	if param.relaxType=="Jac-GMRES"
		maxRelax = max(param.relaxPre(l),param.relaxPost(l));
		if nrhs == 1
			memRelax[l] = getFGMRESmem(N,false,rhsType,maxRelax);
		else
			memRelax[l] = getBlockFGMRESmem(N,nrhs,false,rhsType,maxRelax);
		end
	end
	
	if l > 1 && param.cycleType=='K'
		if nrhs == 1
			memKcycle[l-1] = getFGMRESmem(N,true,rhsType,2);
		else
			memKcycle[l-1] = getBlockFGMRESmem(N,nrhs,true,rhsType,2);
		end
	end
end
memCycle[end] = getCYCLEmem(size(param.As[end],2),nrhs,rhsType,false); # no need for residual on the coarsest level...
param.memRelax = memRelax;
param.memKcycle = memKcycle;
param.memCycle = memCycle;
return param;
end



function transposeHierarchy(param::MGparam,verbose::Bool=false)
# This is a shortened MG setup. It assumes that a setup was previously applied 
# to a matrix A1 (is param.As[1]) with similar properties as A. It keeps the same Ps and memory allocations.
# It assumes that A1 is the same as A in terms of the underlying mesh, and the type (complex or real). 

param.As[1] = param.As[1]';

for l = 1:(param.levels-1)
	if verbose
		println("MG re-setup level: ",l);
		tic()
	end

    if param.relaxType=="Jac" || param.relaxType=="Jac-GMRES" || param.relaxType=="SPAI"
		param.relaxPrecs[l] = conj(param.relaxPrecs[l]);
	else
		error("Not supported");
	end
	param.Rs[l] = param.Ps[l]';
	param.Ps[l] = param.Rs[l]';
	param.As[l+1]  = param.As[l+1]';
end
if verbose 
	tic()
	println("MG setup: coarsest: ",n);
end
if param.coarseSolveType == "MUMPS"
	# when applying mumps, no need to transpose the matrix
	if param.doTranspose == 1;
		param.doTranspose = 0;
	elseif param.doTranspose == 0;
		param.doTranspose = 1;
	else
		error("Is there another option for doTranspose????");
	end
else
	destroyCoarsestLU(param);
	param.LU = lufact(param.As[end]');
end
if verbose 
	println("MG setup: done LU");
	toc();
end
return;
end

# Bilinear "Full Weighting" prolongation
function getFWInterp(n::Array{Int64,1})
# n here is the number of NODES!!!
(P1,nc1) = get1DFWInterp(n[1]);
(P2,nc2) = get1DFWInterp(n[2]);
if length(n)==3
	(P3,nc3) = get1DFWInterp(n[3]);
end
if length(n)==2
	P = kron(P2,P1);
	nc = [nc1,nc2];
else
	P = kron(P3,kron(P2,P1));
	nc = [nc1,nc2,nc3];
end
return P,nc
end

function get1DFWInterp(n::Int64)
# n here is the number of NODES!!!
oddDim = mod(n,2);
if n > 32
	minusHalf = 0.5*ones(n-1);
	P = spdiagm((minusHalf,ones(n),minusHalf),[-1,0,1],n,n);
    if oddDim == 1
        P = P[:,1:2:end];
    else
        P = P[:,[1:2:end;end]];
        P[end-1:end,end-1:end] = speye(2);
#         P = P[:,1:2:end];
#         P[end,end-1:end] = [-0.5,1.5];
    end
else
    P = speye(n);
end
nc = size(P,2);
return P,nc
end


function getSPAIprec(A::SparseMatrixCSC)
s = vec(sum(real(A).^2,2) + sum(imag(A).^2,2));
Q = conj(diag(A))./s;
end